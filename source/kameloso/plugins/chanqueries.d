/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each repeat it themselves.
 +
 +  It is qualified as a service, so while it is not technically mandatory, it
 +  is highly recommended if you plan on mixing in
 +  `kameloso.plugins.common.ChannelAwareness` in your plugins.
 +/
module kameloso.plugins.chanqueries;

version(WithPlugins):
version(WithChanQueriesService):

/// Whether or not to do channel queries for non-home channels.
//version = OmniscientQueries;

private:

import kameloso.plugins.common;
import dialect.defs;

import std.typecons : No, Yes;


// ChannelState
/++
 +  Different states which tracked channels can be in.
 +
 +  This is to keep track of which channels have been queried, which are
 +  currently queued for being queried, etc. It is checked via bitmask, so a
 +  channel can have several channel states.
 +/
enum ChannelState : ubyte
{
    unset = 1 << 0,      /// Initial value, invalid state.
    topicKnown = 1 << 1, /// Topic has been sent once, it is known.
    queued = 1 << 2,     /// Channel queued to be queried.
    queried = 1 << 3,    /// Channel has been queried.
}


// startChannelQueries
/++
 +  Queries channels for information about them and their users.
 +
 +  Checks an internal list of channels once every `dialect.defs.IRCEvent.Type.PING`,
 +  and if one we inhabit hasn't been queried, queries it.
 +/
@(IRCEvent.Type.PING)
void startChannelQueries(ChanQueriesService service)
{
    import core.thread : Fiber;

    if (service.querying) return;  // Try again next PING

    service.querying = true;  // "Lock"

    string[] querylist;

    foreach (immutable channelName, ref state; service.channelStates)
    {
        if (state & (ChannelState.queried | ChannelState.queued))
        {
            // Either already queried or queued to be
            continue;
        }

        state |= ChannelState.queued;
        querylist ~= channelName;
    }

    if (!querylist.length)
    {
        service.querying = false;  // "Unlock"
        return;
    }

    /// Event types that signal the end of a query response.
    static immutable queryTypes =
    [
        IRCEvent.Type.RPL_TOPIC,
        IRCEvent.Type.RPL_NOTOPIC,
        IRCEvent.Type.RPL_ENDOFWHO,
        IRCEvent.Type.RPL_CHANNELMODEIS,
    ];

    /// Event types that signal the end of a WHOIS response.
    static immutable whoisTypes =
    [
        IRCEvent.Type.RPL_ENDOFWHOIS,
        IRCEvent.Type.ERR_UNKNOWNCOMMAND,
    ];

    void dg()
    {
        import kameloso.messaging : raw;
        import kameloso.thread : ThreadMessage, busMessage;
        import core.thread : Fiber;
        import std.concurrency : send;
        import std.string : representation;

        scope(exit)
        {
            service.queriedAtLeastOnce = true;
            service.querying = false;  // "Unlock"
        }

        foreach (immutable i, immutable channelName; querylist)
        {
            if (channelName !in service.channelStates) continue;

            if (i > 0)
            {
                // Delay between runs after first since aMode probes don't delay at end
                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            if (!(service.channelStates[channelName] & ChannelState.topicKnown))
            {
                version(WithPrinterPlugin)
                {
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage("squelch"));
                }

                raw(service.state, "TOPIC " ~ channelName, true);
                Fiber.yield();  // awaiting RPL_TOPIC or RPL_NOTOPIC

                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            raw(service.state, "WHO " ~ channelName, true);
            Fiber.yield();  // awaiting RPL_ENDOFWHO

            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            raw(service.state, "MODE " ~ channelName, true);
            Fiber.yield();  // awaiting RPL_CHANNELMODEIS

            foreach (immutable modechar; service.state.server.aModes.representation)
            {
                import std.format : format;
                // Cannot await by event type; there are too many types,
                // so just delay for twice the normal delay duration
                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay

                version(WithPrinterPlugin)
                {
                    // It's very common to get ERR_CHANOPRIVSNEEDED when querying
                    // channels for specific modes.
                    // [chanoprivsneeded] [#d] sinisalo.freenode.net: "You're not a channel operator" (#482)
                    // Ask the Printer to squelch those messages too.
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage("squelch"));
                }

                raw(service.state, "MODE %s +%c".format(channelName, cast(char)modechar), true);
            }

            if (channelName !in service.channelStates) continue;

            // Overwrite state with `ChannelState.queried`;
            // `topicKnown` etc are no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;
        }

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime.toUnixTime;
        bool[string] uniqueUsers;

        foreach (immutable channelName, const channel; service.state.channels)
        {
            foreach (immutable nickname; channel.users.byKey)
            {
                if (nickname !in service.state.users) continue;

                if (!service.state.users[nickname].account.length &&
                    ((now - service.state.users[nickname].updated) > Timeout.whoisRetry))
                {
                    // No account and sufficient amount of time passed since last WHOIS
                    uniqueUsers[nickname] = true;
                }
            }
        }

        // Clear triggers and await the WHOIS types.
        service.unlistFiberAwaitingEvents(queryTypes);

        import kameloso.common : settings;
        if (!service.serverSupportsWHOIS || !settings.eagerLookups) return;

        service.awaitEvents(whoisTypes);

        scope(exit) service.unlistFiberAwaitingEvents(whoisTypes);

        whoisloop:
        foreach (immutable nickname; uniqueUsers.byKey)
        {
            import kameloso.common : logger;
            import kameloso.messaging : whois;
            import kameloso.thread : CarryingFiber;

            if ((nickname !in service.state.users) ||
                (service.state.users[nickname].account.length))
            {
                // User disappeared, or something else WHOISed it already.
                continue;
            }

            // Delay between runs after first since aMode probes don't delay at end
            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            whois(service.state, nickname, false, true);
            Fiber.yield();  // Await whois types registered above

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            while (true)
            {
                with (IRCEvent.Type)
                switch (thisFiber.payload.type)
                {
                case RPL_ENDOFWHOIS:
                    if (thisFiber.payload.target.nickname == nickname)
                    {
                        // Saw the expected response
                        continue whoisloop;
                    }
                    else
                    {
                        // Someting else caused a WHOIS; yield until the right one comes along
                        Fiber.yield();
                        continue;
                    }

                case ERR_UNKNOWNCOMMAND:
                    if (!thisFiber.payload.aux.length || (thisFiber.payload.aux == "WHOIS"))
                    {
                        // Cannot WHOIS on this server
                        // A different flavour of ERR_UNKNOWNCOMMAND doesn't include the command
                        // We can't say for sure but assume it's erroring on "WHOIS"
                        logger.warning("Warning: This server does not seem to support user accounts.");
                        logger.warning("If this is wrong, please file a GitHub issue.");
                        logger.warning("As it is, functionality will be greatly limited.");
                        service.serverSupportsWHOIS = false;
                        return;
                    }
                    else
                    {
                        // Something else issued an unknown command; yield and try again
                        Fiber.yield();
                        continue;
                    }

                default:
                    import lu.conv : Enum;
                    assert(0, "Unexpected event type triggered query Fiber: " ~
                        Enum!(IRCEvent.Type).toString(thisFiber.payload.type));
                }
            }

            assert(0, "Escaped while (true) loop in query Fiber delegate");
        }
    }

    import kameloso.thread : CarryingFiber;

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32768);
    service.awaitEvents(fiber, queryTypes);
    fiber.call();
}


// onSelfjoin
/++
 +  Adds a channel we join to the internal `ChanQueriesService.channels` list of
 +  channel states.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ChanQueriesService service, const IRCEvent event)
{
    service.channelStates[event.channel] = ChannelState.unset;
}


// onSelfpart
/++
 +  Removes a channel we part from the internal `ChanQueriesService.channels`
 +  list of channel states.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
@(ChannelPolicy.any)
void onSelfpart(ChanQueriesService service, const IRCEvent event)
{
    service.channelStates.remove(event.channel);
}


// onTopic
/++
 +  Registers that we have seen the topic of a channel.
 +
 +  We do this so we know not to query it later. Mostly cosmetic.
 +/
@(IRCEvent.Type.RPL_TOPIC)
@(ChannelPolicy.any)
void onTopic(ChanQueriesService service, const IRCEvent event)
{
    service.channelStates[event.channel] |= ChannelState.topicKnown;
}


// onEndOfNames
/++
 +  After listing names (upon joining a channel), initiate a channel query run
 +  unless one is already running. Additionally don't do it before it has been
 +  done at least once, after login.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(ChannelPolicy.any)
void onEndOfNames(ChanQueriesService service)
{
    if (!service.querying && service.queriedAtLeastOnce)
    {
        service.startChannelQueries();
    }
}


// onEndOfMotd
/++
 +  After successful connection and MOTD list end, start a delayed channel query
 +  on all channels at that time.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.RPL_NOMOTD)
void onEndOfMotd(ChanQueriesService service)
{
    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    void dg()
    {
        service.startChannelQueries();
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32768);
    service.delayFiber(fiber, service.secondsBeforeInitialQueries);
}


version(OmniscientQueries)
{
    mixin UserAwareness!(ChannelPolicy.any);
    mixin ChannelAwareness!(ChannelPolicy.any);
}
else
{
    mixin UserAwareness;
    mixin ChannelAwareness;
}


public:


// ChanQueriesService
/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each try to do it themselves.
 +/
final class ChanQueriesService : IRCPlugin
{
private:
    /++
     +  Extra seconds delay between channel mode/user queries. Not delaying may
     +  cause kicks and disconnects if results are returned quickly.
     +/
    enum secondsBetween = 3;

    /// Seconds after MOTD end before the first round of channel-querying will start.
    enum secondsBeforeInitialQueries = 60;

    /++
     +  Short associative array of the channels the bot is in and which state(s)
     +  they are in.
     +/
    ubyte[string] channelStates;

    /// Whether or not a channel query Fiber is running.
    bool querying;

    /// Whether or not at least one channel query has been made.
    bool queriedAtLeastOnce;

    /// Whether or not the server is known to support WHOIS queries. (Default to true.)
    bool serverSupportsWHOIS = true;

    /// Whether or not to display outgoing queries, as a debugging tool.
    enum hideOutgoingQueries = true;

    mixin IRCPluginImpl;

    /++
     +  Override `kameloso.plugins.common.IRCPluginImpl.onEvent` and inject a server check, so this
     +  service does nothing on Twitch servers. The function to call is
     +  `kameloso.plugins.common.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.common.onEventImpl`
     +          after verifying we're not on a Twitch server.
     +/
    version(TwitchSupport)
    public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Daemon known to be Twitch
            return;
        }

        return onEventImpl(event);
    }
}

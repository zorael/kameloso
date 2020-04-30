/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as their lists of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each have to repeat it themselves.
 +
 +  It is qualified as a service, so while it is not technically mandatory, it
 +  is highly recommended if you plan on mixing in
 +  `kameloso.plugins.awareness.ChannelAwareness` into your plugins.
 +/
module kameloso.plugins.chanqueries;

version(WithPlugins):
version(WithChanQueriesService):

// Whether or not to do channel queries for non-home channels.
//version = OmniscientQueries;

private:

import kameloso.plugins.core;
import kameloso.plugins.common;
import kameloso.plugins.awareness : ChannelAwareness, UserAwareness;
import dialect.defs;
import std.typecons : No, Yes;

version(OmniscientQueries)
{
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    enum omniscientChannelPolicy = ChannelPolicy.home;
}


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

    // Continue anyway if eagerLookups
    if (!querylist.length && !service.state.settings.eagerLookups) return;

    void dg()
    {
        import kameloso.thread : CarryingFiber, ThreadMessage, busMessage;
        import core.thread : Fiber;
        import std.concurrency : send;
        import std.datetime.systime : Clock;
        import std.string : representation;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        service.querying = true;  // "Lock"

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

            version(WithPrinterPlugin)
            {
                immutable squelchMessage = "squelch " ~ channelName;
            }

            /// Common code to send a query, await the results and unlist the fiber.
            void queryAwaitAndUnlist(Types)(const string command, const Types types)
            {
                import kameloso.messaging : raw;
                import std.traits : isArray;

                static if (isArray!Types)
                {
                    service.awaitEvents(types);
                }
                else
                {
                    service.awaitEvent(types);
                }

                version(WithPrinterPlugin)
                {
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage(squelchMessage));
                }

                raw(service.state, command ~ ' ' ~ channelName,
                    (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
                Fiber.yield();  // Awaiting specified types

                while (thisFiber.payload.channel != channelName) Fiber.yield();

                static if (isArray!Types)
                {
                    service.unlistFiberAwaitingEvents(types);
                }
                else
                {
                    service.unlistFiberAwaitingEvent(types);
                }

                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            /// Event types that signal the end of a query response.
            static immutable topicTypes =
            [
                IRCEvent.Type.RPL_TOPIC,
                IRCEvent.Type.RPL_NOTOPIC,
            ];

            queryAwaitAndUnlist("TOPIC", topicTypes);
            queryAwaitAndUnlist("WHO", IRCEvent.Type.RPL_ENDOFWHO);
            queryAwaitAndUnlist("MODE", IRCEvent.Type.RPL_CHANNELMODEIS);

            // MODE generic

            foreach (immutable n, immutable modechar; service.state.server.aModes.representation)
            {
                import std.format : format;

                if (n > 0)
                {
                    // Cannot await by event type; there are too many types.
                    service.delayFiber(service.secondsBetween);
                    Fiber.yield();  // delay
                }

                version(WithPrinterPlugin)
                {
                    // It's very common to get ERR_CHANOPRIVSNEEDED when querying
                    // channels for specific modes.
                    // [chanoprivsneeded] [#d] sinisalo.freenode.net: "You're not a channel operator" (#482)
                    // Ask the Printer to squelch those messages too.
                    service.state.mainThread.send(ThreadMessage.BusMessage(),
                        "printer", busMessage(squelchMessage));
                }

                import kameloso.messaging : mode;
                mode(service.state, channelName, "+%c".format((cast(char)modechar)), string.init,
                    (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
            }

            if (channelName !in service.channelStates) continue;

            // Overwrite state with `ChannelState.queried`;
            // `topicKnown` etc are no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;
        }

        // Stop here if we can't or are not interested in going further
        if (!service.serverSupportsWHOIS || !service.state.settings.eagerLookups) return;

        import kameloso.constants : Timeout;

        immutable now = Clock.currTime.toUnixTime;
        bool[string] uniqueUsers;

        foreach (immutable channelName, const channel; service.state.channels)
        {
            foreach (immutable nickname; channel.users.byKey)
            {
                if (nickname == service.state.client.nickname) continue;

                const user = nickname in service.state.users;

                if (!user || !user.account.length || ((now - user.updated) > Timeout.whoisRetry))
                {
                    // No user, or no account and sufficient amount of time passed since last WHOIS
                    uniqueUsers[nickname] = true;
                }
            }
        }

        if (!uniqueUsers.length) return;  // Early exit

        uniqueUsers.rehash();

        /// Event types that signal the end of a WHOIS response.
        static immutable whoisTypes =
        [
            IRCEvent.Type.RPL_ENDOFWHOIS,
            IRCEvent.Type.ERR_UNKNOWNCOMMAND,
        ];

        service.awaitEvents(whoisTypes);

        scope(exit)
        {
            service.unlistFiberAwaitingEvents(whoisTypes);

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("resetsquelch"));
            }
        }

        long lastQueryResults;

        whoisloop:
        foreach (immutable nickname; uniqueUsers.byKey)
        {
            import kameloso.common : logger;
            import kameloso.messaging : whois;

            if ((nickname !in service.state.users) ||
                (service.state.users[nickname].account.length))
            {
                // User disappeared, or something else WHOISed it already.
                continue;
            }

            // Delay between runs after first since aMode probes don't delay at end
            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            while ((Clock.currTime.toUnixTime - lastQueryResults) < service.secondsBetween-1)
            {
                service.delayFiber(1);
                Fiber.yield();
            }

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch " ~ nickname));
            }

            whois(service.state, nickname, false,
                (service.hideOutgoingQueries ? Yes.quiet : No.quiet), Yes.background);
            Fiber.yield();  // Await whois types registered above

            enum maxConsecutiveUnknownCommands = 3;
            uint consecutiveUnknownCommands;

            while (true)
            {
                with (IRCEvent.Type)
                switch (thisFiber.payload.type)
                {
                case RPL_ENDOFWHOIS:
                    consecutiveUnknownCommands = 0;

                    if (thisFiber.payload.target.nickname == nickname)
                    {
                        // Saw the expected response
                        lastQueryResults = Clock.currTime.toUnixTime;
                        continue whoisloop;
                    }
                    else
                    {
                        // Someting else caused a WHOIS; yield until the right one comes along
                        Fiber.yield();
                        continue;
                    }

                case ERR_UNKNOWNCOMMAND:
                    if (!thisFiber.payload.aux.length)
                    {
                        // A different flavour of ERR_UNKNOWNCOMMAND doesn't include the command
                        // We can't say for sure it's erroring on "WHOIS" specifically
                        // If consecutive three errors, assume it's not supported

                        if (++consecutiveUnknownCommands >= maxConsecutiveUnknownCommands)
                        {
                            import kameloso.common : Tint;

                            // Cannot WHOIS on this server (assume)
                            logger.error("Error: This server does not seem " ~
                                "to support user accounts?");
                            logger.errorf("Consider enabling %sCore%s.%1$spreferHostmasks%2$s.",
                                Tint.log, Tint.warning);
                            service.serverSupportsWHOIS = false;
                            return;
                        }
                    }
                    else if (thisFiber.payload.aux == "WHOIS")
                    {
                        // Cannot WHOIS on this server
                        // Connect will display an error, so don't do it here again
                        service.serverSupportsWHOIS = false;
                        return;
                    }
                    else
                    {
                        // Something else issued an unknown command; yield and try again
                        consecutiveUnknownCommands = 0;
                        Fiber.yield();
                        continue;
                    }
                    break;

                default:
                    import lu.conv : Enum;
                    assert(0, "Unexpected event type triggered query Fiber: " ~
                        "`IRCEvent.Type." ~ Enum!(IRCEvent.Type).toString(thisFiber.payload.type) ~ '`');
                }
            }

            assert(0, "Escaped `while (true)` loop in query Fiber delegate");
        }
    }

    import kameloso.thread : CarryingFiber;

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32_768);
    fiber.call();
}


// onSelfjoin
/++
 +  Adds a channel we join to the internal `ChanQueriesService.channels` list of
 +  channel states.
 +/
@(IRCEvent.Type.SELFJOIN)
@omniscientChannelPolicy
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
@omniscientChannelPolicy
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
@omniscientChannelPolicy
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
@omniscientChannelPolicy
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

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32_768);
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
 +  terms of topic and modes) as well as its list of participants.
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
     +  Override `kameloso.plugins.core.IRCPluginImpl.onEvent` and inject
     +  a server check, so this service does nothing on Twitch servers.
     +  The function to call is `kameloso.plugins.core.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.common.onEventImpl`
     +          after verifying we're not on a Twitch server.
     +/
    version(TwitchSupport)
    override public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Daemon known to be Twitch
            return;
        }

        return onEventImpl(event);
    }
}

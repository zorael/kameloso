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

    if (!querylist.length) return;

    void dg()
    {
        import kameloso.messaging : raw;
        import kameloso.thread : ThreadMessage, busMessage;
        import core.thread : Fiber;
        import std.concurrency : send;
        import std.string : representation;

        scope(exit) service.queriedAtLeastOnce = true;

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

                raw(service.state, "TOPIC " ~ channelName, false);
                Fiber.yield();  // awaiting RPL_TOPIC or RPL_NOTOPIC

                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            raw(service.state, "WHO " ~ channelName, false);
            Fiber.yield();  // awaiting RPL_ENDOFWHO

            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            raw(service.state, "MODE " ~ channelName, false);
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

                raw(service.state, "MODE %s +%c".format(channelName, cast(char)modechar), false);
            }

            if (channelName !in service.channelStates) continue;

            // Overwrite state with `ChannelState.queried`;
            // `topicKnown` etc are no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;
        }

        bool[string] uniqueUsers;

        foreach (immutable channelName, const channel; service.state.channels)
        {
            foreach (immutable nickname; channel.users.byKey)
            {
                if (!service.state.users[nickname].account.length)
                {
                    uniqueUsers[nickname] = true;
                }
            }
        }

        foreach (immutable nickname; uniqueUsers.byKey)
        {
            import kameloso.common : logger;
            import kameloso.messaging : whois;
            import kameloso.thread : CarryingFiber;

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            if (thisFiber.payload.type == IRCEvent.Type.ERR_UNKNOWNCOMMAND)
            {
                // thisFiber.payload.aux is pretty much guaranteed to be "WHOIS"
                // Don't even check. Cannot WHOIS on this server
                logger.warning("Warning: This server does not seem to support user accounts.");
                logger.warning("If this is wrong, please file a GitHub issue.");
                logger.warning("As it is, functionality will be greatly limited.");
                break;
            }

            // Delay between runs after first since aMode probes don't delay at end
            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            version(WithPrinterPlugin)
            {
                service.state.mainThread.send(ThreadMessage.BusMessage(),
                    "printer", busMessage("squelch"));
            }

            whois(service.state, nickname, false, false);
            //raw(service.state, "WHOIS " ~ nickname, false);
            Fiber.yield();  // Await account types registered above
        }

        service.querying = false;  // "Unlock"
    }

    import kameloso.thread : CarryingFiber;
    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32768);

    // Enlist the fiber *ONCE*
    with (IRCEvent.Type)
    {
        static immutable types =
        [
            RPL_TOPIC,
            RPL_NOTOPIC,
            RPL_ENDOFWHO,
            RPL_CHANNELMODEIS,
            RPL_ENDOFWHOIS,
            ERR_UNKNOWNCOMMAND,
        ];

        service.awaitEvents(fiber, types);
    }

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

    /++
     +  Short associative array of the channels the bot is in and which state(s)
     +  they are in.
     +/
    ubyte[string] channelStates;

    /// Whether or not a channel query Fiber is running.
    bool querying;

    /// Whether or not at least one channel query has been made.
    bool queriedAtLeastOnce;

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

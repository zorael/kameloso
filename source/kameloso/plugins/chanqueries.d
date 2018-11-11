/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each try to do it theemselves.
 +
 +  It has no commands.
 +
 +  It is qualified as a service, so while it is not technically mandatory, it
 +  is highly recommended if you plan on mixing in
 +  `kameloso.plugins.common.ChannelAwareness` in your plugins.
 +/
module kameloso.plugins.chanqueries;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.typecons : Flag, No, Yes;


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


// onPing
/++
 +  Queries channels for information about them and their users.
 +
 +  Checks an internal list of channels once every `PING`, and if one we inhabit
 +  hasn't been queried, queries it.
 +/
@(IRCEvent.Type.PING)
void onPing(ChanQueriesService service)
{
    import core.thread : Fiber;

    if (service.state.client.server.daemon == IRCServer.Daemon.twitch) return;
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
        foreach (immutable i, immutable channelName; querylist)
        {
            import kameloso.messaging : raw;
            import core.thread : Fiber;
            import std.string : representation;

            if (i > 0)
            {
                // Delay between runs after first since aMode probes don't delay at end
                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            if (!(service.channelStates[channelName] & ChannelState.topicKnown))
            {
                raw!(Yes.quiet)(service.state, "TOPIC " ~ channelName);
                Fiber.yield();  // awaiting RPL_TOPIC or RPL_NOTOPIC

                service.delayFiber(service.secondsBetween);
                Fiber.yield();  // delay
            }

            raw!(Yes.quiet)(service.state, "WHO " ~ channelName);
            Fiber.yield();  // awaiting RPL_ENDOFWHO

            service.delayFiber(service.secondsBetween);
            Fiber.yield();  // delay

            raw!(Yes.quiet)(service.state, "MODE " ~ channelName);
            Fiber.yield();  // awaiting RPL_CHANNELMODEIS

            foreach (immutable modechar; service.state.client.server.aModes.representation)
            {
                import std.format : format;
                // Cannot await by event type; there are too many types,
                // so just delay for twice the normal delay duration
                service.delayFiber(service.secondsBetween * 2);
                Fiber.yield();  // delay

                raw!(Yes.quiet)(service.state, "MODE %s +%c"
                    .format(channelName, cast(char)modechar));
            }

            // Overwrite state with `ChannelState.queried`;
            // `topicKnown` etc are no longer relevant.
            service.channelStates[channelName] = ChannelState.queried;

            // The main loop will clean up the `awaitingFibers` array.
        }

        service.querying = false;  // "Unlock"
    }

    Fiber fiber = new Fiber(&dg);

    // Enlist the fiber *ONCE*
    with (IRCEvent.Type)
    {
        static immutable types =
        [
            RPL_TOPIC,
            RPL_NOTOPIC,
            RPL_ENDOFWHO,
            RPL_CHANNELMODEIS,
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
    if (service.state.client.server.daemon == IRCServer.Daemon.twitch) return;

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
    if (service.state.client.server.daemon == IRCServer.Daemon.twitch) return;

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
    if (service.state.client.server.daemon == IRCServer.Daemon.twitch) return;

    service.channelStates[event.channel] |= ChannelState.topicKnown;
}


public:


// ChanQueriesService
/++
 +  The Channel Queries service queries channels for information about them (in
 +  terms of topic and modes) as well as its list of participants. It does this
 +  shortly after having joined a channel, as a service to all other plugins,
 +  so they don't each try to do it theemselves.
 +/
final class ChanQueriesService : IRCPlugin
{
    /++
     +  Extra seconds delay between channel mode/user queries. Not delaying may
     +  cause kicks and disconnects if results are returned quickly.
     +/
    enum secondsBetween = 2;

    /++
     +  Short associative array of the channels the bot is in and which state(s)
     +  they are in.
     +/
    ubyte[string] channelStates;

    /// Whether or not a channel query Fiber is running.
    bool querying;

    mixin IRCPluginImpl;
}

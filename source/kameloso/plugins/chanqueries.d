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

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.typecons : Flag, No, Yes;

private:


// ChannelState
/++
 +  Different states which tracked channels can be in.
 +
 +  This is to keep track of which channels have been queried, which are
 +  currently queued for being queried, etc. It is checked via bitmask, so a
 +  channel can have several channel states.
 +/
enum ChannelState
{
    unset = 1 << 0,
    topicKnown = 1 << 1,
    queued = 1 << 2,
    queried = 1 << 3,
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

    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    string[] querylist;

    foreach (channel, queried; service.channels)
    {
        if (queried) continue;
        service.channels[channel] = true;
        querylist ~= channel;
    }

    if (!querylist.length) return;

    Fiber fiber;

    void fiberFn()
    {
        import kameloso.messaging : raw;
        import core.thread : Fiber;

        foreach (channel; querylist)
        {
            raw!(Yes.quiet)(service.state, "WHO " ~ channel);
            Fiber.yield();  // awaiting RPL_ENDOFWHO

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            raw!(Yes.quiet)(service.state, "TOPIC " ~ channel);
            Fiber.yield();  // awaiting RPL_TOPIC or RPL_NOTOPIC

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            raw!(Yes.quiet)(service.state, "MODE " ~ channel);
            Fiber.yield();  // awaiting RPL_CHANNELMODEIS

            service.delayFiber(fiber, service.secondsBetween);
            Fiber.yield();  // delay

            foreach (immutable modechar; service.state.bot.server.aModes)
            {
                import std.format : format;

                raw!(Yes.quiet)(service.state, "MODE %s +%c".format(channel, modechar));
                service.delayFiber(fiber, service.secondsBetween);
                Fiber.yield();
            }
        }
    }

    fiber = new Fiber(&fiberFn);

    with (IRCEvent.Type)
    with (service.state)
    {
        awaitingFibers[RPL_ENDOFWHO] ~= fiber;
        awaitingFibers[RPL_TOPIC] ~= fiber;
        awaitingFibers[RPL_NOTOPIC] ~= fiber;
        awaitingFibers[RPL_CHANNELMODEIS] ~= fiber;
    }

    fiber.call();
}


// onSelfjoin
/++
 +  Adds a channel we join to the internal `ChanQueriesService.channels` list of
 +  channels.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ChanQueriesService service, const IRCEvent event)
{
    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    service.channels[event.channel] = false;
}


// onSelfpart
/++
 +  Removes a channel we part from the internal `ChanQueriesService.channels`
 +  list of channels.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
@(ChannelPolicy.any)
void onSelfpart(ChanQueriesService service, const IRCEvent event)
{
    if (service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    service.channels.remove(event.channel);
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
     +  Short associative array of the channels the bot is in and whether they
     +  have been queried.
     +/
    bool[string] channels;

    mixin IRCPluginImpl;
}

module kameloso.plugins.chanqueries;

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.stdio;

private:


// onPing
/++
 +  FIXME
 +/
@(IRCEvent.Type.PING)
void onPing(ChanQueriesPlugin plugin, const IRCEvent event)
{
    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch)
    {
        // Can't do WHO on Twitch
        return;
    }

    string[] querylist;

    foreach (channel, queried; plugin.channels)
    {
        if (queried) continue;
        plugin.channels[channel] = true;
        querylist ~= channel;
    }

    if (!querylist.length) return;

    void fiberFn()
    {
        import kameloso.messaging : raw;
        import core.thread : Fiber, Thread;
        import core.time : seconds;
        //import std.format : format;

        bool loopedOnce;

        foreach (channel; querylist)
        {
            if (loopedOnce)
            {
                Fiber.yield();
                Thread.sleep(plugin.secondsBetween.seconds);
            }

            raw(plugin.state.mainThread, "MODE " ~ channel);
            Fiber.yield();
            /*Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "MODE %s +b".format(channel));*/
            Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "WHO " ~ channel);

            loopedOnce = true;
        }
    }

    import core.thread : Fiber;

    Fiber fiber = new Fiber(&fiberFn);

    plugin.awaitingFibers[IRCEvent.Type.RPL_CHANNELMODEIS] ~= fiber;
    plugin.awaitingFibers[IRCEvent.Type.RPL_ENDOFWHO] ~= fiber;

    fiber.call();
}


// onSelfjoin
/++
 +  FIXME
 +/
@(ChannelPolicy.any)
@(IRCEvent.Type.SELFJOIN)
void onSelfjoin(ChanQueriesPlugin plugin, const IRCEvent event)
{
    plugin.channels[event.channel] = false;
}


// onSelfpart
/++
 +  FIXME
 +/
@(ChannelPolicy.any)
@(IRCEvent.Type.SELFPART)
void onSelfpart(ChanQueriesPlugin plugin, const IRCEvent event)
{
    plugin.channels.remove(event.channel);
}


public:


// ChanQueriesPlugin
/++
 +  FIXME
 +/
final class ChanQueriesPlugin : IRCPlugin
{
    /// Extra seconds delay between channel mode/user queries.
    enum secondsBetween = 2;

    /++
     +  Short associative array of the channels the bot is in and whether they
     +  have been queried.
     +/
    bool[string] channels;

    mixin IRCPluginImpl;
}

module kameloso.plugins.chanqueries;

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.stdio;

private:


// onPing
/++
 +  Query channels for information about themselves and their users.
 +
 +  Check an internal list of channels once every `PING`, and if one we inhabit
 +  hasn't been queried, query it.
 +/
@(IRCEvent.Type.PING)
void onPing(ChanQueriesPlugin plugin, const IRCEvent event)
{
    import core.thread : Fiber;

    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    string[] querylist;

    foreach (channel, queried; plugin.channels)
    {
        if (queried) continue;
        plugin.channels[channel] = true;
        querylist ~= channel;
    }

    if (!querylist.length) return;

    Fiber fiber;

    void fiberFn()
    {
        import kameloso.messaging : raw;
        import core.thread : Fiber, Thread;
        import core.time : seconds;
        import std.format : format;

        bool loopedOnce;

        foreach (channel; querylist)
        {
            if (loopedOnce)
            {
                Fiber.yield();
                Thread.sleep(plugin.secondsBetween.seconds);
            }

            // Remove timer and restore IRCEvent.Type awaits once we have better
            // chanmodes handling

            raw(plugin.state.mainThread, "MODE " ~ channel);
            Fiber.yield();

            Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "MODE %s +b".format(channel));
            plugin.delayFiber(fiber, plugin.secondsBetween);
            Fiber.yield();

            Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "MODE %s +q".format(channel));
            plugin.delayFiber(fiber, plugin.secondsBetween);
            Fiber.yield();

            Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "MODE %s +I".format(channel));
            plugin.delayFiber(fiber, plugin.secondsBetween);
            Fiber.yield();

            Thread.sleep(plugin.secondsBetween.seconds);
            raw(plugin.state.mainThread, "WHO " ~ channel);

            loopedOnce = true;
        }
    }

    fiber = new Fiber(&fiberFn);

    with (IRCEvent.Type)
    with (plugin)
    {
        awaitingFibers[RPL_CHANNELMODEIS] ~= fiber;
        awaitingFibers[RPL_ENDOFWHO] ~= fiber;
        //awaitingFibers[RPL_ENDOFBANLIST] ~= fiber;
        //awaitingFibers[RPL_ENDOFQUIETLIST] ~= fiber;
        //awaitingFibers[RPL_ENDOFINVITELIST] ~= fiber;
        //awaitingFibers[ERR_CHANOPRIVSNEEDED] ~= fiber;
        //awaitingFibers[ERR_UNKNOWNMODE] ~= fiber;
    }

    fiber.call();
}


// onSelfjoin
/++
 +  Add a channel we join to the internal list of channels.
 +/
@(ChannelPolicy.homeOnly)
@(IRCEvent.Type.SELFJOIN)
void onSelfjoin(ChanQueriesPlugin plugin, const IRCEvent event)
{
    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    plugin.channels[event.channel] = false;
}


// onSelfpart
/++
 +  Remove a channel we part from the internal list of channels.
 +/
@(ChannelPolicy.homeOnly)
@(IRCEvent.Type.SELFPART)
void onSelfpart(ChanQueriesPlugin plugin, const IRCEvent event)
{
    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    plugin.channels.remove(event.channel);
}


public:


// ChanQueriesPlugin
/++
 +  The Channel Queries plugin queries channels for information about it, so
 +  that other plugins that implement channel awareness can catch the results.
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

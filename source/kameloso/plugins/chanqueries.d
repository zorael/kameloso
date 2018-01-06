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
        import core.thread : Fiber;

        bool loopedOnce;

        foreach (channel; querylist)
        {
            if (loopedOnce)
            {
                Fiber.yield();  // awaiting RPL_ENDOFWHO

                plugin.delayFiber(fiber, plugin.secondsBetween);
                Fiber.yield();
            }

            raw(plugin.state.mainThread, "TOPIC " ~ channel);
            Fiber.yield();  // awaiting RPL_TOPIC

            raw(plugin.state.mainThread, "MODE " ~ channel);
            Fiber.yield();  // awaiting RPL_CHANNELMODEIS

            plugin.delayFiber(fiber, plugin.secondsBetween);
            Fiber.yield();

            foreach (immutable modechar; plugin.state.bot.server.aModes)
            {
                import std.format : format;

                raw(plugin.state.mainThread,
                    "MODE %s +%c".format(channel, modechar));
                plugin.delayFiber(fiber, plugin.secondsBetween);
                Fiber.yield();
            }

            plugin.delayFiber(fiber, plugin.secondsBetween);
            Fiber.yield();

            raw(plugin.state.mainThread, "WHO " ~ channel);

            loopedOnce = true;
        }
    }

    fiber = new Fiber(&fiberFn);

    with (IRCEvent.Type)
    with (plugin)
    {
        awaitingFibers[RPL_TOPIC] ~= fiber;
        awaitingFibers[RPL_CHANNELMODEIS] ~= fiber;
        awaitingFibers[RPL_ENDOFWHO] ~= fiber;
    }

    fiber.call();
}


// onSelfjoin
/++
 +  Add a channel we join to the internal list of channels.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.homeOnly)
void onSelfjoin(ChanQueriesPlugin plugin, const IRCEvent event)
{
    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    plugin.channels[event.channel] = false;
}


// onSelfpart
/++
 +  Remove a channel we part from the internal list of channels.
 +/
@(IRCEvent.Type.SELFPART)
@(ChannelPolicy.homeOnly)
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

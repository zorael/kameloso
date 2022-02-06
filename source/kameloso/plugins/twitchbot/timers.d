
module kameloso.plugins.twitchbot.timers;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.base;

import kameloso.messaging;
import dialect.defs;
import lu.json : JSONStorage;
import std.typecons : Flag, No, Yes;
package:




struct TimerDefinition
{
    
    string line;

    
    int messageCountThreshold;

    
    int timeThreshold;

    
    int stagger;
}




Fiber createTimerFiber(TwitchBotPlugin plugin,
    const TimerDefinition timerDef,
    const string channelName)
{
    
    return null;
}




void handleTimerCommand(TwitchBotPlugin plugin,
    const ref IRCEvent event,
    const string targetChannel)
{
    import lu.string : SplitResults, contains, nom, splitInto;
    import std.format : format;

    string slice = event.content;  
    immutable verb = slice.nom!(Yes.inherit)(' ');

    void sendUsage(const string verb = "[add|del|list|clear]")
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s %s [message threshold] [time threshold] [stagger seconds] [text]"
                .format(plugin.state.settings.prefix, event.aux, verb));
    }

    switch (verb)
    {
    case "add":
        import std.algorithm.searching : count;
        import std.conv : ConvException, to;

        if (slice.count(' ') < 3)
        {
            
            
            return sendUsage(verb);
        }

        TimerDefinition timerDef;

        string rawMessageCountThreshold;
        string rawTimeThreshold;
        string rawStagger;

        immutable results = slice.splitInto(rawMessageCountThreshold, rawTimeThreshold, rawStagger);
        if (results != SplitResults.overrun) return sendUsage(verb);

        try
        {
            timerDef.messageCountThreshold = rawMessageCountThreshold.to!int;
            timerDef.timeThreshold = rawTimeThreshold.to!int;
            timerDef.stagger = rawStagger.to!int;
            timerDef.line = slice;
        }
        catch (ConvException e)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid parameters.");
            return sendUsage(verb);
        }

        if ((timerDef.messageCountThreshold < 0) ||
            (timerDef.timeThreshold < 0) || (timerDef.stagger < 0))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Arguments for message count threshold, timer threshold and stagger " ~
                "must all be positive numbers.");
            return;
        }
        else if ((timerDef.messageCountThreshold == 0) && (timerDef.timeThreshold == 0))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "A timer cannot have a message threshold *and* a time threshold of zero.");
            return;
        }

        plugin.timerDefsByChannel[targetChannel] ~= timerDef;
        plugin.timerDefsToJSON.save(plugin.timersFile);
        plugin.rooms[targetChannel].timers ~=
            plugin.createTimerFiber(timerDef, targetChannel);
        privmsg(plugin.state, event.channel, event.sender.nickname, "New timer added.");
        break;

    case "del":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s del [timer index]".format(plugin.state.settings.prefix, event.aux));
            return;
        }

        if (auto timerDefs = targetChannel in plugin.timerDefsByChannel)
        {
            import lu.string : stripped;
            import std.algorithm.iteration : splitter;
            import std.conv : ConvException, to;

            auto room = targetChannel in plugin.rooms;

            if (slice == "*") goto case "clear";

            try
            {
                immutable i = slice.stripped.to!ptrdiff_t - 1;

                if ((i >= 0) && (i < room.timers.length))
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    *timerDefs = (*timerDefs).remove!(SwapStrategy.unstable)(i);
                    room.timers = room.timers.remove!(SwapStrategy.unstable)(i);
                }
                else
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Timer index %s out of range. (max %d)"
                            .format(slice, room.timers.length));
                    return;
                }
            }
            catch (ConvException e)
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "Invalid timer index: " ~ slice);
                
                return;
            }

            if (!room.timers.length) plugin.timerDefsByChannel.remove(targetChannel);
            plugin.timerDefsToJSON.save(plugin.timersFile);
            privmsg(plugin.state, event.channel, event.sender.nickname, "Timer removed.");
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No timers registered for this channel.");
        }
        break;

    case "list":
        if (const timers = targetChannel in plugin.timerDefsByChannel)
        {
            import lu.string : stripped;
            import std.algorithm.comparison : min;

            enum toDisplay = 10;
            enum maxLineLength = 100;

            ptrdiff_t start;

            if (slice.length)
            {
                import std.conv : ConvException, to;

                try
                {
                    start = slice.stripped.to!ptrdiff_t - 1;

                    if ((start < 0) || (start >= timers.length))
                    {
                        privmsg(plugin.state, event.channel, event.sender.nickname,
                            "Invalid timer index or out of bounds.");
                        return;
                    }
                }
                catch (ConvException e)
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Usage: %s%s list [optional starting position number]"
                            .format(plugin.state.settings.prefix, event.aux));
                    return;
                }
            }

            immutable end = min(start+toDisplay, timers.length);

            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Current timers (%d-%d of %d)"
                    .format(start+1, end, timers.length));

            foreach (immutable i, const timer; (*timers)[start..end])
            {
                immutable maxLen = min(timer.line.length, maxLineLength);
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "%d: %s%s (%d:%d:%d)".format(start+i+1, timer.line[0..maxLen],
                        (timer.line.length > maxLen) ? " ...  [truncated]" : string.init,
                        timer.messageCountThreshold, timer.timeThreshold, timer.stagger));
            }
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No timers registered for this channel.");
        }
        break;

    case "clear":
        plugin.rooms[targetChannel].timers.length = 0;
        plugin.timerDefsByChannel.remove(targetChannel);
        plugin.timerDefsToJSON.save(plugin.timersFile);
        privmsg(plugin.state, event.channel, event.sender.nickname, "All timers cleared.");
        break;

    default:
        return sendUsage();
    }
}




JSONStorage timerDefsToJSON(TwitchBotPlugin plugin)
{
    
    return JSONStorage.init;
}




void populateTimers(TwitchBotPlugin plugin, const string filename)
in (filename.length, "Tried to populate timers from an empty filename")
{
    import kameloso.common : logger;
    import std.conv : to;
    import std.format : format;
    import std.json : JSONType;

    JSONStorage timersJSON;
    timersJSON.load(filename);

    bool errored;

    foreach (immutable channelName, const channelTimersJSON; timersJSON.object)
    {
        if (channelTimersJSON.type != JSONType.array)
        {
            logger.errorf("Twitch timer file malformed! Invalid channel timers " ~
                "list type for %s: `%s`", channelName, channelTimersJSON.type);
            errored = true;
            continue;
        }

        plugin.timerDefsByChannel[channelName] = typeof(plugin.timerDefsByChannel[channelName]).init;
        auto timerDefs = channelName in plugin.timerDefsByChannel;

        foreach (timerArrayEntry; channelTimersJSON.array)
        {
            if (timerArrayEntry.type != JSONType.object)
            {
                logger.errorf("Twitch timer file malformed! Invalid timer type " ~
                    "for %s: `%s`", channelName, timerArrayEntry.type);
                errored = true;
                continue;
            }

            TimerDefinition timer;

            timer.line = timerArrayEntry["line"].str;
            timer.messageCountThreshold = timerArrayEntry["messageCountThreshold"].integer.to!int;
            timer.timeThreshold = timerArrayEntry["timeThreshold"].integer.to!int;
            timer.stagger = timerArrayEntry["stagger"].integer.to!int;

            *timerDefs ~= timer;
        }
    }

    if (errored)
    {
        logger.warning("Errors encountered; not all timers were read.");
    }
}

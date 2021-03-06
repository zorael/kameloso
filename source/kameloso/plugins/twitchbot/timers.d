/++
    Implementation of Twitch bot timers. For internal use.

    The [dialect.defs.IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.twitchbot.TwitchBotPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.twitchbot.base]
 +/
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
import core.thread : Fiber;

package:


// TimerDefinition
/++
    Definitions of a Twitch timer.
 +/
struct TimerDefinition
{
    /// The timered line to send to the channel.
    string line;

    /++
        How many messages must have been sent since the last announce before we
        will allow another one.
     +/
    int messageCountThreshold;

    /++
        How many seconds must have passed since the last announce before we will
        allow another one.
     +/
    int timeThreshold;

    /// Delay in seconds before the timer comes into effect.
    int stagger;
}


// createTimerFiber
/++
    Given a [TimerDefinition] and a string channel name, creates a
    [core.thread.fiber.Fiber] that implements the timer.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin].
        timerDef = Definition of the timer to apply.
        channelName = String channel to which the timer belongs.
 +/
Fiber createTimerFiber(TwitchBotPlugin plugin, const TimerDefinition timerDef,
    const string channelName)
{
    import kameloso.constants : BufferSize;

    void dg()
    {
        import std.datetime.systime : Clock;

        const room = channelName in plugin.rooms;

        /// When this timer Fiber was created.
        immutable creation = Clock.currTime.toUnixTime;

        /// The channel message count at last successful trigger.
        ulong lastMessageCount = room.messageCount;

        /// The timestamp at the last successful trigger.
        long lastTimestamp = creation;

        /// Whether or not stagger has passed, so we don't evaluate it every single time.
        bool staggerDone;

        version(TwitchAPIFeatures)
        {
            immutable streamer = room.broadcasterDisplayName;
        }
        else
        {
            import kameloso.plugins.common.base : nameOf;
            immutable streamer = plugin.nameOf(channelName[1..$]);
        }

        while (true)
        {
            if (!staggerDone)
            {
                immutable now = Clock.currTime.toUnixTime;

                if ((now - creation) < timerDef.stagger)
                {
                    // Reset counters so it starts fresh after stagger
                    lastMessageCount = room.messageCount;
                    lastTimestamp = now;
                    Fiber.yield();
                    continue;
                }
            }

            // Avoid evaluating current UNIX time after stagger is done
            staggerDone = true;

            if (room.messageCount < (lastMessageCount + timerDef.messageCountThreshold))
            {
                Fiber.yield();
                continue;
            }

            immutable now = Clock.currTime.toUnixTime;

            if ((now - lastTimestamp) < timerDef.timeThreshold)
            {
                Fiber.yield();
                continue;
            }

            import std.array : replace;
            import std.conv : text;
            import std.random : uniform;

            immutable line = timerDef.line
                .replace("$streamer", streamer)
                .replace("$channel", channelName[1..$])
                .replace("$bot", plugin.state.client.nickname)
                .replace("$random", uniform!"[]"(0, 100).text);

            chan(plugin.state, channelName, line);

            lastMessageCount = room.messageCount;
            lastTimestamp = now;

            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&dg, BufferSize.fiberStack);
}


// handleTimerCommand
/++
    Adds, deletes, lists or clears timers for the specified target channel.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin].
        event = The triggering [dialect.defs.IRCEvent].
        targetChannel = The channel we're handling timers for.
 +/
void handleTimerCommand(TwitchBotPlugin plugin, const ref IRCEvent event, const string targetChannel)
in (targetChannel.length, "Tried to handle timers with an empty target channel string")
{
    import lu.string : SplitResults, contains, nom, splitInto;
    import std.format : format;

    string slice = event.content;  // mutable
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
            /*privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: add [message threshold] [time threshold] [stagger seconds] [text]");*/
            //                                 1                2                 3
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
                //version(PrintStacktraces) logger.trace(e.info);
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


// timerDefsToJSON
/++
    Expresses the [FiberDefinition] associative array
    ([kameloso.plugins.twitchbot.base.TwitchBotPlugin.fiberDefsByChannel])
    in JSON form, for easier saving to and loading from disk.

    Using [std.json.JSONValue] directly fails with an error.
 +/
JSONStorage timerDefsToJSON(TwitchBotPlugin plugin)
{
    import std.json : JSONType, JSONValue;

    JSONStorage json;
    json.reset();

    foreach (immutable channelName, channelTimers; plugin.timerDefsByChannel)
    {
        if (!channelTimers.length) continue;

        json[channelName] = null;  // quirk to initialise it as a JSONType.object

        foreach (const timer; channelTimers)
        {
            JSONValue value;
            value = null;  // as above

            if (json[channelName].type != JSONType.array)
            {
                json[channelName].array = null;
            }

            value["line"] = timer.line;
            value["messageCountThreshold"] = timer.messageCountThreshold;
            value["timeThreshold"] = timer.timeThreshold;
            value["stagger"] = timer.stagger;
            json[channelName].array ~= value;
        }
    }

    return json;
}


// populateTimers
/++
    Populates the [kameloso.plugins.twitchbot.base.TwitchBotPlugin.timerDefsByChannel]
    associative array with the timer definitions in the passed JSON file.

    This reads the JSON values from disk and creates the [TimerDefinition]s
    appropriately.

    Params:
        plugin = The current [kameloso.plugins.twitchbot.base.TwitchBotPlugin].
        filename = Filename of the JSON file to read definitions from.
 +/
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

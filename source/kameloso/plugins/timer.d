/++
    Plugin offering announcement timers; routines that periodically sends lines
    of text to a channel.
 +/
module kameloso.plugins.timer;

version(TwitchSupport):
version(WithTimerPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication, UserAwareness;
import kameloso.common : expandTags, logger;
import kameloso.logger : LogLevel;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// TimerSettings
/++
    All [TimerPlugin] runtime settings, aggregated in a struct.
 +/
@Settings struct TimerSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;
}


// TimerDefinition
/++
    Definitions of a timer.
 +/
struct TimerDefinition
{
private:
    import std.json : JSONValue;

public:
    // Type
    /++
        The different kinds of [TimerDefinition]s. Either one that yields a
        [Type.random|random] response each time, or one that yields a
        [Type.sequential|sequential] one.
     +/
    enum Type
    {
        /++
            Lines should be yielded in a random (technically uniform) order.
         +/
        random = 0,

        /++
            Lines should be yielded sequentially, bumping an internal counter.
         +/
        sequential = 1,
    }

    // Condition
    /++
        Conditions upon which timers decide whether they are to fire yet, or wait still.
     +/
    enum Condition
    {
        /// Both message count and time criteria must be fulfilled.
        both = 0,

        /// Either message count or time criteria may be fulfilled.
        either = 1,
    }

    // name
    /++
        String name identifier of this timer.
     +/
    string name;

    // lines
    /++
        The timered lines to send to the channel.
     +/
    string[] lines;

    // type
    /++
        What type of [TimerDefinition] this is.
     +/
    Type type;

    // condition
    /++
        What message/time conditions this [TimerDefinition] abides by.
     +/
    Condition condition;

    // messageCountThreshold
    /++
        How many messages must have been sent since the last announce before we
        will allow another one.
     +/
    long messageCountThreshold;

    // timeThreshold
    /++
        How many seconds must have passed since the last announce before we will
        allow another one.
     +/
    long timeThreshold;

    // staggerTime
    /++
        Delay in seconds before the timer initially comes into effect.
     +/
    long staggerTime;

    /++
        Delay in number of messages before the timer initially comes into effect.
     +/
    long staggerMessageCount;

    // position
    /++
        The current position, kept to keep track of what line should be yielded
        next in the case of sequential timers.
     +/
    size_t position;

    // getLine
    /++
        Yields a line from the [lines] array, depending on the [type]
        of this timer.

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    string getLine()
    {
        return (type == Type.random) ?
            randomLine() :
            nextSequentialLine();
    }

    // nextSequentialLine
    /++
        Yields a sequential line from the [lines] array. Which line is selected
        depends on the value of [position].

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    string nextSequentialLine()
    {
        if (!lines.length) return string.init;

        size_t i = position++;  // mutable

        if (i >= lines.length)
        {
            // Position needs to be zeroed on response removals
            i = 0;
            position = 1;
        }
        else if (position >= lines.length)
        {
            position = 0;
        }

        return lines[i];
    }

    // randomLine
    /++
        Yields a random line from the [lines] array.

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    string randomLine() const
    {
        import std.random : uniform;

        if (!lines.length) return string.init;

        return lines[uniform(0, lines.length)];
    }

    // toJSON
    /++
        Serialises this [TimerDefinition] into a [std.json.JSONValue|JSONValue].

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this timer.
     +/
    JSONValue toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["name"] = JSONValue(this.name);
        json["type"] = JSONValue(cast(int)this.type);
        json["condition"] = JSONValue(cast(int)this.condition);
        json["messageCountThreshold"] = JSONValue(this.messageCountThreshold);
        json["timeThreshold"] = JSONValue(this.timeThreshold);
        json["staggerTime"] = JSONValue(this.staggerTime);
        json["staggerMessageCount"] = JSONValue(this.staggerTime);
        json["lines"] = null;
        json["lines"].array = null;

        foreach (immutable line; this.lines)
        {
            json["lines"].array ~= JSONValue(line);
        }

        return json;
    }

    // fromJSON
    /++
        Deserialises a [TimerDefinition] from a [std.json.JSONValue|JSONValue].

        Params:
            json = [std.json.JSONValue|JSONValue] to deserialise.

        Returns:
            A new [TimerDefinition] with values loaded from the passed JSON.
     +/
    static TimerDefinition fromJSON(const JSONValue json)
    {
        TimerDefinition def;
        def.name = json["name"].str;
        def.messageCountThreshold = json["messageCountThreshold"].integer;
        def.timeThreshold = json["timeThreshold"].integer;
        def.staggerTime = json["staggerTime"].integer;
        def.staggerMessageCount = json["staggerMessageCount"].integer;
        def.type = (json["type"].integer == cast(int)Type.random) ?
            Type.random :
            Type.sequential;
        def.condition = (json["condition"].integer == cast(int)Condition.both) ?
            Condition.both :
            Condition.either;

        foreach (const lineJSON; json["lines"].array)
        {
            def.lines ~= lineJSON.str;
        }

        return def;
    }
}


// onCommandTimer
/++
    Adds, deletes, lists or clears timers for the specified target channel.

    Changes are persistently saved to the [TimerPlugin.timersFile] file.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("timer")
            .policy(PrefixPolicy.prefixed)
            .description("Adds, removes, lists or clears timers.")
            .syntax("$command [new|add|del|list|clear] ...")
    )
)
void onCommandTimer(TimerPlugin plugin, const ref IRCEvent event)
{
    handleTimerCommand(plugin, event, event.channel);
}


// handleTimerCommand
/++
    Adds, deletes, lists or clears timers for the specified target channel.

    Params:
        plugin = The current [kameloso.plugins.timer.TimerPlugin|TimerPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        channelName = The channel we're handling timers for.
 +/
void handleTimerCommand(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    const string channelName)
{
    import lu.string : SplitResults, contains, nom, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [new|add|del|list|clear] ...";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, channelName, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, channelName, message);
    }

    switch (verb)
    {
    case "new":
        void sendNewUsage()
        {
            enum pattern = "Usage: <b>%s%s<b> new [name] [type] [condition] [message threshold] " ~
                "[time threshold] [stagger message count] [stagger time]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, channelName, message);
        }

        void sendBadNumerics()
        {
            enum message = "Arguments for threshold and stagger values must all be positive numbers.";
            chan(plugin.state, channelName, message);
        }

        TimerDefinition timerDef;

        string messageCountThreshold;
        string type;
        string condition;
        string timeThreshold;
        string staggerMessageCount;
        string staggerTime;

        immutable results = slice.splitInto(
            timerDef.name,
            type,
            condition,
            messageCountThreshold,
            timeThreshold,
            staggerMessageCount,
            staggerTime);

        with (SplitResults)
        final switch (results)
        {
        case match:
            break;

        case underrun:
            if (messageCountThreshold.length) break;
            else
            {
                return sendNewUsage();
            }

        case overrun:
            return sendNewUsage();
        }

        import std.algorithm.comparison : among;

        if (type.among!("random", "rnd", "rng")) timerDef.type = TimerDefinition.Type.random;
        else if (type.among!("sequential", "seq", "sequence")) timerDef.type = TimerDefinition.Type.sequential;
        else
        {
            enum message = "Type must be one of <b>random<b> or <b>sequential<b>.";
            chan(plugin.state, channelName, message);
            return;
        }

        if (condition.among!("both", "and")) timerDef.condition = TimerDefinition.Condition.both;
        else if (condition.among!("either", "or")) timerDef.condition = TimerDefinition.Condition.either;
        else
        {
            enum message = "Condition must be one of <b>both<b> or <b>either<b>.";
            chan(plugin.state, channelName, message);
            return;
        }

        try
        {
            timerDef.messageCountThreshold = messageCountThreshold.to!long;
            timerDef.timeThreshold = timeThreshold.to!long;
            if (staggerMessageCount.length) timerDef.staggerMessageCount = staggerMessageCount.to!long;
            if (staggerTime.length) timerDef.staggerTime = staggerTime.to!long;
        }
        catch (ConvException e)
        {
            return sendBadNumerics();
        }

        if ((timerDef.messageCountThreshold < 0) ||
            (timerDef.timeThreshold < 0) ||
            (timerDef.staggerMessageCount < 0) ||
            (timerDef.staggerTime < 0))
        {
            return sendBadNumerics();
        }
        else if ((timerDef.messageCountThreshold == 0) && (timerDef.timeThreshold == 0))
        {
            enum message = "A timer cannot have a message threshold *and* a time threshold of zero.";
            chan(plugin.state, channelName, message);
            return;
        }

        plugin.timerDefsByChannel[channelName] ~= timerDef;
        saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);
        plugin.channels[channelName].timerFibers ~= plugin.createTimerFiber(timerDef, channelName);

        enum appendPattern = "New timer added. Use <b>%s%s add<b> to add lines.";
        immutable message = appendPattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, channelName, message);
        break;

    case "insert":
        void sendInsertUsage()
        {
            enum pattern = "Usage: <b>%s%s<b> insert [timer name] [position] [timer text...]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, channelName, message);
        }

        string name;
        string linesPosString;

        immutable results = slice.splitInto(name, linesPosString);
        if (results != SplitResults.overrun) return sendInsertUsage();

        auto timerDefs = channelName in plugin.timerDefsByChannel;
        if (!timerDefs) return sendNoSuchTimer();

        auto channel = channelName in plugin.channels;
        if (!channel) return sendNoSuchTimer();

        foreach (immutable i, ref timerDef; *timerDefs)
        {
            if (timerDef.name == name)
            {
                try
                {
                    import std.array : insertInPlace;
                    immutable linesPos = linesPosString.to!size_t;
                    timerDef.lines.insertInPlace(linesPos, slice);
                    destroy(channel.timerFibers[i]);
                    channel.timerFibers[i] = plugin.createTimerFiber(timerDef, channelName);
                    saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                    enum pattern = "Line added to timer <b>%s<b>.";
                    immutable message = pattern.format(name);
                    chan(plugin.state, event.channel, message);
                    return;
                }
                catch (ConvException e)
                {
                    enum message = "Argument for which position to insert line at must be a number.";
                    chan(plugin.state, event.channel, message);
                    return;
                }
            }
        }

        // If we're here, no timer was found with the given name
        return sendNoSuchTimer();

    case "add":
    case "append":
        void sendAddUsage()
        {
            enum pattern = "Usage: <b>%s%s<b> add [timer name] [timer text...]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, channelName, message);
        }

        void sendNoSuchTimerAdd()
        {
            enum noSuchTimerPattern = "No such timer is defined. Add a new one with <b>%s%s new<b>.";
            immutable noSuchTimerMessage = noSuchTimerPattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, channelName, noSuchTimerMessage);
        }

        immutable name = slice.nom!(Yes.inherit)(' ');
        if (!slice.length) return sendAddUsage();

        auto timerDefs = channelName in plugin.timerDefsByChannel;
        if (!timerDefs) return sendNoSuchTimerAdd();

        auto channel = channelName in plugin.channels;
        if (!channel) return sendNoSuchTimerAdd();

        foreach (immutable i, ref timerDef; *timerDefs)
        {
            if (timerDef.name == name)
            {
                timerDef.lines ~= slice;
                destroy(channel.timerFibers[i]);
                channel.timerFibers[i] = plugin.createTimerFiber(timerDef, channelName);
                saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                enum pattern = "Line added to timer <b>%s<b>.";
                immutable message = pattern.format(name);
                chan(plugin.state, event.channel, message);
                return;
            }
        }

        // If we're here, no timer was found with the given name
        return sendNoSuchTimerAdd();

    case "del":
        import std.algorithm.mutation : SwapStrategy, remove;

        void sendDelUsage()
        {
            enum pattern = "Usage: <b>%s%s<b> del [timer name] [optional line number]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, channelName, message);
        }

        if (!slice.length) return sendDelUsage();

        auto timerDefs = channelName in plugin.timerDefsByChannel;
        if (!timerDefs) return sendNoSuchTimer();

        auto channel = channelName in plugin.channels;
        assert(channel);

        string name;
        string linesPosString;

        immutable results = slice.splitInto(name, linesPosString);

        with (SplitResults)
        final switch (results)
        {
        case underrun:
            // Remove the entire timer
            if (!name.length) return sendDelUsage();

            foreach (immutable i, timerDef; *timerDefs)
            {
                if (timerDef.name == name)
                {
                    // Modifying during foreach...
                    *timerDefs = (*timerDefs).remove!(SwapStrategy.unstable)(i);
                    channel.timerFibers = channel.timerFibers.remove!(SwapStrategy.unstable)(i);

                    if (!timerDefs.length) plugin.timerDefsByChannel.remove(channelName);
                    saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                    enum message = "Timer removed.";
                    chan(plugin.state, channelName, message);
                    return;
                }
            }

            return sendNoSuchTimer();

        case match:
            // Remove the specified lines position
            foreach (immutable i, ref timerDef; *timerDefs)
            {
                if (timerDef.name == name)
                {
                    try
                    {
                        immutable linesPos = linesPosString.to!size_t;
                        timerDef.lines = timerDef.lines.remove!(SwapStrategy.stable)(linesPos);
                        saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                        enum pattern = "Line removed from timer. Lines remaining: <b>%d<b>";
                        immutable message = pattern.format(timerDef.lines.length);
                        chan(plugin.state, channelName, message);
                        return;
                    }
                    catch (ConvException e)
                    {
                        enum message = "Argument for which line to remove must be a number.";
                        chan(plugin.state, event.channel, message);
                        return;
                    }
                }
            }

            // If we're here, no timer was found with the given name
            return sendNoSuchTimer();

        case overrun:
            return sendDelUsage();
        }

    case "clear":
        plugin.channels[channelName].timerFibers.length = 0;
        plugin.timerDefsByChannel.remove(channelName);
        saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

        enum message = "All timers cleared.";
        chan(plugin.state, channelName, message);
        break;

    case "list":
        const timerDefs = channelName in plugin.timerDefsByChannel;

        if (!timerDefs)
        {
            enum message = "There are no timers registered for this channel.";
            chan(plugin.state, channelName, message);
            return;
        }

        enum headerPattern = "Current timers for channel <b>%s<b>:";
        immutable headerMessage = headerPattern.format(channelName);
        chan(plugin.state, channelName, headerMessage);

        foreach (const timerDef; *timerDefs)
        {
            enum timerPattern =
                "[\"%s\"] " ~
                "lines:%d | " ~
                "type:%s | " ~
                "condition:%s | " ~
                "message count threshold:%d | " ~
                "time threshold:%d | " ~
                "stagger message count:%d | " ~
                "stagger time:%d";

            immutable timerMessage = timerPattern.format(
                timerDef.name,
                timerDef.lines.length,
                ((timerDef.type == TimerDefinition.Type.random) ? "random" : "sequential"),
                ((timerDef.condition == TimerDefinition.Condition.both) ? "both" : "either"),
                timerDef.messageCountThreshold,
                timerDef.timeThreshold,
                timerDef.staggerMessageCount,
                timerDef.staggerTime,
            );

            chan(plugin.state, channelName, timerMessage);
        }
        break;

    default:
        return sendUsage();
    }
}


// onAnyMessage
/++
    Bumps the message count for any channel on incoming channel messages.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.EMOTE)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onAnyMessage(TimerPlugin plugin, const ref IRCEvent event)
{
    auto channel = event.channel in plugin.channels;

    if (!channel)
    {
        // Race...
        plugin.handleSelfjoin(event.channel);
        channel = event.channel in plugin.channels;
    }

    ++channel.messageCount;
}


// onWelcome
/++
    Loads timers from disk. Additionally sets up a Fiber to periodically call
    timer [core.thread.fiber.Fiber|Fiber]s with a periodicity of [FiberPlugin.timerPeriodicity].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(TimerPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import lu.json : JSONStorage;
    import std.datetime.systime : Clock;

    plugin.reload();

    void periodicDg()
    {
        while (true)
        {
            // Walk through channels, trigger fibers
            foreach (immutable channelName, room; plugin.channels)
            {
                foreach (timerFiber; room.timerFibers)
                {
                    if (!timerFiber || (timerFiber.state != Fiber.State.HOLD))
                    {
                        logger.error("Dead or busy timer Fiber in channel ", channelName);
                        continue;
                    }

                    timerFiber.call();
                }
            }

            delay(plugin, plugin.timerPeriodicity, Yes.yield);
        }
    }

    Fiber periodicFiber = new Fiber(&periodicDg, BufferSize.fiberStack);
    delay(plugin, periodicFiber, plugin.timerPeriodicity);
}


// onSelfjoin
/++
    Simply passes on execution to [handleSelfjoin].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TimerPlugin plugin, const ref IRCEvent event)
{
    return plugin.handleSelfjoin(event.channel);
}


// handleSelfjoin
/++
    Registers a new [TimerPlugin.Channel] as we join a channel, so there's
    always a state struct available.

    Creates the timer [core.thread.fiber.Fiber|Fiber]s that there are definitions
    for in [TimerPlugin.timerDefsByChannel].

    Params:
        plugin = The current [TimerPlugin].
        channelName = The name of the channel we're supposedly joining.
 +/
void handleSelfjoin(TimerPlugin plugin, const string channelName)
{
    if (channelName in plugin.channels) return;

    plugin.channels[channelName] = TimerPlugin.Channel(channelName);
    auto timerDefs = channelName in plugin.timerDefsByChannel;

    if (timerDefs)
    {
        auto channel = channelName in plugin.channels;

        foreach (/*const*/ timerDef; *timerDefs)
        {
            channel.timerFibers ~= plugin.createTimerFiber(timerDef, channelName);
        }
    }
}


// createTimerFiber
/++
    Given a [TimerDefinition] and a string channel name, creates a
    [core.thread.fiber.Fiber|Fiber] that implements the timer.

    Params:
        plugin = The current [kameloso.plugins.timer.TimerPlugin|TimerPlugin].
        timerDef = Definition of the timer to apply.
        channelName = String channel to which the timer belongs.
 +/
Fiber createTimerFiber(
    TimerPlugin plugin,
    /*const*/ TimerDefinition timerDef,
    const string channelName)
{
    import kameloso.constants : BufferSize;

    void dg()
    {
        import std.datetime.systime : Clock;

        /// FIXME
        const channel = channelName in plugin.channels;

        /// FIXME
        immutable creationMessageCount = channel.messageCount;

        /// When this timer Fiber was created.
        immutable creationTime = Clock.currTime.toUnixTime;

        if (timerDef.condition == TimerDefinition.Condition.both)
        {
            while (true)
            {
                // Stagger messages
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - creationMessageCount) < timerDef.staggerMessageCount);

                if (messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }
                else
                {
                    // ended, so break and join the next loop
                    break;
                }
            }

            while (true)
            {
                // Stagger time
                immutable timerUnfulfilled =
                    ((Clock.currTime.toUnixTime - creationTime) < timerDef.staggerTime);

                if (timerUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }
                else
                {
                    // ended, so break and join the main loop
                    break;
                }
            }
        }
        else /*if (timerDef.condition == TimerDefinition.Condition.either)*/
        {
            while (true)
            {
                // Stagger until either is fulfilled
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - creationMessageCount) < timerDef.staggerMessageCount);
                immutable timerUnfulfilled =
                    ((Clock.currTime.toUnixTime - creationTime) < timerDef.staggerTime);

                if (timerUnfulfilled && messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }
                else
                {
                    // ended, so break and join the main loop
                    break;
                }
            }
        }

        /// The channel message count at last successful trigger.
        ulong lastMessageCount = channel.messageCount;  // or creation?

        /// The timestamp at the last successful trigger.
        long lastTimestamp = Clock.currTime.toUnixTime;  // or creation?

        while (true)
        {
            ulong now;

            if (timerDef.condition == TimerDefinition.Condition.both)
            {
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - lastMessageCount) < timerDef.messageCountThreshold);

                if (messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }

                now = Clock.currTime.toUnixTime;
                immutable timerUnfulfilled = ((now - lastTimestamp) < timerDef.timeThreshold);

                if (timerUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }
            }
            else /*if (timerDef.condition == TimerDefinition.Condition.either)*/
            {
                now = Clock.currTime.toUnixTime;

                immutable messageCountUnfulfilled =
                    ((channel.messageCount - lastMessageCount) < timerDef.messageCountThreshold);
                immutable timerUnfulfilled =
                    ((now - lastTimestamp) < timerDef.staggerTime);

                if (timerUnfulfilled && messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }
            }

            import std.array : replace;
            import std.conv : text;
            import std.random : uniform;

            string line = timerDef.getLine()
                .replace("$bot", plugin.state.client.nickname)
                .replace("$channel", channelName[1..$])
                .replace("$random", uniform!"(]"(0, 100).text);

            version(TwitchSupport)
            {
                if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                {
                    import kameloso.plugins.common.misc : nameOf;
                    line = line.replace("$streamer", plugin.nameOf(channelName[1..$]));
                }
            }

            chan(plugin.state, channelName, line);

            lastMessageCount = channel.messageCount;
            lastTimestamp = now;

            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&dg, BufferSize.fiberStack);
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for timers.

    Params:
        aa = The associative array to convert into JSON and save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const TimerDefinition[][string] aa, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    JSONValue json;
    json = null;
    json.object = null;

    foreach (immutable channelName, const timerDefs; aa)
    {
        json[channelName] = null;
        json[channelName].array = null;

        foreach (const timerDef; timerDefs)
        {
            json[channelName].array ~= timerDef.toJSON();
        }
    }

    File(filename, "w").writeln(json.toPrettyString);
}


// initResources
/++
    Reads and writes the file of timers to disk, ensuring that they're there and
    properly formatted.
 +/
void initResources(TimerPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage timersJSON;

    try
    {
        timersJSON.load(plugin.timerFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.timerFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    timersJSON.save(plugin.timerFile);
}


// reload
/++
    Reloads resources from disk.
 +/
void reload(TimerPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage allTimersJSON;
    allTimersJSON.load(plugin.timerFile);

    plugin.timerDefsByChannel = null;

    foreach (immutable channelName, const timerDefsJSON; allTimersJSON.object)
    {
        foreach (const timerDefJSON; timerDefsJSON.array)
        {
            plugin.timerDefsByChannel[channelName] ~= TimerDefinition.fromJSON(timerDefJSON);
        }
    }

    plugin.timerDefsByChannel = plugin.timerDefsByChannel.rehash();
}


mixin MinimalAuthentication;

version(TwitchSupport)
{
    mixin UserAwareness;
}


public:


// TimerPlugin
/++
    The Timer plugin serves reoccuring (timered) announcements.
 +/
final class TimerPlugin : IRCPlugin
{
private:
    import core.time : seconds;

public:
    /// Contained state of a channel, so that there can be several alongside each other.
    static struct Channel
    {
        /// Name of the channel.
        string channelName;

        /// Current message count.
        ulong messageCount;

        /// Concrete Timer [core.thread.fiber.Fiber|Fiber]s.
        Fiber[] timerFibers;
    }

    /// All Timer plugin settings.
    TimerSettings timerSettings;

    /// Array of active channels' state.
    Channel[string] channels;

    /// Associative array of timers; [TimerDefinition] array, keyed by channel name.
    TimerDefinition[][string] timerDefsByChannel;

    /// Filename of file with timer definitions.
    @Resource string timerFile = "timers.json";

    /++
        How often to check whether timers should fire. A smaller number means
        better precision, but also marginally higher gc pressure.
     +/
    static immutable timerPeriodicity = 15.seconds;

    mixin IRCPluginImpl;
}

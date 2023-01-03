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
import kameloso.common : logger;
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
    /++
        Toggle whether or not this plugin should do anything at all.
     +/
    @Enabler bool enabled = true;
}


// Timer
/++
    Definitions of a timer.
 +/
struct Timer
{
private:
    import std.json : JSONValue;

public:
    /++
        The different kinds of [Timer]s. Either one that yields a
        [Type.random|random] response each time, or one that yields a
        [Type.ordered|ordered] one.
     +/
    enum Type
    {
        /++
            Lines should be yielded in a random (technically uniform) order.
         +/
        random = 0,

        /++
            Lines should be yielded in order, bumping an internal counter.
         +/
        ordered = 1,
    }

    /++
        Conditions upon which timers decide whether they are to fire yet, or wait still.
     +/
    enum Condition
    {
        /++
            Both message count and time criteria must be fulfilled.
         +/
        both = 0,

        /++
            Either message count or time criteria may be fulfilled.
         +/
        either = 1,
    }

    /++
        String name identifier of this timer.
     +/
    string name;

    /++
        String name of the channel the [Timer] should trigger in.
     +/
    string channelName;

    /++
        The timered lines to send to the channel.
     +/
    string[] lines;

    /++
        What type of [Timer] this is.
     +/
    Type type;

    /++
        Workhorse [core.thread.fiber.Fiber|Fiber].
     +/
    Fiber fiber;

    /++
        What message/time conditions this [Timer] abides by.
     +/
    Condition condition;

    /++
        How many messages must have been sent since the last announce before we
        will allow another one.
     +/
    long messageCountThreshold;

    /++
        How many seconds must have passed since the last announce before we will
        allow another one.
     +/
    long timeThreshold;

    /++
        Delay in number of messages before the timer initially comes into effect.
     +/
    long messageCountStagger;

    /++
        Delay in seconds before the timer initially comes into effect.
     +/
    long timeStagger;

    /++
        The current position, kept to keep track of what line should be yielded
        next in the case of ordered timers.
     +/
    size_t position;

    // getLine
    /++
        Yields a line from the [lines] array, depending on the [type] of this timer.

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    auto getLine()
    {
        return (type == Type.random) ?
            randomLine() :
            nextOrderedLine();
    }

    // nextOrderedLine
    /++
        Yields an ordered line from the [lines] array. Which line is selected
        depends on the value of [position].

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    auto nextOrderedLine()
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
    auto randomLine() const
    {
        import std.random : uniform;

        if (!lines.length) return string.init;

        return lines[uniform(0, lines.length)];
    }

    // toJSON
    /++
        Serialises this [Timer] into a [std.json.JSONValue|JSONValue].

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this timer.
     +/
    auto toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["name"] = JSONValue(this.name);
        json["channelName"] = JSONValue(this.channelName);
        json["type"] = JSONValue(cast(int)this.type);
        json["condition"] = JSONValue(cast(int)this.condition);
        json["messageCountThreshold"] = JSONValue(this.messageCountThreshold);
        json["timeThreshold"] = JSONValue(this.timeThreshold);
        json["messageCountStagger"] = JSONValue(this.messageCountStagger);
        json["timeStagger"] = JSONValue(this.timeStagger);
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
        Deserialises a [Timer] from a [std.json.JSONValue|JSONValue].

        Params:
            json = [std.json.JSONValue|JSONValue] to deserialise.

        Returns:
            A new [Timer] with values loaded from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        Timer timer;
        timer.name = json["name"].str;
        timer.channelName = json["channelName"].str;
        timer.messageCountThreshold = json["messageCountThreshold"].integer;
        timer.timeThreshold = json["timeThreshold"].integer;
        timer.messageCountStagger = json["messageCountStagger"].integer;
        timer.timeStagger = json["timeStagger"].integer;
        timer.type = (json["type"].integer == cast(int)Type.random) ?
            Type.random :
            Type.ordered;
        timer.condition = (json["condition"].integer == cast(int)Condition.both) ?
            Condition.both :
            Condition.either;

        foreach (const lineJSON; json["lines"].array)
        {
            timer.lines ~= lineJSON.str;
        }

        return timer;
    }
}


// onCommandTimer
/++
    Adds, deletes or lists timers for the specified target channel.

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
            .description("Adds, removes or lists timers.")
            .addSyntax("$command new [name] [type] [condition] [message count threshold] " ~
                "[time threshold] [stagger message count] [stagger time]")
            .addSyntax("$command add [existing timer name] [new timer line]")
            .addSyntax("$command insert [timer name] [position] [new timer line]")
            .addSyntax("$command edit [timer name] [position] [new timer line]")
            .addSyntax("$command del [timer name] [optional line number]")
            .addSyntax("$command list")
    )
)
void onCommandTimer(TimerPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [new|add|del|list] ...";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "new":
        return handleNewTimer(plugin, event, slice);

    case "insert":
        return handleModifyTimerLines(plugin, event, slice, Yes.insert);

    case "edit":
        return handleModifyTimerLines(plugin, event, slice, No.insert);  // --> Yes.edit

    case "add":
        return handleAddToTimer(plugin, event, slice);

    case "del":
        return handleDelTimer(plugin, event, slice);

    case "list":
        return handleListTimers(plugin, event);

    default:
        return sendUsage();
    }
}


// handleNewTimer
/++
    Creates a new timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the creation.
        slice = Relevant slice of the original request string.
 +/
void handleNewTimer(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice)
{
    import kameloso.time : DurationStringException, abbreviatedDuration;
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendNewUsage()
    {
        enum pattern = "Usage: <b>%s%s new<b> [name] [type] [condition] [message count threshold] " ~
            "[time threshold] [stagger message count] [stagger time]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendBadNumerics()
    {
        enum message = "Arguments for threshold and stagger values must all be positive numbers.";
        chan(plugin.state, event.channel, message);
    }

    void sendZeroedConditions()
    {
        enum message = "A timer cannot have a message threshold *and* a time threshold of zero.";
        chan(plugin.state, event.channel, message);
    }

    Timer timer;

    string type;
    string condition;
    string messageCountThreshold;
    string timeThreshold;
    string messageCountStagger;
    string timeStagger;

    immutable results = slice.splitInto(
        timer.name,
        type,
        condition,
        messageCountThreshold,
        timeThreshold,
        messageCountStagger,
        timeStagger);

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

    switch (type)
    {
    case "random":
        timer.type = Timer.Type.random;
        break;

    case "ordered":
        timer.type = Timer.Type.ordered;
        break;

    default:
        enum message = "Type must be one of <b>random<b> or <b>ordered<b>.";
        return chan(plugin.state, event.channel, message);
    }

    switch (condition)
    {
    case "both":
        timer.condition = Timer.Condition.both;
        break;

    case "either":
        timer.condition = Timer.Condition.either;
        break;

    default:
        enum message = "Condition must be one of <b>both<b> or <b>either<b>.";
        return chan(plugin.state, event.channel, message);
    }

    try
    {
        timer.messageCountThreshold = messageCountThreshold.to!long;
        timer.timeThreshold = abbreviatedDuration(timeThreshold).total!"seconds";
        if (messageCountStagger.length) timer.messageCountStagger = messageCountStagger.to!long;
        if (timeStagger.length) timer.timeStagger = abbreviatedDuration(timeStagger).total!"seconds";
    }
    catch (ConvException e)
    {
        return sendBadNumerics();
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }

    if ((timer.messageCountThreshold < 0) ||
        (timer.timeThreshold < 0) ||
        (timer.messageCountStagger < 0) ||
        (timer.timeStagger < 0))
    {
        return sendBadNumerics();
    }
    else if ((timer.messageCountThreshold == 0) && (timer.timeThreshold == 0))
    {
        return sendZeroedConditions();
    }

    timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
    auto channel = event.channel in plugin.channels;

    /*if (!channel)
    {
        plugin.channels[event.channel] = TimerPlugin.Channel.init;
        channel = event.channel in plugin.channels;
    }*/

    plugin.timersByChannel[event.channel][timer.name] = timer;
    channel.timerPointers[timer.name] = &plugin.timersByChannel[event.channel][timer.name];

    enum appendPattern = "New timer added! Use <b>%s%s add<b> to add lines.";
    immutable message = appendPattern.format(plugin.state.settings.prefix, event.aux);
    chan(plugin.state, event.channel, message);
}


// handleDelTimer
/++
    Deletes an existing timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the deletion.
        slice = Relevant slice of the original request string.
 +/
void handleDelTimer(
    TimerPlugin plugin,
    const ref IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.format : format;

    void sendDelUsage()
    {
        enum pattern = "Usage: <b>%s%s del<b> [timer name] [optional line number]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel, message);
    }

    if (!slice.length) return sendDelUsage();

    auto channel = event.channel in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    string name;
    string linePosString;

    immutable results = slice.splitInto(name, linePosString);

    with (SplitResults)
    final switch (results)
    {
    case underrun:
        // Remove the entire timer
        if (!name.length) return sendDelUsage();

        const timerPtr = name in channel.timerPointers;
        if (!timerPtr) return sendNoSuchTimer();

        channel.timerPointers.remove(name);
        if (!channel.timerPointers.length) plugin.channels.remove(event.channel);

        auto channelTimers = event.channel in plugin.timersByChannel;
        (*channelTimers).remove(name);
        if (!channelTimers.length) plugin.timersByChannel.remove(event.channel);

        saveTimersToDisk(plugin);
        enum message = "Timer removed.";
        return chan(plugin.state, event.channel, message);

    case match:
        import std.conv : ConvException, to;

        // Remove the specified lines position
        auto channelTimers = event.channel in plugin.timersByChannel;
        if (!channelTimers) return sendNoSuchTimer();

        auto timer = name in *channelTimers;
        if (!timer) return sendNoSuchTimer();

        try
        {
            import std.algorithm.mutation : SwapStrategy, remove;

            immutable linePos = linePosString.to!size_t;
            timer.lines = timer.lines.remove!(SwapStrategy.stable)(linePos);
            saveTimersToDisk(plugin);

            enum pattern = "Line removed from timer <b>%s<b>. Lines remaining: <b>%d<b>";
            immutable message = pattern.format(name, timer.lines.length);
            return chan(plugin.state, event.channel, message);
        }
        catch (ConvException e)
        {
            enum message = "Argument for which line to remove must be a number.";
            return chan(plugin.state, event.channel, message);
        }

    case overrun:
        sendDelUsage();
    }
}


// handleModifyTimerLines
/++
    Edits a line of an existing timer, or insert one at a specific line position.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the insert or edit.
        slice = Relevant slice of the original request string.
        shouldInsert = Whether or not an insert action was requested. If `No.shouldInsert`,
            then an edit action was requested.
 +/
void handleModifyTimerLines(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice,
    const Flag!"insert" shouldInsert)
{
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendInsertUsage()
    {
        if (shouldInsert)
        {
            enum pattern = "Usage: <b>%s%s insert<b> [timer name] [position] [timer text]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum pattern = "Usage: <b>%s%s edit<b> [timer name] [position] [new timer text]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
        }
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel, message);
    }

    void sendOutOfRange(const size_t upperBound)
    {
        enum pattern = "Line position out of range; valid is <b>[0..%d]<b> (inclusive).";
        immutable message = pattern.format(upperBound);
        chan(plugin.state, event.channel, message);
    }

    string name;
    string linePosString;

    immutable results = slice.splitInto(name, linePosString);
    if (results != SplitResults.overrun) return sendInsertUsage();

    auto channel = event.channel in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    void destroyUpdateSave()
    {
        destroy(timer.fiber);
        timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
        saveTimersToDisk(plugin);
    }

    try
    {
        immutable linePos = linePosString.to!ptrdiff_t;
        if ((linePos < 0) || (linePos >= timer.lines.length)) return sendOutOfRange(timer.lines.length);

        if (shouldInsert)
        {
            import std.array : insertInPlace;

            timer.lines.insertInPlace(linePos, slice);
            destroyUpdateSave();

            enum pattern = "Line added to timer <b>%s<b>.";
            immutable message = pattern.format(name);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            timer.lines[linePos] = slice;
            destroyUpdateSave();

            enum pattern = "Line <b>%d<b> of timer <b>%s<b> edited.";
            immutable message = pattern.format(linePos, name);
            chan(plugin.state, event.channel, message);
        }
    }
    catch (ConvException e)
    {
        enum message = "Position argument must be a number.";
        chan(plugin.state, event.channel, message);
    }
}


// handleAddToTimer
/++
    Adds a line to an existing timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the addition.
        slice = Relevant slice of the original request string.
 +/
void handleAddToTimer(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : nom;
    import std.format : format;

    void sendAddUsage()
    {
        enum pattern = "Usage: <b>%s%s add<b> [existing timer name] [new timer line]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimer()
    {
        enum noSuchTimerPattern = "No such timer is defined. Add a new one with <b>%s%s new<b>.";
        immutable noSuchTimerMessage = noSuchTimerPattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, noSuchTimerMessage);
    }

    immutable name = slice.nom!(Yes.inherit)(' ');
    if (!slice.length) return sendAddUsage();

    auto channel = event.channel in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    void destroyUpdateSave()
    {
        destroy(timer.fiber);
        timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
        saveTimersToDisk(plugin);
    }

    timer.lines ~= slice;
    destroyUpdateSave();

    enum pattern = "Line added to timer <b>%s<b>.";
    immutable message = pattern.format(name);
    chan(plugin.state, event.channel, message);
}


// handleListTimers
/++
    Lists all timers.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the listing.
 +/
void handleListTimers(
    TimerPlugin plugin,
    const ref IRCEvent event)
{
    import std.format : format;

    void sendNoTimersForChannel()
    {
        enum message = "There are no timers registered for this channel.";
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel, message);
    }

    const channel = event.channel in plugin.channels;
    if (!channel) return sendNoTimersForChannel();

    auto channelTimers = event.channel in plugin.timersByChannel;
    if (!channelTimers) return sendNoTimersForChannel();

    enum headerPattern = "Current timers for channel <b>%s<b>:";
    immutable headerMessage = headerPattern.format(event.channel);
    chan(plugin.state, event.channel, headerMessage);

    foreach (const timer; *channelTimers)
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
            timer.name,
            timer.lines.length,
            ((timer.type == Timer.Type.random) ? "random" : "ordered"),
            ((timer.condition == Timer.Condition.both) ? "both" : "either"),
            timer.messageCountThreshold,
            timer.timeThreshold,
            timer.messageCountStagger,
            timer.timeStagger,
        );

        chan(plugin.state, event.channel, timerMessage);
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
        handleSelfjoin(plugin, event.channel, No.force);
        channel = event.channel in plugin.channels;
    }

    ++channel.messageCount;
}


// onWelcome
/++
    Loads timers from disk. Additionally sets up a [core.thread.fiber.Fiber|Fiber]
    to periodically call timer [core.thread.fiber.Fiber|Fiber]s with a periodicity
    of [TimerPlugin.timerPeriodicity].

    Don't call `reload` for this! It undoes anything `handleSelfjoin` may have done.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(TimerPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import lu.json : JSONStorage;
    import core.thread : Fiber;

    JSONStorage allTimersJSON;
    allTimersJSON.load(plugin.timerFile);

    foreach (immutable channelName, const timersJSON; allTimersJSON.object)
    {
        auto channelTimers = channelName in plugin.timersByChannel;
        if (!channelTimers) plugin.timersByChannel[channelName] = typeof(plugin.timersByChannel[channelName]).init;

        foreach (const timerJSON; timersJSON.array)
        {
            auto timer = Timer.fromJSON(timerJSON);
            (*channelTimers)[timer.name] = timer;
        }

        *channelTimers = channelTimers.rehash();
    }

    plugin.timersByChannel = plugin.timersByChannel.rehash();

    void fiberTriggerDg()
    {
        while (true)
        {
            // Walk through channels, trigger fibers
            foreach (immutable channelName, channel; plugin.channels)
            {
                foreach (timerPtr; channel.timerPointers)
                {
                    if (!timerPtr.fiber || (timerPtr.fiber.state != Fiber.State.HOLD))
                    {
                        logger.error("Dead or busy timer Fiber in channel ", channelName);
                        continue;
                    }

                    timerPtr.fiber.call();
                }
            }

            delay(plugin, plugin.timerPeriodicity, Yes.yield);
            // continue;
        }
    }

    Fiber fiberTriggerFiber = new Fiber(&fiberTriggerDg, BufferSize.fiberStack);
    delay(plugin, fiberTriggerFiber, plugin.timerPeriodicity);
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
    return handleSelfjoin(plugin, event.channel, No.force);
}


// handleSelfjoin
/++
    Registers a new [TimerPlugin.Channel] as we join a channel, so there's
    always a state struct available.

    Creates the timer [core.thread.fiber.Fiber|Fiber]s that there are definitions
    for in [TimerPlugin.timersByChannel].

    Params:
        plugin = The current [TimerPlugin].
        channelName = The name of the channel we're supposedly joining.
        force = Whether or not to always set up the channel, regardless of its
            current existence.
 +/
void handleSelfjoin(
    TimerPlugin plugin,
    const string channelName,
    const Flag!"force" force = No.force)
{
    auto channel = channelName in plugin.channels;
    auto channelTimers = channelName in plugin.timersByChannel;

    if (!channel || force)
    {
        // No channel or forcing; create
        plugin.channels[channelName] = TimerPlugin.Channel(channelName);  // as above
        if (!channel) channel = channelName in plugin.channels;
    }

    if (channelTimers)
    {
        // Populate timers
        foreach (ref timer; *channelTimers)
        {
            destroy(timer.fiber);
            timer.fiber = createTimerFiber(plugin, channelName, timer.name);
            channel.timerPointers[timer.name] = &timer;  // Will this work in release mode?
        }
    }
}


// createTimerFiber
/++
    Given a [Timer] and a string channel name, creates a
    [core.thread.fiber.Fiber|Fiber] that implements the timer.

    Params:
        plugin = The current [TimerPlugin].
        channelName = String channel to which the timer belongs.
        name = Timer name, used as inner key in [TimerPlugin.timersByChannel].
 +/
auto createTimerFiber(
    TimerPlugin plugin,
    const string channelName,
    const string name)
{
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;

    void createTimerDg()
    {
        import std.datetime.systime : Clock;

        /// Channel pointer.
        const channel = channelName in plugin.channels;
        assert(channel, channelName ~ " not in plugin.channels");

        auto channelTimers = channelName in plugin.timersByChannel;
        assert(channelTimers, channelName ~ " not in plugin.timersByChanel");

        auto timer = name in *channelTimers;
        assert(timer, name ~ " not in *channelTimers");

        /// Initial message count.
        immutable creationMessageCount = channel.messageCount;

        /// When this timer Fiber was created.
        immutable creationTime = Clock.currTime.toUnixTime;

        if (timer.condition == Timer.Condition.both)
        {
            while (true)
            {
                // Stagger messages
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - creationMessageCount) < timer.messageCountStagger);

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
                    ((Clock.currTime.toUnixTime - creationTime) < timer.timeStagger);

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
        else /*if (timer.condition == Timer.Condition.either)*/
        {
            while (true)
            {
                // Stagger until either is fulfilled
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - creationMessageCount) < timer.messageCountStagger);
                immutable timerUnfulfilled =
                    ((Clock.currTime.toUnixTime - creationTime) < timer.timeStagger);

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
        ulong lastMessageCount = channel.messageCount;

        /// The timestamp at the last successful trigger.
        long lastTimestamp = Clock.currTime.toUnixTime;

        /// `Condition.both` fulfilled (cache).
        bool conditionBothFulfilled;

        /// `Condition.either` fulfilled (cache).
        bool conditionEitherFulfilled;

        while (true)
        {
            import std.array : replace;
            import std.conv : text;
            import std.random : uniform;

            if ((timer.condition == Timer.Condition.both) && !conditionBothFulfilled)
            {
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - lastMessageCount) < timer.messageCountThreshold);

                if (messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }

                immutable now = Clock.currTime.toUnixTime;
                immutable timerUnfulfilled = ((now - lastTimestamp) < timer.timeThreshold);

                if (timerUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }

                conditionBothFulfilled = true;
            }
            else if ((timer.condition == Timer.Condition.either) && !conditionEitherFulfilled)
            {
                immutable now = Clock.currTime.toUnixTime;
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - lastMessageCount) < timer.messageCountThreshold);
                immutable timerUnfulfilled =
                    ((now - lastTimestamp) < timer.timeStagger);

                if (timerUnfulfilled && messageCountUnfulfilled)
                {
                    Fiber.yield();
                    continue;
                }

                conditionEitherFulfilled = true;
            }

            string line = timer.getLine()  // mutable
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
            lastTimestamp = Clock.currTime.toUnixTime;

            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&createTimerDg, BufferSize.fiberStack);
}


// saveTimersToDisk
/++
    Saves timers to disk in JSON format.

    Params:
        plugin = The current [TimerPlugin].
 +/
void saveTimersToDisk(TimerPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage json;

    foreach (immutable channelName, const timers; plugin.timersByChannel)
    {
        json[channelName] = null;
        json[channelName].array = null;

        foreach (const timer; timers)
        {
            json[channelName].array ~= timer.toJSON();
        }
    }

    json.save(plugin.timerFile);
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
        throw new IRCPluginInitialisationException(
            "Timer file is malformed",
            plugin.name,
            plugin.timerFile,
            __FILE__,
            __LINE__);
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

    // Clear timerByChannel and reload from disk
    plugin.timersByChannel = null;

    foreach (immutable channelName, const timersJSON; allTimersJSON.object)
    {
        foreach (const timerJSON; timersJSON.array)
        {
            auto timer = Timer.fromJSON(timerJSON);
            plugin.timersByChannel[channelName][timer.name] = timer;
        }
    }

    plugin.timersByChannel = plugin.timersByChannel.rehash();

    // Recreate timers from definitions
    foreach (immutable channelName, channel; plugin.channels)
    {
        // Just reuse the SELFJOIN routine, but be sure to force it
        // it will destroy the fibers, so we don't have to here
        handleSelfjoin(plugin, channelName, Yes.force);
    }
}


mixin MinimalAuthentication;
mixin ModuleRegistration;

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
    import core.thread : Fiber;
    import core.time : seconds;

public:
    /++
        Contained state of a channel, so that there can be several alongside each other.
     +/
    static struct Channel
    {
        /++
            Name of the channel.
         +/
        string channelName;

        /++
            Current message count.
         +/
        ulong messageCount;

        /++
            Pointers to [Timer]s in [TimerPlugin.timersByChannel].
         +/
        Timer*[string] timerPointers;
    }

    /++
        All Timer plugin settings.
     +/
    TimerSettings timerSettings;

    /++
        Array of active channels' state.
     +/
    Channel[string] channels;

    /++
        Associative array of [Timer]s, keyed by nickname keyed by channel.
     +/
    Timer[string][string] timersByChannel;

    /++
        Filename of file with timer definitions.
     +/
    @Resource string timerFile = "timers.json";

    /++
        How often to check whether timers should fire. A smaller number means
        better precision, but also marginally higher gc pressure.
     +/
    static immutable timerPeriodicity = 15.seconds;

    mixin IRCPluginImpl;
}

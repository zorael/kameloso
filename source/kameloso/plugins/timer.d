/++
    Plugin offering announcement timers; routines that periodically send lines
    of text to a channel.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#timer,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.timer;

version(WithTimerPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import core.thread.fiber : Fiber;


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

    version(TwitchSupport)
    {
        /++
            Toggle whether or not to use Twitch announcements on Twitch servers.
         +/
        bool useAnnouncements = false;
    }
}


// Timer
/++
    Definitions of a timer.
 +/
struct Timer
{
    /++
        The different kinds of [Timer]s. Either one that yields a
        [TimerType.random|random] response each time, or one that yields a
        [TimerType.ordered|ordered] one.
     +/
    enum TimerType
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
    enum TimerCondition
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
        JSON schema of a [Timer].
     +/
    static struct JSONSchema
    {
        private import asdf.serialization : serdeOptional;

        string name;  ///
        int type;  ///
        int condition;  ///
        long messageCountThreshold;  ///
        long timeThreshold;  ///
        long messageCountStagger;  ///
        long timeStagger;  ///
        bool suspended;  ///
        string[] lines;  ///

        @serdeOptional string colour;  ///

        /++
            Returns a [std.json.JSONValue|JSONValue] representation of this [JSONSchema].
         +/
        auto asJSONValue() const
        {
            import std.json : JSONValue;

            JSONValue json;
            json.object = null;
            json["name"] = this.name;
            json["type"] = cast(int) this.type;
            json["condition"] = cast(int) this.condition;
            json["messageCountThreshold"] = this.messageCountThreshold;
            json["timeThreshold"] = this.timeThreshold;
            json["messageCountStagger"] = this.messageCountStagger;
            json["timeStagger"] = this.timeStagger;
            json["colour"] = this.colour;
            json["suspended"] = this.suspended;
            json["lines"] = this.lines.dup;
            return json;
        }
    }

    /++
        String name identifier of this timer.
     +/
    string name;

    /++
        The timered lines to send to the channel.
     +/
    string[] lines;

    /++
        What type of [Timer] this is.
     +/
    TimerType type;

    /++
        Workhorse [core.thread.fiber.Fiber|Fiber].
     +/
    Fiber fiber;

    /++
        What message/time conditions this [Timer] abides by.
     +/
    TimerCondition condition;

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
        The channel message count at last successful trigger.
     +/
    ulong lastMessageCount;

    /++
        The timestamp at the last successful trigger.
     +/
    long lastTimestamp;

    /++
        The current position, kept to keep track of what line should be yielded
        next in the case of ordered timers.
     +/
    size_t position;

    /++
        The colour string to use with Twitch announcements.
     +/
    string colour = "primary";

    /++
        Whether or not this [Timer] is suspended and should not output anything.
     +/
    bool suspended;

    /++
        Constructor.
     +/
    this(const JSONSchema schema)
    {
        this.name = schema.name;
        this.messageCountThreshold = schema.messageCountThreshold;
        this.timeThreshold = schema.timeThreshold;
        this.messageCountStagger = schema.messageCountStagger;
        this.timeStagger = schema.timeStagger;
        this.suspended = schema.suspended;
        this.colour = schema.colour;
        this.lines = schema.lines.dup;

        this.type = (schema.type == cast(int) TimerType.random) ?
            TimerType.random :
            TimerType.ordered;

        this.condition = (schema.condition == cast(int) TimerCondition.both) ?
            TimerCondition.both :
            TimerCondition.either;
    }

    auto asSchema() const
    {
        JSONSchema schema;

        schema.name = this.name;
        schema.type = cast(int) this.type;
        schema.condition = cast(int) this.condition;
        schema.messageCountThreshold = this.messageCountThreshold;
        schema.timeThreshold = this.timeThreshold;
        schema.messageCountStagger = this.messageCountStagger;
        schema.timeStagger = this.timeStagger;
        schema.colour = this.colour;
        schema.suspended = this.suspended;
        schema.lines = this.lines.dup;

        return schema;
    }

    // getLine
    /++
        Yields a line from the [lines] array, depending on the [type] of this timer.

        Returns:
            A line string. If the [lines] array is empty, then an empty string
            is returned instead.
     +/
    auto getLine()
    {
        return (type == TimerType.random) ?
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
        return lines.length ?
            lines[uniform(0, lines.length)] :
            string.init;
    }
}

///
unittest
{
    Timer timer;
    timer.lines = [ "abc", "def", "ghi" ];

    {
        timer.type = Timer.TimerType.ordered;
        assert(timer.getLine() == "abc");
        assert(timer.getLine() == "def");
        assert(timer.getLine() == "ghi");
        assert(timer.getLine() == "abc");
        assert(timer.getLine() == "def");
        assert(timer.getLine() == "ghi");
    }
    {
        import std.algorithm.comparison : among;

        timer.type = Timer.TimerType.random;
        bool[string] linesSeen;

        foreach (immutable i; 0..300)
        {
            linesSeen[timer.getLine()] = true;
        }

        assert("abc" in linesSeen);
        assert("def" in linesSeen);
        assert("ghi" in linesSeen);
    }
}


version(TwitchSupport)
{
    version(WithTwitchPlugin)
    {
        version = WantTwitchAnnouncementColourSyntax;
    }
}


// twitchAnnouncementColourSyntax
/++
    Syntax string to use for the "colour" verb of `!timer`.

    If Twitch support *and* the Twitch plugin is compiled in, it is a
    humanly-readable syntax string, but it will be empty (and thus omitted from
    Help command lists) if either versions are not declared.
 +/
version(WantTwitchAnnouncementColourSyntax)
{
    enum twitchAnnouncementColourSyntax = "$command colour [timer] [colour]";
}
else
{
    /// Ditto
    enum twitchAnnouncementColourSyntax = string.init;
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
            .description("Manages timers.")
            .addSyntax("$command new [name] [type] [condition] [message count threshold] " ~
                "[time threshold] [optional stagger message count] [optional stagger time]")
            .addSyntax("$command modify [name] [type] [condition] [message count threshold] " ~
                "[time threshold] [optional stagger message count] [optional stagger time]")
            .addSyntax(twitchAnnouncementColourSyntax)
            .addSyntax("$command add [existing timer name] [new timer line]")
            .addSyntax("$command insert [timer name] [position] [new timer line]")
            .addSyntax("$command edit [timer name] [position] [new timer line]")
            .addSyntax("$command del [timer name] [optional line number]")
            .addSyntax("$command suspend [timer name]")
            .addSyntax("$command resume [timer name]")
            .addSyntax("$command list")
    )
)
void onCommandTimer(TimerPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [new|modify|add|del|suspend|resume|list] ...";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "new":
        return handleNewTimer(plugin, event, slice);

    case "modify":
    case "mod":
        return handleModifyTimer(plugin, event, slice);

    case "insert":
        return handleModifyTimerLines(plugin, event, slice, insert: true);

    case "edit":
        return handleModifyTimerLines(plugin, event, slice, insert: false);  // --> edit: true

    case "add":
        return handleAddToTimer(plugin, event, slice);

    case "del":
        return handleDelTimer(plugin, event, slice);

    case "suspend":
        return handleSuspendTimer(plugin, event, slice, suspend: true);

    case "resume":
        return handleSuspendTimer(plugin, event, slice, suspend: false);  // --> resume: true

    case "colour":
    case "color":
        return handleColourTimer(plugin, event, slice);

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
    const IRCEvent event,
    /*const*/ string slice)
{
    import kameloso.time : DurationStringException, asAbbreviatedDuration;
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendNewUsage()
    {
        enum pattern = "Usage: <b>%s%s new<b> [name] [type] [condition] [message count threshold] " ~
            "[time threshold] [optional stagger message count] [optional stagger time]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendBadNumerics()
    {
        enum message = "Arguments for threshold and stagger values must all be positive numbers.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendZeroedConditions()
    {
        enum message = "A timer cannot have a message threshold *and* a time threshold of zero.";
        chan(plugin.state, event.channel.name, message);
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
        timer.type = Timer.TimerType.random;
        break;

    case "ordered":
        timer.type = Timer.TimerType.ordered;
        break;

    default:
        enum message = "Type must be one of <b>random<b> or <b>ordered<b>.";
        return chan(plugin.state, event.channel.name, message);
    }

    switch (condition)
    {
    case "both":
        timer.condition = Timer.TimerCondition.both;
        break;

    case "either":
        timer.condition = Timer.TimerCondition.either;
        break;

    default:
        enum message = "Condition must be one of <b>both<b> or <b>either<b>.";
        return chan(plugin.state, event.channel.name, message);
    }

    try
    {
        timer.messageCountThreshold = messageCountThreshold.to!long;
        timer.timeThreshold = timeThreshold.asAbbreviatedDuration.total!"seconds";
        if (messageCountStagger.length) timer.messageCountStagger = messageCountStagger.to!long;
        if (timeStagger.length) timer.timeStagger = timeStagger.asAbbreviatedDuration.total!"seconds";
    }
    catch (ConvException _)
    {
        return sendBadNumerics();
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel.name, e.msg);
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

    auto channel = event.channel.name in plugin.channels;
    assert(channel, "Tried to create a timer in a channel with no IRCChannel in plugin.channels");

    timer.lastMessageCount = channel.messageCount;
    timer.lastTimestamp = event.time;
    timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
    timer.suspended = true;
    plugin.timersByChannel[event.channel.name][timer.name] = timer;
    channel.timerPointers[timer.name] = &plugin.timersByChannel[event.channel.name][timer.name];
    saveTimers(plugin);

    // Start monitor if not already running
    if (!plugin.monitorInstanceID) startTimerMonitor(plugin);

    enum appendPattern = "New timer added! Use <b>%s%s add<b> to add lines " ~
        "and <b>%1$s%2$s resume<b> to start it.";
    immutable message = appendPattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
    chan(plugin.state, event.channel.name, message);
}


// handleModifyTimer
/++
    Modifies an existing timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the modification.
        slice = Relevant slice of the original request string.
 +/
void handleModifyTimer(
    TimerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : splitInto;
    import std.format : format;

    void sendModifyUsage()
    {
        enum pattern = "Usage: <b>%s%s modify<b> [name] [type] [condition] [message count threshold] " ~
            "[time threshold] [optional stagger message count] [optional stagger time]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendBadNumerics()
    {
        enum message = "Arguments for threshold and stagger values must all be positive numbers.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendZeroedConditions()
    {
        enum message = "A timer cannot have a message threshold *and* a time threshold of zero.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNewDescription(const Timer timer)
    {
        import lu.conv : toString;

        enum pattern = "Timer \"<b>%s<b>\" modified to " ~
            "type <b>%s<b>, " ~
            "condition <b>%s<b>, " ~
            "message count threshold <b>%d<b>, " ~
            "time threshold <b>%s<b> seconds, " ~
            "stagger message count <b>%d<b>, " ~
            "stagger time <b>%s<b> seconds";
        immutable message = pattern.format(
            timer.name,
            timer.type.toString,
            timer.condition.toString,
            timer.messageCountThreshold,
            timer.timeThreshold,
            timer.messageCountStagger,
            timer.timeStagger);
        chan(plugin.state, event.channel.name, message);
    }

    string name;
    string typestring;
    string conditionString;
    string messageCountThresholdString;
    string timeThresholdString;
    string messageCountStaggerString;
    string timeStaggerString;
    cast(void) slice.splitInto(
        name,
        typestring,
        conditionString,
        messageCountThresholdString,
        timeThresholdString,
        messageCountStaggerString,
        timeStaggerString);

    if (!typestring.length) return sendModifyUsage();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    Timer.TimerType type;
    Timer.TimerCondition condition;
    long messageCountThreshold;
    long timeThreshold;
    long messageCountStagger;
    long timeStagger;

    switch (typestring)
    {
    case "random":
        type = Timer.TimerType.random;
        break;

    case "ordered":
        type = Timer.TimerType.ordered;
        break;

    default:
        enum message = "Type must be one of <b>random<b> or <b>ordered<b>.";
        return chan(plugin.state, event.channel.name, message);
    }

    if (conditionString.length)
    {
        switch (conditionString)
        {
        case "both":
            condition = Timer.TimerCondition.both;
            break;

        case "either":
            condition = Timer.TimerCondition.either;
            break;

        default:
            enum message = "Condition must be one of <b>both<b> or <b>either<b>.";
            return chan(plugin.state, event.channel.name, message);
        }
    }

    if (messageCountThresholdString.length)
    {
        import kameloso.time : DurationStringException, asAbbreviatedDuration;
        import std.conv : ConvException, to;

        try
        {
            messageCountThreshold = messageCountThresholdString.to!long;
            if (timeThresholdString.length) timeThreshold = timeThresholdString.asAbbreviatedDuration.total!"seconds";
            if (messageCountStaggerString.length) messageCountStagger = messageCountStaggerString.to!long;
            if (timeStaggerString.length) timeStagger = timeStaggerString.asAbbreviatedDuration.total!"seconds";
        }
        catch (DurationStringException e)
        {
            return chan(plugin.state, event.channel.name, e.msg);
        }
        catch (ConvException _)
        {
            enum message = "Message count threshold must be a positive number.";
            return chan(plugin.state, event.channel.name, message);
        }
    }

    if ((messageCountThreshold < 0) ||
        (timeThreshold < 0) ||
        (messageCountStagger < 0) ||
        (timeStagger < 0))
    {
        return sendBadNumerics();
    }
    else if ((timer.messageCountThreshold == 0) && (timer.timeThreshold == 0))
    {
        return sendZeroedConditions();
    }

    if (const channel = event.channel.name in plugin.channels)
    {
        // Reset the message count and timestamp
        timer.lastMessageCount = channel.messageCount;
        timer.lastTimestamp = event.time;
    }

    timer.type = type;
    if (conditionString.length) timer.condition = condition;
    if (messageCountThresholdString.length) timer.messageCountThreshold = messageCountThreshold;
    if (timeThresholdString.length) timer.timeThreshold = timeThreshold;
    if (messageCountStaggerString.length) timer.messageCountStagger = messageCountStagger;
    if (timeStaggerString.length) timer.timeStagger = timeStagger;
    return sendNewDescription(*timer);
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
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.format : format;

    void sendDelUsage()
    {
        enum pattern = "Usage: <b>%s%s del<b> [timer name] [optional line number]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    if (!slice.length) return sendDelUsage();

    auto channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    string name;  // mutable
    string linePosString;  // mutable
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
        // Don't remove no-timer channels from plugin.channels;
        // they're still channels without them

        auto channelTimers = event.channel.name in plugin.timersByChannel;
        (*channelTimers).remove(name);
        if (!channelTimers.length) plugin.timersByChannel.remove(event.channel.name);

        saveTimers(plugin);
        enum message = "Timer removed.";
        return chan(plugin.state, event.channel.name, message);

    case match:
        import std.conv : ConvException, to;

        // Remove the specified lines position
        auto channelTimers = event.channel.name in plugin.timersByChannel;
        if (!channelTimers) return sendNoSuchTimer();

        auto timer = name in *channelTimers;
        if (!timer) return sendNoSuchTimer();

        try
        {
            import std.algorithm.mutation : SwapStrategy, remove;

            immutable linePos = linePosString.to!size_t;
            timer.lines = timer.lines.remove!(SwapStrategy.stable)(linePos);
            saveTimers(plugin);

            enum pattern = "Line removed from timer <b>%s<b>. Lines remaining: <b>%d<b>";
            immutable message = pattern.format(name, timer.lines.length);
            return chan(plugin.state, event.channel.name, message);
        }
        catch (ConvException _)
        {
            enum message = "Argument for which line to remove must be a number.";
            return chan(plugin.state, event.channel.name, message);
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
        insert = Whether or not an insert action was requested. If `insert: false`,
            then an edit action was requested.
 +/
void handleModifyTimerLines(
    TimerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice,
    const bool insert)
{
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendInsertUsage()
    {
        if (insert)
        {
            enum pattern = "Usage: <b>%s%s insert<b> [timer name] [position] [timer text]";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum pattern = "Usage: <b>%s%s edit<b> [timer name] [position] [new timer text]";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            chan(plugin.state, event.channel.name, message);
        }
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOutOfRange(const size_t upperBound)
    {
        enum pattern = "Line position out of range; valid is <b>[0..%d]<b> (inclusive).";
        immutable message = pattern.format(upperBound);
        chan(plugin.state, event.channel.name, message);
    }

    string name;  // mutable
    string linePosString;  // mutable
    immutable results = slice.splitInto(name, linePosString);
    if (results != SplitResults.overrun) return sendInsertUsage();

    auto channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    void destroyUpdateSave()
    {
        destroy(timer.fiber);
        timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
        saveTimers(plugin);
    }

    try
    {
        import lu.string : unquoted;

        immutable linePos = linePosString.to!ptrdiff_t;
        if ((linePos < 0) || (linePos >= timer.lines.length)) return sendOutOfRange(timer.lines.length);

        slice = slice.unquoted;

        if (insert)
        {
            import std.array : insertInPlace;

            timer.lines.insertInPlace(linePos, slice);
            destroyUpdateSave();

            enum pattern = "Line added to timer <b>%s<b>.";
            immutable message = pattern.format(name);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            timer.lines[linePos] = slice;
            destroyUpdateSave();

            enum pattern = "Line <b>#%d<b> of timer <b>%s<b> edited.";
            immutable message = pattern.format(linePos, name);
            chan(plugin.state, event.channel.name, message);
        }
    }
    catch (ConvException _)
    {
        enum message = "Position argument must be a number.";
        chan(plugin.state, event.channel.name, message);
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
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : advancePast, unquoted;
    import std.format : format;

    void sendAddUsage()
    {
        enum pattern = "Usage: <b>%s%s add<b> [existing timer name] [new timer line]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum noSuchTimerPattern = "No such timer is defined. Add a new one with <b>%s%s new<b>.";
        immutable noSuchTimerMessage = noSuchTimerPattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, noSuchTimerMessage);
    }

    immutable name = slice.advancePast(' ', inherit: true);
    if (!slice.length) return sendAddUsage();

    auto channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    void destroyUpdateSave()
    {
        destroy(timer.fiber);
        timer.fiber = createTimerFiber(plugin, event.channel, timer.name);
        saveTimers(plugin);
    }

    timer.lines ~= slice.unquoted;
    destroyUpdateSave();

    enum pattern = "Line added to timer <b>%s<b>.";
    immutable message = pattern.format(name);
    chan(plugin.state, event.channel.name, message);
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
    const IRCEvent event)
{
    import std.format : format;

    void sendNoTimersForChannel()
    {
        enum message = "There are no timers registered for this channel.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    const channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoTimersForChannel();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoTimersForChannel();

    enum headerPattern = "Current timers for channel <b>%s<b>:";
    immutable headerMessage = headerPattern.format(event.channel.name);
    chan(plugin.state, event.channel.name, headerMessage);

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
            "stagger time:%d | " ~
            "suspended:%s";

        immutable timerMessage = timerPattern.format(
            timer.name,
            timer.lines.length,
            ((timer.type == Timer.TimerType.random) ? "random" : "ordered"),
            ((timer.condition == Timer.TimerCondition.both) ? "both" : "either"),
            timer.messageCountThreshold,
            timer.timeThreshold,
            timer.messageCountStagger,
            timer.timeStagger,
            timer.suspended);

        chan(plugin.state, event.channel.name, timerMessage);
    }
}


// handleSuspendTimer
/++
    Suspends or resumes a timer, by modifying [Timer.suspended].

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the suspend or resume.
        slice = Relevant slice of the original request string.
        suspend = Whether or not a suspend action was requested. If `suspend: false`,
            then a resume action was requested.
 +/
void handleSuspendTimer(
    TimerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice,
    const bool suspend)
{
    import lu.string : SplitResults, splitInto;
    import std.format : format;

    void sendUsage()
    {
        immutable verb = suspend ? "suspend" : "resume";
        enum pattern = "Usage: <b>%s%s %s<b> [name]";
        immutable message = pattern.format(
            plugin.state.coreSettings.prefix,
            event.aux[$-1],
            verb);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    string name;  // mutable
    immutable results = slice.splitInto(name);
    if (results != SplitResults.match) return sendUsage();

    auto channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    timer.suspended = suspend;
    saveTimers(plugin);

    if (suspend)
    {
        enum pattern = "Timer suspended. Use <b>%s%s resume %s<b> to resume it.";
        immutable message = pattern.format(
            plugin.state.coreSettings.prefix,
            event.aux[$-1],
            name);
        chan(plugin.state, event.channel.name, message);
    }
    else
    {
        enum message = "Timer resumed!";
        chan(plugin.state, event.channel.name, message);
    }
}


// handleColourTimer
/++
    Assigns a colour to a timer. Used when timers are sent as Twitch announcements.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the suspend or resume.
        slice = Relevant slice of the original request string.
 +/
void handleColourTimer(
    TimerPlugin plugin,
    const IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.algorithm.comparison : among;
    import std.format : format;
    import std.uni : toLower;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s colour<b> [timer name] " ~
            "[colour; one of <b>primary<b>, <b>blue<b>, " ~
            "<b>green<b>, <b>orange<b> or <b>purple<b>]";
        immutable message = pattern.format(
            plugin.state.coreSettings.prefix,
            event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel.name, message);
    }

    string name;  // mutable
    string colourString;  // ditto
    immutable results = slice.splitInto(name, colourString);
    if (results != SplitResults.match) return sendUsage();

    auto channel = event.channel.name in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    auto channelTimers = event.channel.name in plugin.timersByChannel;
    if (!channelTimers) return sendNoSuchTimer();

    auto timer = name in *channelTimers;
    if (!timer) return sendNoSuchTimer();

    immutable colour = colourString.toLower();

    if (!colour.among!("primary", "blue", "green", "orange", "purple"))
    {
        enum message = "Colour must be one of <b>primary<b>, <b>blue<b>, " ~
            "<b>green<b>, <b>orange<b> or <b>purple<b>.";
        chan(plugin.state, event.channel.name, message);
    }
    else
    {
        timer.colour = colour;
        saveTimers(plugin);

        enum message = "Colour changed.";
        chan(plugin.state, event.channel.name, message);
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
void onAnyMessage(TimerPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    auto channel = event.channel.name in plugin.channels;

    if (!channel)
    {
        // Race...
        handleSelfjoin(plugin, event.channel, force: false);
        channel = event.channel.name in plugin.channels;
    }

    ++channel.messageCount;
}


// startTimerMonitor
/++
    Starts the monitor which loops over [Timer]s and calls their
    [core.thread.fiber.Fiber|Fiber]s in turn.

    This overwrites any currently running monitors by changing the value of
    [TimerPlugin.monitorInstanceID]. Likewise, it will end itself if the value
    changes.

    Params:
        plugin = The current [TimerPlugin].
 +/
void startTimerMonitor(TimerPlugin plugin)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.constants : BufferSize;

    immutable oldInstanceID = plugin.monitorInstanceID;
    while (plugin.monitorInstanceID == oldInstanceID)
    {
        import std.random : uniform;
        plugin.monitorInstanceID = uniform(1, uint.max);
    }

    immutable instanceIDSnapshot = plugin.monitorInstanceID;

    void startMonitorDg()
    {
        while (true)
        {
            import std.datetime.systime : Clock;

            if (plugin.monitorInstanceID != instanceIDSnapshot)
            {
                // New monitor started elsewhere
                return;
            }

            // Micro-optimise getting the current time
            long nowInUnix; // = Clock.currTime.toUnixTime();

            // Whether or not there are any timers at all, in any channel
            bool anyTimers;

            // How much time is remaining until the next timer would trigger from time elapsed.
            long timeUntilNextClosestTimeTrigger = long.max;

            // Walk through channels, trigger fibers
            foreach (immutable channelName, channel; plugin.channels)
            {
                inner:
                foreach (immutable timerName, timerPtr; channel.timerPointers)
                {
                    if (!timerPtr.fiber || (timerPtr.fiber.state != Fiber.State.HOLD))
                    {
                        enum pattern = `Dead or busy fiber in <l>%s</> timer "<l>%s</>"`;
                        logger.errorf(pattern, channelName, timerName);
                        continue inner;
                    }

                    anyTimers = true;

                    // Get time here and cache it
                    if (!nowInUnix) nowInUnix = Clock.currTime.toUnixTime();

                    if (!timerPtr.lines.length)
                    {
                        // Message and time counting should not be done if there
                        // are no lines in the timer.
                        timerPtr.lastMessageCount = channel.messageCount;
                        timerPtr.lastTimestamp = nowInUnix;
                        continue;  // line-less timers are never called
                    }

                    immutable timeSinceLast = (nowInUnix - timerPtr.lastTimestamp);
                    immutable timeRemaining = (timerPtr.timeThreshold - timeSinceLast);
                    immutable timeConditionMet = (timeRemaining <= 0);

                    immutable messagesSinceLast = (channel.messageCount - timerPtr.lastMessageCount);
                    immutable messagesRemaining = (timerPtr.messageCountThreshold - messagesSinceLast);
                    immutable messageConditionMet = (messagesRemaining <= 0);

                    bool satisfied;

                    if (timerPtr.condition == Timer.TimerCondition.both)
                    {
                        if (timeConditionMet && messageConditionMet)
                        {
                            timerPtr.fiber.call();
                            satisfied = true;
                        }
                    }
                    else /*if (timerPtr.condition == Timer.TimerCondition.either)*/
                    {
                        if (timeConditionMet || messageConditionMet)
                        {
                            timerPtr.fiber.call();
                            satisfied = true;
                        }
                    }

                    if (!satisfied && !timeConditionMet)
                    {
                        if (timeRemaining < timeUntilNextClosestTimeTrigger)
                        {
                            // Update the time until the next closest time trigger
                            timeUntilNextClosestTimeTrigger = timeRemaining;
                        }
                    }
                }
            }

            if (!anyTimers)
            {
                // There were channels but no timers in them, so end monitor
                plugin.monitorInstanceID = 0;
                return;
            }

            static immutable timerPeriodicitySeconds = plugin.timerPeriodicity.total!"seconds";

            if (timeUntilNextClosestTimeTrigger < timerPeriodicitySeconds)
            {
                import core.time : seconds;

                // Sleep until the next closest time trigger
                immutable timeUntilNextClosestTimeTriggerDuration = timeUntilNextClosestTimeTrigger.seconds;
                delay(plugin, timeUntilNextClosestTimeTriggerDuration, yield: true);
            }
            else
            {
                // Sleep the normal periodicity
                delay(plugin, plugin.timerPeriodicity, yield: true);
            }
        }
    }

    auto startMonitorFiber = new Fiber(&startMonitorDg, BufferSize.fiberStack);
    startMonitorFiber.call();
}


// onWelcome
/++
    Loads timers from disk.

    Additionally starts the monitor fiber, which loops to periodically call
    timer [core.thread.fiber.Fiber|Fiber]s with a periodicity of
    [TimerPlugin.timerPeriodicity].

    Don't call [reload] for this! It undoes anything [handleSelfjoin] may have done.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(TimerPlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    loadTimers(plugin);
}


// onSelfjoin
/++
    Simply passes on execution to [handleSelfjoin].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TimerPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    handleSelfjoin(plugin, event.channel, force: false);
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
    const IRCEvent.Channel eventChannel,
    const bool force = false)
{
    auto channel = eventChannel.name in plugin.channels;
    auto channelTimers = eventChannel.name in plugin.timersByChannel;

    if (!channel || force)
    {
        // No channel or forcing; create
        plugin.channels[eventChannel.name] = TimerPlugin.Channel(eventChannel);  // as above
        if (!channel) channel = eventChannel.name in plugin.channels;
    }

    if (channelTimers)
    {
        import std.datetime.systime : Clock;

        immutable nowInUnix = Clock.currTime.toUnixTime();

        // Populate timers
        foreach (ref timer; *channelTimers)
        {
            destroy(timer.fiber);
            timer.lastMessageCount = channel.messageCount;
            timer.lastTimestamp = nowInUnix;
            timer.fiber = createTimerFiber(plugin, eventChannel, timer.name);
            channel.timerPointers[timer.name] = &timer;  // Will this work in release mode?
        }

        if (!plugin.monitorInstanceID)
        {
            startTimerMonitor(plugin);
        }
    }
}


// createTimerFiber
/++
    Given a [Timer] and a string channel name, creates a
    [core.thread.fiber.Fiber|Fiber] that implements the timer.

    Params:
        plugin = The current [TimerPlugin].
        eventChannel = Channel from the [dialect.defs.IRCEvent|IRCEvent].
        name = Timer name, used as inner key in [TimerPlugin.timersByChannel].
 +/
auto createTimerFiber(
    TimerPlugin plugin,
    const IRCEvent.Channel eventChannel,
    const string name)
{
    import kameloso.constants : BufferSize;
    import core.thread.fiber : Fiber;

    void createTimerDg()
    {
        import std.datetime.systime : Clock;

        // Channel pointer.
        const channel = eventChannel.name in plugin.channels;
        assert(channel, eventChannel.name ~ " not in plugin.channels");

        auto channelTimers = eventChannel.name in plugin.timersByChannel;
        assert(channelTimers, eventChannel.name ~ " not in plugin.timersByChannel");

        auto timer = name in *channelTimers;
        assert(timer, name ~ " not in *channelTimers");

        // Ensure that the Timer was set up with a UNIX timestamp prior to creating this
        assert((timer.lastTimestamp > 0L), "Timer fiber " ~ name ~ " created before initial timestamp was set");

        // Stagger based on message count and time thresholds
        while (true)
        {
            immutable timeDelta = (Clock.currTime.toUnixTime() - timer.lastTimestamp);
            immutable timeStaggerMet = (timeDelta >= timer.timeStagger);
            immutable messageCountDelta = (channel.messageCount - timer.lastMessageCount);
            immutable messageStaggerMet = (messageCountDelta >= timer.messageCountStagger);

            if (timer.condition == Timer.TimerCondition.both)
            {
                if (timeStaggerMet && messageStaggerMet) break;
            }
            else /*if (timer.condition == Timer.TimerCondition.either)*/
            {
                if (timeStaggerMet || messageStaggerMet) break;
            }

            Fiber.yield();
            continue;
        }

        void updateTimer()
        {
            timer.lastMessageCount = channel.messageCount;
            timer.lastTimestamp = Clock.currTime.toUnixTime();
        }

        // Snapshot count and timestamp
        updateTimer();

        // Main loop
        while (true)
        {
            import kameloso.plugins.common : nameOf;
            import kameloso.string : replaceRandom;
            import std.array : replace;

            if (timer.suspended)
            {
                updateTimer();
                Fiber.yield();
                continue;
            }

            string message = timer.getLine();  // mutable

            if (message.length)
            {
                message = message
                    .replace("$bot", nameOf(plugin, plugin.state.client.nickname))
                    .replace("$botNickname", plugin.state.client.nickname)
                    .replace("$channel", eventChannel.name[1..$])
                    .replaceRandom();

                bool announced;

                version(TwitchSupport)
                {
                    if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                    {
                        message = message
                            .replace("$streamer", nameOf(plugin, eventChannel.name[1..$]))
                            .replace("$streamerAccount", eventChannel.name[1..$]);

                        if (plugin.settings.useAnnouncements)
                        {
                            announce(
                                plugin.state,
                                eventChannel,
                                message,
                                timer.colour);
                            announced = true;
                        }
                    }
                }

                if (!announced)
                {
                    chan(plugin.state, eventChannel.name, message);
                }
            }

            updateTimer();
            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&createTimerDg, BufferSize.fiberStack);
}


// saveTimers
/++
    Saves timers to disk in JSON format.

    Params:
        plugin = The current [TimerPlugin].
 +/
void saveTimers(TimerPlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : File;

    JSONValue json;
    json.object = null;

    foreach (immutable channelName, const timers; plugin.timersByChannel)
    {
        json[channelName] = null;
        json[channelName].array = null;

        foreach (const timer; timers)
        {
            json[channelName].array ~= timer.asSchema.asJSONValue;
        }
    }

    immutable serialised = json.toPrettyString;
    File(plugin.timerFile, "w").writeln(serialised);
}


// initResources
/++
    Reads and writes the file of timers to disk, ensuring that they're there and
    properly formatted.
 +/
void initResources(TimerPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : exists, readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = plugin.timerFile.readText.strippedRight;

    if (!content.length)
    {
        File(plugin.timerFile, "w").writeln("{}");
        return;
    }

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    try
    {
        const deserialised = content.deserialize!(Timer.JSONSchema[][string]);

        JSONValue json;
        json.object = null;

        foreach (immutable channelName, const schemas; deserialised)
        {
            json[channelName] = null;
            json[channelName].array = null;

            foreach (const schema; schemas)
            {
                json[channelName].array ~= schema.asJSONValue;
            }
        }

        immutable serialised = json.toPrettyString;
        File(plugin.timerFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Timer file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.timerFile);
    }
}


// loadTimers
/++
    Loads timers from disk.
 +/
void loadTimers(TimerPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;

    immutable content = plugin.timerFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    const json = content.deserialize!(Timer.JSONSchema[][string]);

    plugin.timersByChannel = null;

    foreach (immutable channelName, const timerSchemas; json)
    {
        plugin.timersByChannel[channelName] = typeof(plugin.timersByChannel[channelName]).init;
        auto channelTimers = channelName in plugin.timersByChannel;

        foreach (const schema; timerSchemas)
        {
            auto timer = Timer(schema);
            (*channelTimers)[timer.name] = timer;
        }

        channelTimers.rehash();
    }

    plugin.timersByChannel.rehash();
}


// reload
/++
    Reloads resources from disk.
 +/
void reload(TimerPlugin plugin)
{
    loadTimers(plugin);

    // Recreate timer fibers from definitions
    foreach (/*immutable channelName,*/ channel; plugin.channels)
    {
        // Just reuse the SELFJOIN routine, but be sure to force it
        // it will destroy the fibers, so we don't have to here
        handleSelfjoin(plugin, channel.fromEvent, force: true);
    }
}


// teardown
/++
    Cleanly deinitialises the plugin in terms of its [Timer]
    [core.thread.fiber.Fiber|Fiber]s.
 +/
void teardown(TimerPlugin plugin)
{
    foreach (ref channelTimers; plugin.timersByChannel)
    {
        foreach (ref timer; channelTimers)
        {
            destroy(timer.fiber);
            timer.fiber = null;
        }
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(TimerPlugin plugin, Selftester s)
{
    import kameloso.plugins.common.scheduling : delay;

    s.send("timer");
    s.expect("Usage: ${prefix}timer [new|modify|add|del|suspend|resume|list] ...");

    s.send("timer new");
    s.expect("Usage: ${prefix}timer new [name] [type] [condition] [message count threshold] " ~
        "[time threshold] [optional stagger message count] [optional stagger time]");

    s.send("timer new hirrsteff ordered both 0 10s 0 10s");
    s.expect("New timer added! Use !timer add to add lines.");

    s.send("timer suspend hirrsteff");
    s.expect("Timer suspended. Use ${prefix}timer resume hirrsteff to resume it.");

    s.send("timer add splorf hello");
    s.expect("No such timer is defined. Add a new one with !timer new.");

    s.send("timer add hirrsteff HERLO");
    s.expect("Line added to timer hirrsteff.");

    s.send("timer insert hirrsteff 0 fgsfds");
    s.expect("Line added to timer hirrsteff.");

    s.send("timer edit hirrsteff 1 HARLO");
    s.expect("Line #1 of timer hirrsteff edited.");

    s.send("timer list");
    s.expect("Current timers for channel ${channel}:");
    s.expect(`["hirrsteff"] lines:2 | type:ordered | condition:both | ` ~
        "message count threshold:0 | time threshold:10 | stagger message count:0 | " ~
        "stagger time:10 | suspended:true");

    logger.info("Wait 1 cycle, nothing should happen...");
    delay(plugin, TimerPlugin.timerPeriodicity, yield: true);
    s.requireTriggeredByTimer();

    s.send("timer resume hirrsteff");
    s.expect("Timer resumed!");

    logger.info("Wait <4 cycles...");

    s.expect("fgsfds");
    logger.info("ok");

    s.expect("HARLO");
    logger.info("ok");

    s.expect("fgsfds");
    logger.info("all ok");

    s.send("timer del hirrsteff 0");
    s.expect("Line removed from timer hirrsteff. Lines remaining: 1");

    s.expect("HARLO");
    logger.info("all ok again");

    s.send("timer modify");
    s.expect("Usage: ${prefix}timer modify [name] [type] [condition] [message count threshold] " ~
        "[time threshold] [optional stagger message count] [optional stagger time]");

    s.send("timer modify hirrsteff random both 1 10s");
    s.expect(`Timer "hirrsteff" modified to type random, condition both, ` ~
        "message count threshold 1, time threshold 10 seconds, " ~
        "stagger message count 0, stagger time 10 seconds");

    logger.info("Wait 1 cycle, nothing should happen...");
    delay(plugin, TimerPlugin.timerPeriodicity, yield: true);
    s.requireTriggeredByTimer();

    s.send("blep");
    s.expect("HARLO");
    logger.info("ok");

    s.send("timer del hirrsteff");
    s.expect("Timer removed.");

    s.send("timer del hirrsteff");
    s.expect("There is no timer by that name.");

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!TimerPlugin;

version(TwitchSupport)
{
    mixin UserAwareness;
}

public:


// TimerPlugin
/++
    The Timer plugin serves reoccurring (timered) announcements.
 +/
final class TimerPlugin : IRCPlugin
{
private:
    import core.time : seconds;

    /++
        Contained state of a channel, so that there can be several alongside each other.
     +/
    static struct Channel
    {
        /++
            [dialect.defs.IRCEvent.Channel|Channel] from
            [dialect.defs.IRCEvent|IRCEvent].
         +/
        IRCEvent.Channel fromEvent;

        /++
            Current message count.
         +/
        ulong messageCount;

        /++
            Pointers to [Timer]s in [TimerPlugin.timersByChannel].
         +/
        Timer*[string] timerPointers;

        /++
            Constructor.
         +/
        this(const IRCEvent.Channel fromEvent)
        {
            this.fromEvent = fromEvent;
        }
    }

    /++
        All Timer plugin settings.
     +/
    TimerSettings settings;

    /++
        Array of active channels' state.
     +/
    Channel[string] channels;

    /++
        Associative array of [Timer]s, keyed by nickname keyed by channel.
     +/
    Timer[string][string] timersByChannel;

    /++
        Numeric instance of the monitor fiber, used to detect when a new monitor
        has been started elsewhere.
     +/
    uint monitorInstanceID;

    /++
        Filename of file with timer definitions.
     +/
    @Resource string timerFile = "timers.json";

    /++
        The baseline duration between timer checks.
     +/
    static immutable timerPeriodicity = 10.seconds;

    mixin IRCPluginImpl;
}

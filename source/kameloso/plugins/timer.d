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

    /++
        Delay in number of messages before the timer initially comes into effect.
     +/
    long messageCountStagger;

    // timeStagger
    /++
        Delay in seconds before the timer initially comes into effect.
     +/
    long timeStagger;

    // position
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
        Serialises this [TimerDefinition] into a [std.json.JSONValue|JSONValue].

        Returns:
            A [std.json.JSONValue|JSONValue] that describes this timer.
     +/
    auto toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["name"] = JSONValue(this.name);
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
        Deserialises a [TimerDefinition] from a [std.json.JSONValue|JSONValue].

        Params:
            json = [std.json.JSONValue|JSONValue] to deserialise.

        Returns:
            A new [TimerDefinition] with values loaded from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        TimerDefinition def;
        def.name = json["name"].str;
        def.messageCountThreshold = json["messageCountThreshold"].integer;
        def.timeThreshold = json["timeThreshold"].integer;
        def.messageCountStagger = json["messageCountStagger"].integer;
        def.timeStagger = json["timeStagger"].integer;
        def.type = (json["type"].integer == cast(int)Type.random) ?
            Type.random :
            Type.ordered;
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
            .addSyntax("$command add [timer name] [timer text]")
            .addSyntax("$command insert [timer name] [position] [timer text]")
            .addSyntax("$command edit [timer name] [position] [new timer text]")
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
        return handleInsertLineIntoTimer(plugin, event, slice);

    case "edit":
        return handleEditTimerLine(plugin, event, slice);

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

    TimerDefinition timerDef;

    string messageCountThreshold;
    string type;
    string condition;
    string timeThreshold;
    string messageCountStagger;
    string timeStagger;

    immutable results = slice.splitInto(
        timerDef.name,
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
    case "rnd":
    case "rng":
        timerDef.type = TimerDefinition.Type.random;
        break;

    case "ordered":
    case "order":
    case "sequential":
    case "seq":
    case "sequence":
        timerDef.type = TimerDefinition.Type.ordered;
        break;

    default:
        enum message = "Type must be one of <b>random<b> or <b>ordered<b>.";
        return chan(plugin.state, event.channel, message);
    }

    switch (condition)
    {
    case "both":
    case "and":
        timerDef.condition = TimerDefinition.Condition.both;
        break;

    case "either":
    case "or":
        timerDef.condition = TimerDefinition.Condition.either;
        break;

    default:
        enum message = "Condition must be one of <b>both<b> or <b>either<b>.";
        return chan(plugin.state, event.channel, message);
    }

    try
    {
        timerDef.messageCountThreshold = messageCountThreshold.to!long;
        timerDef.timeThreshold = abbreviatedDuration(timeThreshold).total!"seconds";
        if (messageCountStagger.length) timerDef.messageCountStagger = messageCountStagger.to!long;
        if (timeStagger.length) timerDef.timeStagger = abbreviatedDuration(timeStagger).total!"seconds";
    }
    catch (ConvException e)
    {
        return sendBadNumerics();
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }

    if ((timerDef.messageCountThreshold < 0) ||
        (timerDef.timeThreshold < 0) ||
        (timerDef.messageCountStagger < 0) ||
        (timerDef.timeStagger < 0))
    {
        return sendBadNumerics();
    }
    else if ((timerDef.messageCountThreshold == 0) && (timerDef.timeThreshold == 0))
    {
        enum message = "A timer cannot have a message threshold *and* a time threshold of zero.";
        return chan(plugin.state, event.channel, message);
    }

    plugin.timerDefsByChannel[event.channel] ~= timerDef;
    saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);
    plugin.channels[event.channel].timerFibers ~= plugin.createTimerFiber(timerDef, event.channel);

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
    //import kameloso.time : DurationStringException, abbreviatedDuration;
    import lu.string : SplitResults, /*contains, nom,*/ splitInto;
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.conv : ConvException, to;
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

    auto timerDefs = event.channel in plugin.timerDefsByChannel;
    if (!timerDefs) return sendNoSuchTimer();

    auto channel = event.channel in plugin.channels;
    assert(channel, "Tried to delete a timer from a non-existent channel");

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

                if (!timerDefs.length) plugin.timerDefsByChannel.remove(event.channel);
                saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                enum message = "Timer removed.";
                return chan(plugin.state, event.channel, message);
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
                    return chan(plugin.state, event.channel, message);
                }
                catch (ConvException e)
                {
                    enum message = "Argument for which line to remove must be a number.";
                    return chan(plugin.state, event.channel, message);
                }
            }
        }

        // If we're here, no timer was found with the given name
        return sendNoSuchTimer();

    case overrun:
        sendDelUsage();
    }
}


// handleInsertLineIntoTimer
/++
    Inserts a line into an existing timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the insertion.
        slice = Relevant slice of the original request string.
 +/
void handleInsertLineIntoTimer(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendInsertUsage()
    {
        enum pattern = "Usage: <b>%s%s insert<b> [timer name] [position] [timer text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel, message);
    }

    string name;
    string linesPosString;

    immutable results = slice.splitInto(name, linesPosString);
    if (results != SplitResults.overrun) return sendInsertUsage();

    auto timerDefs = event.channel in plugin.timerDefsByChannel;
    if (!timerDefs) return sendNoSuchTimer();

    auto channel = event.channel in plugin.channels;
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
                channel.timerFibers[i] = plugin.createTimerFiber(timerDef, event.channel);
                saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

                enum pattern = "Line added to timer <b>%s<b>.";
                immutable message = pattern.format(name);
                return chan(plugin.state, event.channel, message);
            }
            catch (ConvException e)
            {
                enum message = "Argument for which position to insert line at must be a number.";
                return chan(plugin.state, event.channel, message);
            }
        }
    }

    // If we're here, no timer was found with the given name
    sendNoSuchTimer();
}


// handleEditTimerLine
/++
    Edits a line of an existing timer.

    Params:
        plugin = The current [TimerPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] that requested the edit.
        slice = Relevant slice of the original request string.
 +/
void handleEditTimerLine(
    TimerPlugin plugin,
    const /*ref*/ IRCEvent event,
    /*const*/ string slice)
{
    import lu.string : SplitResults, splitInto;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendInsertUsage()
    {
        enum pattern = "Usage: <b>%s%s edit<b> [timer name] [position] [new timer text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimer()
    {
        enum message = "There is no timer by that name.";
        chan(plugin.state, event.channel, message);
    }

    string name;
    string linesPosString;

    immutable results = slice.splitInto(name, linesPosString);
    if (results != SplitResults.overrun) return sendInsertUsage();

    auto timerDefs = event.channel in plugin.timerDefsByChannel;
    if (!timerDefs) return sendNoSuchTimer();

    auto channel = event.channel in plugin.channels;
    if (!channel) return sendNoSuchTimer();

    foreach (immutable i, ref timerDef; *timerDefs)
    {
        if (timerDef.name != name) continue;

        try
        {
            immutable linePos = linesPosString.to!ptrdiff_t;

            if (linePos >= timeDef.lines.length)
            {
                enum pattern = "Line position out of range; valid is <b>[0..%d]<b> (inclusive).";
                immutable message = pattern.format(timeDef.lines.length);
                return chan(plugin.state, event.channel, message);
            }

            timerDef.lines[linePos] = slice;
            channel.timerFibers[i] = plugin.createTimerFiber(timerDef, event.channel);
            saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

            enum message = "Line edited.";
            return chan(plugin.state, event.channel, message);
        }
        catch (ConvException e)
        {
            enum message = "Argument for which position to edit line at must be a number.";
            return chan(plugin.state, event.channel, message);
        }
    }

    // If we're here, no timer was found with the given name
    sendNoSuchTimer();
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
        enum pattern = "Usage: <b>%s%s add<b> [timer name] [timer text]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchTimerAdd()
    {
        enum noSuchTimerPattern = "No such timer is defined. Add a new one with <b>%s%s new<b>.";
        immutable noSuchTimerMessage = noSuchTimerPattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, noSuchTimerMessage);
    }

    immutable name = slice.nom!(Yes.inherit)(' ');
    if (!slice.length) return sendAddUsage();

    auto timerDefs = event.channel in plugin.timerDefsByChannel;
    if (!timerDefs) return sendNoSuchTimerAdd();

    auto channel = event.channel in plugin.channels;
    if (!channel) return sendNoSuchTimerAdd();

    foreach (immutable i, ref timerDef; *timerDefs)
    {
        if (timerDef.name == name)
        {
            timerDef.lines ~= slice;
            destroy(channel.timerFibers[i]);
            channel.timerFibers[i] = plugin.createTimerFiber(timerDef, event.channel);
            saveResourceToDisk(plugin.timerDefsByChannel, plugin.timerFile);

            enum pattern = "Line added to timer <b>%s<b>.";
            immutable message = pattern.format(name);
            return chan(plugin.state, event.channel, message);
        }
    }

    // If we're here, no timer was found with the given name
    sendNoSuchTimerAdd();
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

    const timerDefs = event.channel in plugin.timerDefsByChannel;

    if (!timerDefs)
    {
        enum message = "There are no timers registered for this channel.";
        return chan(plugin.state, event.channel, message);
    }

    enum headerPattern = "Current timers for channel <b>%s<b>:";
    immutable headerMessage = headerPattern.format(event.channel);
    chan(plugin.state, event.channel, headerMessage);

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
            ((timerDef.type == TimerDefinition.Type.random) ? "random" : "ordered"),
            ((timerDef.condition == TimerDefinition.Condition.both) ? "both" : "either"),
            timerDef.messageCountThreshold,
            timerDef.timeThreshold,
            timerDef.messageCountStagger,
            timerDef.timeStagger,
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
        plugin.handleSelfjoin(event.channel);
        channel = event.channel in plugin.channels;
    }

    ++channel.messageCount;
}


// onWelcome
/++
    Loads timers from disk. Additionally sets up a [core.thread.fiber.Fiber|Fiber]
    to periodically call timer [core.thread.fiber.Fiber|Fiber]s with a periodicity
    of [TimerPlugin.timerPeriodicity].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
    .fiber(true)
)
void onWelcome(TimerPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import lu.json : JSONStorage;
    import std.datetime.systime : Clock;
    import core.thread : Fiber;

    plugin.reload();
    delay(plugin, plugin.timerPeriodicity, Yes.yield);

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
auto createTimerFiber(
    TimerPlugin plugin,
    /*const*/ TimerDefinition timerDef,
    const string channelName)
{
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;

    void createTimerDg()
    {
        import std.datetime.systime : Clock;

        /// Channel pointer.
        const channel = channelName in plugin.channels;

        /// Initial message count.
        immutable creationMessageCount = channel.messageCount;

        /// When this timer Fiber was created.
        immutable creationTime = Clock.currTime.toUnixTime;

        if (timerDef.condition == TimerDefinition.Condition.both)
        {
            while (true)
            {
                // Stagger messages
                immutable messageCountUnfulfilled =
                    ((channel.messageCount - creationMessageCount) < timerDef.messageCountStagger);

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
                    ((Clock.currTime.toUnixTime - creationTime) < timerDef.timeStagger);

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
                    ((channel.messageCount - creationMessageCount) < timerDef.messageCountStagger);
                immutable timerUnfulfilled =
                    ((Clock.currTime.toUnixTime - creationTime) < timerDef.timeStagger);

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
                    ((now - lastTimestamp) < timerDef.timeStagger);

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

    return new Fiber(&createTimerDg, BufferSize.fiberStack);
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

    plugin.timerDefsByChannel = null;

    foreach (immutable channelName, const timerDefsJSON; allTimersJSON.object)
    {
        foreach (const timerDefJSON; timerDefsJSON.array)
        {
            plugin.timerDefsByChannel[channelName] ~= TimerDefinition.fromJSON(timerDefJSON);
        }
    }

    plugin.timerDefsByChannel = plugin.timerDefsByChannel.rehash();

    // Recreate timers from definitions
    foreach (immutable channelName, channel; plugin.channels)
    {
        foreach (fiber; channel.timerFibers)
        {
            destroy(fiber);
        }

        if (auto timerDefs = channelName in plugin.timerDefsByChannel)
        {
            foreach (timerDef; *timerDefs)
            {
                channel.timerFibers ~= plugin.createTimerFiber(timerDef, channelName);
            }
        }
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

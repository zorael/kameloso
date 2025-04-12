/++
    A simple counter plugin.

    Allows you to define runtime `!word` counters that you can increment,
    decrement or assign specific values to. This can be used to track deaths in
    video games, for instance.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#counter,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.counter;

version(WithCounterPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.messaging;
import dialect.defs;


// CounterSettings
/++
    All Counter plugin settings aggregated.
 +/
@Settings struct CounterSettings
{
    /++
        Whether or not this plugin should react to any events.
     +/
    @Enabler bool enabled = true;

    /++
        User level required to bump a counter.
     +/
    IRCUser.Class minimumPermissionsNeeded = IRCUser.Class.elevated;
}


// Counter
/++
    Embodiment of a counter. Literally just a number with some ancillary metadata.
 +/
struct Counter
{
    /++
        JSON schema for (de-)serialisation.
     +/
    static struct JSONSchema
    {
        long count;  ///
        string word;  ///
        string patternQuery;  ///
        string patternIncrement;  ///
        string patternDecrement;  ///
        string patternAssign;  ///
    }

    /++
        Current count.
     +/
    long count;

    /++
        Counter word.
     +/
    string word;

    /++
        The pattern to use when formatting answers to counter queries;
        e.g. "The current $word count is currently $count.".

        See_Also:
            [formatMessage]
     +/
    string patternQuery = "<b>$word<b> count so far: <b>$count<b>";

    /++
        The pattern to use when formatting confirmations of counter increments;
        e.g. "$word count was increased by +$step and is now $count!".

        See_Also:
            [formatMessage]
     +/
    string patternIncrement = "<b>$word +$step<b>! Current count: <b>$count<b>";

    /++
        The pattern to use when formatting confirmations of counter decrements;
        e.g. "$word count was decreased by -$step and is now $count!".

        See_Also:
            [formatMessage]
     +/
    string patternDecrement = "<b>$word -$step<b>! Current count: <b>$count<b>";

    /++
        The pattern to use when formatting confirmations of counter assignments;
        e.g. "$word count was reset to $count!"

        See_Also:
            [formatMessage]
     +/
    string patternAssign = "<b>$word<b> count assigned to <b>$count<b>!";

    /++
        Constructor. Only kept as a compatibility measure to ensure [word] always
        has a value. Remove later.
     +/
    this(const string word) pure @safe nothrow @nogc
    {
        this.word = word;
    }

    /++
        Constructor.
     +/
    this(const JSONSchema json)
    {
        count = json.count;
        word = json.word;
        patternQuery = json.patternQuery;
        patternIncrement = json.patternIncrement;
        patternDecrement = json.patternDecrement;
        patternAssign = json.patternAssign;
    }

    /++
        Returns a [JSONSchema] representing this [Counter].
     +/
    auto asSchema() const
    {
        JSONSchema json;
        json.count = count;
        json.word = word;
        json.patternQuery = patternQuery;
        json.patternIncrement = patternIncrement;
        json.patternDecrement = patternDecrement;
        json.patternAssign = patternAssign;
        return json;
    }

    // resetEmptyPatterns
    /++
        Resets empty patterns with their default strings.
     +/
    void resetEmptyPatterns()
    {
        const Counter counterInit;
        if (!patternQuery.length) patternQuery = counterInit.patternQuery;
        if (!patternIncrement.length) patternIncrement = counterInit.patternIncrement;
        if (!patternDecrement.length) patternDecrement = counterInit.patternDecrement;
        if (!patternAssign.length) patternAssign = counterInit.patternAssign;
    }
}


// onCommandCounter
/++
    Manages runtime counters (adding, removing and listing).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("counter")
            .policy(PrefixPolicy.prefixed)
            .description("Adds, removes or lists counters.")
            .addSyntax("$command add [counter word]")
            .addSyntax("$command del [counter word]")
            .addSyntax("$command format [counter word] [?+-=] [format pattern]")
            .addSyntax("$command list")
    )
)
void onCommandCounter(CounterPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped, strippedLeft;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|format|list] [counter word]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendFormatUsage()
    {
        enum pattern = "Usage: <b>%s%s format<b> [counter word] [one of ?, +, - and =] [format pattern]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMustBeUniqueAndMayNotContain()
    {
        enum message = "Counter words must be unique and may not contain any of " ~
            "the following characters: [<b>+-=?<b>]";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCounterAlreadyExists()
    {
        enum message = "A counter with that name already exists.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchCounter()
    {
        enum message = "No such counter available.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCounterRemoved(const string word)
    {
        enum pattern = "Counter <b>%s<b> removed.";
        immutable message = pattern.format(word);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoCountersActive()
    {
        enum message = "No counters currently active in this channel.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCountersList(const string[] counters)
    {
        enum pattern = "Current counters: %s";
        immutable arrayPattern = "%-(<b>" ~ plugin.state.coreSettings.prefix ~ "%s<b>, %)<b>";
        immutable list = arrayPattern.format(counters);
        immutable message = pattern.format(list);
        chan(plugin.state, event.channel.name, message);
    }

    void sendFormatPatternUpdated()
    {
        enum message = "Format pattern updated.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendFormatPatternReset()
    {
        enum message = "Format pattern reset.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendCurrentFormatPattern(const string mod, const string customPattern)
    {
        enum pattern = `Current <b>%s<b> format pattern: "<b>%s<b>"`;
        immutable message = pattern.format(mod, customPattern);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoFormatPattern(const string word)
    {
        enum pattern = "Counter <b>%s<b> does not have a custom format pattern.";
        immutable message = pattern.format(word);
        chan(plugin.state, event.channel.name, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);
    slice = slice.strippedLeft;

    switch (verb)
    {
    case "add":
        import kameloso.thread : CarryingFiber;
        import std.typecons : Tuple;
        import core.thread.fiber : Fiber;

        if (!slice.length) goto default;

        if (slice.canFind('+', '-', '=', '?'))
        {
            return sendMustBeUniqueAndMayNotContain();
        }

        if ((event.channel.name in plugin.counters) && (slice in plugin.counters[event.channel.name]))
        {
            return sendCounterAlreadyExists();
        }

        /+
            We need to check both hardcoded and soft channel-specific commands
            for conflicts.
         +/

        auto triggerConflicts(const IRCPlugin.CommandMetadata[string][string] aa)
        {
            foreach (immutable pluginName, pluginCommands; aa)
            {
                if (!pluginCommands.length || (pluginName == "counter")) continue;

                if (slice in pluginCommands)
                {
                    enum pattern = `Counter word "<b>%s<b>" conflicts with a command of the <b>%s<b> plugin.`;
                    immutable message = pattern.format(slice, pluginName);
                    chan(plugin.state, event.channel.name, message);
                    return true;
                }
            }
            return false;
        }

        alias Payload = Tuple!
            (IRCPlugin.CommandMetadata[string][string],
            IRCPlugin.CommandMetadata[string][string]);

        void addCounterDg()
        {
            auto thisFiber = cast(CarryingFiber!Payload) Fiber.getThis();
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            if (triggerConflicts(thisFiber.payload[0])) return;
            else if (triggerConflicts(thisFiber.payload[1])) return;

            plugin.counters[event.channel.name][slice] = Counter(slice);
            saveCounters(plugin);

            enum pattern = "Counter <b>%s<b> added! Access it with <b>%s%s<b>.";
            immutable message = pattern.format(slice, plugin.state.coreSettings.prefix, slice);
            chan(plugin.state, event.channel.name, message);
        }

        defer!Payload(plugin, &addCounterDg, event.channel.name);
        break;

    case "remove":
    case "del":
        if (!slice.length) goto default;

        auto channelCounters = event.channel.name in plugin.counters;
        if (!channelCounters || (slice !in *channelCounters)) return sendNoSuchCounter();

        (*channelCounters).remove(slice);
        if (!channelCounters.length) plugin.counters.remove(event.channel.name);
        saveCounters(plugin);

        return sendCounterRemoved(slice);

    case "format":
        import lu.string : SplitResults, splitInto;
        import std.algorithm.comparison : among;

        string word;  // mutable
        string mod;  // mutable
        immutable results = slice.splitInto(word, mod);

        with (SplitResults)
        final switch (results)
        {
        case match:
            // No pattern given but an empty query is ok
            break;

        case overrun:
            // Pattern given
            break;

        case underrun:
            // Not enough parameters
            return sendFormatUsage();
        }

        if (!mod.among!("?", "+", "-", "="))
        {
            return sendFormatUsage();
        }

        auto channelCounters = event.channel.name in plugin.counters;
        if (!channelCounters) return sendNoSuchCounter();

        auto counter = word in *channelCounters;
        if (!counter) return sendNoSuchCounter();

        alias newPattern = slice;

        if (newPattern == "-")
        {
            // Reset pattern
            const Counter counterInit;
            if      (mod == "?") counter.patternQuery = counterInit.patternQuery;
            else if (mod == "+") counter.patternIncrement = counterInit.patternIncrement;
            else if (mod == "-") counter.patternDecrement = counterInit.patternDecrement;
            else if (mod == "=") counter.patternAssign = counterInit.patternAssign;
            else assert(0, "Impossible case");

            saveCounters(plugin);
            return sendFormatPatternReset();
        }
        else if (newPattern.length)
        {
            import lu.string : unquoted;

            // This allows for the pattern "" to resolve to an empty pattern
            newPattern = newPattern.unquoted;

            if      (mod == "?") counter.patternQuery = newPattern;
            else if (mod == "+") counter.patternIncrement = newPattern;
            else if (mod == "-") counter.patternDecrement = newPattern;
            else if (mod == "=") counter.patternAssign = newPattern;
            else assert(0, "Impossible case");

            saveCounters(plugin);
            return sendFormatPatternUpdated();
        }
        else
        {
            // Query pattern
            immutable modverb =
                (mod == "?") ? "query" :
                (mod == "+") ? "increment" :
                (mod == "-") ? "decrement" :
                (mod == "=") ? "assign" :
                    string.init;
            immutable pattern =
                (mod == "?") ? counter.patternQuery :
                (mod == "+") ? counter.patternIncrement :
                (mod == "-") ? counter.patternDecrement :
                (mod == "=") ? counter.patternAssign :
                    string.init;

            if (!modverb.length || !pattern.length) assert(0, "Impossible case");
            return sendCurrentFormatPattern(modverb, pattern);
        }

    case "list":
        if (event.channel.name !in plugin.counters) return sendNoCountersActive();
        return sendCountersList(plugin.counters[event.channel.name].keys);

    default:
        return sendUsage();
    }
}


// onCounterWord
/++
    Allows users to increment, decrement, and set counters.

    This function fakes
    [kameloso.plugins.IRCEventHandler.Command|IRCEventHandler.Command]s by
    listening for prefixes (and the bot's nickname), and treating whatever comes
    after it as a command word. If it doesn't match a previously added counter,
    it is ignored.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onCounterWord(CounterPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripSeparatedPrefix;
    import lu.string : stripped, strippedLeft, strippedRight;
    import std.algorithm.searching : startsWith;
    import std.conv : ConvException, text, to;
    import std.format : format;
    import std.meta : aliasSeqOf;
    import std.string : indexOf;

    mixin(memoryCorruptionCheck);

    void sendCurrentCount(const Counter counter)
    {
        if (!counter.patternQuery.length) return;

        immutable message = formatMessage(
            plugin,
            counter.patternQuery,
            event,
            counter);
        chan(plugin.state, event.channel.name, message);
    }

    void sendCounterModified(const Counter counter, const long step)
    {
        import std.math : abs;

        immutable pattern = (step >= 0) ? counter.patternIncrement : counter.patternDecrement;
        if (!pattern.length) return;

        immutable message = formatMessage(
            plugin,
            pattern,
            event,
            counter,
            abs(step));
        chan(plugin.state, event.channel.name, message);
    }

    void sendCounterAssigned(const Counter counter, const long step)
    {
        if (!counter.patternAssign.length) return;

        immutable message = formatMessage(
            plugin,
            counter.patternAssign,
            event,
            counter,
            step);
        chan(plugin.state, event.channel.name, message);
    }

    void sendInputIsNaN(const string input)
    {
        enum pattern = "<b>%s<b> is not a number.";
        immutable message = pattern.format(input);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMustSpecifyNumber()
    {
        enum message = "You must specify a number to set the count to.";
        chan(plugin.state, event.channel.name, message);
    }

    string slice = event.content.stripped;  // mutable
    if ((slice.length < (plugin.state.coreSettings.prefix.length+1)) &&  // !w
        (slice.length < (plugin.state.client.nickname.length+2))) return;  // nickname:w

    if (slice.startsWith(plugin.state.coreSettings.prefix))
    {
        slice = slice[plugin.state.coreSettings.prefix.length..$];
    }
    else if (slice.startsWith(plugin.state.client.nickname))
    {
        slice = slice.stripSeparatedPrefix(plugin.state.client.nickname, demandSeparatingChars: true);
    }
    else
    {
        version(TwitchSupport)
        {
            if (plugin.state.client.displayName.length && slice.startsWith(plugin.state.client.displayName))
            {
                slice = slice.stripSeparatedPrefix(plugin.state.client.displayName, demandSeparatingChars: true);
            }
            else
            {
                // Just a random message
                return;
            }
        }
        else
        {
            // As above
            return;
        }
    }

    if (!slice.length) return;

    auto channelCounters = event.channel.name in plugin.counters;
    if (!channelCounters) return;

    ptrdiff_t signPos;

    foreach (immutable sign; aliasSeqOf!"?=+-")  // '-' after '=' to support "!word=-5"
    {
        signPos = slice.indexOf(sign);
        if (signPos != -1) break;
    }

    immutable word = (signPos != -1) ? slice[0..signPos].strippedRight : slice;

    auto counter = word in *channelCounters;
    if (!counter) return;

    slice = (signPos != -1) ? slice[signPos..$] : string.init;

    if (!slice.length || (slice[0] == '?'))
    {
        return sendCurrentCount(*counter);
    }

    // Limit modifications to the configured class
    if (event.sender.class_ < plugin.settings.minimumPermissionsNeeded) return;

    assert(slice.length, "Empty slice after slicing");
    immutable sign = slice[0];

    switch (sign)
    {
    case '+':
    case '-':
        long step;

        if ((slice == "+") || (slice == "++"))
        {
            step = 1;
        }
        else if ((slice == "-") || (slice == "--"))
        {
            step = -1;
        }
        else if (slice.length > 1)
        {
            slice = slice[1..$].strippedLeft;
            step = (sign == '+') ? 1 : -1;  // implicitly (sign == '-')

            try
            {
                step = slice.to!long * step;
            }
            catch (ConvException _)
            {
                return sendInputIsNaN(slice);
            }
        }

        counter.count += step;
        saveCounters(plugin);
        return sendCounterModified(*counter, step);

    case '=':
        slice = slice[1..$].strippedLeft;

        if (!slice.length)
        {
            return sendMustSpecifyNumber();
        }

        long newCount;

        try
        {
            newCount = slice.to!long;
        }
        catch (ConvException _)
        {
            return sendInputIsNaN(slice);
        }

        immutable step = (newCount - counter.count);
        counter.count = newCount;
        saveCounters(plugin);
        return sendCounterAssigned(*counter, step);

    default:
        assert(0, "Hit impossible default case in onCounterWord sign switch");
    }
}


// onWelcome
/++
    Populate the counters array after we have successfully logged onto the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(CounterPlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    loadCounters(plugin);
}


// formatMessage
/++
    Formats a message by a string pattern, replacing select keywords with more
    helpful values.

    Example:
    ---
    immutable pattern = "The $word count was bumped by +$step to $count!";
    immutable message = formatMessage(plugin, pattern, event, counter, step);
    assert(message == "The curse count was bumped by +1 to 92!");
    ---

    Params:
        plugin = The current [CounterPlugin].
        pattern = The custom string pattern we're formatting.
        event = The [dialect.defs.IRCEvent|IRCEvent] that triggered the format.
        counter = The [Counter] that the message relates to.
        step = By what step the counter was modified, if any.

    Returns:
        A new string, with keywords replaced.
 +/
auto formatMessage(
    CounterPlugin plugin,
    const string pattern,
    const IRCEvent event,
    const Counter counter,
    const long step = long.init)
{
    import kameloso.plugins.common : nameOf;
    import kameloso.string : replaceRandom;
    import std.array : replace;
    import std.conv : to;

    auto signedStep()
    {
        import std.conv : text;
        return (step >= 0) ?
            text('+', step) :
            step.to!string;
    }

    string line = pattern
        .replace("$step", step.to!string)
        .replace("$signedstep", signedStep())
        .replace("$count", counter.count.to!string)
        .replace("$word", counter.word)
        .replace("$channel", event.channel.name)
        .replace("$senderNickname", event.sender.nickname)
        .replace("$sender", nameOf(event.sender))
        .replace("$botNickname", plugin.state.client.nickname)
        .replace("$bot", nameOf(plugin, plugin.state.client.nickname))
        .replaceRandom();

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            line = line
                .replace("$streamerAccount", event.channel.name[1..$])
                .replace("$streamer", nameOf(plugin, event.channel.name[1..$]));
        }
    }

    return line;
}


// reload
/++
    Reloads counters from disk.
 +/
void reload(CounterPlugin plugin)
{
    loadCounters(plugin);
}


// saveCounters
/++
    Saves [Counter]s to disk in JSON format.

    Params:
        plugin = The current [CounterPlugin].
 +/
void saveCounters(CounterPlugin plugin)
{
    import asdf.serialization : serializeToJsonPretty;
    import std.stdio : File, writeln;

    Counter.JSONSchema[string][string] json;

    foreach (immutable channelName, ref channelCounters; plugin.counters)
    {
        json[channelName] = null;

        foreach (immutable word, ref counter; channelCounters)
        {
            json[channelName][word] = counter.asSchema;
        }
    }

    immutable serialised = json.serializeToJsonPretty!"    ";
    File(plugin.countersFile, "w").writeln(serialised);
}


// loadCounters
/++
    Loads [Counter]s from disk.

    Params:
        plugin = The current [CounterPlugin].
 +/
void loadCounters(CounterPlugin plugin)
{
    import asdf.serialization : deserialize;
    import std.file : readText;

    plugin.counters = null;

    try
    {
        auto json = plugin.countersFile
            .readText
            .deserialize!(Counter.JSONSchema[string][string]);

        foreach (immutable channelName, channelCountersJSON; json)
        {
            // Initialise the AA
            auto channelCounters = channelName in plugin.counters;

            if (!channelCounters)
            {
                plugin.counters[channelName][string.init] = Counter.init;
                channelCounters = channelName in plugin.counters;
                (*channelCounters).remove(string.init);
            }

            foreach (immutable word, counterSchema; channelCountersJSON)
            {
                (*channelCounters)[word] = Counter(counterSchema);
            }

            (*channelCounters).rehash();
        }

        plugin.counters.rehash();
    }
    catch (Exception e)
    {
        import kameloso.common : logger;
        version(PrintStacktraces) logger.trace(e);
    }
}


// initResources
/++
    Reads and writes the file of persistent counters to disk, ensuring that it's
    there and properly formatted.
 +/
void initResources(CounterPlugin plugin)
{
    import asdf.serialization : deserialize, serializeToJsonPretty;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.stdio : File, writeln;

    try
    {
        auto deserialised = plugin.countersFile
            .readText
            .deserialize!(Counter.JSONSchema[string][string]);

        immutable serialised = deserialised.serializeToJsonPretty!"    ";
        File(plugin.countersFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        import kameloso.common : logger;

        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Counter file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.countersFile);
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(CounterPlugin plugin, Selftester s)
{
    import kameloso.plugins.common.scheduling : delay;
    import core.time : seconds;

    s.send("counter");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter list");
    s.expect("No counters currently active in this channel.");

    s.send("counter last");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter add");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter del blah");
    s.expect("No such counter available.");

    s.send("counter del bluh");
    s.expect("No such counter available.");

    s.send("counter add blah");
    s.expect("Counter blah added! Access it with !blah.");

    s.send("counter add bluh");
    s.expect("Counter bluh added! Access it with !bluh.");

    s.send("counter add bluh");
    s.expect("A counter with that name already exists.");

    s.send("counter list");
    s.expectHead("Current counters: ");
    s.requireInBody("!blah");
    s.requireInBody("!bluh");

    // ------------ ![word]

    s.sendPrefixed("blah");
    s.expect("blah count so far: 0");

    s.sendPrefixed("blah+");
    s.expect("blah +1! Current count: 1");

    s.sendPrefixed("blah++");
    s.expect("blah +1! Current count: 2");

    s.sendPrefixed("blah+2");
    s.expect("blah +2! Current count: 4");

    s.sendPrefixed("blah+abc");
    s.expect("abc is not a number.");

    s.sendPrefixed("blah-");
    s.expect("blah -1! Current count: 3");

    s.sendPrefixed("blah--");
    s.expect("blah -1! Current count: 2");

    s.sendPrefixed("blah-2");
    s.expect("blah -2! Current count: 0");

    s.sendPrefixed("blah=10");
    s.expect("blah count assigned to 10!");

    s.sendPrefixed("blah");
    s.expect("blah count so far: 10");

    s.sendPrefixed("blah?");
    s.expect("blah count so far: 10");

    s.send("counter format blah ? ABC $count DEF");
    s.expect("Format pattern updated.");

    s.send("counter format blah + count +$step = $count");
    s.expect("Format pattern updated.");

    s.send("counter format blah - count -$step = $count");
    s.expect("Format pattern updated.");

    s.send("counter format blah = count := $count");
    s.expect("Format pattern updated.");

    s.sendPrefixed("blah");
    s.expect("ABC 10 DEF");

    s.sendPrefixed("blah+");
    s.expect("count +1 = 11");

    s.sendPrefixed("blah-2");
    s.expect("count -2 = 9");

    s.sendPrefixed("blah=42");
    s.expect("count := 42");

    s.send("counter format blah ? -");
    s.expect("Format pattern reset.");

    s.sendPrefixed("blah");
    s.expect("blah count so far: 42");

    s.send(`counter format blah + ""`);
    s.expect("Format pattern updated.");

    s.send(`counter format blah - ""`);
    s.expect("Format pattern updated.");

    static immutable delayToWait = 5.seconds;

    s.sendPrefixed("blah+");
    delay(plugin, delayToWait, yield: true);
    s.requireTriggeredByTimer();

    s.sendPrefixed("blah-5");
    delay(plugin, delayToWait, yield: true);
    s.requireTriggeredByTimer();

    s.sendPrefixed("blah");
    s.expect("blah count so far: 38");

    // ------------ !counter cleanup

    s.send("counter del blah");
    s.expect("Counter blah removed.");

    s.send("counter del blah");
    s.expect("No such counter available.");

    s.send("counter list");
    s.expect("Current counters: !bluh");

    s.send("counter del bluh");
    s.expect("Counter bluh removed.");

    s.send("counter list");
    s.expect("No counters currently active in this channel.");

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!CounterPlugin;

public:


// CounterPlugin
/++
    The Counter plugin allows for users to define counter commands at runtime.
 +/
final class CounterPlugin : IRCPlugin
{
private:
    /++
        All Counter plugin settings.
     +/
    CounterSettings settings;

    /++
        [Counter]s by counter word by channel name.
     +/
    Counter[string][string] counters;

    /++
        Filename of file with persistent counters.
     +/
    @Resource string countersFile = "counters.json";

    // channelSpecificCommands
    /++
        Compile a list of our runtime counter commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each counter active in the passed channel.
     +/
    override public IRCPlugin.CommandMetadata[string] channelSpecificCommands(const string channelName) @system
    {
        IRCPlugin.CommandMetadata[string] aa;

        const channelCounters = channelName in counters;
        if (!channelCounters) return aa;

        foreach (immutable trigger, immutable _; *channelCounters)
        {
            IRCPlugin.CommandMetadata metadata;
            metadata.description = "A counter";
            aa[trigger] = metadata;
        }

        return aa;
    }

    mixin IRCPluginImpl;
}

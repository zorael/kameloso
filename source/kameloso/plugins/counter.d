/++
    A simple counter plugin.

    Allows you to define runtime `!word` counters that you can increment,
    decrement or assign specific values to. This can be used to track deaths in
    video games, for instance.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#counter
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.counter;

version(WithCounterPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


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
private:
    import std.json : JSONValue;

public:
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
    string patternQuery;

    /++
        The pattern to use when formatting confirmations of counter increments;
        e.g. "$word count was increased by +$step and is now $count!".

        See_Also:
            [formatMessage]
     +/
    string patternIncrement;

    /++
        The pattern to use when formatting confirmations of counter decrements;
        e.g. "$word count was decreased by -$step and is now $count!".

        See_Also:
            [formatMessage]
     +/
    string patternDecrement;

    /++
        The pattern to use when formatting confirmations of counter assignments;
        e.g. "$word count was reset to $count!"

        See_Also:
            [formatMessage]
     +/
    string patternAssign;

    /++
        Constructor. Only kept as a compatibility measure to ensure [word] alawys
        has a value. Remove later.
     +/
    this(const string word)
    {
        this.word = word;
    }

    // toJSON
    /++
        Serialises this [Counter] into a JSON representation.

        Returns:
            A [std.json.JSONValue|JSONValue] that represents this [Counter].
     +/
    auto toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["count"] = JSONValue(count);
        json["word"] = JSONValue(word);
        json["patternQuery"] = JSONValue(patternQuery);
        json["patternIncrement"] = JSONValue(patternIncrement);
        json["patternDecrement"] = JSONValue(patternDecrement);
        json["patternAssign"] = JSONValue(patternAssign);
        return json;
    }

    // fromJSON
    /++
        Deserialises a [Counter] from a JSON representation.

        Params:
            json = [std.json.JSONValue|JSONValue] to build a [Counter] from.
     +/
    static auto fromJSON(const JSONValue json)
    {
        import std.json : JSONException, JSONType;

        Counter counter;

        if (json.type == JSONType.integer)
        {
            // Old format
            counter.count = json.integer;
        }
        else if (json.type == JSONType.object)
        {
            // New format
            counter.count = json["count"].integer;
            counter.word = json["word"].str;
            counter.patternQuery = json["patternQuery"].str;
            counter.patternIncrement = json["patternIncrement"].str;
            counter.patternDecrement = json["patternDecrement"].str;
            counter.patternAssign = json["patternAssign"].str;
        }
        else
        {
            throw new JSONException("Malformed counter file entry");
        }

        return counter;
    }
}


// onCommandCounter
/++
    Manages runtime counters (adding, removing and listing).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.elevated)
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
void onCommandCounter(CounterPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.constants : BufferSize;
    import lu.string : nom, stripped, strippedLeft;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|format|list] [counter word]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendFormatUsage()
    {
        enum pattern = "Usage: <b>%s%s format<b> [counter word] [one of ?, +, - and =] [format pattern]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendMustBeUniqueAndMayNotContain()
    {
        enum message = "Counter words must be unique and may not contain any of " ~
            "the following characters: [<b>+-=?<b>]";
        chan(plugin.state, event.channel, message);
    }

    void sendCounterAlreadyExists()
    {
        enum message = "A counter with that name already exists.";
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchCounter()
    {
        enum message = "No such counter available.";
        chan(plugin.state, event.channel, message);
    }

    void sendCounterRemoved(const string word)
    {
        enum pattern = "Counter <b>%s<b> removed.";
        immutable message = pattern.format(word);
        chan(plugin.state, event.channel, message);
    }

    void sendNoCountersActive()
    {
        enum message = "No counters currently active in this channel.";
        chan(plugin.state, event.channel, message);
    }

    void sendCountersList(const string[] counters)
    {
        enum pattern = "Current counters: %s";
        immutable arrayPattern = "%-(<b>" ~ plugin.state.settings.prefix ~ "%s<b>, %)<b>";
        immutable list = arrayPattern.format(counters);
        immutable message = pattern.format(list);
        chan(plugin.state, event.channel, message);
    }

    void sendFormatPatternUpdated()
    {
        enum message = "Format pattern updated.";
        chan(plugin.state, event.channel, message);
    }

    void sendFormatPatternCleared()
    {
        enum message = "Format pattern cleared.";
        chan(plugin.state, event.channel, message);
    }

    void sendCurrentFormatPattern(const string mod, const string customPattern)
    {
        enum pattern = `Current <b>%s<b> format pattern: "<b>%s<b>"`;
        immutable message = pattern.format(mod, customPattern);
        chan(plugin.state, event.channel, message);
    }

    void sendNoFormatPattern(const string word)
    {
        enum pattern = "Counter <b>%s<b> does not have a custom format pattern.";
        immutable message = pattern.format(word);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    switch (verb)
    {
    case "add":
        if (!slice.length) goto default;

        if (slice.canFind!(c => c.among!('+', '-', '=', '?')))
        {
            return sendMustBeUniqueAndMayNotContain();
        }

        if ((event.channel in plugin.counters) && (slice in plugin.counters[event.channel]))
        {
            return sendCounterAlreadyExists();
        }

        /+
            We need to check both hardcoded and soft channel-specific commands
            for conflicts.
         +/

        import kameloso.thread : ThreadMessage;
        import std.concurrency : send;

        bool triggerConflicts(const IRCPlugin.CommandMetadata[string][string] aa)
        {
            foreach (immutable pluginName, pluginCommands; aa)
            {
                if (!pluginCommands.length || (pluginName == "counter")) continue;

                if (slice in pluginCommands)
                {
                    enum pattern = `Counter word "<b>%s<b>" conflicts with a command of the <b>%s<b> plugin.`;
                    immutable message = pattern.format(slice, pluginName);
                    chan(plugin.state, event.channel, message);
                    return true;
                }
            }
            return false;
        }

        void channelSpecificDg(IRCPlugin.CommandMetadata[string][string] channelSpecificAA)
        {
            if (triggerConflicts(channelSpecificAA)) return;

            plugin.counters[event.channel][slice] = Counter(slice);
            saveCounters(plugin);

            // If we're here there were no conflicts
            enum pattern = "Counter <b>%s<b> added! Access it with <b>%s%s<b>.";
            immutable message = pattern.format(slice, plugin.state.settings.prefix, slice);
            chan(plugin.state, event.channel, message);
        }

        void dg(IRCPlugin.CommandMetadata[string][string] aa)
        {
            if (triggerConflicts(aa)) return;
            plugin.state.mainThread.send(ThreadMessage.PeekCommands(),
                cast(shared)&channelSpecificDg, event.channel);
        }

        plugin.state.mainThread.send(ThreadMessage.PeekCommands(), cast(shared)&dg, string.init);
        break;

    case "remove":
    case "del":
        if (!slice.length) goto default;

        auto channelCounters = event.channel in plugin.counters;
        if (!channelCounters || (slice !in *channelCounters)) return sendNoSuchCounter();

        (*channelCounters).remove(slice);
        if (!channelCounters.length) plugin.counters.remove(event.channel);
        saveCounters(plugin);

        return sendCounterRemoved(slice);

    case "format":
        import lu.string : SplitResults, splitInto;
        import std.algorithm.comparison : among;

        string word;
        string mod;
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

        if (!mod.length) return sendFormatUsage();

        if (!mod.among!("?", "+", "-", "="))
        {
            return sendFormatUsage();
        }

        auto channelCounters = event.channel in plugin.counters;
        if (!channelCounters) return sendNoSuchCounter();

        auto counter = word in *channelCounters;
        if (!counter) return sendNoSuchCounter();

        alias newPattern = slice;

        if (newPattern == "-")
        {
            if      (mod == "?") counter.patternQuery = string.init;
            else if (mod == "+") counter.patternIncrement = string.init;
            else if (mod == "-") counter.patternDecrement = string.init;
            else if (mod == "=") counter.patternAssign = string.init;
            else assert(0, "Impossible case");

            saveCounters(plugin);
            return sendFormatPatternCleared();
        }
        else if (newPattern.length)
        {
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
            immutable modverb =
                (mod == "?") ? "query" :
                (mod == "+") ? "increment" :
                (mod == "-") ? "decrement" :
                (mod == "=") ? "assign" :
                    "<<ERROR>>";

            return sendCurrentFormatPattern(modverb, counter.patternIncrement);
        }

    case "list":
        if (event.channel !in plugin.counters) return sendNoCountersActive();
        return sendCountersList(plugin.counters[event.channel].keys);

    default:
        return sendUsage();
    }
}


// onCounterWord
/++
    Allows users to increment, decrement, and set counters.

    This function fakes
    [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command]s by
    listening for prefixes (and the bot's nickname), and treating whatever comes
    after it as a command word. If it doesn't match a previously added counter,
    it is ignored.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
)
void onCounterWord(CounterPlugin plugin, const ref IRCEvent event)
{
    import kameloso.string : stripSeparatedPrefix;
    import lu.string : beginsWith, stripped, strippedLeft, strippedRight;
    import std.conv : ConvException, text, to;
    import std.format : FormatException, format;
    import std.meta : aliasSeqOf;
    import std.string : indexOf;

    void sendCurrentCount(const Counter counter)
    {
        if (counter.patternQuery.length)
        {
            try
            {
                immutable message = formatMessage(
                    plugin,
                    counter.patternQuery,
                    event,
                    counter,
                    0);
                return chan(plugin.state, event.channel, message);
            }
            catch (FormatException e)
            {
                enum pattern = "Failed to format counter message: %s";
                immutable message = pattern.format(e.msg);
                return chan(plugin.state, event.channel, message);
            }
        }

        enum pattern = "<b>%s<b> count so far: <b>%d<b>";
        immutable message = pattern.format(counter.word, counter.count);
        chan(plugin.state, event.channel, message);
    }

    void sendInputIsNaN(const string input)
    {
        enum pattern = "<b>%s<b> is not a number.";
        immutable message = pattern.format(input);
        chan(plugin.state, event.channel, message);
    }

    void sendCounterModified(const Counter counter, const long step)
    {
        try
        {
            if (step >= 0)
            {
                if (counter.patternIncrement.length)
                {
                    immutable message = formatMessage(
                        plugin,
                        counter.patternIncrement,
                        event,
                        counter,
                        0);
                    return chan(plugin.state, event.channel, message);
                }
            }
            else /*if (step < 0)*/
            {
                if (counter.patternDecrement.length)
                {
                    immutable message = formatMessage(
                        plugin,
                        counter.patternDecrement,
                        event,
                        counter,
                        0);
                    return chan(plugin.state, event.channel, message);
                }
            }
        }
        catch (FormatException e)
        {
            enum pattern = "Failed to format counter modified message: %s";
            immutable message = pattern.format(e.msg);
            return chan(plugin.state, event.channel, message);
        }

        enum pattern = "<b>%s %s<b>! Current count: <b>%d<b>";
        immutable stepText = (step >= 0) ? ('+' ~ step.text) : step.text;
        immutable message = pattern.format(counter.word, stepText, counter.count);
        chan(plugin.state, event.channel, message);
    }

    void sendCounterAssigned(const Counter counter)
    {
        if (counter.patternAssign.length)
        {
            try
            {
                immutable message = formatMessage(
                        plugin,
                        counter.patternAssign,
                        event,
                        counter,
                        0);
                    return chan(plugin.state, event.channel, message);
            }
            catch (FormatException e)
            {
                enum pattern = "Failed to format counter assigned message: %s";
                immutable message = pattern.format(e.msg);
                return chan(plugin.state, event.channel, message);
            }
        }

        enum pattern = "<b>%s<b> count assigned to <b>%d<b>!";
        immutable message = pattern.format(counter.word, counter.count);
        chan(plugin.state, event.channel, message);
    }

    void sendMustSpecifyNumber()
    {
        enum message = "You must specify a number to set the count to.";
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    if ((slice.length < (plugin.state.settings.prefix.length+1)) &&  // !w
        (slice.length < (plugin.state.client.nickname.length+2))) return;  // nickname:w

    if (slice.beginsWith(plugin.state.settings.prefix))
    {
        slice = slice[plugin.state.settings.prefix.length..$];
    }
    else if (slice.beginsWith(plugin.state.client.nickname))
    {
        slice = slice.stripSeparatedPrefix(plugin.state.client.nickname, Yes.demandSeparatingChars);
    }
    else
    {
        version(TwitchSupport)
        {
            if (plugin.state.bot.displayName.length && slice.beginsWith(plugin.state.bot.displayName))
            {
                slice = slice.stripSeparatedPrefix(plugin.state.bot.displayName, Yes.demandSeparatingChars);
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

    auto channelCounters = event.channel in plugin.counters;
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
    if (event.sender.class_ < plugin.counterSettings.minimumPermissionsNeeded) return;

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

        counter.count = newCount;
        saveCounters(plugin);
        return sendCounterAssigned(*counter);

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
void onWelcome(CounterPlugin plugin)
{
    plugin.reload();
}


// formatMessage
/++
    Formats a message by a string pattern, replacing select keywords with more
    helpful values.

    Example:
    ---
    immutable pattern = "The $word count was bumped by +$step to $count!";
    immutable message = formatMessage(plugin, pattern, event, counter, step);
    assert(message == "The curse word was bumped by +1 to 92!");
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
    const ref IRCEvent event,
    const Counter counter,
    const long step)
{
    import kameloso.plugins.common.misc : nameOf;
    import std.conv : text;
    import std.array : replace;
    import std.math : abs;

    string toReturn = pattern
        .replace("$step", abs(step).text)
        .replace("$count", counter.count.text)
        .replace("$word", counter.word)
        .replace("$channel", event.channel)
        .replace("$nickname", event.sender.nickname)
        .replace("$botNickname", plugin.state.client.nickname);

    version(TwitchSupport)
    {
        toReturn = toReturn
            .replace("$bot", plugin.state.bot.displayName)
            .replace("$streamerNickname", event.channel[1..$])
            .replace("$streamer", nameOf(plugin, event.channel[1..$]))
            .replace("$displayName", event.sender.displayName);
    }

    return toReturn;
}


// reload
/++
    Reloads counters from disk.
 +/
void reload(CounterPlugin plugin)
{
    return loadCounters(plugin);
}


// saveCounters
/++
    Saves [Counter]s to disk in JSON format.

    Params:
        plugin = The current [CounterPlugin].
 +/
void saveCounters(CounterPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONType;

    JSONStorage json;

    foreach (immutable channelName, channelCounters; plugin.counters)
    {
        json[channelName] = null;
        json[channelName].object = null;

        foreach (immutable word, counter; channelCounters)
        {
            json[channelName][word] = counter.toJSON();
        }
    }

    if (json.type == JSONType.null_) json.object = null;  // reset to type object if null_
    json.save(plugin.countersFile);
}


// loadCounters
/++
    Loads [Counter]s from disk.

    Params:
        plugin = The current [CounterPlugin].
 +/
void loadCounters(CounterPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.countersFile);
    plugin.counters.clear();

    foreach (immutable channelName, channelCountersJSON; json.object)
    {
        foreach (immutable word, counterJSON; channelCountersJSON.object)
        {
            plugin.counters[channelName][word] = Counter.fromJSON(counterJSON);

            // Backwards compatibility with old counters files
            auto counter = word in plugin.counters[channelName];
            if (!counter.word.length)
            {
                counter.word = word;
            }

            plugin.counters[channelName].rehash();
        }
    }

    plugin.counters.rehash();
}


// initResources
/++
    Reads and writes the file of persistent counters to disk, ensuring that it's
    there and properly formatted.
 +/
void initResources(CounterPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage countersJSON;

    try
    {
        countersJSON.load(plugin.countersFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
        import kameloso.common : logger;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Counters file is malformed",
            plugin.name,
            plugin.countersFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    countersJSON.save(plugin.countersFile);
}


mixin MinimalAuthentication;
mixin ModuleRegistration;

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
    CounterSettings counterSettings;

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
            [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
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

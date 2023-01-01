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
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// User level required to bump a counter.
    IRCUser.Class minimumPermissionsNeeded = IRCUser.Class.elevated;
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

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    switch (verb)
    {
    case "add":
        if (!slice.length) goto default;

        if (slice.canFind!(c => c.among!('+', '-', '=', '?')))
        {
            enum message = "Counter words must be unique and may not contain any of " ~
                "the following characters: [<b>+-=?<b>]";
            return chan(plugin.state, event.channel, message);
        }

        if ((event.channel in plugin.counters) && (slice in plugin.counters[event.channel]))
        {
            enum message = "A counter with that name already exists.";
            return chan(plugin.state, event.channel, message);
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

            plugin.counters[event.channel][slice] = 0;
            saveResourceToDisk(plugin.counters, plugin.countersFile);

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

        if ((event.channel !in plugin.counters) || (slice !in plugin.counters[event.channel]))
        {
            enum message = "No such counter available.";
            return chan(plugin.state, event.channel, message);
        }

        plugin.counters[event.channel].remove(slice);
        if (!plugin.counters[event.channel].length) plugin.counters.remove(event.channel);
        saveResourceToDisk(plugin.counters, plugin.countersFile);

        enum pattern = "Counter <b>%s<b> removed.";
        immutable message = pattern.format(slice);
        chan(plugin.state, event.channel, message);
        break;

    case "list":
        if (event.channel !in plugin.counters)
        {
            enum message = "No counters currently active in this channel.";
            return chan(plugin.state, event.channel, message);
        }

        enum pattern = "Current counters: %s";
        immutable arrayPattern = "%-(<b>" ~ plugin.state.settings.prefix ~ "%s<b>, %)<b>";
        immutable list = arrayPattern.format(plugin.counters[event.channel].keys);
        immutable message = pattern.format(list);
        chan(plugin.state, event.channel, message);
        break;

    default:
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [counter word]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        break;
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
    import lu.string : beginsWith, stripped, strippedLeft, strippedRight;
    import std.conv : ConvException, text, to;
    import std.format : format;
    import std.meta : aliasSeqOf;
    import std.string : indexOf;

    string slice = event.content.stripped;  // mutable
    if ((slice.length < (plugin.state.settings.prefix.length+1)) &&  // !w
        (slice.length < (plugin.state.client.nickname.length+2))) return;  // nickname:w

    if (slice.beginsWith(plugin.state.settings.prefix))
    {
        slice = slice[plugin.state.settings.prefix.length..$];
    }
    else if (slice.beginsWith(plugin.state.client.nickname))
    {
        import kameloso.string : stripSeparatedPrefix;
        slice = slice.stripSeparatedPrefix(plugin.state.client.nickname, Yes.demandSeparatingChars);
    }
    else
    {
        // Just a random message
        return;
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

    auto count = word in *channelCounters;
    if (!count) return;

    slice = (signPos != -1) ? slice[signPos..$] : string.init;

    if (!slice.length || (slice[0] == '?'))
    {
        import std.conv : text;

        enum pattern = "<b>%s<b> count so far: <b>%s<b>";
        immutable message = pattern.format(word, plugin.counters[event.channel][word]);
        return chan(plugin.state, event.channel, message);
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
            catch (ConvException e)
            {
                enum pattern = "<b>%s<b> is not a number.";
                immutable message = pattern.format(slice);
                return chan(plugin.state, event.channel, message);
            }
        }

        *count += step;
        saveResourceToDisk(plugin.counters, plugin.countersFile);

        enum pattern = "<b>%s %s<b>! Current count: <b>%d<b>";
        immutable stepText = (step >= 0) ? ('+' ~ step.text) : step.text;
        immutable message = pattern.format(word, stepText, *count);
        chan(plugin.state, event.channel, message);
        break;

    case '=':
        slice = slice[1..$].strippedLeft;

        if (!slice.length)
        {
            enum message = "You must specify a number to set the count to.";
            return chan(plugin.state, event.channel, message);
        }

        long newCount;

        try
        {
            newCount = slice.to!long;
        }
        catch (ConvException e)
        {
            enum pattern = "Not a number: <b>%s<b>";
            immutable message = pattern.format(slice);
            return chan(plugin.state, event.channel, message);
        }

        *count = newCount;
        saveResourceToDisk(plugin.counters, plugin.countersFile);

        enum pattern = "<b>%s<b> count assigned to <b>%s<b>!";
        immutable message = pattern.format(word, newCount);
        chan(plugin.state, event.channel, message);
        break;

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


// reload
/++
    Reloads counters from disk.
 +/
void reload(CounterPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage countersJSON;
    countersJSON.load(plugin.countersFile);
    plugin.counters.clear();
    plugin.counters.populateFromJSON(countersJSON, No.lowercaseKeys);
    plugin.counters = plugin.counters.rehash();
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for counters.

    Params:
        aa = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const long[string][string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
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
    /// All Counter plugin settings.
    CounterSettings counterSettings;

    /// Counter integer by counter word by channel name.
    long[string][string] counters;

    /// Filename of file with persistent counters.
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

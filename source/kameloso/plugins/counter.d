/++
 +  A simple counter plugin.
 +
 +  Allows you to define runtime `!word` counters that you can increment,
 +  decrement or assign specific values to. This can be used to track deaths in
 +  video games, for instance.
 +
 +  Undefined behaviour if a counter command word conflicts with that of another
 +  command. (Generally both should trigger.)
 +/
module kameloso.plugins.counter;

version(WithPlugins):
version(WithCounterPlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// CounterSettings
/++
 +  All Counter plugin settings aggregated.
 +/
@Settings struct CounterSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;
}


// onCommandCounter
/++
 +  Manages runtime counters.
 +/
@Terminating
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "counter")
@Description("Manages counters.", "$command [add|del|list]")
void onCommandCounter(CounterPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold;
    import lu.string : nom, stripped, strippedLeft;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;
    import std.format : format;

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    if (slice.canFind!(c => c.among('+', '-', '=', ' ')))
    {
        chan(plugin.state, event.channel,
            "Counter names must not contain any of the following characters: [+-= ]");
        return;
    }

    switch (verb)
    {
    case "add":
        if (!slice.length) goto default;

        if ((event.channel in plugin.counters) && (slice in plugin.counters[event.channel]))
        {
            chan(plugin.state, event.channel, "A counter with that name already exists.");
            return;
        }

        enum pattern = "Counter %s added! Access it with %s.";

        immutable command = plugin.state.settings.prefix ~ slice;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(slice.ircBold, command.ircBold) :
            pattern.format(slice, command);

        plugin.counters[event.channel][slice] = 0;
        chan(plugin.state, event.channel, message);
        saveResourceToDisk(plugin.counters, plugin.countersFile);
        break;

    case "remove":
    case "del":
        if (!slice.length) goto default;

        if ((event.channel !in plugin.counters) || (slice !in plugin.counters[event.channel]))
        {
            chan(plugin.state, event.channel, "No such counter enabled.");
            return;
        }

        enum pattern = "Counter %s removed.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(slice.ircBold) :
            pattern.format(slice);

        plugin.counters[event.channel].remove(slice);
        if (!plugin.counters[event.channel].length) plugin.counters.remove(event.channel);

        chan(plugin.state, event.channel, message);
        saveResourceToDisk(plugin.counters, plugin.countersFile);
        break;

    case "list":
    case string.init:
        if (event.channel !in plugin.counters)
        {
            chan(plugin.state, event.channel, "No counters currently active in this channel.");
            return;
        }

        enum pattern = "Current counters: %s";
        immutable arrayPattern = "%-(" ~ plugin.state.settings.prefix ~ "%s, %)";

        immutable list = arrayPattern.format(plugin.counters[event.channel].keys);
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(list.ircBold) :
            pattern.format(list);

        chan(plugin.state, event.channel, message);
        break;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [add|del|list]"
            .format(plugin.state.settings.prefix, event.aux));
        break;
    }
}


// onCounterWord
/++
 +  Increments, decrements, sets or clears a counter.
 +
 +  If an invalid counter word was supplied, the call is silently ignored.
 +/
@Terminating
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onCounterWord(CounterPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold;
    import lu.string : stripped, strippedLeft;
    import std.conv : ConvException, text, to;
    import std.format : format;
    import std.meta : aliasSeqOf;
    import std.string : indexOf;

    string slice = event.content.stripped;  // mutable
    if (slice.length < (plugin.state.settings.prefix.length+1)) return;

    auto channelCounters = event.channel in plugin.counters;
    if (!channelCounters) return;

    slice = slice[plugin.state.settings.prefix.length..$];

    ptrdiff_t signPos;

    foreach (immutable sign; aliasSeqOf!"+=-")  // '-' after '=' to support "!word=-5"
    {
        signPos = slice.indexOf(sign);
        if (signPos != -1) break;
    }

    immutable word = (signPos != -1) ? slice[0..signPos] : slice;

    auto count = word in *channelCounters;
    if (!count) return;

    slice = (signPos != -1) ? slice[signPos..$] : string.init;

    if (!slice.length)
    {
        import std.conv : text;

        enum pattern = "Current %s: %s";

        immutable countText =  plugin.counters[event.channel][word].text;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(word.ircBold, countText.ircBold) :
            pattern.format(word, countText);

        chan(plugin.state, event.channel, message);
        return;
    }

    immutable sign = slice[0];

    switch (sign)
    {
    case '+':
    case '-':
        int step;

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
            try
            {
                step = slice.strippedLeft.to!int;
            }
            catch (ConvException e)
            {
                enum pattern = "Not a number: %s";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(slice.ircBold) :
                    pattern.format(slice);

                chan(plugin.state, event.channel, message);
                return;
            }
        }

        enum pattern = "%s %s! Current count: %s";

        *count = *count + step;

        immutable countText = (*count).text;
        immutable stepText = (step >= 0) ? ('+' ~ step.text) : step.text;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(word.ircBold, stepText.ircBold, countText.ircBold) :
            pattern.format(word, stepText, countText);

        chan(plugin.state, event.channel, message);
        saveResourceToDisk(plugin.counters, plugin.countersFile);
        break;

    case '=':
        slice = slice[1..$];

        if (!slice.length)
        {
            chan(plugin.state, event.channel, "You must specify a number to set the count to.");
            return;
        }

        int newCount;

        try
        {
            newCount = slice.to!int;
        }
        catch (ConvException e)
        {
            enum pattern = "Not a number: %s";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(slice.ircBold) :
                pattern.format(slice);

            chan(plugin.state, event.channel, message);
            return;
        }

        enum pattern = "%s count assigned to %s!";

        immutable countText =  newCount.text;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(word.ircBold, countText.ircBold) :
            pattern.format(word, countText);

        *count = newCount;
        chan(plugin.state, event.channel, message);
        saveResourceToDisk(plugin.counters, plugin.countersFile);
        break;

    default:
        assert(0, "Hit impossible default case in onCounterWord sign switch");
    }
}


// onEndOfMotd
/++
 +  Populate the counters array after we have successfully logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(CounterPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage countersJSON;
    countersJSON.load(plugin.countersFile);
    plugin.counters.populateFromJSON(countersJSON, No.lowercaseKeys);
    plugin.counters.rehash();
}


// saveResourceToDisk
/++
 +  Saves the passed resource to disk, but in JSON format.
 +
 +  This is used with the associative arrays for counters.
 +
 +  Params:
 +      aa = The JSON-convertible resource to save.
 +      filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const int[string][string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
}


// initResources
/++
 +  Reads and writes the file of persistent counters to disk, ensuring that it's
 +  there and properly formatted.
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
        import kameloso.common : logger;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.countersFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    countersJSON.save(plugin.countersFile);
}


mixin MinimalAuthentication;


public:


// CounterPlugin
/++
 +  The Counter plugin allows for users to define counter commands at runtime.
 +/
final class CounterPlugin : IRCPlugin
{
private:
    /// All Counter plugin settings.
    CounterSettings counterSettings;

    /// Counter integer by counter word by channel name.
    int[string][string] counters;

    /// Filename of file with persistent counters.
    @Resource string countersFile = "counters.json";

    mixin IRCPluginImpl;
}

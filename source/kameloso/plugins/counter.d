/++
 +  A simple counter plugin.
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
 +  All Count plugin settings aggregated.
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
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "counter")
@Description("Manages counters.", "$command [add|del|reset|list]")
void onCommandCounter(CounterPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold;
    import lu.string : nom, stripped, strippedLeft;
    import std.format : format;

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    switch (verb)
    {
    case "add":
        if (!slice.length) goto default;

        plugin.counters[event.channel][slice] = 0;
        chan(plugin.state, event.channel, "Counter added, it's at 0");
        break;

    case "remove":
    case "del":
        if (!slice.length) goto default;

        if ((event.channel !in plugin.counters) || (slice !in plugin.counters[event.channel]))
        {
            chan(plugin.state, event.channel, "No such counter");
            return;
        }

        plugin.counters[event.channel].remove(slice);
        chan(plugin.state, event.channel, "Counter removed.");
        break;

    case "clear":
    case "reset":
    case "zero":
    case "init":
        if (!slice.length) goto default;

        if ((event.channel !in plugin.counters) || (slice !in plugin.counters[event.channel]))
        {
            chan(plugin.state, event.channel, "No such counter");
            return;
        }

        plugin.counters[event.channel][slice] = 0;
        chan(plugin.state, event.channel, "Counter reset.");
        break;

    case "list":
    case string.init:
        if (event.channel !in plugin.counters)
        {
            chan(plugin.state, event.channel, "No counters currently active in this channel.");
            return;
        }

        enum pattern = "Current counters: %s.";
        enum arrayPattern = "%-%(%s,%)";

        immutable list = arrayPattern.format(plugin.counters[event.channel]);
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(list.ircBold) :
            pattern.format(list);

        chan(plugin.state, event.channel, message);
        break;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [add|del|reset|list]"
            .format(plugin.state.settings.prefix, event.aux));
        break;
    }
}


// onCounterWord
/++
 +  Increments, decrements, sets or clears a counter.
 +
 +  If an invalid counter was supplied, the call is silently ignored.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onCounterWord(CounterPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold;
    import lu.string : contains, stripped, strippedLeft;
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

    foreach (immutable sign; aliasSeqOf!"+-=*")
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

        enum pattern = "Current %s count: %s";

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

        immutable countText =  plugin.counters[event.channel][word].text;
        immutable stepText = (step >= 0) ? ('+' ~ step.text) : step.text;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(word.ircBold, stepText.ircBold, countText.ircBold) :
            pattern.format(word, stepText, countText);

        chan(plugin.state, event.channel, message);
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

        *count = newCount;

        immutable countText =  newCount.text;
        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(word.ircBold, countText.ircBold) :
            pattern.format(word, countText);

        chan(plugin.state, event.channel, message);
        break;

    case '*':
        enum pattern = "%s count reset.";

        *count = 0;

        immutable message = pattern.format(word);

        chan(plugin.state, event.channel, message);
        break;

    default:
        assert(0, "Hit impossible default case in onCounterWord sign switch");
    }
}


mixin MinimalAuthentication;


public:


// CounterPlugin
/++
 +  The Counter plugin allows for users to define counter commands at runtime.
 +  Calling the command bumps the counter.
 +/
final class CounterPlugin : IRCPlugin
{
private:
    /// All Counter plugin settings.
    CounterSettings counterSettings;

    /// Counter integer by counter word by channel name.
    int[string][string] counters;

    mixin IRCPluginImpl;
}

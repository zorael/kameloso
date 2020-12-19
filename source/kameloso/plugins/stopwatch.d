/++
    A simple stopwatch plugin. It offers the ability to start and stop timers,
    to get how much time passed between the creation of a stopwatch and the
    cessation of it.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#stopwatch
 +/
module kameloso.plugins.stopwatch;

version(WithPlugins):
version(WithStopwatchPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// StopwatchSettings
/++
    All Stopwatch plugin runtime settings aggregated.
 +/
@Settings struct StopwatchSettings
{
    /// Whether or not this plugin is enabled.
    @Enabler bool enabled = true;
}


// onCommandStopwatch
/++
    Manages stopwatches.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "stopwatch")
@BotCommand(PrefixPolicy.prefixed, "sw", Yes.hidden)
@Description("Manages stopwatches.", "$command [start|stop|status]")
void onCommandStopwatch(StopwatchPlugin plugin, const ref IRCEvent event)
{
    import kameloso.irccolours : ircBold, ircColourByHash;
    import lu.string : nom, stripped, strippedLeft;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    string getDiff(const string id)
    {
        import core.time : msecs;

        assert((event.channel in plugin.stopwatches),
            "Tried to access stopwatches from nonexistent channel");
        assert((id in plugin.stopwatches[event.channel]),
            "Tried to fetch stopwatch start timestamp for a nonexistent id");

        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable diff = now - SysTime.fromUnixTime(plugin.stopwatches[event.channel][id]);
        return diff.toString;
    }

    switch (verb)
    {
    case "start":
        immutable stopwatchAlreadyExists = (event.channel in plugin.stopwatches) &&
            (event.sender.nickname in plugin.stopwatches[event.channel]);
        immutable message = "Stopwatch " ~ (stopwatchAlreadyExists ? "restarted!" : "started!");
        plugin.stopwatches[event.channel][event.sender.nickname] = Clock.currTime.toUnixTime;
        chan(plugin.state, event.channel, message);
        break;

    case "stop":
    case "end":
    case "status":
    case string.init:
        immutable id = ((event.sender.class_ >= IRCUser.Class.operator) && slice.length) ?
            slice :
            event.sender.nickname;

        if ((event.channel !in plugin.stopwatches) || (id !in plugin.stopwatches[event.channel]))
        {
            if (id == event.sender.nickname)
            {
                chan(plugin.state, event.channel, "You do not have a stopwatch running.");
            }
            else
            {
                enum pattern = "There is no such stopwatch running. (%s)";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash) :
                    pattern.format(id);

                chan(plugin.state, event.channel, message);
            }
            return;
        }

        immutable diff = getDiff(id);

        switch (verb)
        {
        case "stop":
        case "end":
            enum pattern = "Stopwatch stopped after %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(diff.ircBold) :
                pattern.format(diff);

            chan(plugin.state, event.channel, message);
            plugin.stopwatches[event.channel].remove(id);
            break;

        case "status":
        case string.init:
            enum pattern = "Elapsed time: %s";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(diff.ircBold) :
                pattern.format(diff);

            chan(plugin.state, event.channel, message);
            break;

        default:
            assert(0, "Unexpected inner case in nested onCommandStopwatch switch");
        }
        break;

    case "clear":
        enum pattern = "Clearing all stopwatches in channel %s.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(event.channel.ircBold) :
            pattern.format(event.channel);

        chan(plugin.state, event.channel, message);
        plugin.stopwatches.remove(event.channel);
        break;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [start|stop|status]"  // hide clear
            .format(plugin.state.settings.prefix, event.aux));
        break;
    }
}


mixin MinimalAuthentication;


public:

/++
    The Stopwatch plugin offers the ability to start stopwatches, and print
    how much time elapsed upon stopping them.
 +/
final class StopwatchPlugin : IRCPlugin
{
private:
    /// All Stopwatch plugin settings.
    StopwatchSettings stopwatchSettings;

    /// Vote start timestamps by user by channel.
    long[string][string] stopwatches;

    mixin IRCPluginImpl;
}

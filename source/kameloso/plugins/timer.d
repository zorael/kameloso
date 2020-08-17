/++
 +  A simple timer plugin. It offers the ability to start and stop stopwatch-like
 +  timers, to get how much time passed between the creation of a timer and
 +  the cessation of it.
 +/
module kameloso.plugins.timer;

version(WithPlugins):
version(WithTimerPlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// TimerSettings
/++
 +  All Timer plugin runtime settings aggregated.
 +/
@Settings struct TimerSettings
{
    /// Whether or not this plugin is enabled.
    @Enabler bool enabled = true;
}


// onCommandTimer
/++
 +  Manages timers.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "timer")
@Description("Manages timers.", "$command [start|stop|status]")
void onCommandTimer(TimerPlugin plugin, const IRCEvent event)
{
    import kameloso.irccolours : ircBold, ircColourByHash;
    import lu.string : nom, stripped, strippedLeft;
    import std.datetime.systime : Clock, SysTime;

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    string getDiff(const string id)
    {
        import core.time : msecs;

        assert((event.channel in plugin.timers),
            "Tried to access timers from nonexistent channel");
        assert((id in plugin.timers[event.channel]),
            "Tried to fetch timer start timestamp for a nonexistent id");

        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable diff = now - SysTime.fromUnixTime(plugin.timers[event.channel][id]);
        return diff.toString;
    }

    switch (verb)
    {
    case "start":
        immutable timerAlreadyExists = (event.channel in plugin.timers) &&
            (event.sender.nickname in plugin.timers[event.channel]);
        immutable message = "Timer " ~ (timerAlreadyExists ? "restarted." : "started.");
        plugin.timers[event.channel][event.sender.nickname] = Clock.currTime.toUnixTime;
        chan(plugin.state, event.channel, message);
        break;

    case "stop":
    case "end":
    case "status":
    case string.init:
        immutable id = ((event.sender.class_ >= IRCUser.Class.operator) && slice.length) ?
            slice :
            event.sender.nickname;

        if ((event.channel !in plugin.timers) || (id !in plugin.timers[event.channel]))
        {
            if (id == event.sender.nickname)
            {
                chan(plugin.state, event.channel, "You do not have a timer running.");
            }
            else
            {
                enum pattern = "There is no such timer running. (%s)";

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
            enum pattern = "Timer stopped after %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(diff.ircBold) :
                pattern.format(diff);

            chan(plugin.state, event.channel, message);
            plugin.timers[event.channel].remove(id);
            break;

        case "status":
        case string.init:
            enum pattern = "Elapsed time: %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(diff.ircBold) :
                pattern.format(diff);

            chan(plugin.state, event.channel, message);
            break;

        default:
            assert(0, "Unexpected inner case in nested onCommandTimer switch");
        }
        break;

    case "clear":
        enum pattern = "Clearing all timers in channel %s.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(event.channel.ircBold) :
            pattern.format(event.channel);

        chan(plugin.state, event.channel, message);
        plugin.timers.remove(event.channel);
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
 +  The Timer plugin offers the ability to start timers, and print how much
 +  time elapsed upon stopping them.
 +/
final class TimerPlugin : IRCPlugin
{
private:
    /// All Timer plugin settings.
    TimerSettings timerSettings;

    /// Vote start timestamps by user by channel.
    long[string][string] timers;

    mixin IRCPluginImpl;
}

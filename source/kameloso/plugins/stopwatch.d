/++
    A simple stopwatch plugin. It offers the ability to start and stop timers,
    to get how much time passed between the creation of a stopwatch and the
    cessation of it.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#stopwatch
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.stopwatch;

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
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.whitelist)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("stopwatch")
            .policy(PrefixPolicy.prefixed)
            .description("Starts, stops, or shows status of stopwatches.")
            .addSyntax("$command start")
            .addSyntax("$command stop")
            .addSyntax("$command status")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("sw")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandStopwatch(StopwatchPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, stripped, strippedLeft;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    slice = slice.strippedLeft;

    string getDiff(const string id)
    {
        import kameloso.time : timeSince;
        import core.time : msecs;

        auto channelWatches = event.channel in plugin.stopwatches;
        assert(channelWatches, "Tried to access stopwatches from nonexistent channel");

        auto watch = id in *channelWatches;
        assert(watch, "Tried to fetch stopwatch start timestamp for a nonexistent id");

        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable diff = now - SysTime.fromUnixTime(*watch);
        return timeSince(diff);
    }

    switch (verb)
    {
    case "start":
        auto channelWatches = event.channel in plugin.stopwatches;
        immutable stopwatchAlreadyExists = (channelWatches && (event.sender.nickname in *channelWatches));
        immutable message = "Stopwatch " ~ (stopwatchAlreadyExists ? "restarted!" : "started!");
        plugin.stopwatches[event.channel][event.sender.nickname] = Clock.currTime.toUnixTime;
        return chan(plugin.state, event.channel, message);

    case "stop":
    case "end":
    case "status":
    case string.init:
        immutable id = slice.length ?
            slice :
            event.sender.nickname;

        auto channelWatches = event.channel in plugin.stopwatches;
        if (!channelWatches || (id !in *channelWatches))
        {
            if (id == event.sender.nickname)
            {
                enum message = "You do not have a stopwatch running.";
                chan(plugin.state, event.channel, message);
            }
            else
            {
                enum pattern = "There is no such stopwatch running. (<h>%s<h>)";
                immutable message = pattern.format(id);
                chan(plugin.state, event.channel, message);
            }
            return;
        }

        immutable diff = getDiff(id);

        switch (verb)
        {
        case "stop":
        case "end":
            if ((id != event.sender.nickname) && (event.sender.class_ < IRCUser.Class.operator))
            {
                enum message = "You cannot end or stop someone else's stopwatch.";
                return chan(plugin.state, event.channel, message);
            }

            plugin.stopwatches[event.channel].remove(id);
            enum pattern = "Stopwatch stopped after <b>%s<b>.";
            immutable message = pattern.format(diff);
            return chan(plugin.state, event.channel, message);

        case "status":
        case string.init:
            enum pattern = "Elapsed time: <b>%s<b>";
            immutable message = pattern.format(diff);
            return chan(plugin.state, event.channel, message);

        default:
            assert(0, "Unexpected inner case in nested onCommandStopwatch switch");
        }

    case "clear":
        plugin.stopwatches.remove(event.channel);
        enum pattern = "Clearing all stopwatches in channel <b>%s<b>.";
        immutable message = pattern.format(event.channel);
        return chan(plugin.state, event.channel, message);

    default:
        enum pattern = "Usage: <b>%s%s<b> [start|stop|status]";  // hide clear
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        return chan(plugin.state, event.channel, message);
    }
}


mixin MinimalAuthentication;
mixin ModuleRegistration;

public:


// StopWatchPlugin
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

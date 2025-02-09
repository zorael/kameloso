/++
    A simple stopwatch plugin. It offers the ability to start and stop timers,
    to get how much time passed between the creation of a stopwatch and the
    cessation of it.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#stopwatch,
        [kameloso.plugins.common],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.stopwatch;

version(WithStopwatchPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.messaging;
import dialect.defs;


// StopwatchSettings
/++
    All Stopwatch plugin runtime settings aggregated.
 +/
@Settings struct StopwatchSettings
{
    /++
        Whether or not this plugin is enabled.
     +/
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
void onCommandStopwatch(StopwatchPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped, strippedLeft;
    import std.datetime.systime : Clock;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [start|stop|status]";  // hide clear
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoStopwatch()
    {
        enum message = "You do not have a stopwatch running.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchStopwatch(const string id)
    {
        enum pattern = "There is no such stopwatch running. (<h>%s<h>)";
        immutable message = pattern.format(id);
        chan(plugin.state, event.channel.name, message);
    }

    void sendCannotStopOthersStopwatches()
    {
        enum message = "You cannot end or stop someone else's stopwatch.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendStoppedAfter(const string diff)
    {
        enum pattern = "Stopwatch stopped after <b>%s<b>.";
        immutable message = pattern.format(diff);
        chan(plugin.state, event.channel.name, message);
    }

    void sendElapsedTime(const string diff)
    {
        enum pattern = "Elapsed time: <b>%s<b>";
        immutable message = pattern.format(diff);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMissingClearPermissions()
    {
        enum message = "You do not have permissions to clear all stopwatches.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendClearingStopwatches(const string channelName)
    {
        enum pattern = "Clearing all stopwatches in channel <b>%s<b>.";
        immutable message = pattern.format(channelName);
        chan(plugin.state, event.channel.name, message);
    }

    void sendStartedOrRestarted(const bool restarted)
    {
        immutable message = "Stopwatch " ~ (restarted ? "restarted!" : "started!");
        chan(plugin.state, event.channel.name, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);
    slice = slice.strippedLeft;

    string getDiff(const string id)
    {
        import kameloso.time : timeSince;
        import std.datetime.systime : SysTime;
        import core.time : Duration;

        auto channelWatches = event.channel.name in plugin.stopwatches;
        assert(channelWatches, "Tried to access stopwatches from nonexistent channel");

        auto watch = id in *channelWatches;
        assert(watch, "Tried to fetch stopwatch start timestamp for a nonexistent id");

        auto now = Clock.currTime;
        now.fracSecs = Duration.zero;
        immutable diff = now - SysTime.fromUnixTime(*watch);
        return timeSince(diff);
    }

    switch (verb)
    {
    case "start":
        auto channelWatches = event.channel.name in plugin.stopwatches;
        immutable stopwatchAlreadyExists = (channelWatches && (event.sender.nickname in *channelWatches));
        plugin.stopwatches[event.channel.name][event.sender.nickname] = Clock.currTime.toUnixTime();
        return sendStartedOrRestarted(stopwatchAlreadyExists);

    case "stop":
    case "end":
    case "status":
    case string.init:
        immutable id = slice.length ?
            slice :
            event.sender.nickname;

        auto channelWatches = event.channel.name in plugin.stopwatches;
        if (!channelWatches || (id !in *channelWatches))
        {
            return (id == event.sender.nickname) ?
                sendNoStopwatch() :
                sendNoSuchStopwatch(id);
        }

        immutable diff = getDiff(id);

        switch (verb)
        {
        case "stop":
        case "end":
            if ((id != event.sender.nickname) && (event.sender.class_ < IRCUser.Class.operator))
            {
                return sendCannotStopOthersStopwatches();
            }

            plugin.stopwatches[event.channel.name].remove(id);

            if (!plugin.stopwatches[event.channel.name].length)
            {
                plugin.stopwatches.remove(event.channel.name);
            }
            return sendStoppedAfter(diff);

        case "status":
        case string.init:
            return sendElapsedTime(diff);

        default:
            assert(0, "Unexpected inner case in nested onCommandStopwatch switch");
        }

    case "clear":
        if (event.sender.class_ < IRCUser.Class.operator)
        {
            return sendMissingClearPermissions();
        }

        plugin.stopwatches.remove(event.channel.name);
        return sendClearingStopwatches(event.channel.name);

    default:
        return sendUsage();
    }
}


// serialiseStopwatches
/++
    Serialises the stopwatches to a temporary file.

    Params:
        plugin = The current [StopwatchPlugin].
 +/
void serialiseStopwatches(StopwatchPlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    if (!plugin.stopwatches.length) return;

    auto file = File(plugin.stopwatchTempFile, "w");
    file.writeln(JSONValue(plugin.stopwatches).toPrettyString);
}


// deserialiseStopwatches
/++
    Deserialises the stopwatches from a temporary file.

    Params:
        plugin = The current [StopwatchPlugin].
 +/
void deserialiseStopwatches(StopwatchPlugin plugin)
{
    import lu.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.stopwatchTempFile);

    foreach (immutable channelName, const channelStopwatchesJSON; json.object)
    {
        auto channelStopwatches = channelName in plugin.stopwatches;

        foreach (immutable nickname, const stopwatchJSON; channelStopwatchesJSON.object)
        {
            (*channelStopwatches)[nickname] = stopwatchJSON.integer;
        }
    }
}


// onWelcome
/++
    Deserialises stopwatches saved to disk upon successfully registering to the server,
    restoring any ongoing watches.

    The temporary file is removed immediately afterwards.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(StopwatchPlugin plugin)
{
    import std.file : exists, remove;

    if (plugin.stopwatchTempFile.exists)
    {
        deserialiseStopwatches(plugin);
        remove(plugin.stopwatchTempFile);
    }
}


// teardown
/++
    Tears down the [StopwatchPlugin], serialising any ongoing stopwatches to file,
    so they aren't lost to the ether.
 +/
void teardown(StopwatchPlugin plugin)
{
    if (!plugin.stopwatches.length) return;
    serialiseStopwatches(plugin);
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(StopwatchPlugin _, Selftester s)
{
    // ------------ !stopwatch

    s.send("stopwatch harbl");
    s.expect("Usage: !stopwatch [start|stop|status]");

    s.send("stopwatch");
    s.expect("You do not have a stopwatch running.");

    s.send("stopwatch status");
    s.expect("You do not have a stopwatch running.");

    s.send("stopwatch status harbl");
    s.expect("There is no such stopwatch running. (harbl)");

    s.send("stopwatch start");
    s.expect("Stopwatch started!");

    s.send("stopwatch");
    s.expectHead("Elapsed time: ");

    s.send("stopwatch status");
    s.expectHead("Elapsed time: ");

    s.send("stopwatch start");
    s.expect("Stopwatch restarted!");

    s.send("stopwatch stop");
    s.expectHead("Stopwatch stopped after ");

    s.send("stopwatch start");
    s.expect("Stopwatch started!");

    s.send("stopwatch clear");
    s.expect("Clearing all stopwatches in channel ${channel}.");

    s.send("stopwatch");
    s.expect("You do not have a stopwatch running.");

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!StopwatchPlugin;

public:


// StopwatchPlugin
/++
    The Stopwatch plugin offers the ability to start stopwatches, and print
    how much time elapsed upon stopping them.
 +/
final class StopwatchPlugin : IRCPlugin
{
private:
    /++
        All Stopwatch plugin settings.
     +/
    StopwatchSettings stopwatchSettings;

    /++
        Stopwatch start timestamps by user by channel.
     +/
    long[string][string] stopwatches;

    /++
        Temporary file to store ongoing stopwatches to, between connections
        (and executions of the program).
     +/
    @Resource string stopwatchTempFile = "stopwatches.json";

    mixin IRCPluginImpl;
}

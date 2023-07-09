/++
    A simple stopwatch plugin. It offers the ability to start and stop timers,
    to get how much time passed between the creation of a stopwatch and the
    cessation of it.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#stopwatch,
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.stopwatch;

version(WithStopwatchPlugin):

private:

import kameloso.plugins;
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
void onCommandStopwatch(StopwatchPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, stripped, strippedLeft;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [start|stop|status]";  // hide clear
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    void sendNoStopwatch()
    {
        enum message = "You do not have a stopwatch running.";
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchStopwatch(const string id)
    {
        enum pattern = "There is no such stopwatch running. (<h>%s<h>)";
        immutable message = pattern.format(id);
        chan(plugin.state, event.channel, message);
    }

    void sendCannotStopOthersStopwatches()
    {
        enum message = "You cannot end or stop someone else's stopwatch.";
        chan(plugin.state, event.channel, message);
    }

    void sendStoppedAfter(const string diff)
    {
        enum pattern = "Stopwatch stopped after <b>%s<b>.";
        immutable message = pattern.format(diff);
        chan(plugin.state, event.channel, message);
    }

    void sendElapsedTime(const string diff)
    {
        enum pattern = "Elapsed time: <b>%s<b>";
        immutable message = pattern.format(diff);
        chan(plugin.state, event.channel, message);
    }

    void sendMissingClearPermissions()
    {
        enum message = "You do not have permissions to clear all stopwatches.";
        chan(plugin.state, event.channel, message);
    }

    void sendClearingStopwatches(const string channelName)
    {
        enum pattern = "Clearing all stopwatches in channel <b>%s<b>.";
        immutable message = pattern.format(channelName);
        chan(plugin.state, event.channel, message);
    }

    void sendStartedOrRestarted(const bool restarted)
    {
        immutable message = "Stopwatch " ~ (restarted ? "restarted!" : "started!");
        chan(plugin.state, event.channel, message);
    }

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
        plugin.stopwatches[event.channel][event.sender.nickname] = Clock.currTime.toUnixTime;
        return sendStartedOrRestarted(stopwatchAlreadyExists);

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

            plugin.stopwatches[event.channel].remove(id);
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

        plugin.stopwatches.remove(event.channel);
        return sendClearingStopwatches(event.channel);

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

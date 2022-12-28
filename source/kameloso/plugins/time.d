/++
    A simple plugin for querying the time in different timezones.
 +/
module kameloso.plugins.time;

version(WithTimePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// TimeSettings
/++
    All [TimePlugin] runtime settings, aggregated in a struct.
 +/
@Settings struct TimeSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;
}


// onCommandTime
/++
    Reports the time in the specified timezone, in an override specified in the
    timezones definitions file, or in the one local to the bot.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("time")
            .policy(PrefixPolicy.prefixed)
            .description("Reports the time in a given timezone.")
            .addSyntax("$command [optional timezone]")
    )
)
void onCommandTime(TimePlugin plugin, const ref IRCEvent event)
{
    import lu.string : stripped;
    import std.datetime.systime : Clock;
    import std.datetime.timezone : LocalTime;
    import std.format : format;

    immutable specified = event.content.stripped;
    const overrideZone = event.channel in plugin.channelTimeZones;

    immutable timezone = specified.length ?
        getTimeZoneByName(specified, plugin.installedTimeZones) :
        overrideZone ?
            getTimeZoneByName(*overrideZone, plugin.installedTimeZones) :
            LocalTime();

    if (!timezone)
    {
        if (specified.length)
        {
            enum pattern = "Invalid timezone: <b>%s<b>";
            immutable message = pattern.format(specified);
            chan(plugin.state, event.channel, message);
        }
        else if (overrideZone)
        {
            enum pattern = `Internal error; possible malformed entry "<b>%s<b>" in timezones file.`;
            immutable message = pattern.format(*overrideZone);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum message = "Internal error.";
            chan(plugin.state, event.channel, message);
        }
        return;
    }

    immutable now = Clock.currTime(timezone);

    if (specified.length)
    {
        enum pattern = "The time is currently <b>%02d:%02d<b> in <b>%s<b>.";
        immutable message = pattern.format(now.hour, now.minute, specified);
        return chan(plugin.state, event.channel, message);
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            import kameloso.plugins.common.misc : nameOf;

            // No specific timezone specified; report the streamer's
            // (technically the bot's, unless an override was entered in the config file)
            enum pattern = "The time is currently %02d:%02d for %s.";
            immutable message = pattern.format(
                now.hour,
                now.minute,
                nameOf(plugin, event.channel[1..$]));
            return chan(plugin.state, event.channel, message);
        }
    }

    if (overrideZone)
    {
        enum pattern = "The time is currently <b>%02d:%02d<b> in <b>%s<b>.";
        immutable message = pattern.format(
            now.hour,
            now.minute,
            *overrideZone);
        chan(plugin.state, event.channel, message);
    }
    else
    {
        enum pattern = "The time is currently <b>%02d:%02d<b> locally.";
        immutable message = pattern.format(now.hour, now.minute);
        chan(plugin.state, event.channel, message);
    }
}


// getTimeZoneByName
/++
    Takes a string representation of a timezone (e.g. `Europe/Stockholm`) and
    returns a [std.datetime.timezone.TimeZone|TimeZone] that corresponds to it,
    if one was found.

    Params:
        specified = Timezone identification string.
        installedTimeZones = Array of available timezone (strings).

    Returns:
        A [std.datetime.timezone.TimeZone|TimeZone] that matches the passed
        `specified` identification string, or `null` if none was found.
 +/
auto getTimeZoneByName(
    const string specified,
    const string[] installedTimeZones)
in (specified.length, "Tried to get timezone of an empty string")
{
    import lu.string : contains;
    import std.algorithm.searching : canFind;
    import std.array : replace;
    import core.time : TimeException;

    static immutable string[6] prefixes =
    [
        "Europe/",
        "America/",
        "Asia/",
        "Africa/",
        "Australia/",
        "Pacific/",
    ];

    string resolvePrefixedTimeZone(const string zonestring)
    {
        if (zonestring.contains('/')) return string.init;

        foreach (immutable prefix; prefixes[])
        {
            immutable prefixed = prefix ~ zonestring;

            if (installedTimeZones.canFind(prefixed))
            {
                return prefixed;
            }
        }

        return string.init;
    }

    immutable withUnderscores = specified.replace(' ', '_');
    immutable zonestring = installedTimeZones.canFind(withUnderscores) ?
        withUnderscores :
        resolvePrefixedTimeZone(withUnderscores);

    try
    {
        version(Windows)
        {
            import std.datetime.timezone : WindowsTimeZone;
            return WindowsTimeZone.getTimeZone(zonestring);
        }
        else version(Posix)
        {
            import std.datetime.timezone : PosixTimeZone;
            return PosixTimeZone.getTimeZone(zonestring);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug");
        }
    }
    catch (TimeException e)
    {
        // core.time.TimeException@std/datetime/timezone.d(2096): /usr/share/zoneinfo is not a file.
        return null;
    }
}


// onCommandSetZone
/++
    Sets the timezone for a channel, to be used to properly pad the output of `!time`.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("setzone")
            .policy(PrefixPolicy.prefixed)
            .description("Sets the timezone to be used when querying the time in a channel.")
            .addSyntax("$command [timezone string]")
    )
)
void onCommandSetZone(TimePlugin plugin, const ref IRCEvent event)
{
    import lu.string : stripped;
    import std.format : format;
    import std.json : JSONValue;

    immutable specified = event.content.stripped;

    if (specified == "-")
    {
        plugin.channelTimeZones.remove(event.channel);
        saveResourceToDisk(plugin.channelTimeZones, plugin.timezonesFile);

        enum message = "Timezone cleared.";
        return chan(plugin.state, event.channel, message);
    }

    immutable timezone = getTimeZoneByName(specified, plugin.installedTimeZones);

    if (!timezone || !timezone.name.length)
    {
        enum pattern = "Invalid timezone: <b>%s<b>";
        immutable message = pattern.format(specified);
        return chan(plugin.state, event.channel, message);
    }

    plugin.channelTimeZones[event.channel] = timezone.name;
    saveResourceToDisk(plugin.channelTimeZones, plugin.timezonesFile);

    enum pattern = "Timezone changed to <b>%s<b>.";
    immutable message = pattern.format(timezone.name);
    chan(plugin.state, event.channel, message);
}


// saveResourceToDisk
/++
    Saves the timezone map to 0-11disk, but in JSON format.

    Params:
        aa = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const string[string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
}


// setup
/++
    Sets up the [TimePlugin].
 +/
void setup(TimePlugin plugin)
{
    version(Windows)
    {
        import std.datetime.timezone : WindowsTimeZone;
        plugin.installedTimeZones = WindowsTimeZone.getInstalledTZNames();
    }
    else version(Posix)
    {
        import std.datetime.timezone : PosixTimeZone;
        plugin.installedTimeZones = PosixTimeZone.getInstalledTZNames();
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug");
    }
}


// reload
/++
    Reloads the timezones map from disk.
 +/
void reload(TimePlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage channelTimeZonesJSON;
    channelTimeZonesJSON.load(plugin.timezonesFile);
    plugin.channelTimeZones.clear();
    plugin.channelTimeZones.populateFromJSON(channelTimeZonesJSON, Yes.lowercaseKeys);
}


// initResources
/++
    Reads and writes the file of timezones to disk, ensuring that they're there and
    properly formatted.
 +/
void initResources(TimePlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage timezonesJSON;

    try
    {
        timezonesJSON.load(plugin.timezonesFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Timezones file is malformed",
            plugin.name,
            plugin.timezonesFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    timezonesJSON.save(plugin.timezonesFile);
}


mixin UserAwareness;
mixin ModuleRegistration;

version(TwitchSupport)
{
    import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness;

    mixin ChannelAwareness;  // Only needed to get TwitchAwareness in
    mixin TwitchAwareness;
}

public:


// TimePlugin
/++
    The Time plugin replies to queries of what the time is in a given timezone.
 +/
final class TimePlugin : IRCPlugin
{
private:
    import lu.json : JSONStorage;

    // timeSettings
    /++
        All Time plugin settings gathered.
     +/
    TimeSettings timeSettings;

    // installedTimeZones
    /++
        Array of timezone identification strings, populated during plugin setup.
     +/
    string[] installedTimeZones;

    // channelTimeZones
    /++
        Channel timezone map.
     +/
    string[string] channelTimeZones;

    // timezonesFile
    /++
        Filename of file to which we should save timezone channel definitions.
     +/
    @Resource string timezonesFile = "timezones.json";

    mixin IRCPluginImpl;
}
/++
    A simple plugin for querying the time in different timezones.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#time,
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.time;

version(WithTimePlugin):

private:

import kameloso.plugins;
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
    /++
        Toggle whether or not this plugin should do anything at all.
     +/
    @Enabler bool enabled = true;

    /++
        Whether to use AM/PM notation instead of 24-hour time.
     +/
    bool amPM = false;
}


// zonestringAliases
/++
    Timezone string aliases.

    Module-level since we can't have static immutable associative arrays, and as
    such populated in a module constructor.

    The alternative is to put it in [TimePlugin] and have a modul-level `setup`
    that populates it, but since it never changes during the program's run time,
    it may as well be here.
 +/
immutable string[string] zonestringAliases;


// installedTimezones
/++
    String array of installed timezone names.

    The reasoning around [zonestringAliases] apply here as well.
 +/
immutable string[] installedTimezones;


// module ctor
/++
    Populates [zonestringAliases] and [installedTimezones].
 +/
shared static this()
{
    version(Posix)
    {
        import std.datetime.timezone : PosixTimeZone;

        installedTimezones = PosixTimeZone.getInstalledTZNames().idup;

        zonestringAliases =
        [
            "CST" : "US/Central",
            "EST" : "US/Eastern",
            "PST" : "US/Pacific",
            "Central" : "US/Central",
            "Eastern" : "US/Eastern",
            "Pacific" : "US/Pacific",
        ];
    }
    else version(Windows)
    {
        import std.datetime.timezone : WindowsTimeZone;

        installedTimezones = WindowsTimeZone.getInstalledTZNames().idup;

        /+
        Some excerpts:
        [
            "Central America Standard Time",
            "Central Asia Standard Time",
            "Central Europe Standard Time",
            "Central European Standard Time",
            "Central Pacific Standard Time",
            "Central Standard Time",
            "Central Standard Time (Mexico)",
            "E. Africa Standard Time",
            "E. Australia Standard Time",
            "E. Europe Standard Time",
            "E. South America Standard Time",
            "Eastern Standard Time",
            "Eastern Standard Time (Mexico)",
            "GMT Standard Time",
            "Greenwich Standard Time",
            "Middle East Standard Time",
            "Mountain Standard Time",
            "Mountain Standard Time (Mexico)",
            "North Asia East Standard Time",
            "North Asia Standard Time",
            "Pacific SA Standard Time",
            "Pacific Standard Time",
            "Pacific Standard Time (Mexico)",
            "SA Eastern Standard Time",
            "SA Pacific Standard Time",
            "SA Western Standard Time",
            "SE Asia Standard Time",
            "US Eastern Standard Time",
            "US Mountain Standard Time",
            "UTC",
            "UTC+12",
            "UTC+13",
            "UTC-02",
            "UTC-08",
            "UTC-09",
            "UTC-11",
            "W. Australia Standard Time",
            "W. Central Africa Standard Time",
            "W. Europe Standard Time",
            "W. Mongolia Standard Time",
            "West Asia Standard Time",
            "West Pacific Standard Time",
        ]
         +/

        zonestringAliases =
        [
            "CST" : "Central Standard Time",
            "EST" : "Eastern Standard Time",
            "PST" : "Pacific Standard Time",
            "CET" : "Central European Standard Time",
        ];
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }
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

    void sendInvalidTimezone(const string zonestring)
    {
        enum pattern = "Invalid timezone: <b>%s<b>";
        immutable message = pattern.format(zonestring);
        chan(plugin.state, event.channel, message);
    }

    void sendMalformedEntry(const string overrideString)
    {
        enum pattern = `Internal error; possible malformed entry "<b>%s<b>" in timezones file.`;
        immutable message = pattern.format(overrideString);
        chan(plugin.state, event.channel, message);
    }

    void sendInternalError()
    {
        enum message = "Internal error.";
        chan(plugin.state, event.channel, message);
    }

    void sendTimestampInZone(const string timestamp, const string specified)
    {
        enum pattern = "The time is currently <b>%s<b> in <b>%s<b>.";
        immutable message = pattern.format(timestamp, specified);
        chan(plugin.state, event.channel, message);
    }

    void sendTimestampLocal(const string timestamp)
    {
        enum pattern = "The time is currently <b>%s<b> locally.";
        immutable message = pattern.format(timestamp);
        chan(plugin.state, event.channel, message);
    }

    version(TwitchSupport)
    void sendTimestampTwitch(const string timestamp)
    {
        import kameloso.plugins.common.misc : nameOf;

        // No specific timezone specified; report the streamer's
        // (technically the bot's, unless an override was entered in the config file)
        enum pattern = "The time is currently %s for %s.";
        immutable name = (plugin.state.client.nickname == event.channel[1..$]) ?
            "me" :
            nameOf(plugin, event.channel[1..$]);
        immutable message = pattern.format(timestamp, name);
        chan(plugin.state, event.channel, message);
    }

    string getTimestamp(/*const*/ ubyte hour, const ubyte minute)
    {
        import std.format : format;

        if (plugin.timeSettings.amPM)
        {
            immutable amPM = (hour < 12) ? "AM" : "PM";
            hour %= 12;
            if (hour == 0) hour = 12;

            enum pattern = "%d:%02d %s";
            return pattern.format(hour, minute, amPM);
        }
        else
        {
            enum pattern = "%02d:%02d";
            return pattern.format(hour, minute);
        }
    }

    immutable specified = event.content.stripped;
    const overrideZone = event.channel in plugin.channelTimezones;

    immutable timezone = specified.length ?
        getTimezoneByName(specified) :
        overrideZone ?
            getTimezoneByName(*overrideZone) :
            LocalTime();

    if (!timezone)
    {
        return specified.length ?
            sendInvalidTimezone(specified) :
            overrideZone ?
                sendMalformedEntry(*overrideZone) :
                sendInternalError();
    }

    immutable now = Clock.currTime(timezone);
    immutable timestamp = getTimestamp(now.hour, now.minute);

    if (specified.length)
    {
        return sendTimestampInZone(timestamp, specified);
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            return sendTimestampTwitch(timestamp);
        }
    }

    return overrideZone ?
        sendTimestampInZone(timestamp, *overrideZone) :
        sendTimestampLocal(timestamp);
}


// getTimezoneByName
/++
    Takes a string representation of a timezone (e.g. `Europe/Stockholm`) and
    returns a [std.datetime.timezone.TimeZone|TimeZone] that corresponds to it,
    if one was found.

    Params:
        specified = Timezone identification string.

    Returns:
        A [std.datetime.timezone.TimeZone|TimeZone] that matches the passed
        `specified` identification string, or `null` if none was found.
 +/
auto getTimezoneByName(const string specified)
in (specified.length, "Tried to get timezone of an empty string")
{
    import core.time : TimeException;

    string getZonestring()
    {
        import lu.string : contains;
        import std.algorithm.searching : canFind;

        if (immutable zonestringAlias = specified in zonestringAliases)
        {
            return *zonestringAlias;
        }

        version(Posix)
        {
            import std.array : replace;

            string resolvePrefixedTimezone(const string zonestring)
            {
                if (zonestring.contains('/')) return string.init;

                static immutable string[7] prefixes =
                [
                    "Europe/",
                    "America/",
                    "Asia/",
                    "Africa/",
                    "Australia/",
                    "Pacific/",
                    "Etc/",
                ];

                foreach (immutable prefix; prefixes[])
                {
                    immutable prefixed = prefix ~ zonestring;
                    if (installedTimezones.canFind(prefixed)) return prefixed;
                }

                return string.init;
            }

            immutable withUnderscores = specified.replace(' ', '_');
            return installedTimezones.canFind(withUnderscores) ?
                withUnderscores :
                resolvePrefixedTimezone(withUnderscores);
        }
        else version(Windows)
        {
            string resolveStandardTimezone(const string zonestring)
            {
                import std.algorithm.searching : endsWith;

                if (zonestring.endsWith("Standard Time")) return string.init;

                immutable withStandardTime = zonestring ~ " Standard Time";
                return installedTimezones.canFind(withStandardTime) ?
                    withStandardTime :
                    string.init;
            }

            return installedTimezones.canFind(specified) ?
                specified :
                resolveStandardTimezone(specified);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }
    }

    try
    {
        version(Windows)
        {
            import std.datetime.timezone : TZ = WindowsTimeZone;
        }
        else version(Posix)
        {
            import std.datetime.timezone : TZ = PosixTimeZone;
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        return TZ.getTimeZone(getZonestring());
    }
    catch (TimeException _)
    {
        // core.time.TimeException@std/datetime/timezone.d(2096): /usr/share/zoneinfo is not a file.
        // On invalid timezone string
        return null;
    }
}

///
unittest
{
    import std.exception : assertThrown;
    import core.time : TimeException;

    // core.time.TimeException@std/datetime/timezone.d(2096): /usr/share/zoneinfo is not a file.
    // As above

    void assertMatches(const string specified, const string expected)
    {
        version(Posix)
        {
            import std.datetime.timezone : TZ = PosixTimeZone;
        }
        else version(Windows)
        {
            import std.datetime.timezone : TZ = WindowsTimeZone;
        }

        immutable actual = getTimezoneByName(specified);
        immutable result = TZ.getTimeZone(expected);
        assert((actual.name == result.name), result.name);
    }

    version(Posix)
    {
        assertMatches("Stockholm", "Europe/Stockholm");
        assertMatches("CET", "CET");
        assertMatches("Tokyo", "Asia/Tokyo");
        assertThrown!TimeException(assertMatches("Nangijala", string.init));
    }
    else version(Windows)
    {
        assertMatches("CET", "Central European Standard Time");
        assertMatches("Central", "Central Standard Time");
        assertMatches("Tokyo", "Tokyo Standard Time");
        assertMatches("UTC", "UTC");
        assertThrown!TimeException(assertMatches("Nangijala", string.init));
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
        plugin.channelTimezones.remove(event.channel);
        saveResourceToDisk(plugin.channelTimezones, plugin.timezonesFile);

        enum message = "Timezone cleared.";
        return chan(plugin.state, event.channel, message);
    }

    immutable timezone = getTimezoneByName(specified);

    if (!timezone || !timezone.name.length)
    {
        enum pattern = "Invalid timezone: <b>%s<b>";
        immutable message = pattern.format(specified);
        return chan(plugin.state, event.channel, message);
    }

    plugin.channelTimezones[event.channel] = timezone.name;
    saveResourceToDisk(plugin.channelTimezones, plugin.timezonesFile);

    enum pattern = "Timezone changed to <b>%s<b>.";
    immutable message = pattern.format(timezone.name);
    chan(plugin.state, event.channel, message);
}


// saveResourceToDisk
/++
    Saves the timezone map to disk in JSON format.

    Params:
        aa = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const string[string] aa, const string filename)
in (filename.length, "Tried to save resources to an empty filename string")
{
    import std.json : JSONValue;
    import std.stdio : File;

    File(filename, "w").writeln(JSONValue(aa).toPrettyString);
}


// reload
/++
    Reloads the timezones map from disk.
 +/
void reload(TimePlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage channelTimezonesJSON;
    channelTimezonesJSON.load(plugin.timezonesFile);
    plugin.channelTimezones.clear();
    plugin.channelTimezones.populateFromJSON(channelTimezonesJSON, Yes.lowercaseKeys);
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
mixin PluginRegistration!TimePlugin;

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

    // channelTimezones
    /++
        Channel timezone map.
     +/
    string[string] channelTimezones;

    // timezonesFile
    /++
        Filename of file to which we should save timezone channel definitions.
     +/
    @Resource string timezonesFile = "timezones.json";

    mixin IRCPluginImpl;
}

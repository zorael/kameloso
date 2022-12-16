/++
    A simple plugin for querying the time in different timezones.

    Limitations: Currently only supports a single local time zone override.
 +/
module kameloso.plugins.time;

version(WithTimePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.datetime.timezone : TimeZone;


// TimeSettings
/++
    All [TimePlugin] runtime settings, aggregated in a struct.
 +/
@Settings struct TimeSettings
{
    /// Toggle whether or not this plugin should do anything at all.
    @Enabler bool enabled = true;

    /// Name of timezone to use for local time; e.g. "Europe/Stockholm".
    string localTimeZoneOverride;
}


// onCommandTime
/++
    Reports the time in the specified timezone, in the override specified in the
    configuration file, or in the one local to the bot.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("time")
            .policy(PrefixPolicy.prefixed)
            .description("Reports the time in a given time zone, or the one local to the bot.")
            .addSyntax("$command [optional timezone]")
    )
)
void onCommandTime(TimePlugin plugin, const ref IRCEvent event)
{
    import std.datetime.systime : Clock;
    import std.format : format;

    immutable timeZone = event.content.length ?
        getTimeZoneByName(event.content, plugin.installedTimeZones) :
        cast(immutable)plugin.localTimeZone;

    if (!timeZone)
    {
        enum pattern = "Invalid time zone: <b>%s<b>";
        immutable message = pattern.format(event.content);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    immutable now = Clock.currTime(timeZone);

    if (timeZone.name.length)
    {
        // Not LocalTime, whose .name property is always null
        enum pattern = "Current time in <b>%s<b>: <b>%02d:%02d<b>";
        immutable message = pattern.format(event.content, now.hour, now.minute);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    version(TwitchSupport)
    {
        if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) && event.channel.length)
        {
            import kameloso.plugins.common.misc : nameOf;

            // No specific time zone specified; report the streamer's
            // (technically the bot's, unless an override was entered in the config file)
            enum pattern = "Current time for %s: %02d:%02d";
            immutable message = pattern.format(
                nameOf(plugin, event.channel[1..$]),
                now.hour,
                now.minute);
            return privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }

    if (plugin.timeSettings.localTimeZoneOverride.length)
    {
        enum pattern = "Current time in <b>%s<b>: <b>%02d:%02d<b>";
        immutable message = pattern.format(
            plugin.timeSettings.localTimeZoneOverride,
            now.hour,
            now.minute);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
    else
    {
        enum pattern = "Current time locally: <b>%02d:%02d<b>";
        immutable message = pattern.format(now.hour, now.minute);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// getTimeZoneByName
/++
    Takes a string representation of a time zone (e.g. `Europe/Stockholm`) and
    returns a [std.datetime.timezone.TimeZone|TimeZone] that corresponds to it,
    if one was found.

    Params:
        specified = Time zone identification string.
        installedTimeZones = Array of available time zone (strings).

    Returns:
        A [std.datetime.timezone.TimeZone|TimeZone] that matches the passed
        `specified` identification string, or `null` if none was found.
 +/
auto getTimeZoneByName(
    const string specified,
    const string[] installedTimeZones)
in (specified.length, "Tried to get time zone of an empty string")
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

    if (plugin.timeSettings.localTimeZoneOverride.length)
    {
        plugin.privateLocalTimeZone = cast()getTimeZoneByName(
            plugin.timeSettings.localTimeZoneOverride,
            plugin.installedTimeZones);

        if (!plugin.localTimeZone)
        {
            import kameloso.plugins.common.misc : IRCPluginInitialisationException;
            import std.format : format;

            enum pattern = "Invalid time zone override in configuration file; " ~
                `"%s" is not a valid identifier on this platform.`;
            immutable message = pattern.format(plugin.timeSettings.localTimeZoneOverride);

            throw new IRCPluginInitialisationException(
                message,
                plugin.name,
                string.init,
                __FILE__,
                __LINE__);
        }

        if (plugin.localTimeZone.name != plugin.timeSettings.localTimeZoneOverride)
        {
            plugin.timeSettings.localTimeZoneOverride = plugin.localTimeZone.name;
        }
    }
    else
    {
        import std.datetime.timezone : LocalTime;
        plugin.privateLocalTimeZone = cast()LocalTime();
    }
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
    // timeSettings
    /++
        All Time plugin settings gathered.
     +/
    TimeSettings timeSettings;

    // privateLocalTimeZone
    /++
        Private reference to a technically immutable
        [std.datetime.timezone.TimeZone|TimeZone], potentially one to the
        [std.datetime.timezone.LocalTime|LocalTime] singleton.

        We have to cast away the immutability to be able to set this member
        outside of a class constructor. Care has to be taken to only use
        [localTimeZone] to access it, so we don't violate the immutability.
     +/
    private TimeZone privateLocalTimeZone;

    // localTimeZone
    /++
        Accessor providing an immutable reference to [privateLocalTimeZone].

        It should only be accessed via this, so as not to violate immutability
        more than is absolutely necessary.
     +/
    auto localTimeZone() const @property
    {
        return cast(immutable)privateLocalTimeZone;
    }

    // installedTimeZones
    /++
        Array of time zone identification strings, populated during plugin setup.
     +/
    string[] installedTimeZones;


    mixin IRCPluginImpl;
}

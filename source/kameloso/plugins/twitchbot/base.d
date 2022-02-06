
module kameloso.plugins.twitchbot.base;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.api;
import kameloso.plugins.twitchbot.timers;

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.constants : BufferSize;
import kameloso.messaging;
import dialect.defs;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

@Settings struct TwitchBotSettings
{
private:
    import lu.uda : Unserialisable;

public:
    @Enabler bool enabled = true;
    bool bellOnMessage = false;
    bool bellOnImportant = false;
    bool promoteBroadcasters = true;
    bool promoteModerators = true;
    bool promoteVIPs = true;

    version(Windows)
    {
        bool singleWorkerThread = true;
    }
    else
    {
        bool singleWorkerThread = false;
    }

    @Unserialisable bool keygen = false;
}

void onImportant(TwitchBotPlugin plugin) {}

void onAutomaticStop(TwitchBotPlugin plugin, const ref IRCEvent event) {}

void reportStreamTime(TwitchBotPlugin plugin,
    const TwitchBotPlugin.Room room,
    const Flag!"justNowEnded" justNowEnded = No.justNowEnded)
{
    import kameloso.common : timeSince;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import core.time : msecs;

    version(TwitchAPIFeatures)
    {
        immutable streamer = room.broadcasterDisplayName;
    }
    else
    {
        import kameloso.plugins.common.misc : nameOf;
        immutable streamer = plugin.nameOf(room.name[1..$]);
    }

    if (room.broadcast.active)
    {
        assert(!justNowEnded, "Tried to report ended stream time on an active stream");

        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable delta = now - SysTime.fromUnixTime(room.broadcast.startTime);
        immutable timestring = timeSince(delta);
        bool sent;

        version(TwitchAPIFeatures)
        {
            if (room.broadcast.chattersSeen.length)
            {
                enum pattern = "%s has been live for %s, so far with %d unique viewers. " ~
                    "(max at any one time has so far been %d viewers)";

                chan(plugin.state, room.name, pattern.format(streamer, timestring,
                    room.broadcast.chattersSeen.length,
                    room.broadcast.maxConcurrentChatters));
                sent = true;
            }
        }

        if (!sent)
        {
            chan(plugin.state, room.name, "%s has been live for %s."
                .format(streamer, timestring));
        }
    }
    else
    {
        if (room.broadcast.stopTime)
        {
            auto end = SysTime.fromUnixTime(room.broadcast.stopTime);
            end.fracSecs = 0.msecs;
            immutable delta = end - SysTime.fromUnixTime(room.broadcast.startTime);
            immutable timestring = timeSince(delta);

            if (justNowEnded)
            {
                bool sent;

                version(TwitchAPIFeatures)
                {
                    if (room.broadcast.numViewersLastStream)
                    {
                        enum pattern = "%s streamed for %s, with %d unique viewers. " ~
                            "(max at any one time was %d viewers)";

                        chan(plugin.state, room.name, pattern.format(streamer, timestring,
                            room.broadcast.numViewersLastStream,
                            room.broadcast.maxConcurrentChatters));
                        sent = true;
                    }
                }

                if (!sent)
                {
                    enum pattern = "%s streamed for %s.";
                    chan(plugin.state, room.name, pattern.format(streamer, timestring));
                }
            }
            else
            {
                enum pattern = "%s is currently not streaming. " ~
                    "Previous session ended %d-%02d-%02d %02d:%02d with an uptime of %s.";

                chan(plugin.state, room.name, pattern.format(streamer,
                    end.year, end.month, end.day, end.hour, end.minute, timestring));
            }
        }
        else
        {
            assert(!justNowEnded, "Tried to report stream time of a just ended stream " ~
                "but no stop time had been recorded");

            chan(plugin.state, room.name, streamer ~ " is currently not streaming.");
        }
    }
}

void onEndOfMOTD(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    plugin.populateTimers(plugin.timersFile);

    version(TwitchAPIFeatures)
    {
        import lu.string : beginsWith;
        import std.concurrency : Tid;

        if (!plugin.useAPIFeatures) return;

        immutable pass = plugin.state.bot.pass.beginsWith("oauth:") ?
            plugin.state.bot.pass[6..$] :
            plugin.state.bot.pass;
        plugin.authorizationBearer = "Bearer " ~ pass;

        if (plugin.bucket is null)
        {
            plugin.bucket[string.init] = QueryResponse.init;
            plugin.bucket.remove(string.init);
        }

        if (plugin.twitchBotSettings.singleWorkerThread)
        {
            import std.concurrency : spawn;

            assert((plugin.persistentWorkerTid == Tid.init),
                "Double-spawn of Twitch single worker thread");

            plugin.persistentWorkerTid = spawn(&persistentQuerier,
                plugin.bucket, plugin.queryResponseTimeout,
                plugin.state.connSettings.caBundleFile);
        }

        void validationDg()
        {
            import kameloso.common : Tint;
            import std.conv : to;
            import std.datetime.systime : Clock, SysTime;
            import core.time : weeks;

            try
            {
                immutable validationJSON = getValidation(plugin);
                plugin.userID = validationJSON["user_id"].str;
                immutable expiresIn = validationJSON["expires_in"].integer;

                if (expiresIn == 0L)
                {
                    import kameloso.messaging : quit;
                    import std.typecons : Flag, No, Yes;

                    logger.error("Error: Your Twitch authorisation key has expired.");
                    quit!(Yes.priority)(plugin.state, string.init, Yes.quiet);
                }
                else
                {
                    immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
                    immutable now = Clock.currTime;

                    if ((expiresWhen - now) > 1.weeks)
                    {
                        enum pattern = "Your Twitch authorisation key will expire on " ~
                            "%s%02d-%02d-%02d%s.";
                        logger.infof!pattern( Tint.log, expiresWhen.year,
                            expiresWhen.month, expiresWhen.day, Tint.info);
                    }
                    else
                    {
                        enum pattern = "Warning: Your Twitch authorisation key will expire " ~
                            "%s%02d-%02d-%02d %02d:%02d%s.";
                        logger.warningf!pattern( Tint.log, expiresWhen.year,
                            expiresWhen.month, expiresWhen.day, expiresWhen.hour,
                            expiresWhen.minute, Tint.warning);
                    }
                }
            }
            catch (TwitchQueryException e)
            {
                import kameloso.common : curlErrorStrings;
                import etc.c.curl : CurlError;

                logger.errorf("Failed to validate Twitch API keys: %s (%s%s%s) (%2$s%5$s%4$s)",
                    e.msg, Tint.log, e.error, Tint.error, curlErrorStrings[e.errorCode]);

                if (e.errorCode == CurlError.ssl_cacert)
                {
                    logger.errorf("You may need to supply a CA bundle file " ~
                        "(e.g. %scacert.pem%s) in the configuration file.",
                        Tint.log, Tint.error);
                }

                logger.error("Disabling API features.");
                version(PrintStacktraces) logger.trace(e);
                plugin.useAPIFeatures = false;
            }
        }

        Fiber validationFiber = new Fiber(&validationDg, BufferSize.fiberStack);
        validationFiber.call();
    }
}

void onCAP(TwitchBotPlugin plugin) {}

void teardown(TwitchBotPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : Tid, send;

    if (plugin.twitchBotSettings.singleWorkerThread &&
        (plugin.persistentWorkerTid != Tid.init))
    {
        plugin.persistentWorkerTid.send(ThreadMessage.Teardown());
    }
}

void postprocess(TwitchBotPlugin plugin, ref IRCEvent event) {}

mixin TwitchAwareness;

public:

final class TwitchBotPlugin : IRCPlugin
{
private:
    import kameloso.terminal : TerminalToken;
    import core.time : seconds;

package:
    static struct Room
    {
        static struct Broadcast
        {
            bool active;
            long startTime;
            long stopTime;

            version(TwitchAPIFeatures)
            {
                bool[string] chattersSeen;
                int maxConcurrentChatters;
                size_t numViewersLastStream;
            }
        }

        this(const string name) @safe pure nothrow @nogc
        {
            this.name = name;
        }

        string name;
        Broadcast broadcast;
        int voteInstance;
        ulong messageCount;
        Fiber[] timers;

        version(TwitchAPIFeatures)
        {
            string broadcasterDisplayName;
            string id;
            JSONValue[string] follows;
        }
    }

    TwitchBotSettings twitchBotSettings;
    Room[string] rooms;
    TimerDefinition[][string] timerDefsByChannel;
    @Resource string timersFile = "twitchtimers.json";
    static immutable timerPeriodicity = 5.seconds;
    private enum bellString = ("" ~ cast(char)(TerminalToken.bell));
    string bell = bellString;

    version(TwitchAPIFeatures)
    {
        import std.concurrency : Tid;

        enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";
        string authorizationBearer;
        bool useAPIFeatures = true;
        string userID;
        long approximateQueryTime = 700;
        enum approximateQueryGrowthMultiplier = 1.1;
        enum approximateQueryRetryTimeDivisor = 3;
        enum approximateQueryMeasurementPadding = 30;
        enum approximateQueryAveragingWeight = 3;
        enum queryResponseTimeout = 15;
        enum queryBufferSize = 4096;
        static immutable chattersCheckPeriodicity = 180.seconds;
        Tid persistentWorkerTid;
        shared QueryResponse[string] bucket;
    }

    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return true;
    }

    mixin IRCPluginImpl;
}

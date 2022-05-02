/++
    This is an example Twitch streamer bot. It supports querying uptime or how
    long a streamer has been live, follower age queries, etc. It can also emit
    some terminal bells on certain events, to draw attention.

    One immediately obvious venue of expansion is expression bans, such as if a
    message has too many capital letters, etc. There is no protection from spam yet.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitchbot
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.twitchbot.base;

version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.twitchbot.api;

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : expandTags, logger;
import kameloso.constants : BufferSize;
import kameloso.logger : LogLevel;
import kameloso.messaging;
import dialect.defs;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


/// All Twitch bot plugin runtime settings.
@Settings struct TwitchBotSettings
{
private:
    import lu.uda : Unserialisable;

public:
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /++
        Whether or not to count emotes in chat, to be able to respond to `!ecount`
        queries about how many times a specific one has been seen.
     +/
    bool ecount = true;

    /++
        Whether or not to count the time people spend watching streams, to be
        able to respond to `!watchtime`.
     +/
    bool watchtime = true;

    /++
        Whether or not broadcasters are always implicitly class
        [dialect.defs.IRCUser.Class.staff|IRCUser.Class.staff].
     +/
    bool promoteBroadcasters = true;

    /++
        Whether or not moderators are always implicitly (at least) class
        [dialect.defs.IRCUser.Class.operator|IRCUser.Class.operator].
     +/
    bool promoteModerators = true;

    /++
        Whether or not VIPs are always implicitly (at least) class
        [dialect.defs.IRCUser.Class.whitelist|IRCUser.Class.whitelist].
     +/
    bool promoteVIPs = true;

    /++
        Whether to use one persistent worker for Twitch queries or to use separate subthreads.

        It's a trade-off. A single worker thread obviously spawns fewer threads,
        which makes it a better choice on Windows systems where creating such is
        comparatively expensive. You also get to enjoy being able to reuse the
        HTTP client. On the other hand, it's also slower (likely due to
        concurrency message passing overhead).
     +/
    bool singleWorkerThread = true;

    @Unserialisable
    {
        /// Whether or not to bell on every message.
        bool bellOnMessage = false;

        /// Whether or not to bell on important events, like subscriptions.
        bool bellOnImportant = false;

        /++
            Whether or not to start a captive session for generating a Twitch
            authorisation key. Should not be permanently set in the configuration file!
         +/
        bool keygen = false;
    }
}


// onImportant
/++
    Bells on any important event, like subscriptions, cheers and raids, if the
    [TwitchBotSettings.bellOnImportant] setting is set.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
    .onEvent(IRCEvent.Type.TWITCH_CHEER)
    .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
    .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
    .onEvent(IRCEvent.Type.TWITCH_BULKGIFT)
    .onEvent(IRCEvent.Type.TWITCH_SUBUPGRADE)
    .onEvent(IRCEvent.Type.TWITCH_CHARITY)
    .onEvent(IRCEvent.Type.TWITCH_BITSBADGETIER)
    .onEvent(IRCEvent.Type.TWITCH_RITUAL)
    .onEvent(IRCEvent.Type.TWITCH_EXTENDSUB)
    .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
    .onEvent(IRCEvent.Type.TWITCH_RAID)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onImportant(TwitchBotPlugin plugin)
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    if (!plugin.twitchBotSettings.bellOnImportant) return;

    write(plugin.bell);
    stdout.flush();
}


// onSelfjoin
/++
    Registers a new [TwitchBotPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Simply passes on execution to [handleSelfjoin].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    return plugin.handleSelfjoin(event.channel);
}


// handleSelfjoin
/++
    Registers a new [TwitchBotPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Params:
        plugin = The current [TwitchBotPlugin].
        channelName = The name of the channel we're supposedly joining.
 +/
void handleSelfjoin(TwitchBotPlugin plugin, const string channelName)
in (channelName.length, "Tried to handle SELFJOIN with an empty channel string")
{
    if (channelName in plugin.rooms) return;

    plugin.rooms[channelName] = TwitchBotPlugin.Room(channelName);
}


// onUserstate
/++
    Warns if we're not a moderator when we join a home channel.

    "You will not get USERSTATE for other people. Only for yourself."
    https://discuss.dev.twitch.tv/t/no-userstate-on-people-joining/11598
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.USERSTATE)
    .channelPolicy(ChannelPolicy.home)
)
void onUserstate(const ref IRCEvent event)
{
    import lu.string : contains;

    if (!event.target.badges.contains("moderator/") &&
        !event.target.badges.contains("broadcaster/"))
    {
        enum pattern = "The bot is not a moderator of home channel <l>%s</>. " ~
            "Consider elevating it to such to avoid being as rate-limited.";
        logger.warningf(pattern.expandTags(LogLevel.warning), event.channel);
    }
}


// onSelfpart
/++
    Removes a channel's corresponding [TwitchBotPlugin.Room] when we leave it.

    This resets all that channel's transient state.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFPART)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfpart(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    if (auto room = event.channel in plugin.rooms)
    {
        room.broadcast.active = false;  // In case there is a periodicalChattersDg running
        plugin.rooms.remove(event.channel);
    }
}


// onCommandUptime
/++
    Reports how long the streamer has been streaming.

    Technically, how much time has passed since `!start` was issued.

    The streamer's name is divined from the `plugin.state.users` associative
    array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("uptime")
            .policy(PrefixPolicy.prefixed)
            .description("Reports how long the streamer has been streaming.")
    )
)
void onCommandUptime(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    const room = event.channel in plugin.rooms;
    assert(room, "Tried to process `onCommandUptime` on a nonexistent room");

    reportStreamTime(plugin, *room);
}


// onCommandStart
/++
    Marks the start of a broadcast, for later uptime queries.

    Consecutive calls to `!start` are ignored.

    The streamer's name is divined from the `plugin.state.users` associative
    array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("start")
            .policy(PrefixPolicy.prefixed)
            .description("Marks the start of a broadcast.")
            .addSyntax("$command [optional HH:MM or MM time already elapsed]")
    )
)
void onCommandStart(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.format : format;
    import core.thread : Fiber;

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to start a broadcast on a nonexistent room");

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [optional HH:MM or MM time already elapsed]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void initBroadcast()
    {
        room.broadcast = typeof(room.broadcast).init;
        room.broadcast.active = true;
    }

    if (event.content.length)
    {
        import lu.string : contains, nom, stripped;
        import std.conv : ConvException, to;

        /+
            A time was given. Allow it to override any existing broadcasts.
         +/
        try
        {
            string slice = event.content.stripped;  // mutable

            if (event.content.contains(':'))
            {
                immutable hours = slice.nom(':').to!int;
                immutable minutes = slice.to!int;
                if ((hours < 0) || (minutes < 0) || (minutes > 59)) return sendUsage();
                immutable elapsed = (hours * 3600) + (minutes * 60);

                initBroadcast();
                room.broadcast.startTime = (event.time - elapsed);

                enum pattern = "Broadcast start registered (as %d:%02d ago)!";
                immutable message = pattern.format(hours, minutes);
                chan(plugin.state, event.channel, message);
            }
            else
            {
                immutable minutes = slice.to!int;
                if (minutes < 0) return sendUsage();
                immutable elapsed = (minutes * 60);

                initBroadcast();
                room.broadcast.startTime = (event.time - elapsed);

                /+
                    Technically we should do `minutes.plurality("minute", "minutes")`
                    but the chance of minutes being 1 is very slim.
                 +/
                enum pattern = "Broadcast start registered (as %d minutes ago)!";
                immutable message = pattern.format(minutes);
                chan(plugin.state, event.channel, message);
            }
        }
        catch (ConvException e)
        {
            return sendUsage();
        }
    }
    else
    {
        /+
            No specific time was given. Refuse if there's already a broadcast active.
         +/
        if (room.broadcast.active)
        {
            chan(plugin.state, event.channel,
                room.broadcasterDisplayName ~ " is already live.");
            return;
        }

        initBroadcast();
        room.broadcast.startTime = event.time;
        chan(plugin.state, event.channel, "Broadcast start registered!");
    }

    void periodicalChattersCheckDg()
    {
        uint addedSinceLastRehash;

        while (room.broadcast.active)
        {
            import kameloso.plugins.common.delayawait : delay;
            import std.json : JSONType;

            immutable chattersJSON = getChatters(plugin, room.broadcasterName);
            if (chattersJSON.type != JSONType.object) return;

            // https://twitchinsights.net/bots
            // https://twitchbots.info/bots
            static immutable botBlacklist =
            [
                //"nightbot",
                "streamlabs",
                "streamelements",
                "soundalerts",
                //"moobot",
                "anotherttvviewer",
                "kaxips06",
                "la_kaylee",
                "commanderroot",
                "rogueg1rl",
                "midsooooooooon",
                "lanarayyyy",
                "itzemmaaaaaaa",
                "aliengathering",
                "elysian",
                "lurxx",
                "feet",
                "aten",
                "spiketrapclair",
                "soundalerts",
                "ffxivstyx",
                "curvaceous_natalia",
                "viewer_of_irl",
                "frw33ds_kitten",
                "fashionable_camille",
                "lurking_miku",
                "stixffxiv",
                "eatsaoe",
                "wafflebudder",
                "elbretweets",
                "underworldnaiad",
                "beardedstrumerwaitingroom",
                "icantcontrolit",
                "nerdydreams",
                "uncle_spawn",
                "hades_osiris",
                "0ax2",
                "violets_tv",
                "dankingaround",
                "erika_fnbr",
                "comettunes",
            ];

            static immutable chatterTypes =
            [
                "admins",
                //"broadcaster",
                "global_mods",
                "moderators",
                "staff",
                "viewers",
                "vips",
            ];

            uint chatterCount;

            foreach (immutable chatterType; chatterTypes)
            {
                foreach (immutable viewerJSON; chattersJSON["chatters"][chatterType].array)
                {
                    import std.algorithm.searching : canFind, endsWith;

                    immutable viewer = viewerJSON.str;

                    if (viewer.endsWith("bot") ||
                        botBlacklist.canFind(viewer) ||
                        (viewer == plugin.state.client.nickname))
                    {
                        continue;
                    }

                    room.broadcast.chattersSeen[viewer] = true;
                    ++chatterCount;

                    static immutable periodicitySeconds = plugin.chattersCheckPeriodicity.total!"seconds";

                    if (auto channelViewerTimes = event.channel in plugin.viewerTimesByChannel)
                    {
                        if (auto viewerTime = viewer in *channelViewerTimes)
                        {
                            *viewerTime += periodicitySeconds;
                        }
                        else
                        {
                            (*channelViewerTimes)[viewer] = periodicitySeconds;
                            ++addedSinceLastRehash;

                            if ((addedSinceLastRehash > 128) &&
                                (addedSinceLastRehash > channelViewerTimes.length))
                            {
                                // channel-viewer times AA doubled in size; rehash
                                *channelViewerTimes = (*channelViewerTimes).rehash();
                                addedSinceLastRehash = 0;
                            }
                        }
                    }
                    else
                    {
                        plugin.viewerTimesByChannel[event.channel][viewer] = periodicitySeconds;
                        ++addedSinceLastRehash;
                    }

                }
            }

            if (chatterCount > room.broadcast.maxConcurrentChatters)
            {
                room.broadcast.maxConcurrentChatters = chatterCount;
            }

            delay(plugin, plugin.chattersCheckPeriodicity, Yes.yield);
        }
    }

    Fiber chattersCheckFiber =
        new Fiber(&twitchTryCatchDg!periodicalChattersCheckDg, BufferSize.fiberStack);
    chattersCheckFiber.call();
}


// onCommandStop
/++
    Marks the stop of a broadcast.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("stop")
            .policy(PrefixPolicy.prefixed)
            .description("Marks the end of a broadcast.")
    )
)
void onCommandStop(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to stop a broadcast on a nonexistent room");

    if (!room.broadcast.active)
    {
        if (event.type != IRCEvent.Type.TWITCH_HOSTSTART)
        {
            chan(plugin.state, event.channel, "Broadcast was never registered as started...");
        }
        return;
    }

    room.broadcast.active = false;
    room.broadcast.stopTime = event.time;
    room.broadcast.numViewersLastStream = room.broadcast.chattersSeen.length;
    room.broadcast.chattersSeen = null;

    chan(plugin.state, event.channel, "Broadcast ended!");
    reportStreamTime(plugin, *room, Yes.justNowEnded);

    if (plugin.viewerTimesByChannel.length)
    {
        saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
    }
}


// onAutomaticStop
/++
    Automatically signals a stream stop when a host starts.

    This is generally done as the last thing after a stream session, so it makes
    sense to automate [onCommandStop].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.TWITCH_HOSTSTART)
    .channelPolicy(ChannelPolicy.home)
)
void onAutomaticStop(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    return onCommandStop(plugin, event);
}


// reportStreamTime
/++
    Reports how long a broadcast has currently been ongoing, up until now lasted,
    or previously lasted.

    Params:
        plugin = The current [TwitchBotPlugin].
        room = The [TwitchBotPlugin.Room] of the channel.
        justNowEnded = Whether or not the stream ended just now.
 +/
void reportStreamTime(TwitchBotPlugin plugin,
    const TwitchBotPlugin.Room room,
    const Flag!"justNowEnded" justNowEnded = No.justNowEnded)
{
    import kameloso.common : timeSince;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import core.time : msecs;

    if (room.broadcast.active)
    {
        assert(!justNowEnded, "Tried to report ended stream time on an active stream");

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable delta = now - SysTime.fromUnixTime(room.broadcast.startTime);
        immutable timestring = timeSince(delta);

        if (room.broadcast.chattersSeen.length)
        {
            enum pattern = "%s has been live for %s, so far with %d unique viewers. " ~
                "(max at any one time has so far been %d viewers)";
            immutable message = pattern.format(room.broadcasterDisplayName, timestring,
                room.broadcast.chattersSeen.length,
                room.broadcast.maxConcurrentChatters);
            chan(plugin.state, room.channelName, message);
        }
        else
        {
            enum pattern = "%s has been live for %s.";
            immutable message = pattern.format(room.broadcasterDisplayName, timestring);
            chan(plugin.state, room.channelName, message);
        }
    }
    else
    {
        if (room.broadcast.stopTime)
        {
            // There was at least one stream this session (we have a stop timestamp)
            auto end = SysTime.fromUnixTime(room.broadcast.stopTime);
            end.fracSecs = 0.msecs;
            immutable delta = end - SysTime.fromUnixTime(room.broadcast.startTime);
            immutable timestring = timeSince(delta);

            if (justNowEnded)
            {
                if (room.broadcast.numViewersLastStream)
                {
                    enum pattern = "%s streamed for %s, with %d unique viewers. " ~
                        "(max at any one time was %d viewers)";
                    immutable message = pattern.format(room.broadcasterDisplayName, timestring,
                        room.broadcast.numViewersLastStream,
                        room.broadcast.maxConcurrentChatters);
                    chan(plugin.state, room.channelName, message);
                }
                else
                {
                    enum pattern = "%s streamed for %s.";
                    immutable message = pattern.format(room.broadcasterDisplayName, timestring);
                    chan(plugin.state, room.channelName, message);
                }
            }
            else
            {
                enum pattern = "%s is currently not streaming. " ~
                    "Previous session ended %d-%02d-%02d %02d:%02d with an uptime of %s.";
                immutable message = pattern.format(room.broadcasterDisplayName,
                    end.year, end.month, end.day, end.hour, end.minute, timestring);
                chan(plugin.state, room.channelName, message);
            }
        }
        else
        {
            assert(!justNowEnded, "Tried to report stream time of a just ended stream " ~
                "but no stop time had been recorded");

            // No streams this session
            chan(plugin.state, room.channelName,
                room.broadcasterDisplayName ~ " is currently not streaming.");
        }
    }
}


// onCommandFollowAge
/++
    Implements "Follow Age", or the ability to query the server how long you
    (or a specified user) have been a follower of the current channel.

    Lookups are done asynchronously in subthreads.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("followage")
            .policy(PrefixPolicy.prefixed)
            .description("Queries the server for how long you have been a follower " ~
                "of the current channel. Optionally takes a nickname parameter, " ~
                "to query for someone else.")
            .addSyntax("$command [optional nickname]")
    )
)
void onCommandFollowAge(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : beginsWith, nom, stripped;
    import std.conv : to;
    import std.json : JSONValue;
    import core.thread : Fiber;

    if (!plugin.useAPIFeatures) return;

    void followageDg()
    {
        string slice = event.content.stripped;  // mutable
        immutable nameSpecified = (slice.length > 0);

        string idString;
        string fromDisplayName;

        if (!nameSpecified)
        {
            // Assume the user is asking about itself
            idString = event.sender.id.to!string;
            fromDisplayName = event.sender.displayName;
        }
        else
        {
            string givenName = slice.nom!(Yes.inherit)(' ');  // mutable
            if (givenName.beginsWith('@')) givenName = givenName[1..$];

            if (const user = givenName in plugin.state.users)
            {
                // Stored user
                idString = user.id.to!string;
                fromDisplayName = user.displayName;
            }
            else
            {
                foreach (const user; plugin.state.users)
                {
                    if (user.displayName == givenName)
                    {
                        // Found user by displayName
                        idString = user.id.to!string;
                        fromDisplayName = user.displayName;
                        break;
                    }
                }

                if (!idString.length)
                {
                    import std.json : JSONType;

                    // None on record, look up
                    immutable userURL = "https://api.twitch.tv/helix/users?login=" ~ givenName;
                    immutable userJSON = getTwitchEntity(plugin, userURL);

                    if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
                    {
                        chan(plugin.state, event.channel, "No such user: " ~ givenName);
                        return;
                    }

                    idString = userJSON["id"].str;
                    fromDisplayName = userJSON["display_name"].str;
                }
            }
        }

        void reportFollowAge(const JSONValue followingUserJSON)
        {
            import kameloso.common : timeSince;
            import std.datetime.systime : Clock, SysTime;
            import std.format : format;

            static immutable string[12] months =
            [
                "January",
                "February",
                "March",
                "April",
                "May",
                "June",
                "July",
                "August",
                "September",
                "October",
                "November",
                "December",
            ];

            /*{
                "followed_at": "2019-09-13T13:07:43Z",
                "from_id": "20739840",
                "from_name": "mike_bison",
                "to_id": "22216721",
                "to_name": "Zorael"
            }*/

            enum datestampPattern = "%s %d";
            immutable when = SysTime.fromISOExtString(followingUserJSON["followed_at"].str);
            immutable diff = Clock.currTime - when;
            immutable timeline = diff.timeSince!(7, 3);
            immutable datestamp = datestampPattern.format(months[cast(int)when.month-1], when.year);

            if (nameSpecified)
            {
                enum pattern = "%s has been a follower for %s, since %s.";
                immutable message = pattern.format(fromDisplayName, timeline, datestamp);
                chan(plugin.state, event.channel, message);
            }
            else
            {
                enum pattern = "You have been a follower for %s, since %s.";
                immutable message = pattern.format(timeline, datestamp);
                chan(plugin.state, event.channel, message);
            }

        }

        assert(idString.length, "Empty idString despite lookup");

        // Identity ascertained; look up in cached list

        import std.json : JSONType;

        auto room = event.channel in plugin.rooms;
        assert(room, "Tried to look up follow age in a nonexistent room");

        if (!room.follows.length)
        {
            // Follows have not yet been cached!
            // This can technically happen, though practically the caching is
            // done immediately after joining so there should be no time for
            // !followage queries to sneak in.
            // Luckily we're inside a Fiber so we can cache it ourselves.
            room.follows = getFollows(plugin, room.id);
        }

        if (const thisFollow = idString in room.follows)
        {
            return reportFollowAge(*thisFollow);
        }

        // If we're here there were no matches.

        if (nameSpecified)
        {
            import std.format : format;

            enum pattern = "%s is currently not a follower.";
            immutable message = pattern.format(fromDisplayName);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum message = "You are currently not a follower.";
            chan(plugin.state, event.channel, message);
        }
    }

    Fiber followageFiber = new Fiber(&twitchTryCatchDg!followageDg, BufferSize.fiberStack);
    followageFiber.call();
}


// onRoomState
/++
    Records the room ID of a home channel, and queries the Twitch servers for
    the display name of its broadcaster.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.home)
)
void onRoomState(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    auto room = event.channel in plugin.rooms;

    if (!room)
    {
        // Race...
        plugin.handleSelfjoin(event.channel);
        room = event.channel in plugin.rooms;
    }

    room.id = event.aux;

    if (!plugin.useAPIFeatures) return;

    void getDisplayNameDg()
    {
        immutable userURL = "https://api.twitch.tv/helix/users?id=" ~ event.aux;
        immutable userJSON = getTwitchEntity(plugin, userURL);

        /*if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
        {
            chan(plugin.state, event.channel, "No such user: " ~ event.aux);
            return;
        }*/

        room.broadcasterDisplayName = userJSON["display_name"].str;
    }

    Fiber getDisplayNameFiber = new Fiber(&twitchTryCatchDg!getDisplayNameDg, BufferSize.fiberStack);
    getDisplayNameFiber.call();

    // Always cache as soon as possible, before we get any !followage requests
    void cacheFollowsDg()
    {
        room.follows = getFollows(plugin, room.id);
    }

    Fiber cacheFollowsFiber = new Fiber(&twitchTryCatchDg!cacheFollowsDg, BufferSize.fiberStack);
    cacheFollowsFiber.call();
}


// onCommandShoutout
/++
    Emits a shoutout to another streamer.

    Merely gives a link to their channel and echoes what game they last streamed.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("shoutout")
            .policy(PrefixPolicy.prefixed)
            .description("Emits a shoutout to another streamer.")
            .addSyntax("$command [name of streamer] [optional number of times to spam]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("so")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandShoutout(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.common.misc : idOf;
    import dialect.common : isValidNickname;
    import lu.string : SplitResults, beginsWith, splitInto, stripped;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [name of streamer] [optional number of times to spam]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    string target;
    string numTimesString;

    immutable results = slice.splitInto(target, numTimesString);
    if (target.beginsWith('@')) target = target[1..$];

    if (!target.length || (results == SplitResults.overrun))
    {
        return sendUsage();
    }

    // Limit number of times to spam to an outrageous 10
    enum numTimesCap = 10;
    uint numTimes = 1;

    if (numTimesString.length)
    {
        import std.conv : ConvException, to;

        try
        {
            import std.algorithm.comparison : min;
            numTimes = min(numTimesString.to!uint, numTimesCap);
        }
        catch (ConvException e)
        {
            return sendUsage();
        }
    }

    immutable nickname = idOf(plugin, target);

    if (!nickname.isValidNickname(plugin.state.server))
    {
        chan(plugin.state, event.channel, "Invalid streamer name.");
        return;
    }

    void shoutoutQueryDg()
    {
        immutable userURL = "https://api.twitch.tv/helix/users?login=" ~ nickname;
        immutable userJSON = getTwitchEntity(plugin, userURL);

        if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
        {
            chan(plugin.state, event.channel, "No such user: " ~ target);
            return;
        }

        immutable id = userJSON["id"].str;
        immutable login = userJSON["login"].str;
        immutable channelURL = "https://api.twitch.tv/helix/channels?broadcaster_id=" ~ id;
        immutable channelJSON = getTwitchEntity(plugin, channelURL);

        if ((channelJSON.type != JSONType.object) || ("broadcaster_name" !in channelJSON))
        {
            chan(plugin.state, event.channel, "Impossible error; user has no channel?");
            return;
        }

        immutable broadcasterDisplayName = channelJSON["broadcaster_name"].str;
        immutable gameName = channelJSON["game_name"].str;
        immutable lastSeenPlayingPattern = gameName.length ?
            " (last seen playing %s)" : "%s";
        immutable pattern = "Shoutout to %s! Visit them at https://twitch.tv/%s!" ~ lastSeenPlayingPattern;
        immutable message = pattern.format(broadcasterDisplayName, login, gameName);

        foreach (immutable i; 0..numTimes)
        {
            chan(plugin.state, event.channel, message);
        }
    }

    Fiber shoutoutFiber = new Fiber(&twitchTryCatchDg!shoutoutQueryDg, BufferSize.fiberStack);
    shoutoutFiber.call();
}


// onCommandVanish
/++
    Hides a user's messages (making them "disappear") by briefly timing them out.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("vanish")
            .policy(PrefixPolicy.prefixed)
            .description(`Hides a user's messages (making them "disappear") by briefly timing them out.`)
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("poof")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandVanish(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    immutable message = "/timeout " ~ event.sender.nickname ~ " 1";
    chan(plugin.state, event.channel, message);
}


// onCommandRepeat
/++
    Repeats a given message n number of times.

    Requires moderator privileges to work correctly.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("repeat")
            .policy(PrefixPolicy.prefixed)
            .description("Repeats a given message n number of times.")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("spam")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandRepeat(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom;
    import std.algorithm.searching : count;
    import std.algorithm.comparison : min;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [number of times] [text...]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length || !event.content.count(' ')) return sendUsage();

    string slice = event.content;  // mutable
    immutable numTimesString = slice.nom(' ');

    try
    {
        enum maxNumTimes = 10;
        immutable numTimes = min(numTimesString.to!int, maxNumTimes);

        if (numTimes < 1)
        {
            enum message = "Number of times must be greater than 0.";
            chan(plugin.state, event.channel, message);
            return;
        }

        foreach (immutable i; 0..numTimes)
        {
            chan(plugin.state, event.channel, slice);
        }
    }
    catch (ConvException e)
    {
        return sendUsage();
    }
}


// onAnyMessage
/++
    Bells on any message, if the [TwitchBotSettings.bellOnMessage] setting is set.

    Belling is useful with small audiences, so you don't miss messages.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .onEvent(IRCEvent.Type.EMOTE)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onAnyMessage(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    if (plugin.twitchBotSettings.bellOnMessage)
    {
        import kameloso.terminal : TerminalToken;
        import std.stdio : stdout, write;

        write(plugin.bell);
        stdout.flush();
    }

    // ecount!
    if (plugin.twitchBotSettings.ecount && event.emotes.length)
    {
        import lu.string : nom;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : count;
        import std.conv : to;

        foreach (immutable emotestring; event.emotes.splitter('/'))
        {
            auto channelcount = event.channel in plugin.ecount;

            if (!channelcount)
            {
                plugin.ecount[event.channel][string.init] = 0L;
                channelcount = event.channel in plugin.ecount;
                (*channelcount).remove(string.init);
            }

            string slice = emotestring;  // mutable
            immutable id = slice.nom(':');//.to!uint;
            auto thisEmoteCount = id in *channelcount;

            if (!thisEmoteCount)
            {
                (*channelcount)[id] = 0L;
                thisEmoteCount = id in *channelcount;
            }

            *thisEmoteCount += slice.count(',') + 1;
        }
    }
}


// onEndOfMOTD
/++
    Sets up various things after we have successfully
    logged onto the server.

    Has to be done at MOTD, as we only know whether we're on Twitch after
    [dialect.defs.IRCEvent.Type.RPL_MYINFO|RPL_MYINFO] or so.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMOTD(TwitchBotPlugin plugin)
{
    import lu.string : beginsWith;
    import std.concurrency : Tid;
    import std.typecons : Flag, No, Yes;

    if (plugin.useAPIFeatures)
    {
        // Concatenate the Bearer and OAuth headers once.
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
                plugin.bucket, plugin.state.connSettings.caBundleFile);
        }

        void validationDg()
        {
            import lu.string : plurality;
            import std.conv : to;
            import std.datetime.systime : Clock, SysTime;
            import core.time : days, hours, weeks;

            try
            {
                /*
                {
                    "client_id": "tjyryd2ojnqr8a51ml19kn1yi2n0v1",
                    "expires_in": 5036421,
                    "login": "zorael",
                    "scopes": [
                        "bits:read",
                        "channel:moderate",
                        "channel:read:subscriptions",
                        "channel_editor",
                        "chat:edit",
                        "chat:read",
                        "user:edit:broadcast",
                        "whispers:edit",
                        "whispers:read"
                    ],
                    "user_id": "22216721"
                }
                */

                immutable validationJSON = getValidation(plugin);
                plugin.userID = validationJSON["user_id"].str;
                immutable expiresIn = validationJSON["expires_in"].integer;

                /+
                    The below can probably never happen, as we never get to
                    connect if the key has expired.
                 +/
                /*if (expiresIn == 0L)
                {
                    import kameloso.messaging : quit;
                    import std.typecons : Flag, No, Yes;

                    // Expired.
                    logger.error("Error: Your Twitch authorisation key has expired.");
                    quit!(Yes.priority)(plugin.state, string.init, Yes.quiet);
                    return;
                }*/

                immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
                immutable now = Clock.currTime;
                immutable delta = (expiresWhen - now);
                immutable numDays = delta.total!"days";

                if (delta > 1.weeks)
                {
                    // More than a week away, just .info
                    enum pattern = "Your Twitch authorisation key will expire " ~
                        "in <l>%d days</> on <l>%4d-%02d-%02d</>.";
                    logger.infof(pattern.expandTags(LogLevel.info), numDays,
                        expiresWhen.year, expiresWhen.month, expiresWhen.day);
                }
                else if (delta > 1.days)
                {
                    // A week or less, more than a day; warning
                    enum pattern = "Warning: Your Twitch authorisation key will expire " ~
                        "in <l>%d %s</> on <l>%4d-%02d-%02d %02d:%02d</>.";
                    logger.warningf(pattern.expandTags(LogLevel.warning),
                        numDays, numDays.plurality("day", "days"),
                        expiresWhen.year, expiresWhen.month, expiresWhen.day,
                        expiresWhen.hour, expiresWhen.minute);
                }
                else
                {
                    // Less than a day; warning
                    immutable numHours = delta.total!"hours";
                    enum pattern = "WARNING: Your Twitch authorisation key will expire " ~
                        "in <l>%d %s</> at <l>%02d:%02d</>.";
                    logger.warningf(pattern.expandTags(LogLevel.warning),
                        numHours, numHours.plurality("hour", "hours"),
                        expiresWhen.hour, expiresWhen.minute);
                }
            }
            catch (TwitchQueryException e)
            {
                // Something is deeply wrong.

                if (e.code == 2)
                {
                    import kameloso.constants : MagicErrorStrings;

                    enum wikiPattern = cast(string)MagicErrorStrings.visitWikiOneliner;

                    if (e.error == MagicErrorStrings.sslLibraryNotFound)
                    {
                        enum pattern = "Failed to validate Twitch API keys: <l>%s</> " ~
                            "<t>(is OpenSSL installed?)";
                        logger.errorf(pattern.expandTags(LogLevel.error),
                            cast(string)MagicErrorStrings.sslLibraryNotFoundRewritten);
                        logger.error(wikiPattern.expandTags(LogLevel.error));

                        version(Windows)
                        {
                            enum getoptPattern = cast(string)MagicErrorStrings.getOpenSSLSuggestion;
                            logger.error(getoptPattern.expandTags(LogLevel.error));
                        }
                    }
                    else
                    {
                        enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) (<t>%d</>)";
                        logger.errorf(pattern.expandTags(LogLevel.error), e.msg, e.error, e.code);
                        logger.error(wikiPattern.expandTags(LogLevel.error));
                    }
                }
                else
                {
                    enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) (<t>%d</>)";
                    logger.errorf(pattern.expandTags(LogLevel.error), e.msg, e.error, e.code);
                }

                logger.warning("Disabling API features. Expect breakage.");
                //version(PrintStacktraces) logger.trace(e);
                plugin.useAPIFeatures = false;
            }
        }

        Fiber validationFiber = new Fiber(&validationDg, BufferSize.fiberStack);
        validationFiber.call();
    }
}


// onCommandEcount
/++
    `!ecount`; reporting how many times a Twitch emote has been seen.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("ecount")
            .policy(PrefixPolicy.prefixed)
            .description("Reports how many times an emote has been used in the channel.")
            .addSyntax("$command [emote]")
    )
)
void onCommandEcount(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, stripped;
    import std.format : format;
    import std.conv  : to;

    void sendResults(const long count)
    {
        // 425618:3-5
        string slice = event.emotes;  // mutable
        slice.nom(':');

        immutable start = slice.nom('-').to!size_t;
        immutable end = slice
            .nom!(Yes.inherit)('/')
            .nom!(Yes.inherit)(',')
            .to!size_t + 1;  // upper-bound inclusive!

        string rawSlice = event.raw;  // mutable
        rawSlice.nom(event.channel);
        rawSlice.nom(" :");

        // Slice it as a dstring to (hopefully) get full characters
        immutable dline = rawSlice.to!dstring;
        immutable emote = dline[start..end];

        // No real point using plurality since most emotes should have a count > 1
        enum pattern = "%s has been used %d times!";
        immutable message = pattern.format(emote, count);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length)
    {
        enum pattern = "Usage: %s%s [emote]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }
    else if (!event.emotes.length)
    {
        enum message = "That is not a Twitch emote.";
        chan(plugin.state, event.channel, message);
        return;
    }

    const channelcounts = event.channel in plugin.ecount;
    if (!channelcounts) return sendResults(0L);

    string slice = event.emotes;
    immutable id = slice.nom(':');//.to!uint;

    auto thisEmoteCount = id in *channelcounts;
    if (!thisEmoteCount) return sendResults(0L);

    sendResults(*thisEmoteCount);
}


// onCommandWatchtime
/++
    Implements `!watchtime`; the ability to query the bot for how long the user
    (or a specified user) has been watching any of the channel's streams.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("watchtime")
            .policy(PrefixPolicy.prefixed)
            .description("Reports how long a user has been watching the channel's streams.")
            .addSyntax("$command [optional nickname]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("wt")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandWatchtime(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.common : timeSince;
    import lu.string : beginsWith, nom, stripped;
    import std.conv : to;
    import std.format : format;
    import core.thread : Fiber;
    import core.time : Duration, seconds;

    void watchtimeDg()
    {
        string slice = event.content.stripped;  // mutable
        immutable nameSpecified = (slice.length > 0);

        string nickname;
        string displayName;

        if (!nameSpecified)
        {
            // Assume the user is asking about itself
            nickname = event.sender.nickname;
            displayName = event.sender.displayName;
        }
        else
        {
            string givenName = slice.nom!(Yes.inherit)(' ');  // mutable
            if (givenName.beginsWith('@')) givenName = givenName[1..$];

            if (const user = givenName in plugin.state.users)
            {
                // Stored user
                nickname = user.nickname;
                displayName = user.displayName;
            }
            else
            {
                foreach (const user; plugin.state.users)
                {
                    if (user.displayName == givenName)
                    {
                        // Found user by displayName
                        nickname = user.nickname;
                        displayName = user.displayName;
                        break;
                    }
                }

                if (!displayName.length)
                {
                    import std.json : JSONType;

                    // None on record, look up
                    immutable userURL = "https://api.twitch.tv/helix/users?login=" ~ givenName;
                    immutable userJSON = getTwitchEntity(plugin, userURL);

                    if ((userJSON.type != JSONType.object) || ("id" !in userJSON))
                    {
                        chan(plugin.state, event.channel, "No such user: " ~ givenName);
                        return;
                    }

                    nickname = givenName;
                    displayName = userJSON["display_name"].str;
                }
            }
        }

        void reportNoViewerTime()
        {
            enum pattern = "%s has not been watching this channel's streams.";
            immutable message = pattern.format(displayName);
            chan(plugin.state, event.channel, message);
        }

        void reportViewerTime(const Duration time)
        {
            enum pattern = "%s has been a viewer for a total of %s.";
            immutable message = pattern.format(displayName, timeSince(time));
            chan(plugin.state, event.channel, message);
        }

        void reportNoViewerTimeInvoker()
        {
            enum message = "You have not been watching this channel's streams.";
            chan(plugin.state, event.channel, message);
        }

        void reportViewerTimeInvoker(const Duration time)
        {
            enum pattern = "You have been a viewer for a total of %s.";
            immutable message = pattern.format(timeSince(time));
            chan(plugin.state, event.channel, message);
        }

        if (nickname == event.channel[1..$])
        {
            if (nameSpecified)
            {
                enum pattern = "%s is the streamer though...";
                immutable message = pattern.format(nickname);
                chan(plugin.state, event.channel, message);
            }
            else
            {
                enum message = "You are the streamer though...";
                chan(plugin.state, event.channel, message);
            }
            return;
        }
        else if (nickname == plugin.state.client.nickname)
        {
            enum message = "I've seen it all.";
            chan(plugin.state, event.channel, message);
            return;
        }

        if (auto channelViewerTimes = event.channel in plugin.viewerTimesByChannel)
        {
            if (auto viewerTime = nickname in *channelViewerTimes)
            {
                return nameSpecified ?
                    reportViewerTime((*viewerTime).seconds) :
                    reportViewerTimeInvoker((*viewerTime).seconds);
            }
        }

        // If we're here, there were no matches
        return nameSpecified ?
            reportNoViewerTime() :
            reportNoViewerTimeInvoker();
    }

    Fiber watchtimeFiber = new Fiber(&twitchTryCatchDg!watchtimeDg, BufferSize.fiberStack);
    watchtimeFiber.call();
}


// onCAP
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the [dialect.defs.IRCEvent.Type.CAP|CAP] events.

    We can't do it in [start] since the calls to save and exit would go unheard,
    as [start] happens before the main loop starts. It would then immediately
    fail to read if too much time has passed, and nothing would be saved.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CAP)
)
void onCAP(TwitchBotPlugin plugin)
{
    import kameloso.plugins.twitchbot.keygen;
    import std.algorithm.searching : endsWith;

    if (plugin.twitchBotSettings.keygen &&
        (plugin.state.server.daemon == IRCServer.Daemon.unset) &&
        plugin.state.server.address.endsWith(".twitch.tv"))
    {
        return plugin.generateKey();
    }
}


// onMyInfo
/++
    Sets up a Fiber to periodically cache followers.

    Cannot be done on [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME] as the server
    daemon isn't known by then.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_MYINFO)
)
void onMyInfo(TwitchBotPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.common : nextMidnight;
    import std.datetime.systime : Clock;
    import core.thread : Fiber;

    // Clear and re-cache follows once every midnight
    void cacheFollowersDg()
    {
        while (true)
        {
            if (plugin.isEnabled)
            {
                foreach (immutable channelName, room; plugin.rooms)
                {
                    room.follows = getFollows(plugin, room.id);
                }
            }

            immutable now = Clock.currTime;
            delay(plugin, now.nextMidnight-now, Yes.yield);
        }
    }

    immutable now = Clock.currTime;

    Fiber followersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);
    delay(plugin, followersFiber, now.nextMidnight-now);

    // Load ecounts.
    plugin.reload();

    // Periodically save ecounts and viewer times
    void saveResourcesDg()
    {
        while (true)
        {
            if (plugin.ecount.length)
            {
                saveResourceToDisk(plugin.ecount, plugin.ecountFile);
            }

            if (plugin.viewerTimesByChannel.length)
            {
                saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
            }

            delay(plugin, plugin.savePeriodicity, Yes.yield);
        }
    }

    Fiber saveResourcesFiber = new Fiber(&saveResourcesDg, BufferSize.fiberStack);
    delay(plugin, saveResourcesFiber, plugin.savePeriodicity);
}


// start
/++
    Disables the bell if we're not running inside a terminal.
 +/
void start(TwitchBotPlugin plugin)
{
    import kameloso.terminal : isTerminal;
    import std.concurrency : thisTid;

    plugin.mainThread = cast(shared)thisTid;

    if (!isTerminal)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.bell = string.init;
    }
}


// teardown
/++
    De-initialises the plugin. Shuts down any persistent worker threads.
 +/
void teardown(TwitchBotPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : Tid, send;

    if (plugin.twitchBotSettings.singleWorkerThread &&
        (plugin.persistentWorkerTid != Tid.init))
    {
        // It may not have been started if we're aborting very early.
        plugin.persistentWorkerTid.send(ThreadMessage.teardown());
    }

    if (plugin.ecount.length)
    {
        saveResourceToDisk(plugin.ecount, plugin.ecountFile);
    }

    if (plugin.viewerTimesByChannel.length)
    {
        saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
    }
}


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] and modifies the
    sender and target class based on their badges (and the current settings).
 +/
void postprocess(TwitchBotPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!event.sender.nickname.length || !event.channel.length) return;

    version(TwitchPromoteEverywhere) {}
    else
    {
        if (!plugin.state.bot.homeChannels.canFind(event.channel)) return;
    }

    static void postprocessImpl(const TwitchBotPlugin plugin,
        const ref IRCEvent event, ref IRCUser user)
    {
        import lu.string : contains;

        if (user.class_ == IRCUser.Class.blacklist) return;

        if (plugin.twitchBotSettings.promoteBroadcasters)
        {
            if ((user.class_ < IRCUser.Class.staff) &&
                (user.nickname == event.channel[1..$]))
            {
                // User is broadcaster but is not registered as staff
                user.class_ = IRCUser.Class.staff;
                return;
            }
        }

        // Stop here if there are no badges to promote
        if (!user.badges.length) return;

        if (plugin.twitchBotSettings.promoteModerators)
        {
            if ((user.class_ < IRCUser.Class.operator) &&
                user.badges.contains("moderator/"))
            {
                // User is moderator but is not registered as at least operator
                user.class_ = IRCUser.Class.operator;
                return;
            }
        }

        if (plugin.twitchBotSettings.promoteVIPs)
        {
            if ((user.class_ < IRCUser.Class.whitelist) &&
                user.badges.contains("vip/"))
            {
                // User is VIP but is not registered as at least whitelist
                user.class_ = IRCUser.Class.whitelist;
                return;
            }
        }

        // There is no "registered" list; just map subscribers to registered 1:1
        if ((user.class_ < IRCUser.Class.registered) &&
            user.badges.contains("subscriber/"))
        {
            user.class_ = IRCUser.Class.registered;
        }
    }

    /*if (event.sender.nickname.length)*/ postprocessImpl(plugin, event, event.sender);
    if (event.target.nickname.length) postprocessImpl(plugin, event, event.target);
}


// initResources
/++
    Reads and writes the file of emote counters to disk, ensuring that it's
    there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage ecountJSON;
    JSONStorage viewersJSON;

    try
    {
        ecountJSON.load(plugin.ecountFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.ecountFile.baseName ~ " may be malformed.");
    }

    try
    {
        viewersJSON.load(plugin.viewersFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.viewersFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    ecountJSON.save(plugin.ecountFile);
    viewersJSON.save(plugin.viewersFile);
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for `ecount`.

    Params:
        aa = The associative array to convert into JSON and save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(const long[string][string] aa, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    const json = JSONValue(aa);
    File(filename, "w").writeln(json.toPrettyString);
}


// reload
/++
    Reloads the plugin, loading emote counters from disk.
 +/
void reload(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage ecountJSON;
    ecountJSON.load(plugin.ecountFile);
    plugin.ecount.clear();
    plugin.ecount.populateFromJSON(ecountJSON);
    plugin.ecount = plugin.ecount.rehash();

    JSONStorage viewersJSON;
    viewersJSON.load(plugin.viewersFile);
    plugin.viewerTimesByChannel.clear();
    plugin.viewerTimesByChannel.populateFromJSON(viewersJSON);
    plugin.viewerTimesByChannel = plugin.viewerTimesByChannel.rehash();
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;


public:


// TwitchBotPlugin
/++
    The Twitch Bot plugin is an example Twitch streamer bot. It contains some
    basic tools for streamers, and the audience thereof.
 +/
final class TwitchBotPlugin : IRCPlugin
{
private:
    import kameloso.terminal : TerminalToken;
    import std.concurrency : Tid;
    import core.time : hours, seconds;

package:
    /// Contained state of a channel, so that there can be several alongside each other.
    static struct Room
    {
        /// Aggregate of a broadcast.
        static struct Broadcast
        {
            /// Whether or not the streamer is currently broadcasting.
            bool active;

            /// UNIX timestamp of when broadcasting started.
            long startTime;

            /// UNIX timestamp of when broadcasting ended.
            long stopTime;

            /// Users seen in the channel.
            bool[string] chattersSeen;

            /// How many users were max seen as in the channel at the same time.
            int maxConcurrentChatters;

            /// How many users visited the channel during the last stream.
            size_t numViewersLastStream;
        }

        /// Constructor taking a string (channel) name.
        this(const string channelName) @safe pure nothrow @nogc
        {
            this.channelName = channelName;
            this.broadcasterName = channelName[1..$];
            this.broadcasterDisplayName = this.broadcasterName;  // until we resolve it
        }

        /// Name of the channel.
        string channelName;

        /// Struct instance representing the current broadcast.
        Broadcast broadcast;

        /// Account name of the broadcaster.
        string broadcasterName;

        /// Display name of the broadcaster.
        string broadcasterDisplayName;

        /// Broadcaster user/account/room ID (not name).
        string id;

        /// A JSON list of the followers of the channel.
        JSONValue[string] follows;
    }

    /// All Twitch Bot plugin settings.
    TwitchBotSettings twitchBotSettings;

    /// Array of active bot channels' state.
    Room[string] rooms;

    /++
        [kameloso.terminal.TerminalToken.bell|TerminalToken.bell] as string,
        for use as bell.
     +/
    private enum bellString = "" ~ cast(char)(TerminalToken.bell);

    /// Effective bell after [kameloso.terminal.isTerminal|isTerminal] checks.
    string bell = bellString;

    /// The Twitch application ID for kameloso.
    enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";

    /// Authorisation token for the "Authorization: Bearer <token>".
    string authorizationBearer;

    /// Whether or not to use features requiring querying Twitch API.
    shared static bool useAPIFeatures = true;

    /// The bot's numeric account/ID.
    string userID;

    /++
        How long a Twitch HTTP query usually takes.

        It tries its best to self-balance the number based on how long queries
        actually take. Start off conservatively.
     +/
    long approximateQueryTime = 700;

    /++
        The multiplier of how much the query time should temporarily increase
        when it turned out to be a bit short.
     +/
    enum approximateQueryGrowthMultiplier = 1.1;

    /++
        The divisor of how much to wait before retrying a query, after the
        timed waited turned out to be a bit short.
     +/
    enum approximateQueryRetryTimeDivisor = 3;

    /++
        By how many milliseconds to pad measurements of how long a query took
        to be on the conservative side.
     +/
    enum approximateQueryMeasurementPadding = 30;

    /++
        The weight to assign the current approximate query time before
        making a weighted average based on a new value. This gives the
        averaging some inertia.
     +/
    enum approximateQueryAveragingWeight = 3;

    /++
        How big a buffer to preallocate when doing HTTP API queries.
     +/
    enum queryBufferSize = 4096;

    /++
        When broadcasting, how often to check and enumerate chatters.
     +/
    static immutable chattersCheckPeriodicity = 60.seconds;

    /// Associative array of viewer times; seconds keyed by nickname keyed by channel.
    long[string][string] viewerTimesByChannel;

    /// The thread ID of the persistent worker thread.
    Tid persistentWorkerTid;

    /// The thread ID of the main thread, for access from threads.
    shared static Tid mainThread;

    /// Associative array of responses from async HTTP queries.
    shared QueryResponse[string] bucket;

    /// File to save emote counters to.
    @Resource ecountFile = "twitch-ecount.json";

    /// File to save viewer times to.
    @Resource viewersFile = "twitch-viewers.json";

    /// Emote counters associative array; counter longs keyed by emote ID string keyed by channel.
    long[string][string] ecount;

    /// How often to save `ecount`s and viewer times, to ward against losing information to crashes.
    static immutable savePeriodicity = 2.hours;


    // isEnabled
    /++
        Override
        [kameloso.plugins.common.core.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled]
        and inject a server check, so this plugin only works on Twitch, in addition
        to doing nothing when [TwitchbotSettings.enabled] is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return ((state.server.daemon == IRCServer.Daemon.twitch) ||
            (state.server.daemon == IRCServer.Daemon.unset)) &&
            (twitchBotSettings.enabled || twitchBotSettings.keygen);
    }

    mixin IRCPluginImpl;
}

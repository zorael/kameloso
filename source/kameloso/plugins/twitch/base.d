/++
    This is an example Twitch channel bot. It supports querying uptime or how
    long a streamer has been live, follower age queries, etc. It can also emit
    some terminal bells on certain events, to draw attention.

    One immediately obvious venue of expansion is expression bans, such as if a
    message has too many capital letters, etc. There is no protection from spam yet.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitch
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.twitch.base;


// TwitchSettings
/++
    All Twitch plugin runtime settings.

    Placed outside of the `version` gates to make sure it is always available,
    even on non-`WithTwitchPlugin` builds, so that the Twitch stub may
    import it and provide lines to the configuration file.
 +/
package @Settings struct TwitchSettings
{
private:
    import dialect.defs : IRCUser;
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
        Whether or not to only count watchtime for users that has shown activity
        in the channel. This makes it ignore silent lurkers.
     +/
    bool watchtimeExcludesLurkers = true;

    /++
        What kind of song requests to accept, if any.
     +/
    SongRequestMode songrequestMode = SongRequestMode.youtube;

    /++
        What level of user permissions are needed to issue song requests.
     +/
    IRCUser.Class songrequestPermsNeeded = IRCUser.Class.whitelist;

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
        [dialect.defs.IRCUser.Class.elevated|IRCUser.Class.elevated].
     +/
    bool promoteVIPs = true;

    @Unserialisable
    {
        /// Whether or not to bell on every message.
        bool bellOnMessage = false;

        /// Whether or not to bell on important events, like subscriptions.
        bool bellOnImportant = false;

        /++
            Whether or not to start a captive session for requesting a Twitch
            access token with normal chat privileges.
         +/
        bool keygen = false;

        /++
            Whether or not to start a captive session for requesting a Twitch
            access token with broadcaster privileges.
         +/
        bool superKeygen = false;

        /++
            Whether or not to start a captive session for requesting Google
            access tokens.
         +/
        bool googleKeygen = false;

        /++
            Whether or not to start a captive session for requesting Spotify
            access tokens.
         +/
        bool spotifyKeygen = false;
    }
}


// SRM
/++
    Song requests may be either disabled, or either in YouTube or Spotify mode.

    `SongRequestMode` abbreviated to fit into `printObjects` output formatting.
 +/
private enum SRM
{
    /++
        Song requests are disabled.
     +/
    disabled,

    /++
        Song requests relate to a YouTube playlist.
     +/
    youtube,

    /++
        Song requests relatet to a Spotify playlist.
     +/
    spotify,
}

/// Alias to [SRM].
alias SongRequestMode = SRM;

private import kameloso.plugins.common.core;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.api;

import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.constants : BufferSize;
import kameloso.messaging;
import dialect.defs;
import std.datetime.systime : SysTime;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// Credentials
/++
    Credentials needed to access APIs like that of Google and Spotify.

    See_Also:
        https://console.cloud.google.com/apis/credentials
 +/
package struct Credentials
{
    /++
        Broadcaster-level Twitch key.
     +/
    string broadcasterKey;

    /++
        Google client ID.
     +/
    string googleClientID;

    /++
        Google client secret.
     +/
    string googleClientSecret;

    /++
        Google API OAuth access token.
     +/
    string googleAccessToken;

    /++
        Google API OAuth refresh token.
     +/
    string googleRefreshToken;

    /++
        YouTube playlist ID.
     +/
    string youtubePlaylistID;

    /++
        Google client ID.
     +/
    string spotifyClientID;

    /++
        Google client secret.
     +/
    string spotifyClientSecret;

    /++
        Spotify API OAuth access token.
     +/
    string spotifyAccessToken;

    /++
        Spotify API OAuth refresh token.
     +/
    string spotifyRefreshToken;

    /++
        Spotify playlist ID.
     +/
    string spotifyPlaylistID;

    /++
        Serialises these [Credentials] into JSON.

        Returns:
            `this` represented in JSON.
     +/
    auto toJSON() const
    {
        JSONValue json;
        json = null;
        json.object = null;

        json["broadcasterKey"] = this.broadcasterKey;
        json["googleClientID"] = this.googleClientID;
        json["googleClientSecret"] = this.googleClientSecret;
        json["googleAccessToken"] = this.googleAccessToken;
        json["googleRefreshToken"] = this.googleRefreshToken;
        json["youtubePlaylistID"] = this.youtubePlaylistID;
        json["spotifyClientID"] = this.spotifyClientID;
        json["spotifyClientSecret"] = this.spotifyClientSecret;
        json["spotifyAccessToken"] = this.spotifyAccessToken;
        json["spotifyRefreshToken"] = this.spotifyRefreshToken;
        json["spotifyPlaylistID"] = this.spotifyPlaylistID;

        return json;
    }

    /++
        Deserialises some [Credentials] from JSON.

        Params:
            json = JSON representation of some [Credentials].
     +/
    static auto fromJSON(const JSONValue json)
    {
        typeof(this) creds;
        creds.broadcasterKey = json["broadcasterKey"].str;
        creds.googleClientID = json["googleClientID"].str;
        creds.googleClientSecret = json["googleClientSecret"].str;
        creds.googleAccessToken = json["googleAccessToken"].str;
        creds.googleRefreshToken = json["googleRefreshToken"].str;
        creds.youtubePlaylistID = json["youtubePlaylistID"].str;
        creds.spotifyClientID = json["spotifyClientID"].str;
        creds.spotifyClientSecret = json["spotifyClientSecret"].str;
        creds.spotifyAccessToken = json["spotifyAccessToken"].str;
        creds.spotifyRefreshToken = json["spotifyRefreshToken"].str;
        creds.spotifyPlaylistID = json["spotifyPlaylistID"].str;
        return creds;
    }
}


// onImportant
/++
    Bells on any important event, like subscriptions, cheers and raids, if the
    [TwitchSettings.bellOnImportant] setting is set.
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
void onImportant(TwitchPlugin plugin, const ref IRCEvent event)
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    // Record viewer as active
    if (auto room = event.channel in plugin.rooms)
    {
        if (room.broadcast.active)
        {
            room.broadcast.activeViewers[event.sender.nickname] = true;
        }
    }

    if (plugin.twitchSettings.bellOnImportant)
    {
        write(plugin.bell);
        stdout.flush();
    }
}


// onSelfjoin
/++
    Registers a new [TwitchPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Simply passes on execution to [handleSelfjoin].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TwitchPlugin plugin, const ref IRCEvent event)
{
    return plugin.handleSelfjoin(event.channel);
}


// handleSelfjoin
/++
    Registers a new [TwitchPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = The name of the channel we're supposedly joining.
 +/
void handleSelfjoin(TwitchPlugin plugin, const string channelName)
in (channelName.length, "Tried to handle SELFJOIN with an empty channel string")
{
    if (channelName in plugin.rooms) return;

    plugin.rooms[channelName] = TwitchPlugin.Room(channelName);
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
        logger.warningf(pattern, event.channel);
    }
}


// onSelfpart
/++
    Removes a channel's corresponding [TwitchPlugin.Room] when we leave it.

    This resets all that channel's transient state.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFPART)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfpart(TwitchPlugin plugin, const ref IRCEvent event)
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
void onCommandUptime(TwitchPlugin plugin, const ref IRCEvent event)
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
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("start")
            .policy(PrefixPolicy.prefixed)
            .description("Marks the start of a broadcast.")
            .addSyntax("$command [optional duration time already elapsed]")
    )
)
void onCommandStart(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.time : DurationStringException, abbreviatedDuration, timeSince;
    import std.format : format;
    import core.thread : Fiber;

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to start a broadcast in a nonexistent room");

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [optional duration time already elapsed]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void initBroadcast()
    {
        // Initialise a Broadcast with a new unique ID by using its constructor
        room.broadcast = TwitchPlugin.Room.Broadcast(true);
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
            initBroadcast();
            immutable elapsed = abbreviatedDuration(event.content.stripped);
            room.broadcast.startTime = (event.time - elapsed.total!"seconds");

            enum pattern = "Broadcast start registered (as %s ago)!";
            immutable message = pattern.format(timeSince(elapsed));
            chan(plugin.state, event.channel, message);
        }
        catch (ConvException e)
        {
            return sendUsage();
        }
        catch (DurationStringException e)
        {
            chan(plugin.state, event.channel, e.msg);
            return;
        }
        catch (Exception e)
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

    immutable uniqueIDSnapshot = room.broadcast.uniqueID;
    uint addedSinceLastRehash;

    while (room.broadcast.active && plugin.useAPIFeatures &&
        (room.broadcast.uniqueID == uniqueIDSnapshot))
    {
        import kameloso.plugins.common.delayawait : delay;
        import std.json : JSONType;

        const botBlacklist = getBotList(plugin);
        immutable chattersJSON = getChatters(plugin, room.broadcasterName);

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

                // continue early if we shouldn't monitor watchtime
                if (!plugin.twitchSettings.watchtime) continue;

                if (plugin.twitchSettings.watchtimeExcludesLurkers)
                {
                    // Exclude lurkers from watchtime monitoring
                    if (viewer !in room.broadcast.activeViewers) continue;
                }

                enum periodicitySeconds = plugin.chattersCheckPeriodicity.total!"seconds";

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
void onCommandStop(TwitchPlugin plugin, const ref IRCEvent event)
{
    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to stop a broadcast in a nonexistent room");

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

    if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
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
void onAutomaticStop(TwitchPlugin plugin, const ref IRCEvent event)
{
    return onCommandStop(plugin, event);
}


// reportStreamTime
/++
    Reports how long a broadcast has currently been ongoing, up until now lasted,
    or previously lasted.

    Params:
        plugin = The current [TwitchPlugin].
        room = The [TwitchPlugin.Room] of the channel.
        justNowEnded = Whether or not the stream ended just now.
 +/
void reportStreamTime(
    TwitchPlugin plugin,
    const TwitchPlugin.Room room,
    const Flag!"justNowEnded" justNowEnded = No.justNowEnded)
{
    import kameloso.time : timeSince;
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
                if (room.broadcast.numViewersLastStream > 0)
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

    See_Also:
        [kameloso.plugins.twitch.api.getFollows]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
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
void onCommandFollowAge(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : beginsWith, nom, stripped;
    import std.conv : to;
    import std.json : JSONType, JSONValue;
    import core.thread : Fiber;

    if (!plugin.useAPIFeatures) return;

    string slice = event.content.stripped;  // mutable
    string idString;
    string displayName;
    immutable nameSpecified = (slice.length > 0);

    if (!nameSpecified)
    {
        // Assume the user is asking about itself
        idString = event.sender.id.to!string;
        displayName = event.sender.displayName;
    }
    else
    {
        string givenName = slice.nom!(Yes.inherit)(' ');  // mutable
        if (givenName.beginsWith('@')) givenName = givenName[1..$];
        immutable user = getTwitchUser(plugin, givenName, Yes.searchByDisplayName);

        if (!user.nickname.length)
        {
            chan(plugin.state, event.channel, "No such user: " ~ givenName);
            return;
        }

        idString = user.idString;
        displayName = user.displayName;
    }

    void reportFollowAge(const JSONValue followingUserJSON)
    {
        import kameloso.time : timeSince;
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
            immutable message = pattern.format(displayName, timeline, datestamp);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum pattern = "You have been a follower for %s, since %s.";
            immutable message = pattern.format(timeline, datestamp);
            chan(plugin.state, event.channel, message);
        }
    }

    // Identity ascertained; look up in cached list

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
        room.followsLastCached = event.time;
    }

    enum minimumTimeBetweenRecaches = 10;

    if (const thisFollow = idString in room.follows)
    {
        return reportFollowAge(*thisFollow);
    }
    else if (event.time > (room.followsLastCached + minimumTimeBetweenRecaches))
    {
        // No match, but minimumTimeBetweenRecaches passed since last recache
        room.follows = getFollows(plugin, room.id);
        room.followsLastCached = event.time;

        if (const thisFollow = idString in room.follows)
        {
            return reportFollowAge(*thisFollow);
        }
    }

    // If we're here there were no matches.

    if (nameSpecified)
    {
        import std.format : format;

        enum pattern = "%s is currently not a follower.";
        immutable message = pattern.format(displayName);
        chan(plugin.state, event.channel, message);
    }
    else
    {
        enum message = "You are currently not a follower.";
        chan(plugin.state, event.channel, message);
    }
}


// onRoomState
/++
    Records the room ID of a home channel, and queries the Twitch servers for
    the display name of its broadcaster.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
)
void onRoomState(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
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

    immutable userURL = "https://api.twitch.tv/helix/users?id=" ~ event.aux;
    immutable userJSON = getTwitchEntity(plugin, userURL);
    room.broadcasterDisplayName = userJSON["display_name"].str;

    room.follows = getFollows(plugin, room.id);
    room.followsLastCached = event.time;
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
void onCommandVanish(TwitchPlugin plugin, const ref IRCEvent event)
{
    immutable message = ".timeout " ~ event.sender.nickname ~ " 1";
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
void onCommandRepeat(TwitchPlugin plugin, const ref IRCEvent event)
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


// onCommandNuke
/++
    Deletes recent messages containing a supplied word or phrase.

    See_Also:
        [TwitchPlugin.Room.lastNMessages]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("nuke")
            .policy(PrefixPolicy.prefixed)
            .description("Deletes recent messages containing a supplied word or phrase.")
            .addSyntax("$command [word or phrase]")
    )
)
void onCommandNuke(TwitchPlugin plugin, const ref IRCEvent event)
{
    import std.conv : text;
    import std.uni : toLower;

    if (!event.content.length)
    {
        import std.format : format;
        enum pattern = "Usage: %s%s [word or phrase]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to nuke a word in a nonexistent room");
    immutable phraseToLower = event.content.toLower;

    foreach (immutable storedEvent; room.lastNMessages)
    {
        import std.algorithm.searching : canFind;
        import std.uni : asLowerCase;

        if (storedEvent.sender.class_ >= IRCUser.Class.operator) continue;
        else if (!storedEvent.content.length) continue;

        if (storedEvent.content.asLowerCase.canFind(phraseToLower))
        {
            chan!(Yes.priority)(plugin.state, event.channel, text(".delete ", storedEvent.id));
        }
    }

    // Also nuke the nuking message in case there were spoilers in it
    chan(plugin.state, event.channel, text(".delete ", event.id));
}


// onCommandSongRequest
/++
    Implements `!songrequest`, allowing viewers to request songs (actually
    YouTube videos) to be added to the streamer's playlist.

    See_Also:
        [kameloso.plugins.twitch.google.addVideoToYouTubePlaylist]
        [kameloso.plugins.twitch.spotify.addTrackToSpotifyPlaylist]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("songrequest")
            .policy(PrefixPolicy.prefixed)
            .description("Requests a song.")
            .addSyntax("$command [YouTube link, YouTube video ID, Spotify link or Spotify track ID]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("sr")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandSongRequest(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.twitch.common : ErrorJSONException, UnexpectedJSONException;
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, HttpVerb, Uri;
    import lu.string : contains, nom, stripped;
    import std.format : format;
    import core.time : seconds;

    if (plugin.twitchSettings.songrequestMode == SongRequestMode.disabled) return;
    else if (event.sender.class_ < plugin.twitchSettings.songrequestPermsNeeded)
    {
        // Issue an error?
        logger.error("User does not have the needed permissions to issue song requests.");
        return;
    }

    if (event.sender.class_ < IRCUser.class_.operator)
    {
        const room = event.channel in plugin.rooms;
        assert(room, "Tried to make a song request in a nonexistent room");

        if (const lastRequestTimestamp = event.sender.nickname in room.songrequestHistory)
        {
            if ((event.time - *lastRequestTimestamp) < TwitchPlugin.Room.minimumTimeBetweenSongRequests)
            {
                enum pattern = "At least %d seconds must pass between song requests.";
                immutable message = pattern.format(TwitchPlugin.Room.minimumTimeBetweenSongRequests);
                chan(plugin.state, event.channel, message);
                return;
            }
        }
    }

    if (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube)
    {
        immutable url = event.content.stripped;

        enum videoIDLength = 11;

        if (url.length == videoIDLength)
        {
            // Probably a video ID
        }
        else if (!url.length ||
            url.contains(' ') ||
            (!url.contains("youtube.com/") &&
            !url.contains("youtu.be/")))
        {
            enum pattern = "Usage: %s%s [YouTube link or video ID]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
            return;
        }

        auto creds = event.channel in plugin.secretsByChannel;

        if (!creds || !creds.googleAccessToken.length || !creds.youtubePlaylistID.length)
        {
            enum message = "Missing Google API credentials and/or YouTube playlist ID. " ~
                "Run the program with <l>--set twitch.googleKeygen</> to set up.";
            logger.error(message);
            return;
        }

        // Patterns:
        // https://www.youtube.com/watch?v=jW1KXvCg5bY&t=123
        // www.youtube.com/watch?v=jW1KXvCg5bY&t=123
        // https://youtu.be/jW1KXvCg5bY?t=123
        // youtu.be/jW1KXvCg5bY?t=123
        // jW1KXvCg5bY

        string slice = url;  // mutable
        string videoID;

        if (slice.length == videoIDLength)
        {
            videoID = slice;
        }
        else if (slice.contains("youtube.com/watch?v="))
        {
            slice.nom("youtube.com/watch?v=");
            videoID = slice.nom!(Yes.inherit)('&');
        }
        else if (slice.contains("youtu.be/"))
        {
            slice.nom("youtu.be/");
            videoID = slice.nom!(Yes.inherit)('?');
        }
        else
        {
            logger.warning("Malformed video link?");
            return;
        }

        try
        {
            import kameloso.plugins.twitch.google : addVideoToYouTubePlaylist;

            immutable json = addVideoToYouTubePlaylist(plugin, *creds, videoID);
            immutable title = json["snippet"]["title"].str;
            //immutable position = json["snippet"]["position"].integer;

            enum pattern = "%s added to playlist.";
            immutable message = pattern.format(title);
            chan(plugin.state, event.channel, message);
        }
        catch (ErrorJSONException e)
        {
            enum message = "Invalid YouTube video URL.";
            chan(plugin.state, event.channel, message);
        }
        // Let other exceptions fall down to twitchTryCatchDg
    }
    else if (plugin.twitchSettings.songrequestMode == SongRequestMode.spotify)
    {
        immutable url = event.content.stripped;

        enum trackIDLength = 22;

        if (url.length == trackIDLength)
        {
            // Probably a track ID
        }
        else if (!url.length ||
            url.contains(' ') ||
            !url.contains("spotify.com/track/"))
        {
            enum pattern = "Usage: %s%s [Spotify link or track ID]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
            return;
        }

        auto creds = event.channel in plugin.secretsByChannel;

        if (!creds || !creds.spotifyAccessToken.length || !creds.spotifyPlaylistID)
        {
            enum message = "Missing Spotify API credentials and/or playlist ID. " ~
                "Run the program with <l>--set twitch.spotifyKeygen</> to set up.";
            logger.error(message);
            return;
        }

        // Patterns
        // https://open.spotify.com/track/65EGCfqn3di7gLMllw1Tg0?si=02eb9a0c9d6c4972

        string slice = url;  // mutable
        string trackID;

        if (slice.length == trackIDLength)
        {
            trackID = slice;
        }
        else if (slice.contains("spotify.com/track/"))
        {
            slice.nom("spotify.com/track/");
            trackID = slice.nom!(Yes.inherit)('?');
        }
        else
        {
            logger.warning("Malformed track link?");
            return;
        }

        try
        {
            import kameloso.plugins.twitch.spotify : addTrackToSpotifyPlaylist, getSpotifyTrackByID;
            import std.json : JSONType;

            immutable json = addTrackToSpotifyPlaylist(plugin, *creds, trackID);

            if ((json.type != JSONType.object)  || "snapshot_id" !in json)
            {
                logger.error("An error occurred.\n", json.toPrettyString);
                return;
            }

            const trackJSON = getSpotifyTrackByID(*creds, trackID);
            immutable artist = trackJSON["artists"].array[0].object["name"].str;
            immutable track = trackJSON["name"].str;

            enum pattern = "%s - %s added to playlist.";
            immutable message = pattern.format(artist, track);
            chan(plugin.state, event.channel, message);
        }
        catch (ErrorJSONException e)
        {
            enum message = "Invalid Spotify track URL.";
            chan(plugin.state, event.channel, message);
        }
        // Let other exceptions fall down to twitchTryCatchDg
    }
}


// onCommandStartPoll
/++
    Starts a Twitch poll.

    Note: Experimental, since we cannot try it out ourselves.

    See_Also:
        [kameloso.plugins.twitch.api.createPoll]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("startpoll")
            .policy(PrefixPolicy.prefixed)
            .description("Starts a Twitch poll.")
            .addSyntax(`$command "[poll title]" [duration] [choice1] [choice2] ...`)
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("startvote")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("createpoll")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandStartPoll(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.time : DurationStringException, abbreviatedDuration;
    import lu.string : splitInto;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.json : JSONType;

    void sendUsage()
    {
        import std.format : format;
        enum pattern = `Usage: %s%s "[poll title]" [duration] [choice1] [choice2] ...`;
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    // mutable
    string title;
    string durationString;
    string[] choices;

    event.content.splitInto(title, durationString, choices);
    if (choices.length < 2) return sendUsage();

    try
    {
        durationString = durationString
            .abbreviatedDuration
            .total!"seconds"
            .to!string;
    }
    catch (ConvException e)
    {
        enum message = "Invalid duration.";
        chan(plugin.state, event.channel, message);
        return;
    }
    catch (DurationStringException e)
    {
        chan(plugin.state, event.channel, e.msg);
        return;
    }
    catch (Exception e)
    {
        chan(plugin.state, event.channel, e.msg);
        return;
    }

    try
    {
        immutable responseJSON = createPoll(plugin, event.channel, title, durationString, choices);
        enum pattern = `Poll "%s" created.`;
        immutable message = pattern.format(responseJSON.array[0].object["title"].str);
        chan(plugin.state, event.channel, message);
    }
    catch (TwitchQueryException e)
    {
        import std.algorithm.searching : endsWith;

        if ((e.code == 403) &&
            (e.error == "Forbidden") &&
            e.msg.endsWith("is not a partner or affiliate"))
        {
            version(WithVotesPlugin)
            {
                enum message = "You must be an affiliate to create Twitch polls. " ~
                    "(Consider using the Votes plugin.)";
            }
            else
            {
                enum message = "You must be an affiliate to create Twitch polls.";
            }

            chan(plugin.state, event.channel, message);
        }
        else
        {
            // Fall back to twitchTryCatchDg's exception handling
            throw e;
        }
    }
    // As above
}


// onCommandEndPoll
/++
    Ends a Twitch poll.

    Currently ends the first active poll if there are several.

    Note: Experimental, since we cannot try it out ourselves.

    See_Also:
        [kameloso.plugins.twitch.api.endPoll]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("endpoll")
            .policy(PrefixPolicy.prefixed)
            .description("Ends a Twitch poll.")
            //.addSyntax("$command [terminating]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("endvote")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandEndPoll(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.json : JSONType;
    import std.stdio : writeln;

    immutable pollInfoJSON = getPolls(plugin, event.channel);

    if (!pollInfoJSON.array.length)
    {
        enum message = "There are no active polls to end.";
        chan(plugin.state, event.channel, message);
        return;
    }

    immutable voteID = pollInfoJSON.array[0].object["id"].str;
    immutable endResponseJSON = endPoll(plugin, event.channel, voteID, Yes.terminate);

    if ((endResponseJSON.type != JSONType.object) ||
        ("choices" !in endResponseJSON) ||
        (endResponseJSON["choices"].array.length < 2))
    {
        // Invalid response in some way
        logger.error("Unexpected response from server when ending a poll");
        writeln(endResponseJSON.toPrettyString);
        return;
    }

    /*static struct Choice
    {
        string title;
        long votes;
    }

    Choice[] choices;
    long totalVotes;

    foreach (immutable i, const choiceJSON; endResponseJSON["choices"].array)
    {
        Choice choice;
        choice.title = choiceJSON["title"].str;
        choice.votes =
            choiceJSON["votes"].integer +
            choiceJSON["channel_points_votes"].integer +
            choiceJSON["bits_votes"].integer;
        choices ~= choice;
        totalVotes += choice.votes;
    }

    auto sortedChoices = choices.sort!((a,b) => a.votes > b.votes);*/

    enum message = "Poll ended.";
    chan(plugin.state, event.channel, message);
}


// onAnyMessage
/++
    Bells on any message, if the [TwitchSettings.bellOnMessage] setting is set.
    Also counts emotes for `ecount` and records active viewers.

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
void onAnyMessage(TwitchPlugin plugin, const ref IRCEvent event)
{
    if (plugin.twitchSettings.bellOnMessage)
    {
        import kameloso.terminal : TerminalToken;
        import std.stdio : stdout, write;

        write(plugin.bell);
        stdout.flush();
    }

    if (event.type == IRCEvent.Type.QUERY)
    {
        // Ignore queries for the rest of this function
        return;
    }

    // ecount!
    if (plugin.twitchSettings.ecount && event.emotes.length)
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
            plugin.ecountDirty = true;
        }
    }

    // Record viewer as active
    if (auto room = event.channel in plugin.rooms)
    {
        if (room.broadcast.active)
        {
            room.broadcast.activeViewers[event.sender.nickname] = true;
        }

        room.lastNMessages.put(event);
    }
}


// onEndOfMOTD
/++
    Sets up various things after we have successfully
    logged onto the server.

    Has to be done at MOTD, as we only know whether we're on Twitch after
    [dialect.defs.IRCEvent.Type.RPL_MYINFO|RPL_MYINFO] or so.

    Some of this could be done in [initialise], like spawning the persistent
    worker thread, but then it'd always be spawned even if the plugin is disabled
    or if we end up on a non-Twitch server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
    .fiber(true)
)
void onEndOfMOTD(TwitchPlugin plugin)
{
    import kameloso.constants : MagicErrorStrings;
    import lu.string : beginsWith;
    import std.concurrency : spawn;
    import std.datetime.systime : Clock, SysTime;

    // Concatenate the Bearer and OAuth headers once.
    // This has to be done *after* connect's register
    immutable pass = plugin.state.bot.pass.beginsWith("oauth:") ?
        plugin.state.bot.pass[6..$] :
        plugin.state.bot.pass;
    plugin.authorizationBearer = "Bearer " ~ pass;

    // Initialise the bucket, just so that it isn't null
    plugin.bucket[0] = QueryResponse.init;
    plugin.bucket.remove(0);

    // Spawn the persistent worker.
    plugin.persistentWorkerTid = spawn(
        &persistentQuerier,
        plugin.bucket,
        plugin.state.connSettings.caBundleFile);

    enum retriesInCaseOfConnectionErrors = 5;
    uint retry;

    while (true)
    {
        if (plugin.state.settings.headless)
        {
            try
            {
                import kameloso.plugins.common.delayawait : delay;
                import kameloso.messaging : quit;

                immutable validationJSON = getValidation(plugin, plugin.state.bot.pass, Yes.async);
                plugin.userID = validationJSON["user_id"].str;
                immutable expiresIn = validationJSON["expires_in"].integer;
                immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
                immutable now = Clock.currTime;
                immutable delta = (expiresWhen - now);

                // Schedule quitting on expiry
                delay(plugin, (() => quit(plugin.state)), delta);
            }
            catch (TwitchQueryException e)
            {
                if ((e.code == 2) && (e.error != MagicErrorStrings.sslLibraryNotFound))
                {
                    if (retry++ < retriesInCaseOfConnectionErrors) continue;
                }
                plugin.useAPIFeatures = false;
            }
            return;
        }

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

            immutable validationJSON = getValidation(plugin, plugin.state.bot.pass, Yes.async);
            plugin.userID = validationJSON["user_id"].str;
            immutable expiresIn = validationJSON["expires_in"].integer;
            immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
            generateExpiryReminders(plugin, expiresWhen);
        }
        catch (TwitchQueryException e)
        {
            // Something is deeply wrong.

            if (e.code == 2)
            {
                enum wikiMessage = cast(string)MagicErrorStrings.visitWikiOneliner;

                if (e.error == MagicErrorStrings.sslLibraryNotFound)
                {
                    enum pattern = "Failed to validate Twitch API keys: <l>%s</> " ~
                        "<t>(is OpenSSL installed?)";
                    logger.errorf(pattern, cast(string)MagicErrorStrings.sslLibraryNotFoundRewritten);
                    logger.error(wikiMessage);

                    version(Windows)
                    {
                        enum getoptMessage = cast(string)MagicErrorStrings.getOpenSSLSuggestion;
                        logger.error(getoptMessage);
                    }
                }
                else
                {
                    if (retry++ < retriesInCaseOfConnectionErrors) continue;

                    enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) (<t>%d</>)";
                    logger.errorf(pattern, e.msg, e.error, e.code);
                    logger.error(wikiMessage);
                }
            }
            else
            {
                enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) (<t>%d</>)";
                logger.errorf(pattern, e.msg, e.error, e.code);
            }

            logger.warning("Disabling API features. Expect breakage.");
            //version(PrintStacktraces) logger.trace(e);
            plugin.useAPIFeatures = false;
        }
        return;
    }
}


// onCommandEcount
/++
    `!ecount`; reporting how many times a Twitch emote has been seen.

    See_Also:
        [TwitchPlugin.ecount]
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
void onCommandEcount(TwitchPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, stripped;
    import std.format : format;
    import std.conv  : to;

    if (!plugin.twitchSettings.ecount) return;

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
    .fiber(true)
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
void onCommandWatchtime(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.time : timeSince;
    import lu.string : beginsWith, nom, stripped;
    import std.conv : to;
    import std.format : format;
    import core.thread : Fiber;
    import core.time : Duration, seconds;

    if (!plugin.useAPIFeatures) return;
    else if (!plugin.twitchSettings.watchtime) return;

    string slice = event.content.stripped;  // mutable
    string nickname;
    string displayName;
    immutable nameSpecified = (slice.length > 0);

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
        immutable user = getTwitchUser(plugin, givenName, Yes.searchByDisplayName);

        if (!user.nickname.length)
        {
            chan(plugin.state, event.channel, "No such user: " ~ givenName);
            return;
        }

        nickname = user.nickname;
        displayName = user.displayName;
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


// onCommandSetTitle
/++
    Changes the title of the current channel.

    See_Also:
        [kameloso.plugins.twitch.api.modifyChannel]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("settitle")
            .policy(PrefixPolicy.prefixed)
            .description("Sets the channel title.")
            .addSyntax("$command [title]")
    )
)
void onCommandSetTitle(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.format : format;

    if (!plugin.useAPIFeatures) return;

    immutable unescapedTitle = event.content.stripped;

    if (!unescapedTitle.length)
    {
        enum pattern = "Usage: %s%s [title]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }

    immutable title = unescapedTitle.unquoted.replace(`"`, `\"`);

    try
    {
        modifyChannel(plugin, event.channel, title, string.init);

        enum pattern = "Channel title set to: %s";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel, message);
    }
    catch (TwitchQueryException e)
    {
        if ((e.code == 401) && (e.error == "Unauthorized"))
        {
            static uint idWhenComplainedAboutExpiredKey;

            if (idWhenComplainedAboutExpiredKey != plugin.state.connectionID)
            {
                // broadcaster "superkey" expired.
                enum message = "The broadcaster-level API key has expired.";
                chan(plugin.state, event.channel, message);
                idWhenComplainedAboutExpiredKey = plugin.state.connectionID;
            }
        }
        else
        {
            throw e;
        }
    }
}


// onCommandSetGame
/++
    Changes the game of the current channel.

    See_Also:
        [kameloso.plugins.twitch.api.modifyChannel]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("setgame")
            .policy(PrefixPolicy.prefixed)
            .description("Sets the channel game.")
            .addSyntax("$command [game name]")
    )
)
void onCommandSetGame(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.format : format;
    import std.string : isNumeric;
    import std.uri : encodeComponent;

    if (!plugin.useAPIFeatures) return;

    immutable unescapedGameName = event.content.stripped;

    if (!unescapedGameName.length)
    {
        enum pattern = "Usage: %s%s [game name]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }

    immutable specified = unescapedGameName.unquoted.replace(`"`, `\"`);
    string id = specified.isNumeric ? specified : string.init;  // mutable

    try
    {
        string name;  // mutable

        if (!id.length)
        {
            immutable gameInfo = getTwitchGame(plugin, specified.encodeComponent, string.init);
            id = gameInfo.id;
            name = gameInfo.name;
        }
        else if (id == "0")
        {
            name = "(unset)";
        }
        else /*if (id.length)*/
        {
            immutable gameInfo = getTwitchGame(plugin, string.init, id);
            name = gameInfo.name;
        }

        modifyChannel(plugin, event.channel, string.init, id);

        enum pattern = "Game set to: %s";
        immutable message = pattern.format(name);
        chan(plugin.state, event.channel, message);
    }
    catch (EmptyDataException e)
    {
        enum message = "Could not find a game by that name.";
        chan(plugin.state, event.channel, message);
    }
    catch (TwitchQueryException e)
    {
        if ((e.code == 401) && (e.error == "Unauthorized"))
        {
            static uint idWhenComplainedAboutExpiredKey;

            if (idWhenComplainedAboutExpiredKey != plugin.state.connectionID)
            {
                // broadcaster "superkey" expired.
                enum message = "The broadcaster-level API key has expired.";
                chan(plugin.state, event.channel, message);
                idWhenComplainedAboutExpiredKey = plugin.state.connectionID;
            }
        }
        else
        {
            throw e;
        }
    }
}


// onCommandCommercial
/++
    Starts a commercial in the current channel.

    See_Also:
        [kameloso.plugins.twitch.api.startCommercial]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("commercial")
            .policy(PrefixPolicy.prefixed)
            .description("Starts a commercial in the current channel.")
            .addSyntax("$command [commercial length; valid values are 30, 60, 90, 120, 150 and 180]")
    )
)
void onCommandCommercial(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped;
    import std.algorithm.comparison : among;
    import std.format : format;

    immutable lengthString = event.content.stripped;

    if (!lengthString.length)
    {
        enum pattern = "Usage: %s%s [commercial length; valid values are 30, 60, 90, 120, 150 and 180]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }

    const room = event.channel in plugin.rooms;

    if (!room.broadcast.active)
    {
        enum pattern = "Broadcast start was never marked with %sstart.";
        immutable message = pattern.format(plugin.state.settings.prefix);
        chan(plugin.state, event.channel, message);
        return;
    }

    if (!lengthString.among!("30", "60", "90", "120", "150", "180"))
    {
        enum message = "Commercial length must be one of 30, 60, 90, 120, 150 or 180.";
        chan(plugin.state, event.channel, message);
        return;
    }

    try
    {
        startCommercial(plugin, event.channel, lengthString);
    }
    catch (TwitchQueryException e)
    {
        if ((e.code == 400) && (e.error == "Bad Request"))
        {
            chan(plugin.state, event.channel, e.msg);
        }
        else
        {
            throw e;
        }
    }
}


// start
/++
    Start the captive key generation routine immediately after connection has
    been established.
 +/
void start(TwitchPlugin plugin)
{
    import std.algorithm.searching : endsWith;

    immutable someKeygenWanted =
        plugin.twitchSettings.keygen ||
        plugin.twitchSettings.superKeygen ||
        plugin.twitchSettings.googleKeygen ||
        plugin.twitchSettings.spotifyKeygen;

    if (!plugin.state.server.address.endsWith(".twitch.tv"))
    {
        if (someKeygenWanted)
        {
            enum message = "A Twitch keygen was requested but the configuration " ~
                "file is not set up to connect to Twitch. (<l>irc.chat.twitch.tv</>)";
            logger.trace();
            logger.warning(message);
            logger.trace();
        }

        // Not conncting to Twitch, return early
        return;
    }

    if (someKeygenWanted || (!plugin.state.bot.pass.length && !plugin.state.settings.force))
    {
        import kameloso.thread : ThreadMessage;
        import std.concurrency : prioritySend;

        // Some keygen, reload to load secrets so existing ones are read
        // Not strictly needed for normal keygen
        plugin.reload();

        bool needSeparator;
        enum separator = "---------------------------------------------------------------------";

        // Automatically keygen if no pass
        if (plugin.twitchSettings.keygen ||
            (!plugin.state.bot.pass.length && !plugin.state.settings.force))
        {
            import kameloso.plugins.twitch.keygen : requestTwitchKey;
            plugin.requestTwitchKey();
            if (*plugin.state.abort) return;
            plugin.twitchSettings.keygen = false;
            needSeparator = true;
        }

        if (plugin.twitchSettings.superKeygen)
        {
            import kameloso.plugins.twitch.keygen : requestTwitchSuperKey;
            if (needSeparator) logger.trace(separator);
            plugin.requestTwitchSuperKey();
            if (*plugin.state.abort) return;
            plugin.twitchSettings.superKeygen = false;
            needSeparator = true;
        }

        if (plugin.twitchSettings.googleKeygen)
        {
            import kameloso.plugins.twitch.google : requestGoogleKeys;
            if (needSeparator) logger.trace(separator);
            plugin.requestGoogleKeys();
            if (*plugin.state.abort) return;
            plugin.twitchSettings.googleKeygen = false;
            needSeparator = true;
        }

        if (plugin.twitchSettings.spotifyKeygen)
        {
            import kameloso.plugins.twitch.spotify : requestSpotifyKeys;
            if (needSeparator) logger.trace(separator);
            plugin.requestSpotifyKeys();
            if (*plugin.state.abort) return;
            plugin.twitchSettings.spotifyKeygen = false;
        }

        // Remove custom Twitch settings so we can reconnect without jumping
        // back into keygens.
        static immutable string[8] settingsToPop =
        [
            "twitch.keygen",
            "twitchbot.keygen",
            "twitch.superKeygen",
            "twitchbot.superKeygen",
            "twitch.googleKeygen",
            "twitchbot.googleKeygen",
            "twitch.spotifyKeygen",
            "twitchbot.spotifyKeygen",
        ];

        foreach (immutable setting; settingsToPop[])
        {
            plugin.state.mainThread.prioritySend(ThreadMessage.popCustomSetting(setting));
        }

        plugin.state.mainThread.prioritySend(ThreadMessage.reconnect);
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
    .fiber(true)
)
void onMyInfo(TwitchPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.time : nextMidnight;
    import std.datetime.systime : Clock;
    import core.thread : Fiber;

    // Clear and re-cache follows once every midnight
    void cacheFollowersDg()
    {
        while (true)
        {
            immutable now = Clock.currTime;

            if (plugin.isEnabled && plugin.useAPIFeatures)
            {
                foreach (immutable channelName, room; plugin.rooms)
                {
                    room.follows = getFollows(plugin, room.id);
                    room.followsLastCached = now.toUnixTime;
                }
            }

            delay(plugin, now.nextMidnight-now, Yes.yield);
        }
    }

    immutable now = Clock.currTime;

    Fiber cacheFollowersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);
    delay(plugin, cacheFollowersFiber, now.nextMidnight-now);

    // Load ecounts.
    plugin.reload();

    // delay once before looping
    delay(plugin, plugin.savePeriodicity, Yes.yield);

    // Periodically save ecounts and viewer times
    while (true)
    {
        if (plugin.twitchSettings.ecount && plugin.ecountDirty && plugin.ecount.length)
        {
            saveResourceToDisk(plugin.ecount, plugin.ecountFile);
            plugin.ecountDirty = false;
        }

        /+
            Only save watchtimes if there's at least one broadcast currently ongoing.
            Since we save at broadcast stop there won't be anything new to save otherwise.
            +/
        if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
        {
            foreach (const room; plugin.rooms)
            {
                if (room.broadcast.active)
                {
                    // At least one broadcast active
                    saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                    break;
                }
            }
        }

        delay(plugin, plugin.savePeriodicity, Yes.yield);
    }
}


// generateExpiryReminders
/++
    Generates and delays Twitch authorisation token expiry reminders.

    Params:
        plugin = The current [TwitchPlugin].
        expiresWhen = A [std.datetime.systime.SysTime|SysTime] of when the expiry occurs.
 +/
void generateExpiryReminders(TwitchPlugin plugin, const SysTime expiresWhen)
{
    import kameloso.plugins.common.delayawait : delay;
    import lu.string : plurality;
    import std.datetime.systime : Clock;
    import std.meta : AliasSeq;
    import core.time : days, hours, minutes, seconds, weeks;

    auto untilExpiry()
    {
        immutable now = Clock.currTime;
        return (expiresWhen - now) + 59.seconds;
    }

    void warnOnWeekDg()
    {
        immutable numDays = untilExpiry.total!"days";
        if (numDays <= 0) return;

        // More than a week away, just .info
        enum pattern = "Your Twitch authorisation token will expire " ~
            "in <l>%d days</> on <l>%4d-%02d-%02d</>.";
        logger.infof(pattern, numDays, expiresWhen.year, expiresWhen.month, expiresWhen.day);
    }

    void warnOnDaysDg()
    {
        int numDays;
        int numHours;
        untilExpiry.split!("days", "hours")(numDays, numHours);
        if ((numDays < 0) || (numHours < 0)) return;

        // A week or less, more than a day; warning
        if (numHours > 0)
        {
            enum pattern = "Warning: Your Twitch authorisation token will expire " ~
                "in <l>%d %s and %d %s</> at <l>%4d-%02d-%02d %02d:%02d</>.";
            logger.warningf(pattern,
                numDays, numDays.plurality("day", "days"),
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.year, expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "Warning: Your Twitch authorisation token will expire " ~
                "in <l>%d %s</> at <l>%4d-%02d-%02d %02d:%02d</>.";
            logger.warningf(pattern,
                numDays, numDays.plurality("day", "days"),
                expiresWhen.year, expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
    }

    void warnOnHoursDg()
    {
        int numHours;
        int numMinutes;
        untilExpiry.split!("hours", "minutes")(numHours, numMinutes);
        if ((numHours < 0) || (numMinutes < 0)) return;

        // Less than a day; warning
        if (numMinutes > 0)
        {
            enum pattern = "WARNING: Your Twitch authorisation token will expire " ~
                "in <l>%d %s and %d %s</> at <l>%02d:%02d</>.";
            logger.warningf(pattern,
                numHours, numHours.plurality("hour", "hours"),
                numMinutes, numMinutes.plurality("minute", "minutes"),
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "WARNING: Your Twitch authorisation token will expire " ~
                "in <l>%d %s</> at <l>%02d:%02d</>.";
            logger.warningf(pattern,
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.hour, expiresWhen.minute);
        }
    }

    void warnOnMinutesDg()
    {
        immutable numMinutes = untilExpiry.total!"minutes";
        if (numMinutes <= 0) return;

        // Less than an hour; warning
        enum pattern = "WARNING: Your Twitch authorisation token will expire " ~
            "in <l>%d minutes</> at <l>%02d:%02d</>.";
        logger.warningf(pattern,
            numMinutes, expiresWhen.hour, expiresWhen.minute);
    }

    void quitOnExpiry()
    {
        import kameloso.messaging : quit;

        // Key expired
        enum message = "Your Twitch authorisation token has expired. " ~
            "Run the program with <l>--set twitch.keygen</> to generate a new one.";
        logger.error(message);
        quit(plugin.state, "Twitch authorisation token expired");
    }

    alias reminderPoints = AliasSeq!(
        14.days,
        7.days,
        3.days,
        1.days,
        12.hours,
        6.hours,
        1.hours,
        30.minutes,
        10.minutes,
        5.minutes,
    );

    immutable now = Clock.currTime;
    immutable trueExpiry = (expiresWhen - now);

    foreach (immutable reminderPoint; reminderPoints)
    {
        if (trueExpiry >= reminderPoint)
        {
            immutable untilPoint = (trueExpiry - reminderPoint);
            if (reminderPoint >= 1.weeks) delay(plugin, &warnOnWeekDg, untilPoint);
            else if (reminderPoint >= 1.days) delay(plugin, &warnOnDaysDg, untilPoint);
            else if (reminderPoint >= 1.hours) delay(plugin, &warnOnHoursDg, untilPoint);
            else /*if (reminderPoint >= 1.minutes)*/ delay(plugin, &warnOnMinutesDg, untilPoint);
        }
    }

    // Schedule quitting on expiry
    delay(plugin, &quitOnExpiry, trueExpiry);

    // Also announce once normally how much time is left
    if (trueExpiry >= 1.weeks) warnOnWeekDg();
    else if (trueExpiry >= 1.days) warnOnDaysDg();
    else if (trueExpiry >= 1.hours) warnOnHoursDg();
    else /*if (trueExpiry >= 1.minutes)*/ warnOnMinutesDg();
}


// initialise
/++
    Initialises the Twitch plugin.
 +/
void initialise(TwitchPlugin plugin)
{
    import kameloso.terminal : isTerminal;
    import std.concurrency : thisTid;

    // Reset the shared static useAPIFeatures between instantiations.
    plugin.useAPIFeatures = true;

    // Register this thread as the main thread.
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
void teardown(TwitchPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : Tid, send;

    if (plugin.persistentWorkerTid != Tid.init)
    {
        // It may not have been started if we're aborting very early.
        plugin.persistentWorkerTid.send(ThreadMessage.teardown());
    }

    if (plugin.twitchSettings.ecount && /*plugin.ecountDirty &&*/ plugin.ecount.length)
    {
        // Might as well always save on exit.
        saveResourceToDisk(plugin.ecount, plugin.ecountFile);
        //plugin.ecountDirty = false;
    }

    if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
    {
        saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
    }
}


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] and modifies the
    sender and target class based on their badges (and the current settings).
 +/
void postprocess(TwitchPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!event.sender.nickname.length || !event.channel.length) return;

    version(TwitchPromoteEverywhere) {}
    else
    {
        if (!plugin.state.bot.homeChannels.canFind(event.channel)) return;
    }

    static void postprocessImpl(const TwitchPlugin plugin,
        const ref IRCEvent event, ref IRCUser user)
    {
        import lu.string : contains;

        if (user.class_ == IRCUser.Class.blacklist) return;

        if (plugin.twitchSettings.promoteBroadcasters)
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

        if (plugin.twitchSettings.promoteModerators)
        {
            if ((user.class_ < IRCUser.Class.operator) &&
                user.badges.contains("moderator/"))
            {
                // User is moderator but is not registered as at least operator
                user.class_ = IRCUser.Class.operator;
                return;
            }
        }

        if (plugin.twitchSettings.promoteVIPs)
        {
            if ((user.class_ < IRCUser.Class.elevated) &&
                user.badges.contains("vip/"))
            {
                // User is VIP but is not registered as at least elevated
                user.class_ = IRCUser.Class.elevated;
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
    Reads and writes resource files to disk, ensure that they're there and properly formatted.
 +/
void initResources(TwitchPlugin plugin)
{
    import kameloso.plugins.common.misc : IRCPluginInitialisationException;
    import lu.json : JSONStorage;
    import std.file : exists, mkdir, remove;
    import std.json : JSONException;
    import std.path : baseName, buildNormalizedPath, dirName;

    void loadFile(
        ref JSONStorage json,
        const string file,
        const size_t line = __LINE__)
    {
        try
        {
            json.load(file);
        }
        catch (JSONException e)
        {
            version(PrintStacktraces) logger.error("JSONException: ", e.msg);
            throw new IRCPluginInitialisationException(
                file ~ " is malformed",
                plugin.name,
                file,
                __FILE__,
                line);
        }

        // Let other Exceptions pass.
    }

    JSONStorage ecountJSON;
    JSONStorage viewersJSON;
    JSONStorage secretsJSON;

    // Ensure the subdirectory exists
    immutable subdir = plugin.ecountFile.dirName;
    if (!subdir.exists) mkdir(subdir);

    immutable oldEcount = buildNormalizedPath(
        plugin.state.settings.resourceDirectory,
        "twitch-ecount.json");
    immutable hasOldEcount = oldEcount.exists;
    immutable ecountFile = hasOldEcount ? oldEcount : plugin.ecountFile;

    immutable oldViewers = buildNormalizedPath(
        plugin.state.settings.resourceDirectory,
        "twitch-viewers.json");
    immutable hasOldViewers = oldViewers.exists;
    immutable viewersFile = hasOldViewers ? oldViewers : plugin.viewersFile;

    immutable oldSecrets = buildNormalizedPath(
        plugin.state.settings.resourceDirectory,
        "twitch-secrets.json");
    immutable hasOldSecrets = oldSecrets.exists;
    immutable secretsFile = hasOldSecrets ? oldSecrets : plugin.secretsFile;

    loadFile(ecountJSON, ecountFile);
    loadFile(viewersJSON, viewersFile);
    loadFile(secretsJSON, secretsFile);

    ecountJSON.save(plugin.ecountFile);
    viewersJSON.save(plugin.viewersFile);
    secretsJSON.save(plugin.secretsFile);

    if (hasOldEcount) remove(oldEcount);
    if (hasOldViewers) remove(oldViewers);
    if (hasOldSecrets) remove(oldSecrets);
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for `ecount`, as well as for keeping
    track of viewers.

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


// saveSecretsToDisk
/++
    Saves Twitch secrets to disk, in JSON format.

    Params:
        aa = Associative array of credentials.
        filename = Filename of the file to write to.
 +/
package void saveSecretsToDisk(const Credentials[string] aa, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    JSONValue json;
    json = null;
    json.object = null;

    foreach (immutable channelName, creds; aa)
    {
        json[channelName] = null;
        json[channelName].object = null;
        json[channelName] = creds.toJSON();
    }

    File(filename, "w").writeln(json.toPrettyString);
}


// reload
/++
    Reloads the plugin, loading emote counters from disk.
 +/
void reload(TwitchPlugin plugin)
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

    JSONStorage secretsJSON;
    secretsJSON.load(plugin.secretsFile);
    plugin.secretsByChannel.clear();

    foreach (immutable channelName, credsJSON; secretsJSON.storage.object)
    {
        plugin.secretsByChannel[channelName] = Credentials.fromJSON(credsJSON);
    }

    plugin.secretsByChannel = plugin.secretsByChannel.rehash();
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;


public:


// TwitchPlugin
/++
    The Twitch plugin is an example Twitch streamer bot. It contains some
    basic tools for streamers, and the audience thereof.
 +/
final class TwitchPlugin : IRCPlugin
{
private:
    import kameloso.terminal : TerminalToken;
    import lu.container : CircularBuffer;
    import std.concurrency : Tid;
    import core.time : hours, seconds;

package:
    /// Contained state of a channel, so that there can be several alongside each other.
    static struct Room
    {
        /// Aggregate of a broadcast.
        static struct Broadcast
        {
        private:
            uint privateUniqueID;

        public:
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

            /// Hashmap of active viewers (who have shown activity).
            bool[string] activeViewers;

            /// Accessor for `privateUniqueID`.
            auto uniqueID() const
            {
                return privateUniqueID;
            }

            /// Constructor.
            this(const bool active)
            {
                this.active = active;
            }
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

        /// Unix timestamp of when [follows] was last cached.
        long followsLastCached;

        /// How many messages to keep in memory, to allow for nuking.
        enum messageMemory = 64;

        /// The last n messages sent in the channel, used by `nuke`.
        CircularBuffer!(IRCEvent, No.dynamic, messageMemory) lastNMessages;

        /++
            The minimum amount of time in seconds that must have passed between
            two song requests by one person.

            Users of class [dialect.defs.IRCUser.Class.operator|operator] or
            higher are exempt.
         +/
        enum minimumTimeBetweenSongRequests = 60;

        /// Song request history; UNIX timestamps keyed by nickname.
        long[string] songrequestHistory;
    }

    /// All Twitch plugin settings.
    TwitchSettings twitchSettings;

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

    /// API keys and tokens, keyed by channel.
    Credentials[string] secretsByChannel;

    /// The thread ID of the persistent worker thread.
    Tid persistentWorkerTid;

    /// The thread ID of the main thread, for access from threads.
    shared static Tid mainThread;

    /// Associative array of responses from async HTTP queries.
    shared QueryResponse[int] bucket;

    @Resource
    {
        version(Posix)
        {
            /// File to save emote counters to.
            string ecountFile = "twitch/ecount.json";

            /// File to save viewer times to.
            string viewersFile = "twitch/viewers.json";

            /// File to save API keys and tokens to.
            string secretsFile = "twitch/secrets.json";
        }
        else version(Windows)
        {
            // As above.
            string ecountFile = "twitch\\ecount.json";

            // ditto
            string viewersFile = "twitch\\viewers.json";

            // ditto
            string secretsFile = "twitch\\secrets.json";
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }
    }

    /// Emote counters associative array; counter longs keyed by emote ID string keyed by channel.
    long[string][string] ecount;

    /// Whether or not [ecount] has been modified and there's a point in saving it to disk.
    bool ecountDirty;

    /// How often to save `ecount`s and viewer times, to ward against losing information to crashes.
    static immutable savePeriodicity = 2.hours;


    // isEnabled
    /++
        Override
        [kameloso.plugins.common.core.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled]
        and inject a server check, so this plugin only works on Twitch, in addition
        to doing nothing when [TwitchSettings.enabled] is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return ((state.server.daemon == IRCServer.Daemon.twitch) ||
            (state.server.daemon == IRCServer.Daemon.unset)) &&
            (twitchSettings.enabled ||
                twitchSettings.keygen ||
                twitchSettings.superKeygen ||
                twitchSettings.googleKeygen ||
                twitchSettings.spotifyKeygen);
    }

    mixin IRCPluginImpl;
}

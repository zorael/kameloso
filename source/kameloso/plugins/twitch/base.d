/++
    This is a Twitch channel bot. It supports song requests, counting how many
    times an emote has been used, reporting how long a viewer has been a follower,
    how much time they have spent watching the stream, and some miscellanea.

    For local use it can also emit some terminal bells on certain events, to draw attention.

    If the `promote*` settings are toggled, some viewers will be automatically given
    privileges based on their channel "status"; one of broadcaster, moderator and
    VIPs. Viewers that don't fall into any of those categories are not given any
    special permissions unless awarded manually. Nothing promotes into the
    `whitelist` class as it's meant to be assigned to manually.

    Mind that the majority of the other plugins still work on Twitch, so you also have
    the [kameloso.plugins.counter|Counter] plugin for death counters, the
    [kameloso.plugins.quotes|Quotes] plugin for streamer quotes, the
    [kameloso.plugins.timer|Timer] plugin for timed announcements, the
    [kameloso.plugins.oneliners|Oneliners] plugin for oneliner commands, etc.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitch,
        [kameloso.plugins.twitch.api],
        [kameloso.plugins.twitch.common],
        [kameloso.plugins.twitch.keygen],
        [kameloso.plugins.common.core],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.base;


// TwitchSettings
/++
    All Twitch plugin runtime settings.

    Placed outside of the `version` gates to make sure it is always available,
    even on non-`WithTwitchPlugin` builds, so that the Twitch stub may
    import it and provide lines to the configuration file.
 +/
@Settings package struct TwitchSettings
{
private:
    import dialect.defs : IRCUser;
    import lu.uda : Unserialisable;

public:
    /++
        Whether or not this plugin should react to any events.
     +/
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
        Whether or not to convert queries received by someone whose channel is a
        home channel into a channel message in that channel.
     +/
    bool fakeChannelFromQueries = false;

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
        /++
            Whether or not to bell on every message.
         +/
        bool bellOnMessage = false;

        /++
            Whether or not to bell on important events, like subscriptions.
         +/
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
            Runtime "alias" to [googleKeygen].
         +/
        bool youtubeKeygen = false;

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

/++
    Alias to [SRM].
 +/
alias SongRequestMode = SRM;

private import kameloso.plugins.common.core;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.api;
import kameloso.plugins.twitch.common;
import dialect.postprocessors.twitch;  // To trigger the module ctor

import kameloso.plugins;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : RehashingAA, logger;
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

        Returns:
            A new [Credentials] with values from the paseed `json`.
     +/
    static auto fromJSON(const JSONValue json)
    {
        Credentials creds;

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


// Follow
/++
    Embodiment of the notion of someone following someone else on Twitch.

    This cannot be a Voldemort type inside [kameloso.plugins.twitch.api.getFollows|getFollows]
    since we need an array of them inside [TwitchPlugin.Room].
 +/
package struct Follow
{
private:
    import std.datetime.systime : SysTime;

public:
    /++
        Display name of follower.
     +/
    string displayName;

    /++
        Time when the follow action took place.
     +/
    SysTime when;

    /++
        Twitch ID of follower.
     +/
    uint followerID;

    // fromJSON
    /++
        Constructs a [Follow] from a JSON representation.

        Params:
            json = JSON representation of a follow.

        Returns:
            A new [Follow] with values derived from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        import std.conv : to;

        /*{
            "followed_at": "2019-09-13T13:07:43Z",
            "from_id": "20739840",
            "from_name": "mike_bison",
            "to_id": "22216721",
            "to_name": "Zorael"
        }*/

        Follow follow;

        follow.displayName = json["from_name"].str;
        follow.when = SysTime.fromISOExtString(json["followed_at"].str);
        follow.followerID = json["from_id"].str.to!uint;

        return follow;
    }
}


// Mixins
mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;
mixin PluginRegistration!(TwitchPlugin, -5.priority);


// onImportant
/++
    Bells on any important event, like subscriptions, cheers and raids, if the
    [TwitchSettings.bellOnImportant] setting is set.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
    .onEvent(IRCEvent.Type.TWITCH_CHEER)
    .onEvent(IRCEvent.Type.TWITCH_DIRECTCHEER)
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
    .onEvent(IRCEvent.Type.TWITCH_CROWDCHANT)
    .onEvent(IRCEvent.Type.TWITCH_ANNOUNCEMENT)
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
        if (room.stream.live)
        {
            room.stream.activeViewers[event.sender.nickname] = true;
        }
    }

    if (plugin.twitchSettings.bellOnImportant)
    {
        write(TwitchPlugin.bell);
        stdout.flush();
    }
}


// onSelfjoin
/++
    Registers a new [TwitchPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Simply passes on execution to [initRoom].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TwitchPlugin plugin, const ref IRCEvent event)
{
    if (event.channel !in plugin.rooms)
    {
        initRoom(plugin, event.channel);
    }
}


// initRoom
/++
    Registers a new [TwitchPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = The name of the channel we're supposedly joining.
 +/
void initRoom(TwitchPlugin plugin, const string channelName)
in (channelName.length, "Tried to init Room with an empty channel string")
{
    plugin.rooms[channelName] = TwitchPlugin.Room(channelName);
}


// onUserstate
/++
    Warns if we're not a moderator when we join a home channel.

    "You will not get USERSTATE for other people. Only for yourself."
    https://discuss.dev.twitch.tv/t/no-userstate-on-people-joining/11598

    This sometimes happens once per outgoing message sent, causing it to spam
    the moderator warning.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.USERSTATE)
    .channelPolicy(ChannelPolicy.home)
)
void onUserstate(TwitchPlugin plugin, const ref IRCEvent event)
{
    import std.string : indexOf;

    if ((event.target.badges.indexOf("moderator/") != -1) ||
        (event.target.badges.indexOf("broadcaster/") != -1))
    {
        if (auto channel = event.channel in plugin.state.channels)
        {
            if (auto ops = 'o' in channel.mods)
            {
                if (plugin.state.client.nickname !in *ops)
                {
                    (*ops)[plugin.state.client.nickname] = true;
                }
            }
            else
            {
                channel.mods['o'][plugin.state.client.nickname] = true;
            }
        }
    }
    else
    {
        auto room = event.channel in plugin.rooms;

        if (!room)
        {
            // Race...
            initRoom(plugin, event.channel);
            room = event.channel in plugin.rooms;
        }

        if (!room.sawUserstate)
        {
            // First USERSTATE; warn about not being mod
            room.sawUserstate = true;
            enum pattern = "The bot is not a moderator of home channel <l>%s</>. " ~
                "Consider elevating it to such to avoid being as rate-limited.";
            logger.warningf(pattern, event.channel);
        }
    }
}


// onGlobalUserstate
/++
    Fetches global custom BetterTV, FrankerFaceZ and 7tv emotes.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.GLOBALUSERSTATE)
    .fiber(true)
)
void onGlobalUserstate(TwitchPlugin plugin)
{
    // dialect sets the display name during parsing
    //assert(plugin.state.client.displayName == event.target.displayName);
    importCustomGlobalEmotes(plugin);
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
    auto room = event.channel in plugin.rooms;
    if (!room) return;

    if (room.stream.live)
    {
        import std.datetime.systime : Clock;

        // We're leaving in the middle of a stream?
        // Close it and rotate, in case someone has a pointer to it
        // copied from nested functions in uptimeMonitorDg
        room.stream.live = false;
        room.stream.stopTime = Clock.currTime;
        room.stream.chattersSeen = null;
        appendToStreamHistory(plugin, room.stream);
        room.stream = TwitchPlugin.Room.Stream.init;
    }

    plugin.rooms.remove(event.channel);
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


// reportStreamTime
/++
    Reports how long a broadcast has currently been ongoing, up until now lasted,
    or previously lasted.

    Params:
        plugin = The current [TwitchPlugin].
        room = The [TwitchPlugin.Room] of the channel.
 +/
void reportStreamTime(
    TwitchPlugin plugin,
    const TwitchPlugin.Room room)
{
    import kameloso.time : timeSince;
    import lu.json : JSONStorage;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import core.time : msecs;

    if (room.stream.live)
    {
        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable delta = (now - room.stream.startTime);
        immutable timestring = timeSince!(7, 1)(delta);

        if (room.stream.numViewersMax > 0)
        {
            enum pattern = "%s has been live streaming %s for %s, currently with %d viewers. " ~
                "(Maximum this stream has so far been %d concurrent viewers.)";
            immutable message = pattern.format(
                room.broadcasterDisplayName,
                room.stream.gameName,
                timestring,
                room.stream.numViewers,
                room.stream.numViewersMax);
            return chan(plugin.state, room.channelName, message);
        }
        else
        {
            enum pattern = "%s has been live streaming %s for %s.";
            immutable message = pattern.format(
                room.broadcasterDisplayName,
                room.stream.gameName,
                timestring);
            return chan(plugin.state, room.channelName, message);
        }
    }

    // Stream down, check if we have one on record to report instead
    JSONStorage json;
    json.load(plugin.streamHistoryFile);

    if (!json.array.length)
    {
        // No streams this session and none on record
        immutable message = room.broadcasterDisplayName ~ " is currently not streaming.";
        return chan(plugin.state, room.channelName, message);
    }

    const previousStream = TwitchPlugin.Room.Stream.fromJSON(json.array[$-1]);
    immutable delta = (previousStream.stopTime - previousStream.startTime);
    immutable timestring = timeSince!(7, 1)(delta);
    immutable gameName = previousStream.gameName.length ?
        previousStream.gameName :
        "something";

    if (previousStream.numViewersMax > 0)
    {
        enum pattern = "%s is currently not streaming. " ~
            "Last streamed %s on %4d-%02d-%02d for %s, " ~
            "with a maximum of %d concurrent viewers.";
        immutable message = pattern.format(
            room.broadcasterDisplayName,
            gameName,
            previousStream.stopTime.year,
            cast(int)previousStream.stopTime.month,
            previousStream.stopTime.day,
            timestring,
            previousStream.numViewersMax);
        return chan(plugin.state, room.channelName, message);
    }
    else
    {
        enum pattern = "%s is currently not streaming. " ~
            "Last streamed %s on %4d-%02d-%02d for %s.";
        immutable message = pattern.format(
            room.broadcasterDisplayName,
            gameName,
            previousStream.stopTime.year,
            cast(int)previousStream.stopTime.month,
            previousStream.stopTime.day,
            timestring);
        return chan(plugin.state, room.channelName, message);
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
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : startsWith;
    import std.conv : to;

    void sendNoSuchUser(const string givenName)
    {
        immutable message = "No such user: " ~ givenName;
        chan(plugin.state, event.channel, message);
    }

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
        string givenName = slice.advancePast(' ', Yes.inherit);  // mutable
        if (givenName.startsWith('@')) givenName = givenName[1..$];
        immutable user = getTwitchUser(plugin, givenName, string.init, Yes.searchByDisplayName);
        if (!user.nickname.length) return sendNoSuchUser(givenName);

        idString = user.idString;
        displayName = user.displayName;
    }

    void reportFollowAge(const Follow follow)
    {
        import kameloso.time : timeSince;
        import std.datetime.systime : Clock;
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

        enum datestampPattern = "%s %d";
        immutable delta = (Clock.currTime - follow.when);
        immutable timeline = delta.timeSince!(7, 3);
        immutable datestamp = datestampPattern.format(
            months[cast(int)follow.when.month-1],
            follow.when.year);

        if (nameSpecified)
        {
            enum pattern = "%s has been a follower for %s, since %s.";
            immutable message = pattern.format(follow.displayName, timeline, datestamp);
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

    Additionally fetches custom BetterTV, FrankerFaceZ and 7tv emotes for the channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
)
void onRoomState(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : ThreadMessage, boxed;
    import std.concurrency : send;

    auto room = event.channel in plugin.rooms;

    if (!room)
    {
        // Race...
        initRoom(plugin, event.channel);
        room = event.channel in plugin.rooms;
    }

    /+
        Only start a room monitor Fiber if the room doesn't seem initialised.
        If it does, it should already have a monitor running. Since we're not
        resetting the room unique ID, we'd get two duplicate monitors. So don't.
     +/
    immutable shouldStartRoomMonitor = !room.id.length;
    auto twitchUser = getTwitchUser(plugin, string.init, event.aux[0]);

    if (!twitchUser.nickname.length)
    {
        // No such user?
        return;
    }

    room.id = event.aux[0];  // Assign this here after the nickname.length check
    room.broadcasterDisplayName = twitchUser.displayName;
    auto storedUser = twitchUser.nickname in plugin.state.users;

    if (!storedUser)
    {
        // Forge a new IRCUser
        auto newUser = IRCUser(
            twitchUser.nickname,
            twitchUser.nickname,
            twitchUser.nickname ~ ".tmi.twitch.tv");
        newUser.account = newUser.nickname;
        newUser.class_ = IRCUser.Class.anyone;
        plugin.state.users[newUser.nickname] = newUser;
        storedUser = newUser.nickname in plugin.state.users;
    }

    IRCUser userCopy = *storedUser;  // dereference and copy
    plugin.state.mainThread.send(ThreadMessage.putUser(string.init, boxed(userCopy)));

    if (shouldStartRoomMonitor)
    {
        startRoomMonitorFibers(plugin, event.channel);
        importCustomEmotes(plugin, event.channel, room.id);  // also only do this once
    }
}


// onGuestRoomState
/++
    Fetches custom BetterTV, FrankerFaceZ and 7tv emotes for a guest channel iff
    version `TwitchCustomEmotesEverywhere`.
 +/
version(TwitchCustomEmotesEverywhere)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.guest)
    .fiber(true)
)
void onGuestRoomState(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    if (event.channel in plugin.customEmotesByChannel)
    {
        // Already done
        return;
    }

    importCustomEmotes(plugin, event.channel, event.aux[0]);
}


// onCommandShoutout
/++
    Emits a shoutout to another streamer.

    Merely gives a link to their channel and echoes what game they last streamed
    (or are currently streaming).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
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
void onCommandShoutout(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.common.misc : idOf;
    import lu.string : SplitResults, splitInto, stripped;
    import std.algorithm.searching : startsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [name of streamer] [optional number of times to spam]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    void sendCountNotANumber()
    {
        enum message = "The passed count is not a number.";
        chan(plugin.state, event.channel, message);
    }

    void sendInvalidStreamerName()
    {
        enum message = "Invalid streamer name.";
        chan(plugin.state, event.channel, message);
    }

    void sendNoSuchUser(const string target)
    {
        immutable message = "No such user: " ~ target;
        chan(plugin.state, event.channel, message);
    }

    void sendUserHasNoChannel()
    {
        enum message = "Impossible error; user has no channel?";
        chan(plugin.state, event.channel, message);
    }

    void sendNoShoutoutOfCurrentChannel()
    {
        enum message = "Can't give a shoutout to the current channel...";
        chan(plugin.state, event.channel, message);
    }

    void sendOtherError()
    {
        enum message = "An error occurred when preparing the shoutout.";
        chan(plugin.state, event.channel, message);
    }

    string slice = event.content.stripped;  // mutable
    string target;  // ditto
    string numTimesString;  // ditto
    immutable results = slice.splitInto(target, numTimesString);

    if (target.startsWith('@')) target = target[1..$].stripped;

    if (!target.length || (results == SplitResults.overrun))
    {
        return sendUsage();
    }

    immutable login = idOf(plugin, target);

    if (login == event.channel[1..$])
    {
        return sendNoShoutoutOfCurrentChannel();
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
            numTimes = min(numTimesString.stripped.to!uint, numTimesCap);
        }
        catch (ConvException e)
        {
            return sendCountNotANumber();
        }
    }

    immutable shoutout = createShoutout(plugin, login);

    with (typeof(shoutout).State)
    final switch (shoutout.state)
    {
    case success:
        // Drop down
        break;

    case noSuchUser:
        return sendNoSuchUser(login);

    case noChannel:
        return sendUserHasNoChannel();

    case otherError:
        return sendOtherError();
    }

    const stream = getStream(plugin, login);
    string lastSeenPlayingPattern = "%s";  // mutable

    if (shoutout.gameName.length)
    {
        lastSeenPlayingPattern = stream.live ?
            " (currently playing %s)" :
            " (last seen playing %s)";
    }

    immutable pattern = "Shoutout to %s! Visit them at https://twitch.tv/%s !" ~ lastSeenPlayingPattern;
    immutable message = pattern.format(shoutout.displayName, login, shoutout.gameName);

    foreach (immutable i; 0..numTimes)
    {
        chan(plugin.state, event.channel, message);
    }
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
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : count;
    import std.algorithm.comparison : min;
    import std.conv : ConvException, to;
    import std.format : format;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [number of times] [text...]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    void sendNumTimesGTZero()
    {
        enum message = "Number of times must be greater than 0.";
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length || !event.content.count(' ')) return sendUsage();

    string slice = event.content.stripped;  // mutable
    immutable numTimesString = slice.advancePast(' ');

    try
    {
        enum maxNumTimes = 10;
        immutable numTimes = min(numTimesString.to!int, maxNumTimes);
        if (numTimes < 1) return sendNumTimesGTZero();

        foreach (immutable i; 0..numTimes)
        {
            chan(plugin.state, event.channel, slice);
        }
    }
    catch (ConvException _)
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
    import lu.string : stripped, unquoted;
    import std.uni : toLower;

    void sendUsage()
    {
        import std.format : format;
        enum pattern = "Usage: %s%s [word or phrase]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length) return sendUsage();

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to nuke a word in a nonexistent room");
    immutable phraseToLower = event.content
        .stripped
        .unquoted
        .toLower;

    if (!phraseToLower.length) return sendUsage();

    foreach (immutable storedEvent; room.lastNMessages)
    {
        import std.algorithm.searching : canFind;
        import std.uni : asLowerCase;

        if (storedEvent.sender.class_ >= IRCUser.Class.operator) continue;
        else if (!storedEvent.content.length) continue;

        if (storedEvent.content.asLowerCase.canFind(phraseToLower))
        {
            enum properties = Message.Property.priority;
            immutable message = ".delete " ~ storedEvent.id;
            chan(plugin.state, event.channel, message, properties);
        }
    }

    // Also nuke the nuking message in case there were spoilers in it
    immutable message = ".delete " ~ event.id;
    chan(plugin.state, event.channel, message);
}


// onCommandSongRequest
/++
    Implements `!songrequest`, allowing viewers to request songs (actually
    YouTube videos or Spotify tracks) to be added to the streamer's playlist.

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
    import lu.string : advancePast, stripped;
    import std.format : format;
    import std.string : indexOf;
    import core.time : seconds;

    /+
        The minimum amount of time in seconds that must have passed between
        two song requests by one non-operator person.
     +/
    enum minimumTimeBetweenSongRequests = 60;

    void sendUsage()
    {
        immutable pattern = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Usage: %s%s [YouTube link or video ID]" :
            "Usage: %s%s [Spotify link or track ID]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    void sendMissingCredentials()
    {
        immutable channelMessage = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Missing Google API credentials and/or YouTube playlist ID." :
            "Missing Spotify API credentials and/or Spotify playlist ID.";
        immutable terminalMessage = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            channelMessage ~ " Run the program with <l>--set twitch.googleKeygen</> to set it up." :
            channelMessage ~ " Run the program with <l>--set twitch.spotifyKeygen</> to set it up.";
        chan(plugin.state, event.channel, channelMessage);
        logger.error(terminalMessage);
    }

    void sendInvalidCredentials()
    {
        immutable message = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Invalid Google API credentials." :
            "Invalid Spotify API credentials.";
        chan(plugin.state, event.channel, message);
    }

    void sendAtLastNSecondsMustPass()
    {
        import kameloso.time : timeSince;

        enum pattern = "At least %s must pass between song requests.";
        immutable duration = timeSince(minimumTimeBetweenSongRequests.seconds);
        immutable message = pattern.format(duration);
        chan(plugin.state, event.channel, message);
    }

    void sendInsufficientPermissions()
    {
        enum message = "You do not have the needed permissions to issue song requests.";
        chan(plugin.state, event.channel, message);
    }

    void sendInvalidURL()
    {
        immutable message = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Invalid YouTube video URL." :
            "Invalid Spotify track URL.";
        chan(plugin.state, event.channel, message);
    }

    void sendNonspecificError()
    {
        enum message = "A non-specific error occurred.";
        chan(plugin.state, event.channel, message);
    }

    void sendAddedToYouTubePlaylist(const string title)
    {
        enum pattern = "%s added to playlist.";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel, message);
    }

    void sendAddedToSpotifyPlaylist(const string artist, const string track)
    {
        enum pattern = "%s - %s added to playlist.";
        immutable message = pattern.format(artist, track);
        chan(plugin.state, event.channel, message);
    }

    if (plugin.twitchSettings.songrequestMode == SongRequestMode.disabled) return;

    if (event.sender.class_ < plugin.twitchSettings.songrequestPermsNeeded)
    {
        return sendInsufficientPermissions();
    }

    auto room = event.channel in plugin.rooms;  // must be mutable for history
    assert(room, "Tried to make a song request in a nonexistent room");

    if (event.sender.class_ < IRCUser.class_.operator)
    {
        if (const lastRequestTimestamp = event.sender.nickname in room.songrequestHistory)
        {
            if ((event.time - *lastRequestTimestamp) < minimumTimeBetweenSongRequests)
            {
                return sendAtLastNSecondsMustPass();
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
        else if (
            !url.length ||
            (url.indexOf(' ') != -1) ||
            ((url.indexOf("youtube.com/") == -1) && (url.indexOf("youtu.be/") == -1)))
        {
            return sendUsage();
        }

        auto creds = event.channel in plugin.secretsByChannel;
        if (!creds || !creds.googleAccessToken.length || !creds.youtubePlaylistID.length)
        {
            return sendMissingCredentials();
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
        else if (slice.indexOf("youtube.com/watch?v=") != -1)
        {
            slice.advancePast("youtube.com/watch?v=");
            videoID = slice.advancePast('&', Yes.inherit);
        }
        else if (slice.indexOf("youtu.be/") != -1)
        {
            slice.advancePast("youtu.be/");
            videoID = slice.advancePast('?', Yes.inherit);
        }
        else
        {
            //return logger.warning("Bad link parsing?");
            return sendInvalidURL();
        }

        try
        {
            import kameloso.plugins.twitch.google : addVideoToYouTubePlaylist;
            import std.json : JSONType;

            immutable json = addVideoToYouTubePlaylist(plugin, *creds, videoID);

            if ((json.type != JSONType.object) || ("snippet" !in json))
            {
                logger.error("Unexpected JSON in YouTube response.");
                logger.trace(json.toPrettyString);
                return;
            }

            immutable title = json["snippet"]["title"].str;
            //immutable position = json["snippet"]["position"].integer;
            room.songrequestHistory[event.sender.nickname] = event.time;
            return sendAddedToYouTubePlaylist(title);
        }
        catch (InvalidCredentialsException _)
        {
            return sendInvalidCredentials();
        }
        catch (ErrorJSONException _)
        {
            return sendNonspecificError();
        }
        // Let other exceptions fall through
    }
    else if (plugin.twitchSettings.songrequestMode == SongRequestMode.spotify)
    {
        immutable url = event.content.stripped;

        enum trackIDLength = 22;

        if (url.length == trackIDLength)
        {
            // Probably a track ID
        }
        else if (
            !url.length ||
            (url.indexOf(' ') != -1) ||
            (url.indexOf("spotify.com/track/") == -1))
        {
            return sendUsage();
        }

        auto creds = event.channel in plugin.secretsByChannel;
        if (!creds || !creds.spotifyAccessToken.length || !creds.spotifyPlaylistID)
        {
            return sendMissingCredentials();
        }

        // Patterns
        // https://open.spotify.com/track/65EGCfqn3di7gLMllw1Tg0?si=02eb9a0c9d6c4972

        string slice = url;  // mutable
        string trackID;

        if (slice.length == trackIDLength)
        {
            trackID = slice;
        }
        else if (slice.indexOf("spotify.com/track/") != -1)
        {
            slice.advancePast("spotify.com/track/");
            trackID = slice.advancePast('?', Yes.inherit);
        }
        else
        {
            return sendInvalidURL();
        }

        try
        {
            import kameloso.plugins.twitch.spotify : addTrackToSpotifyPlaylist, getSpotifyTrackByID;
            import std.json : JSONType;

            immutable json = addTrackToSpotifyPlaylist(plugin, *creds, trackID);

            if ((json.type != JSONType.object) || ("snapshot_id" !in json))
            {
                logger.error("Unexpected JSON in Spotify response.");
                logger.trace(json.toPrettyString);
                return;
            }

            const trackJSON = getSpotifyTrackByID(*creds, trackID);
            immutable artist = trackJSON["artists"].array[0].object["name"].str;
            immutable track = trackJSON["name"].str;
            room.songrequestHistory[event.sender.nickname] = event.time;
            return sendAddedToSpotifyPlaylist(artist, track);
        }
        catch (ErrorJSONException _)
        {
            return sendInvalidURL();
        }
        // Let other exceptions fall through
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
            .description("(Experimental) Starts a Twitch poll.")
            .addSyntax(`$command "[poll title]" [duration] "[choice 1]" "[choice 2]" ...`)
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
    import kameloso.time : DurationStringException, asAbbreviatedDuration;
    import lu.string : splitWithQuotes;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.json : JSONType;

    void sendUsage()
    {
        import std.format : format;
        enum pattern = `Usage: %s%s "[poll title]" [duration] "[choice 1]" "[choice 2]" ...`;
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    immutable chunks = splitWithQuotes(event.content);
    if (chunks.length < 4) return sendUsage();

    immutable title = chunks[0];
    string durationString = chunks[1];  // mutable
    immutable choices = chunks[2..$];

    try
    {
        durationString = durationString
            .asAbbreviatedDuration
            .total!"seconds"
            .to!string;
    }
    catch (ConvException _)
    {
        enum message = "Invalid duration.";
        return chan(plugin.state, event.channel, message);
    }
    /*catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }*/
    catch (Exception e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }

    try
    {
        immutable responseJSON = createPoll(plugin, event.channel, title, durationString, choices);
        enum pattern = `Poll "%s" created.`;
        immutable message = pattern.format(responseJSON[0].object["title"].str);
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException _)
    {
        enum message = "Missing broadcaster-level API token.";
        enum superMessage = message ~ " Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
        chan(plugin.state, event.channel, message);
        logger.error(superMessage);
    }
    catch (TwitchQueryException e)
    {
        import std.algorithm.searching : endsWith;

        if ((e.code == 403) &&
            (e.error == "Forbidden") &&
            e.msg.endsWith("is not a partner or affiliate"))
        {
            version(WithPollPlugin)
            {
                enum message = "You must be an affiliate to create Twitch polls. " ~
                    "(Consider using the generic Poll plugin.)";
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
            .description("(Experimental) Ends a Twitch poll.")
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

    try
    {
        const pollInfoJSON = getPolls(plugin, event.channel);

        if (!pollInfoJSON.length)
        {
            enum message = "There are no active polls to end.";
            return chan(plugin.state, event.channel, message);
        }

        immutable voteID = pollInfoJSON[0].object["id"].str;
        immutable endResponseJSON = endPoll(plugin, event.channel, voteID, Yes.terminate);

        if ((endResponseJSON.type != JSONType.object) ||
            ("choices" !in endResponseJSON) ||
            (endResponseJSON["choices"].array.length < 2))
        {
            // Invalid response in some way
            logger.error("Unexpected response from server when ending a poll");
            logger.trace(endResponseJSON.toPrettyString);
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
    catch (MissingBroadcasterTokenException e)
    {
        enum pattern = "Missing broadcaster-level API token for channel <l>%s</>.";
        logger.errorf(pattern, e.channelName);

        enum superMessage = "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
        logger.error(superMessage);
    }
}


// onAnyMessage
/++
    Bells on any message, if the [TwitchSettings.bellOnMessage] setting is set.
    Also counts emotes for `ecount` and records active viewers.

    Belling is useful with small audiences so you don't miss messages, but
    obviously only makes sense when run locally.
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

        write(TwitchPlugin.bell);
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
        import lu.string : advancePast;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : count;
        import std.conv : to;

        foreach (immutable emotestring; event.emotes.splitter('/'))
        {
            if (!emotestring.length) continue;

            auto channelcount = event.channel in plugin.ecount;
            if (!channelcount)
            {
                plugin.ecount[event.channel][string.init] = 0L;
                channelcount = event.channel in plugin.ecount;
                (*channelcount).remove(string.init);
            }

            string slice = emotestring;  // mutable
            immutable id = slice.advancePast(':');

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
        if (room.stream.live)
        {
            room.stream.activeViewers[event.sender.nickname] = true;
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
)
void onEndOfMOTD(TwitchPlugin plugin)
{
    import std.algorithm.searching : startsWith;
    import std.concurrency : spawn;

    // Concatenate the Bearer and OAuth headers once.
    // This has to be done *after* connect's register
    immutable pass = plugin.state.bot.pass.startsWith("oauth:") ?
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

    startValidator(plugin);
    startSaver(plugin);
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
            .description("Reports how many times a Twitch emote has been used in the channel.")
            .addSyntax("$command [emote]")
    )
)
void onCommandEcount(TwitchPlugin plugin, const ref IRCEvent event)
{
    import lu.string : advancePast;
    import std.array : replace;
    import std.format : format;
    import std.conv  : to;

    if (!plugin.twitchSettings.ecount) return;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [emote]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    void sendNotATwitchEmote()
    {
        enum message = "That is not a Twitch, BetterTTV, FrankerFaceZ or 7tv emote.";
        chan(plugin.state, event.channel, message);
    }

    void sendResults(const long count)
    {
        // 425618:3-5,7-8/peepoLeave:9-18
        string slice = event.emotes;  // mutable
        slice.advancePast(':');

        immutable start = slice.advancePast('-').to!size_t;
        immutable end = slice
            .advancePast('/', Yes.inherit)
            .advancePast(',', Yes.inherit)
            .to!size_t + 1;  // upper-bound inclusive!

        string rawSlice = event.raw;  // mutable
        rawSlice.advancePast(event.channel);
        rawSlice.advancePast(" :");

        // Slice it as a dstring to (hopefully) get full characters
        // Undo replacements
        immutable dline = rawSlice.to!dstring;
        immutable emote = dline[start..end]
            .replace(dchar(';'), dchar(':'));

        // No real point using plurality since most emotes should have a count > 1
        // Make the pattern "%,?d", and supply an extra ' ' argument to get European grouping
        enum pattern = "%s has been used %,d times!";
        immutable message = pattern.format(emote, count);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length)
    {
        return sendUsage();
    }
    else if (!event.emotes.length)
    {
        return sendNotATwitchEmote();
    }

    const channelcounts = event.channel in plugin.ecount;
    if (!channelcounts) return sendResults(0L);

    string slice = event.emotes;

    // Replace emote colons so as not to conflict with emote tag syntax
    immutable id = slice
        .advancePast(':')
        .replace(':', ';');

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
    .addCommand(
        IRCEventHandler.Command()
            .word("hours")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandWatchtime(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.time : timeSince;
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : startsWith;
    import std.format : format;
    import core.time : Duration;

    if (!plugin.twitchSettings.watchtime) return;

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
        string givenName = slice.advancePast(' ', Yes.inherit);  // mutable
        if (givenName.startsWith('@')) givenName = givenName[1..$];
        immutable user = getTwitchUser(plugin, givenName, string.init, Yes.searchByDisplayName);

        if (!user.nickname.length)
        {
            immutable message = "No such user: " ~ givenName;
            return chan(plugin.state, event.channel, message);
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
        return chan(plugin.state, event.channel, message);
    }

    if (auto channelViewerTimes = event.channel in plugin.viewerTimesByChannel)
    {
        if (auto viewerTime = nickname in *channelViewerTimes)
        {
            import core.time : seconds;

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
    .addCommand(
        IRCEventHandler.Command()
            .word("title")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandSetTitle(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.format : format;

    immutable unescapedTitle = event.content.stripped;

    if (!unescapedTitle.length)
    {
        enum pattern = "Usage: %s%s [title]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        return chan(plugin.state, event.channel, message);
    }

    immutable title = unescapedTitle.unquoted.replace(`"`, `\"`);

    try
    {
        modifyChannel(plugin, event.channel, title, string.init);

        enum pattern = "Channel title set to: %s";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException _)
    {
        enum channelMessage = "Missing broadcaster-level API key.";
        enum terminalMessage = channelMessage ~
            " Run the program with <l>--set twitch.superKeygen</> to set it up.";
        chan(plugin.state, event.channel, channelMessage);
        logger.error(terminalMessage);
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
            .addSyntax("$command")
    )
)
void onCommandSetGame(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.format : format;
    import std.string : isNumeric;
    import std.uri : encodeComponent;

    immutable unescapedGameName = event.content.stripped;

    if (!unescapedGameName.length)
    {
        const channelInfo = getChannel(plugin, event.channel);

        enum pattern = "Currently playing game: %s";
        immutable gameName = channelInfo.gameName.length ?
            channelInfo.gameName :
            "(nothing)";
        immutable message = pattern.format(gameName);
        return chan(plugin.state, event.channel, message);
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
    catch (EmptyResponseException _)
    {
        enum message = "Empty response from server!";
        chan(plugin.state, event.channel, message);
    }
    catch (EmptyDataJSONException _)
    {
        enum message = "Could not find a game by that name; check spelling.";
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException _)
    {
        enum channelMessage = "Missing broadcaster-level API key.";
        enum terminalMessage = channelMessage ~
            " Run the program with <l>--set twitch.superKeygen</> to set it up.";
        chan(plugin.state, event.channel, channelMessage);
        logger.error(terminalMessage);
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
            .addSyntax("$command [commercial duration; valid values are 30, 60, 90, 120, 150 and 180]")
    )
)
void onCommandCommercial(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : stripped;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : endsWith;
    import std.format : format;

    string lengthString = event.content.stripped;  // mutable
    if (lengthString.endsWith('s')) lengthString = lengthString[0..$-1];

    if (!lengthString.length)
    {
        enum pattern = "Usage: %s%s [commercial duration; valid values are 30, 60, 90, 120, 150 and 180]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        return chan(plugin.state, event.channel, message);
    }

    const room = event.channel in plugin.rooms;
    assert(room, "Tried to start a commercial in a nonexistent room");

    if (!room.stream.live)
    {
        enum message = "There is no ongoing stream.";
        return chan(plugin.state, event.channel, message);
    }

    if (!lengthString.among!("30", "60", "90", "120", "150", "180"))
    {
        enum message = "Commercial duration must be one of 30, 60, 90, 120, 150 or 180.";
        return chan(plugin.state, event.channel, message);
    }

    try
    {
        startCommercial(plugin, event.channel, lengthString);
    }
    catch (MissingBroadcasterTokenException e)
    {
        enum pattern = "Missing broadcaster-level API token for channel <l>%s</>.";
        logger.errorf(pattern, e.channelName);

        enum superMessage = "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
        logger.error(superMessage);
    }
    catch (EmptyResponseException _)
    {
        enum message = "Empty response from server!";
        chan(plugin.state, event.channel, message);
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


// importCustomEmotes
/++
    Fetches custom channel-specific BetterTTV, FrankerFaceZ and 7tv emotes via API calls.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = Name of channel to import emotes for.
        idString = Twitch ID of channel, in string form.
 +/
void importCustomEmotes(
    TwitchPlugin plugin,
    const string channelName,
    const string idString)
in (Fiber.getThis, "Tried to call `importCustomEmotes` from outside a Fiber")
in (channelName.length, "Tried to import custom emotes with an empty channel name string")
in (idString.length, "Tried to import custom emotes with an empty ID string")
{
    import core.memory : GC;

    GC.disable();
    scope(exit) GC.enable();

    // Initialise the AA so we can get a pointer to it.
    plugin.customEmotesByChannel[channelName][dstring.init] = false;
    auto customEmotes = channelName in plugin.customEmotesByChannel;
    *customEmotes = null;

    alias GetEmoteFun = void function(
        TwitchPlugin,
        ref bool[dstring],
        const string,
        const string);

    void getEmoteSet(GetEmoteFun fun, const string setName)
    {
        try
        {
            fun(plugin, *customEmotes, idString, __FUNCTION__);
        }
        catch (Exception e)
        {
            enum pattern = "Failed to fetch custom <l>%s</> emotes for channel <l>%s</>: <t>%s";
            logger.warningf(pattern, setName, channelName, e.msg);
            version(PrintStacktraces) logger.trace(e);
            //throw e;
        }
    }

    getEmoteSet(&getBTTVEmotes, "BetterTTV");
    getEmoteSet(&getFFZEmotes, "FrankerFaceZ");
    getEmoteSet(&get7tvEmotes, "7tv");
    customEmotes.rehash();
}


// importCustomGlobalEmotes
/++
    Fetches custom global BetterTTV, FrankerFaceZ and 7tv emotes via API calls.

    Params:
        plugin = The current [TwitchPlugin].
 +/
void importCustomGlobalEmotes(TwitchPlugin plugin)
in (Fiber.getThis, "Tried to call `importCustomGlobalEmotes` from outside a Fiber")
{
    import core.memory : GC;

    GC.disable();
    scope(exit) GC.enable();

    alias GetGlobalEmoteFun = void function(
        TwitchPlugin,
        ref bool[dstring],
        const string);

    void getGlobalEmoteSet(GetGlobalEmoteFun fun, const string setName)
    {
        try
        {
            fun(plugin, plugin.customGlobalEmotes, __FUNCTION__);
        }
        catch (Exception e)
        {
            enum pattern = "Failed to fetch global <l>%s</> emotes: <t>%s";
            logger.warningf(pattern, setName, e.msg);
            version(PrintStacktraces) logger.trace(e.msg);
            //throw e;
        }
    }

    plugin.customGlobalEmotes = null;  // In case we're reimporting definitions
    getGlobalEmoteSet(&getBTTVGlobalEmotes, "BetterTTV");
    getGlobalEmoteSet(&get7tvGlobalEmotes, "7tv");
    plugin.customGlobalEmotes.rehash();
}


// embedCustomEmotes
/++
    Embeds custom emotes into the [dialect.defs.IRCEvent|IRCEvent] passed by reference,
    so that the [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin] can
    highlight them with colours.

    This is called in [postprocess].

    Params:
        event = [dialect.defs.IRCEvent|IRCEvent] in flight.
        customEmotes = `bool[dstring]` associative array of channel-specific custom emotes.
        customGlobalEmotes = `bool[dstring]` associative array of global custom emotes.
 +/
void embedCustomEmotes(
    ref IRCEvent event,
    const bool[dstring] customEmotes,
    const bool[dstring] customGlobalEmotes)
{
    import lu.string : strippedRight;
    import std.algorithm.comparison : among;
    import std.array : Appender;
    import std.conv : to;
    import std.string : indexOf;

    static Appender!(char[]) sink;

    scope(exit)
    {
        if (sink.data.length)
        {
            event.emotes ~= sink.data;
            sink.clear();
        }
    }

    if (sink.capacity == 0) sink.reserve(64);  // guesstimate

    immutable dline = event.content.strippedRight.to!dstring;
    ptrdiff_t pos = dline.indexOf(' ');
    dstring previousEmote;  // mutable
    size_t prev;

    static bool isEmoteCharacter(const dchar dc)
    {
        // Unsure about '-' and '(' but be conservative and keep
        return (
            ((dc >= dchar('a')) && (dc <= dchar('z'))) ||
            ((dc >= dchar('A')) && (dc <= dchar('Z'))) ||
            ((dc >= dchar('0')) && (dc <= dchar('9'))) ||
            dc.among!(dchar(':'), dchar(')'), dchar('-'), dchar('(')));
    }

    void appendEmote(const dstring dword)
    {
        import std.array : replace;
        import std.format : formattedWrite;

        enum pattern = "/%s:%d-%d";
        immutable slicedPattern = (event.emotes.length || sink.data.length) ?
            pattern :
            pattern[1..$];
        immutable dwordEscaped = dword.replace(dchar(':'), dchar(';'));
        immutable end = (pos == -1) ?
            dline.length :
            pos;
        sink.formattedWrite(slicedPattern, dwordEscaped, prev, end-1);
        previousEmote = dword;
    }

    void checkWord(const dstring dword)
    {
        import std.format : formattedWrite;

        // Micro-optimise a bit by skipping AA lookups of words that are unlikely to be emotes
        if ((dword.length > 1) &&
            isEmoteCharacter(dword[$-1]) &&
            isEmoteCharacter(dword[0]))
        {
            // Can reasonably be an emote
        }
        else
        {
            // Can reasonably not
            return;
        }

        if (dword == previousEmote)
        {
            enum pattern = ",%d-%d";
            immutable end = (pos == -1) ?
                dline.length :
                pos;
            sink.formattedWrite(pattern, prev, end-1);
            return;  // cannot return non-void from `void` function
        }

        if ((dword in customEmotes) || (dword in customGlobalEmotes))
        {
            return appendEmote(dword);
        }
    }

    if (pos == -1)
    {
        // No bounding space, check entire (one-word) line
        return checkWord(dline);
    }

    while (true)
    {
        if (pos > prev)
        {
            checkWord(dline[prev..pos]);
        }

        prev = (pos + 1);
        if (prev >= dline.length) return;

        pos = dline.indexOf(' ', prev);
        if (pos == -1)
        {
            return checkWord(dline[prev..$]);
        }
    }

    assert(0, "Unreachable");
}

///
unittest
{
    bool[dstring] customEmotes =
    [
        ":tf:"d : true,
        "FrankerZ"d : true,
        "NOTED"d : true,
    ];

    bool[dstring] customGlobalEmotes =
    [
        "KEKW"d : true,
        "NotLikeThis"d : true,
        "gg"d : true,
    ];

    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;

    {
        event.content = "come on its easy, now rest then talk talk more left, left, " ~
            "right re st, up, down talk some rest a bit talk poop  :tf:";
        //event.emotes = string.init;
        embedCustomEmotes(event, customEmotes, customGlobalEmotes);
        enum expectedEmotes = ";tf;:113-116";
        assert((event.emotes == expectedEmotes), event.emotes);
    }
    {
        event.content = "NOTED  FrankerZ  NOTED NOTED    gg";
        event.emotes = string.init;
        embedCustomEmotes(event, customEmotes, customGlobalEmotes);
        enum expectedEmotes = "NOTED:0-4/FrankerZ:7-14/NOTED:17-21,23-27/gg:32-33";
        assert((event.emotes == expectedEmotes), event.emotes);
    }
    {
        event.content = "No emotes here KAPPA";
        event.emotes = string.init;
        embedCustomEmotes(event, customEmotes, customGlobalEmotes);
        enum expectedEmotes = string.init;
        assert((event.emotes == expectedEmotes), event.emotes);
    }
}


// initialise
/++
    Start the captive key generation routine(s) before connecting to the server.
 +/
void initialise(TwitchPlugin plugin)
{
    import kameloso.plugins.common.misc : IRCPluginInitialisationException;
    import kameloso.terminal : isTerminal;
    import std.algorithm.searching : endsWith;

    if (!isTerminal)
    {
        // Not a TTY so replace our bell string with an empty one
        TwitchPlugin.bell = string.init;
    }

    immutable someKeygenWanted =
        plugin.twitchSettings.keygen ||
        plugin.twitchSettings.superKeygen ||
        plugin.twitchSettings.googleKeygen ||
        plugin.twitchSettings.youtubeKeygen ||
        plugin.twitchSettings.spotifyKeygen;

    if (!plugin.state.server.address.endsWith(".twitch.tv"))
    {
        if (someKeygenWanted)
        {
            // Not connecting to Twitch yet keygens requested
            enum message = "A Twitch keygen was requested but the configuration " ~
                "file is not set up to connect to Twitch";
            throw new IRCPluginInitialisationException(message, plugin.name);
        }
        return;
    }

    if (someKeygenWanted || (!plugin.state.bot.pass.length && !plugin.state.settings.force))
    {
        import kameloso.thread : ThreadMessage;
        import lu.json : JSONStorage;
        import std.concurrency : send;

        if (plugin.state.settings.headless)
        {
            // Headless mode is enabled, so a captive keygen session doesn't make sense
            return;
        }

        // Some keygen, reload to load secrets so existing ones are read
        // Not strictly needed for normal keygen but for everything else
        JSONStorage secretsJSON;
        secretsJSON.load(plugin.secretsFile);

        foreach (immutable channelName, credsJSON; secretsJSON.storage.object)
        {
            plugin.secretsByChannel[channelName] = Credentials.fromJSON(credsJSON);
        }

        bool needSeparator;
        enum separator = "---------------------------------------------------------------------";

        // Automatically keygen if no pass
        if (plugin.twitchSettings.keygen ||
            (!plugin.state.bot.pass.length && !plugin.state.settings.force))
        {
            import kameloso.plugins.twitch.keygen : requestTwitchKey;
            requestTwitchKey(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.keygen = false;
            plugin.state.mainThread.send(ThreadMessage.popCustomSetting("twitch.keygen"));
            needSeparator = true;
        }

        if (plugin.twitchSettings.superKeygen)
        {
            import kameloso.plugins.twitch.keygen : requestTwitchSuperKey;
            if (needSeparator) logger.trace(separator);
            requestTwitchSuperKey(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.superKeygen = false;
            plugin.state.mainThread.send(ThreadMessage.popCustomSetting("twitch.superKeygen"));
            needSeparator = true;
        }

        if (plugin.twitchSettings.googleKeygen ||
            plugin.twitchSettings.youtubeKeygen)
        {
            import kameloso.plugins.twitch.google : requestGoogleKeys;
            if (needSeparator) logger.trace(separator);
            requestGoogleKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.googleKeygen = false;
            plugin.twitchSettings.youtubeKeygen = false;
            plugin.state.mainThread.send(ThreadMessage.popCustomSetting("twitch.googleKeygen"));
            plugin.state.mainThread.send(ThreadMessage.popCustomSetting("twitch.youtubeKeygen"));
            needSeparator = true;
        }

        if (plugin.twitchSettings.spotifyKeygen)
        {
            import kameloso.plugins.twitch.spotify : requestSpotifyKeys;
            if (needSeparator) logger.trace(separator);
            requestSpotifyKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.state.mainThread.send(ThreadMessage.popCustomSetting("twitch.spotifyKeygen"));
            plugin.twitchSettings.spotifyKeygen = false;
        }
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
void onMyInfo(TwitchPlugin plugin)
{
    // Load ecounts and such.
    loadResources(plugin);
}


// startRoomMonitorFibers
/++
    Starts room monitor fibers.

    These detect new streams (and updates ongoing ones), updates chatters, and caches followers.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = String key of room to start the monitors of.
 +/
void startRoomMonitorFibers(TwitchPlugin plugin, const string channelName)
in (channelName.length, "Tried to start room monitor fibers with an empty channel name string")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import std.datetime.systime : Clock;
    import core.time : MonoTime, hours, seconds;

    // How often to poll the servers for various information about a channel.
    static immutable monitorUpdatePeriodicity = 60.seconds;

    void chatterMonitorDg()
    {
        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start chatter monitor delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;

        static immutable botUpdatePeriodicity = 3.hours;
        MonoTime lastBotUpdateTime;
        string[] botBlacklist;

        while (true)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            if (!room.stream.live)
            {
                delay(plugin, monitorUpdatePeriodicity, Yes.yield);
                continue;
            }

            try
            {
                immutable now = MonoTime.currTime;
                immutable sinceLastBotUpdate = (now - lastBotUpdateTime);

                if (sinceLastBotUpdate >= botUpdatePeriodicity)
                {
                    botBlacklist = getBotList(plugin);
                    lastBotUpdateTime = now;
                }

                immutable chattersJSON = getChatters(plugin, room.broadcasterName);

                static immutable string[6] chatterTypes =
                [
                    "admins",
                    //"broadcaster",
                    "global_mods",
                    "moderators",
                    "staff",
                    "viewers",
                    "vips",
                ];

                foreach (immutable chatterType; chatterTypes[])
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

                        room.stream.chattersSeen[viewer] = true;

                        // continue early if we shouldn't monitor watchtime
                        if (!plugin.twitchSettings.watchtime) continue;

                        if (plugin.twitchSettings.watchtimeExcludesLurkers)
                        {
                            // Exclude lurkers from watchtime monitoring
                            if (viewer !in room.stream.activeViewers) continue;
                        }

                        enum periodicitySeconds = monitorUpdatePeriodicity.total!"seconds";

                        if (auto channelViewerTimes = room.channelName in plugin.viewerTimesByChannel)
                        {
                            if (auto viewerTime = viewer in *channelViewerTimes)
                            {
                                *viewerTime += periodicitySeconds;
                            }
                            else
                            {
                                (*channelViewerTimes)[viewer] = periodicitySeconds;
                            }
                        }
                        else
                        {
                            plugin.viewerTimesByChannel[room.channelName][viewer] = periodicitySeconds;
                        }

                        plugin.viewerTimesDirty = true;
                    }
                }
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, monitorUpdatePeriodicity, Yes.yield);
        }
    }

    void uptimeMonitorDg()
    {
        static void closeStream(TwitchPlugin.Room* room)
        {
            room.stream.live = false;
            room.stream.stopTime = Clock.currTime;
            room.stream.chattersSeen = null;
        }

        void rotateStream(TwitchPlugin.Room* room)
        {
            appendToStreamHistory(plugin, room.stream);
            room.stream = TwitchPlugin.Room.Stream.init;
        }

        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start chatter monitor delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;

        while (true)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            try
            {
                auto streamFromServer = getStream(plugin, room.broadcasterName);  // must not be const nor immutable

                if (!streamFromServer.idString.length)  // == TwitchPlugin.Room.Stream.init)
                {
                    // Stream down
                    if (room.stream.live)
                    {
                        // Was up but just ended
                        closeStream(room);
                        rotateStream(room);

                        if (plugin.twitchSettings.watchtime && plugin.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.viewerTimesDirty = false;
                        }
                    }
                }
                else
                {
                    // Stream up
                    if (!room.stream.idString.length)
                    {
                        // New stream!
                        room.stream = streamFromServer;

                        /*if (plugin.twitchSettings.watchtime && plugin.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.viewerTimesDirty = false;
                        }*/
                    }
                    else if (room.stream.idString == streamFromServer.idString)
                    {
                        // Same stream running, just update it
                        room.stream.update(streamFromServer);
                    }
                    else /*if (room.stream.idString != streamFromServer.idString)*/
                    {
                        // New stream, but stale one exists. Rotate and insert
                        closeStream(room);
                        rotateStream(room);
                        room.stream = streamFromServer;

                        if (plugin.twitchSettings.watchtime && plugin.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.viewerTimesDirty = false;
                        }
                    }
                }
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, monitorUpdatePeriodicity, Yes.yield);
        }
    }

    // Clear and re-cache follows once every midnight
    void cacheFollowersDg()
    {
        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start follower cache delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;

        while (true)
        {
            import kameloso.time : nextMidnight;

            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            immutable now = Clock.currTime;

            try
            {
                room.follows = getFollows(plugin, room.id);
                room.followsLastCached = now.toUnixTime();
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, (now.nextMidnight - now), Yes.yield);
        }
    }

    Fiber uptimeMonitorFiber = new Fiber(&uptimeMonitorDg, BufferSize.fiberStack);
    uptimeMonitorFiber.call();

    Fiber chatterMonitorFiber = new Fiber(&chatterMonitorDg, BufferSize.fiberStack);
    chatterMonitorFiber.call();

    Fiber cacheFollowersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);
    cacheFollowersFiber.call();
}


// startValidator
/++
    Starts a validator [core.thread.fiber.Fiber|Fiber].

    This will validate the API access token and output to the terminal for how
    much longer it is valid. If it has expired, it will exit the program.

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startValidator(TwitchPlugin plugin)
{
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;

    void validatorDg()
    {
        import kameloso.plugins.common.delayawait : delay;
        import core.time : minutes;

        while (!plugin.botUserIDString.length)
        {
            static immutable retryDelay = 1.minutes;

            if (plugin.state.settings.headless)
            {
                try
                {
                    import kameloso.messaging : quit;
                    import std.datetime.systime : Clock, SysTime;

                    immutable validationJSON = getValidation(plugin, plugin.state.bot.pass, Yes.async);
                    plugin.botUserIDString = validationJSON["user_id"].str;
                    immutable expiresIn = validationJSON["expires_in"].integer;
                    immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime() + expiresIn);
                    immutable now = Clock.currTime;
                    immutable delta = (expiresWhen - now);

                    // Schedule quitting on expiry
                    delay(plugin, (() => quit(plugin.state)), delta);
                }
                catch (TwitchQueryException e)
                {
                    version(PrintStacktraces) logger.trace(e);
                    delay(plugin, retryDelay, Yes.yield);
                    continue;
                }
                catch (EmptyResponseException e)
                {
                    version(PrintStacktraces) logger.trace(e);
                    delay(plugin, retryDelay, Yes.yield);
                    continue;
                }
                return;
            }

            try
            {
                import std.datetime.systime : Clock;

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
                plugin.botUserIDString = validationJSON["user_id"].str;
                immutable expiresIn = validationJSON["expires_in"].integer;
                immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime() + expiresIn);
                generateExpiryReminders(plugin, expiresWhen);
            }
            catch (TwitchQueryException e)
            {
                import kameloso.constants : MagicErrorStrings;

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

                        // Unrecoverable
                        return;
                    }
                    else
                    {
                        enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) <t>(%d)";
                        logger.errorf(pattern, e.msg, e.error, e.code);
                        logger.error(wikiMessage);
                    }
                }
                else
                {
                    enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) <t>(%d)";
                    logger.errorf(pattern, e.msg, e.error, e.code);
                }

                version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, Yes.yield);
                continue;
            }
            catch (EmptyResponseException e)
            {
                // HTTP query failed; just retry
                enum pattern = "Failed to validate Twitch API keys: <t>%s</>";
                logger.errorf(pattern, e.msg);
                version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, Yes.yield);
                continue;
            }
        }
    }

    Fiber validatorFiber = new Fiber(&validatorDg, BufferSize.fiberStack);
    validatorFiber.call();
}


// startSaver
/++
    Starts a saver [core.thread.fiber.Fiber|Fiber].

    This will save resources to disk periodically.

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startSaver(TwitchPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;
    import core.time : hours;

    // How often to save `ecount`s and viewer times, to ward against losing information to crashes.
    static immutable savePeriodicity = 2.hours;

    void periodicallySaveDg()
    {
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
            if (plugin.twitchSettings.watchtime && plugin.viewerTimesDirty)
            {
                saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                plugin.viewerTimesDirty = false;
            }

            delay(plugin, savePeriodicity, Yes.yield);
        }
    }

    Fiber periodicallySaveFiber = new Fiber(&periodicallySaveDg, BufferSize.fiberStack);
    delay(plugin, periodicallySaveFiber, savePeriodicity);
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

    void warnOnWeeksDg()
    {
        immutable numDays = untilExpiry.total!"days";
        if (numDays <= 0) return;

        // More than a week away, just .info
        enum pattern = "Your Twitch authorisation token will expire " ~
            "in <l>%d days</> on <l>%4d-%02d-%02d";
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
                "in <l>%d %s and %d %s</> at <l>%4d-%02d-%02d %02d:%02d";
            logger.warningf(pattern,
                numDays, numDays.plurality("day", "days"),
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.year, expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "Warning: Your Twitch authorisation token will expire " ~
                "in <l>%d %s</> at <l>%4d-%02d-%02d %02d:%02d";
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
                "in <l>%d %s and %d %s</> at <l>%02d:%02d";
            logger.warningf(pattern,
                numHours, numHours.plurality("hour", "hours"),
                numMinutes, numMinutes.plurality("minute", "minutes"),
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "WARNING: Your Twitch authorisation token will expire " ~
                "in <l>%d %s</> at <l>%02d:%02d";
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
            "in <l>%d minutes</> at <l>%02d:%02d";
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
            if (reminderPoint >= 1.weeks) delay(plugin, &warnOnWeeksDg, untilPoint);
            else if (reminderPoint >= 1.days) delay(plugin, &warnOnDaysDg, untilPoint);
            else if (reminderPoint >= 1.hours) delay(plugin, &warnOnHoursDg, untilPoint);
            else /*if (reminderPoint >= 1.minutes)*/ delay(plugin, &warnOnMinutesDg, untilPoint);
        }
    }

    // Schedule quitting on expiry
    delay(plugin, &quitOnExpiry, trueExpiry);

    // Also announce once normally how much time is left
    if (trueExpiry >= 1.weeks) warnOnWeeksDg();
    else if (trueExpiry >= 1.days) warnOnDaysDg();
    else if (trueExpiry >= 1.hours) warnOnHoursDg();
    else /*if (trueExpiry >= 1.minutes)*/ warnOnMinutesDg();
}


// appendToStreamHistory
/++
    Appends a [TwitchPlugin.Room.Stream|Stream] to the history file.

    Params:
        plugin = The current [TwitchPlugin].
        stream = The (presumably ended) stream to save to record.
 +/
void appendToStreamHistory(TwitchPlugin plugin, const TwitchPlugin.Room.Stream stream)
{
    import lu.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.streamHistoryFile);
    json.array ~= stream.toJSON();
    json.save(plugin.streamHistoryFile);
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
        plugin.persistentWorkerTid.send(ThreadMessage.teardown);
    }

    if (plugin.twitchSettings.ecount && plugin.ecount.length)
    {
        // Might as well always save on exit. Ignore dirty flag.
        saveResourceToDisk(plugin.ecount, plugin.ecountFile);
    }

    if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
    {
        // As above
        saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
    }
}


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] and modifies the
    sender and target class based on their badges (and the current settings).

    Additionally embeds custom BTTV/FrankerFaceZ/7tv emotes into the event.
 +/
void postprocess(TwitchPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;

    if ((plugin.twitchSettings.fakeChannelFromQueries) && (event.type == IRCEvent.Type.QUERY))
    {
        alias pred = (homeChannelEntry, senderNickname) => (homeChannelEntry[1..$] == senderNickname);

        if (plugin.state.bot.homeChannels.canFind!pred(event.sender.nickname))
        {
            event.type = IRCEvent.Type.CHAN;
            event.channel = '#' ~ event.sender.nickname;
        }
    }
    else if (!event.sender.nickname.length || !event.channel.length)
    {
        return;
    }

    immutable eventCanContainEmotes = event.content.length &&
        event.type.among!(IRCEvent.Type.CHAN, IRCEvent.Type.EMOTE);

    version(TwitchCustomEmotesEverywhere)
    {
        if (eventCanContainEmotes)
        {
            // No checks needed
            if (const customEmotes = event.channel in plugin.customEmotesByChannel)
            {
                embedCustomEmotes(event, *customEmotes, plugin.customGlobalEmotes);
            }
        }
    }
    else
    {
        // Only embed if the event is in a home channel
        immutable isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel);

        if (isHomeChannel && eventCanContainEmotes)
        {
            if (const customEmotes = event.channel in plugin.customEmotesByChannel)
            {
                embedCustomEmotes(event, *customEmotes, plugin.customGlobalEmotes);
            }
        }
    }

    version(TwitchPromoteEverywhere)
    {
        // No checks needed
    }
    else
    {
        version(TwitchCustomEmotesEverywhere)
        {
            import std.algorithm.searching : canFind;

            // isHomeChannel only defined if version not TwitchCustomEmotesEverywhere
            immutable isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel);
        }

        if (!isHomeChannel) return;
    }

    static void postprocessImpl(
        const TwitchPlugin plugin,
        const ref IRCEvent event,
        ref IRCUser user)
    {
        import std.string : indexOf;

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
                (user.badges.indexOf("moderator/") != -1))
            {
                // User is moderator but is not registered as at least operator
                user.class_ = IRCUser.Class.operator;
                return;
            }
        }

        if (plugin.twitchSettings.promoteVIPs)
        {
            if ((user.class_ < IRCUser.Class.elevated) &&
                (user.badges.indexOf("vip/") != -1))
            {
                // User is VIP but is not registered as at least elevated
                user.class_ = IRCUser.Class.elevated;
                return;
            }
        }

        // There is no "registered" list; just map subscribers to registered 1:1
        if ((user.class_ < IRCUser.Class.registered) &&
            (user.badges.indexOf("subscriber/") != -1))
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
    import std.file : exists, mkdir;
    import std.json : JSONException, JSONType;
    import std.path : dirName;

    void loadFile(
        const string fileDescription,
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
                fileDescription ~ " file is malformed",
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
    JSONStorage historyJSON;

    // Ensure the subdirectory exists
    immutable subdir = plugin.ecountFile.dirName;
    if (!subdir.exists) mkdir(subdir);

    loadFile("ecount", ecountJSON, plugin.ecountFile);
    loadFile("Viewers", viewersJSON, plugin.viewersFile);
    loadFile("Secrets", secretsJSON, plugin.secretsFile);
    loadFile("Stream history", historyJSON, plugin.streamHistoryFile);

    if (historyJSON.type != JSONType.array) historyJSON.array = null;  // coerce to array if needed

    ecountJSON.save(plugin.ecountFile);
    viewersJSON.save(plugin.viewersFile);
    secretsJSON.save(plugin.secretsFile);
    historyJSON.save(plugin.streamHistoryFile);
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
void saveResourceToDisk(/*const*/ RehashingAA!(string, long)[string] aa, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File;

    long[string][string] tempAA;

    foreach (immutable channelName, rehashingAA; aa)
    {
        tempAA[channelName] = rehashingAA.aaOf;
    }

    immutable json = JSONValue(tempAA);
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
    import std.stdio : File;

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


// loadResources
/++
    Loads all resources from disk.
 +/
void loadResources(TwitchPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage ecountJSON;
    long[string][string] tempEcount;
    ecountJSON.load(plugin.ecountFile);
    tempEcount.populateFromJSON(ecountJSON);
    plugin.ecount = null;

    foreach (immutable channelName, channelCounts; tempEcount)
    {
        plugin.ecount[channelName] = RehashingAA!(string, long)(channelCounts);
    }

    JSONStorage viewersJSON;
    long[string][string] tempViewers;
    viewersJSON.load(plugin.viewersFile);
    tempViewers.populateFromJSON(viewersJSON);
    plugin.viewerTimesByChannel = null;

    foreach (immutable channelName, channelViewers; tempViewers)
    {
        plugin.viewerTimesByChannel[channelName] = RehashingAA!(string, long)(channelViewers);
    }

    JSONStorage secretsJSON;
    secretsJSON.load(plugin.secretsFile);
    plugin.secretsByChannel = null;

    foreach (immutable channelName, credsJSON; secretsJSON.storage.object)
    {
        plugin.secretsByChannel[channelName] = Credentials.fromJSON(credsJSON);
    }

    plugin.secretsByChannel = plugin.secretsByChannel.rehash();
}


// reload
/++
    Reloads the plugin, loading resources from disk and re-importing custom emotes.
 +/
void reload(TwitchPlugin plugin)
{
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;

    loadResources(plugin);

    void importDg()
    {
        plugin.customGlobalEmotes = null;
        importCustomGlobalEmotes(plugin);

        foreach (immutable channelName, const room; plugin.rooms)
        {
            plugin.customEmotesByChannel.remove(channelName);
            importCustomEmotes(plugin, channelName, room.id);
        }
    }

    Fiber importFiber = new Fiber(&importDg, BufferSize.fiberStack);
    importFiber.call();
}


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
    import std.datetime.systime : SysTime;

package:
    /++
        Contained state of a channel, so that there can be several alongside each other.
     +/
    static struct Room
    {
    private:
        /++
            A unique ID for this instance of a room.
         +/
        uint _uniqueID;

    public:
        /++
            Representation of a broadcast (stream).
         +/
        static struct Stream
        {
        private:
            import std.json : JSONValue;

            /++
                The unique ID of a stream, as supplied by Twitch.

                Cannot be made immutable or generated `opAssign`s break.
             +/
            /*immutable*/ string _idString;

        package:
            /++
                Whether or not the stream is currently ongoing.
             +/
            bool live; // = false;

            /++
                The numerical ID of the user/account of the channel owner. In string form.
             +/
            string userIDString;

            /++
                The user/account name of the channel owner.
             +/
            string userLogin;

            /++
                The display name of the channel owner.
             +/
            string userDisplayName;

            /++
                The unique ID of a game, as supplied by Twitch. In string form.
             +/
            string gameIDString;

            /++
                The name of the game that's being streamed.
             +/
            string gameName;

            /++
                The title of the stream.
             +/
            string title;

            /++
                Stream tags.
             +/
            string[] tags;

            /++
                When the stream started.
             +/
            SysTime startTime;

            /++
                When the stream ended.
             +/
            SysTime stopTime;

            /++
                How many people were viewing the stream the last time the monitor
                [core.thread.fiber.Fiber|Fiber] checked.
             +/
            long numViewers;

            /++
                The maximum number of people seen watching this stream.
             +/
            long numViewersMax;

            /++
                Users seen in the channel.
             +/
            RehashingAA!(string, bool) chattersSeen;

            /++
                Hashmap of active viewers (who have shown activity).
             +/
            RehashingAA!(string, bool) activeViewers;

            /++
                Accessor to [_idString].

                Returns:
                    This stream's ID, as reported by Twitch, in string form.
             +/
            auto idString() const
            {
                return _idString;
            }

            /++
                Takes a second [Stream] and updates this one with values from it.

                Params:
                    updated =  A second [Stream] from which to inherit values.
             +/
            void update(const Stream updated)
            {
                assert(_idString.length, "Stream not properly initialised");

                this.userDisplayName = updated.userDisplayName;
                this.gameIDString = updated.gameIDString;
                this.gameName = updated.gameName;
                this.title = updated.title;
                this.numViewers = updated.numViewers;
                this.tags = updated.tags.dup;

                if (this.numViewers > this.numViewersMax)
                {
                    this.numViewersMax = this.numViewers;
                }
            }

            /++
                Constructor.

                Params:
                    idString = This stream's ID, as reported by Twitch, in string form.
             +/
            this(const string idString) pure @safe nothrow @nogc
            {
                this._idString = idString;
            }

            /++
                Serialises this [Stream] into a JSON representation.

                Returns:
                    A [std.json.JSONValue|JSONValue] that represents this [Stream].
             +/
            auto toJSON() const
            {
                JSONValue json;
                json = null;
                json.object = null;

                json["idString"] = JSONValue(this._idString);
                json["gameIDString"] = JSONValue(this.gameIDString);
                json["gameName"] = JSONValue(this.gameName);
                json["title"] = JSONValue(this.title);
                json["startTimeUnix"] = JSONValue(this.startTime.toUnixTime());
                json["stopTimeUnix"] = JSONValue(this.stopTime.toUnixTime());
                json["numViewersMax"] = JSONValue(this.numViewersMax);
                json["tags"] = JSONValue(this.tags);
                return json;
            }

            /++
                Deserialises a [Stream] from a JSON representation.

                Params:
                    json = [std.json.JSONValue|JSONValue] to build a [Stream] from.

                Returns:
                    A new [Stream] with values from the passed `json`.
             +/
            static auto fromJSON(const JSONValue json)
            {
                import std.algorithm.iteration : map;
                import std.array : array;

                if ("idString" !in json)
                {
                    // Invalid entry
                    enum message = "No `idString` key in Stream JSON representation";
                    throw new UnexpectedJSONException(message);
                }

                auto stream = Stream(json["idString"].str);
                stream.gameIDString = json["gameIDString"].str;
                stream.gameName = json["gameName"].str;
                stream.title = json["title"].str;
                stream.startTime = SysTime.fromUnixTime(json["startTimeUnix"].integer);
                stream.stopTime = SysTime.fromUnixTime(json["stopTimeUnix"].integer);
                stream.tags = json["tags"].array
                    .map!(tag => tag.str)
                    .array;

                if (const numViewersMaxJSON = "numViewersMax" in json)
                {
                    stream.numViewersMax = numViewersMaxJSON.integer;
                }
                else
                {
                    // Legacy
                    stream.numViewersMax = json["maxViewerCount"].integer;
                }

                return stream;
            }
        }

        /++
            Constructor taking a string (channel) name.

            Params:
                channelName = Name of the channel.
         +/
        this(const string channelName) /*pure nothrow @nogc*/ @safe
        {
            import std.random : uniform;

            this.channelName = channelName;
            this.broadcasterName = channelName[1..$];
            this.broadcasterDisplayName = this.broadcasterName;  // until we resolve it
            this._uniqueID = uniform(1, uint.max);
        }

        /++
            Accessor to [_uniqueID].

            Returns:
                A unique ID, in the form of the value of `_uniqueID`.
         +/
        auto uniqueID() const
        {
            assert((_uniqueID > 0), "Room not properly initialised");
            return _uniqueID;
        }

        /++
            Name of the channel.
         +/
        string channelName;

        /++
            The current, ongoing stream.
         +/
        Stream stream;

        /++
            Account name of the broadcaster.
         +/
        string broadcasterName;

        /++
            Display name of the broadcaster.
         +/
        string broadcasterDisplayName;

        /++
            Broadcaster user/account/room ID (not name).
         +/
        string id;

        /++
            A JSON list of the followers of the channel.
         +/
        Follow[string] follows;

        /++
            UNIX timestamp of when [follows] was last cached.
         +/
        long followsLastCached;

        /++
            How many messages to keep in memory, to allow for nuking.
         +/
        enum messageMemory = 128;

        /++
            The last n messages sent in the channel, used by `nuke`.
         +/
        CircularBuffer!(IRCEvent, No.dynamic, messageMemory) lastNMessages;

        /++
            Song request history; UNIX timestamps keyed by nickname.
         +/
        long[string] songrequestHistory;

        /++
            Set when we see a [dialect.defs.IRCEvent.Type.USERSTATE|USERSTATE]
            upon joining the channel.
         +/
        bool sawUserstate;
    }

    /++
        All Twitch plugin settings.
     +/
    TwitchSettings twitchSettings;

    /++
        Array of active bot channels' state.
     +/
    Room[string] rooms;

    /++
        Custom channel-specific BetterTTV, FrankerFaceZ and 7tv emotes, as
        fetched via API calls.
     +/
    bool[dstring][string] customEmotesByChannel;

    /++
        Custom global BetterTTV, FrankerFaceZ and 7tv emotes, as fetched via API calls.
     +/
    bool[dstring] customGlobalEmotes;

    /++
        Effective bell after [kameloso.terminal.isTerminal] checks.
     +/
    static string bell = "" ~ cast(char)(TerminalToken.bell);

    /++
        The Twitch application ID for the kameloso bot.
     +/
    enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";

    /++
        Authorisation token for the "Authorization: Bearer <token>".
     +/
    string authorizationBearer;

    /++
        The bot's numeric account/ID.
     +/
    string botUserIDString;

    /++
        How long a Twitch HTTP query usually takes.

        It tries its best to self-balance the number based on how long queries
        actually take. Start off conservatively.
     +/
    long approximateQueryTime = 700;

    // QueryConstants
    /++
        Constants used when scheduling API queries.
     +/
    enum QueryConstants : double
    {
        /++
            The multiplier of how much the query time should temporarily increase
            when it turned out to be a bit short.
         +/
        growthMultiplier = 1.1,

        /++
            The divisor of how much to wait before retrying a query, after the
            timed waited turned out to be a bit short.
         +/
        retryTimeDivisor = 3,

        /++
            By how many milliseconds to pad measurements of how long a query took
            to be on the conservative side.
         +/
        measurementPadding = 30,

        /++
            The weight to assign the current approximate query time before
            making a weighted average based on a new value. This gives the
            averaging some inertia.
         +/
        averagingWeight = 3,
    }

    /++
        How many times to retry a Twitch server query.
     +/
    enum delegateRetries = 10;

    /++
        Associative array of viewer times; seconds keyed by nickname keyed by channel.
     +/
    RehashingAA!(string, long)[string] viewerTimesByChannel;

    /++
        Whether or not [viewerTimesByChannel] has been modified and there's a
        point in saving it to disk.
     +/
    bool viewerTimesDirty;

    /++
        API keys and tokens, keyed by channel.
     +/
    Credentials[string] secretsByChannel;

    /++
        The thread ID of the persistent worker thread.
     +/
    Tid persistentWorkerTid;

    /++
        Associative array of responses from async HTTP queries.
     +/
    shared QueryResponse[int] bucket;

    @Resource("twitch")
    {
        /++
            File to save emote counters to.
         +/
        string ecountFile = "ecount.json";

        /++
            File to save viewer times to.
         +/
        string viewersFile = "viewers.json";

        /++
            File to save API keys and tokens to.
         +/
        string secretsFile = "secrets.json";

        /++
            File to save stream history to.
         +/
        string streamHistoryFile = "history.json";
    }

    /++
        Emote counters associative array; counter longs keyed by emote ID string keyed by channel.
     +/
    RehashingAA!(string, long)[string] ecount;

    /++
        Whether or not [ecount] has been modified and there's a point in saving it to disk.
     +/
    bool ecountDirty;

    // isEnabled
    /++
        Override
        [kameloso.plugins.common.core.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.common.core.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
        and inject a server check, so this plugin only works on Twitch, in addition
        to doing nothing when [TwitchSettings.enabled] is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    override public bool isEnabled() const pure nothrow @nogc
    {
        return (
            (state.server.daemon == IRCServer.Daemon.twitch) ||
            (state.server.daemon == IRCServer.Daemon.unset)) &&
            (twitchSettings.enabled ||
                twitchSettings.keygen ||
                twitchSettings.superKeygen ||
                twitchSettings.googleKeygen ||
                twitchSettings.youtubeKeygen ||
                twitchSettings.spotifyKeygen);
    }

    mixin IRCPluginImpl;
}

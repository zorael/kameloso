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
            Whether or not to start a terminal wizard requesting a Twitch
            access token with normal chat privileges.
         +/
        bool keygen = false;

        /++
            Whether or not to start a terminal wizard requesting a Twitch
            access token with broadcaster privileges.
         +/
        bool superKeygen = false;

        /++
            Whether or not to start a terminal wizard requesting Google
            access tokens.
         +/
        bool googleKeygen = false;

        /++
            Runtime "alias" to [googleKeygen].
         +/
        bool youtubeKeygen = false;

        /++
            Whether or not to start a terminal wizard requesting Spotify
            access tokens.
         +/
        bool spotifyKeygen = false;

        /++
            Whether or not to import custom emotes.
         +/
        bool customEmotes = true;
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
import kameloso.thread : Sendable;
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
        Broadcaster-level full Bearer token.
     +/
    string broadcasterBearerToken;

    /++
        Broadcaster-level token expiry timestamp.
     +/
    long broadcasterKeyExpiry;

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
        json["broadcasterBearerToken"] = this.broadcasterBearerToken;
        json["broadcasterKeyExpiry"] = this.broadcasterKeyExpiry;
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

        if (const broadcasterBearerToken = "broadcasterBearerToken" in json)
        {
            // New field, be conservative for a few releases
            creds.broadcasterBearerToken = broadcasterBearerToken.str;
        }

        if (const broadcasterExpiry = "broadcasterKeyExpiry" in json)
        {
            // New field, be conservative for a few releases
            creds.broadcasterKeyExpiry = broadcasterExpiry.integer;
        }

        return creds;
    }
}


// Follower
/++
    Embodiment of the notion of someone following someone else on Twitch.

    This cannot be a Voldemort type inside [kameloso.plugins.twitch.api.getFollowers|getFollowers]
    since we need an array of them inside [TwitchPlugin.Room].
 +/
package struct Follower
{
private:
    import std.datetime.systime : SysTime;

public:
    /++
        Display name of follower.
     +/
    string displayName;

    /++
        Account name of follower.
     +/
    string login;

    /++
        Time when the follow action took place.
     +/
    SysTime when;

    /++
        Twitch numerical ID of follower.
     +/
    uint id;

    // fromJSON
    /++
        Constructs a [Follower] from a JSON representation.

        Params:
            json = JSON representation of a follower.

        Returns:
            A new [Follower] with values derived from the passed JSON.
     +/
    static auto fromJSON(const JSONValue json)
    {
        import std.conv : to;

        /+
        {
            "user_id": "11111",
            "user_name": "UserDisplayName",
            "user_login": "userloginname",
            "followed_at": "2022-05-24T22:22:08Z",
        },
         +/

        Follower follower;
        follower.id = json["user_id"].str.to!uint;
        follower.displayName = json["user_name"].str;
        follower.login = json["user_login"].str;
        follower.when = SysTime.fromISOExtString(json["followed_at"].str);
        return follower;
    }
}


// Mixins
mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;
mixin PluginRegistration!(TwitchPlugin, -5.priority);


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
    .onEvent(IRCEvent.Type.SELFCHAN)
    .onEvent(IRCEvent.Type.SELFEMOTE)
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

        write(plugin.transient.bell);
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

        auto channelcount = event.channel in plugin.ecount;

        foreach (immutable emotestring; event.emotes.splitter('/'))
        {
            if (!emotestring.length) continue;

            if (!channelcount)
            {
                plugin.ecount[event.channel] = RehashingAA!(string, long).init;
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
            plugin.transient.ecountDirty = true;
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
        write(plugin.transient.bell);
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
void onSelfjoin(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    const room = event.channel in plugin.rooms;
    if (!room)
    {
        // To be expected but may have been initialised elsewhere due to race
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
    plugin.rooms[channelName].lastNMessages.resize(TwitchPlugin.Room.messageMemory);
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
void onUserstate(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
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
    import kameloso.plugins.twitch.emotes : importCustomEmotes;

    // dialect sets the display name during parsing
    //assert(plugin.state.client.displayName == event.target.displayName);
    importCustomEmotes(plugin);
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
            cast(uint)previousStream.stopTime.month,
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
            cast(uint)previousStream.stopTime.month,
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
        [kameloso.plugins.twitch.api.getFollowers]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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
    import std.algorithm.comparison : among;
    import std.algorithm.searching : startsWith;

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to look up follow age in a nonexistent room");

    string slice = event.content.stripped;  // mutable
    if ((slice.length) && (slice[0] == '@')) slice = slice[1..$];

    immutable otherNameSpecified = slice.length &&
        !slice.among(event.sender.nickname, event.sender.displayName);

    void sendNoSuchUser(const string name)
    {
        immutable message = "No such user: " ~ name;
        chan(plugin.state, event.channel, message);
    }

    void reportFollowAge(const Follower follower)
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
        immutable delta = (Clock.currTime - follower.when);
        immutable timeline = delta.timeSince!(7, 3);
        immutable datestamp = datestampPattern.format(
            months[cast(uint)follower.when.month-1],
            follower.when.year);

        if (otherNameSpecified)
        {
            enum pattern = "%s has been a follower for %s, since %s.";
            immutable message = pattern.format(follower.displayName, timeline, datestamp);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum pattern = "You have been a follower for %s, since %s.";
            immutable message = pattern.format(timeline, datestamp);
            chan(plugin.state, event.channel, message);
        }
    }

    void reportNotAFollower(const string name)
    {
        if (otherNameSpecified)
        {
            import std.format : format;

            immutable user = getTwitchUser(plugin, name, 0, Yes.searchByDisplayName);
            if (!user.nickname.length) return sendNoSuchUser(name);

            enum pattern = "%s is currently not a follower.";
            immutable message = pattern.format(user.displayName);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            // Assume the user is asking about itself
            enum message = "You are currently not a follower.";
            chan(plugin.state, event.channel, message);
        }
    }

    auto reportFromCache(const string name)
    {
        if (const follower = name in room.followers)
        {
            reportFollowAge(*follower);
            return true;
        }

        foreach (const follower; room.followers.byValue)
        {
            // No need to check key or login property

            if (follower.displayName == name)
            {
                reportFollowAge(follower);
                return true;
            }
        }

        return false;
    }

    if (!room.followers.length)
    {
        // Followers have not yet been cached!
        // This can technically happen, though practically the caching is
        // done immediately after joining so there should be no time for
        // !followage queries to sneak in.
        // Luckily we're inside a fiber so we can cache it ourselves.
        room.followers = getFollowers(plugin, room.id);
        room.followersLastCached = event.time;
    }

    immutable name = slice.length ?
        slice :
        event.sender.nickname;

    bool found = reportFromCache(name);  // mutable for reuse
    if (found) return;

    enum minimumSecondsBetweenRecaches = 10;

    if (event.time > (room.followersLastCached + minimumSecondsBetweenRecaches))
    {
        // No match, but minimumSecondsBetweenRecaches passed since last recache
        room.followers = getFollowers(plugin, room.id);
        room.followersLastCached = event.time;
        found = reportFromCache(name);
        if (found) return;
    }

    // No matches and/or not enough time has passed since last recache
    return reportNotAFollower(name);
}


// onRoomState
/++
    Records the room ID of a home channel, and queries the Twitch servers for
    the display name of its broadcaster.

    Fetches custom BetterTV, FrankerFaceZ and 7tv emotes for the channel.

    Validates any broadcaster-level access tokens and displays an error if it has expired.

    Sets up reminders about when the broadcaster-level token will expire.
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
    import std.conv : to;

    auto room = event.channel in plugin.rooms;
    if (!room)
    {
        // Race...
        initRoom(plugin, event.channel);
        room = event.channel in plugin.rooms;
    }
    else
    {
        if (room.id) return;  // Already initialised? Double roomstate?
    }

    room.id = event.aux[0].to!uint;  // Assign this before spending time in getTwitchUser

    /+
        Fetch the broadcaster's Twitch user through an API call and store it as
        a new IRCUser in the plugin.state.users AA, including its display name.
        Additionally send the user to other plugins by way of a concurrency message.
     +/
    auto twitchUser = getTwitchUser(plugin, string.init, room.id);
    if (!twitchUser.nickname.length) return;  // No such user? Something is deeply wrong

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
        newUser.displayName = twitchUser.displayName;
        newUser.id = twitchUser.id;
        plugin.state.users[newUser.nickname] = newUser;
        storedUser = newUser.nickname in plugin.state.users;
    }

    IRCUser userCopy = *storedUser;  // dereference and blit
    plugin.state.mainThread.send(ThreadMessage.putUser(string.init, boxed(userCopy)));

    /+
        Start room monitors for the chanenl. We can assume they have not already
        been started, as room was either null or room.id was set above.
     +/
    startRoomMonitors(plugin, event.channel);

    if (plugin.twitchSettings.customEmotes)
    {
        import kameloso.plugins.common.delayawait : delay;
        import kameloso.constants : BufferSize;
        import core.time : Duration;

        void importEmotesDg()
        {
            import kameloso.plugins.twitch.emotes : importCustomEmotes;
            importCustomEmotes(plugin, event.channel, room.id);
        }

        /+
            Custom emote import may take a long time, so delay it as a fiber to
            defer invocation and avoid blocking here.
         +/
        Fiber importEmotesFiber = new Fiber(&importEmotesDg, BufferSize.fiberStack);
        delay(plugin, importEmotesFiber, Duration.zero);
    }

    auto creds = event.channel in plugin.secretsByChannel;

    if (creds && creds.broadcasterKey.length)
    {
        void onExpiryDg()
        {
            enum pattern = "The broadcaster-level access token for channel <l>%s</> has expired. " ~
                "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
            logger.errorf(pattern, event.channel);
            creds.broadcasterKey = string.init;
            creds.broadcasterBearerToken = string.init;
            //creds.broadcasterKeyExpiry = 0;  // keep it for reference
            saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
        }

        try
        {
            import std.datetime.systime : SysTime;
            generateExpiryReminders(
                plugin,
                SysTime.fromUnixTime(creds.broadcasterKeyExpiry),
                "The broadcaster-level authorisation token for channel <l>" ~ event.channel ~ "</>",
                &onExpiryDg);
        }
        catch (InvalidCredentialsException _)
        {
            onExpiryDg();
        }
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
    import kameloso.plugins.twitch.emotes : importCustomEmotes;
    import std.conv : to;

    if (!plugin.twitchSettings.customEmotes) return;

    if (event.channel in plugin.customEmotesByChannel)
    {
        // Already done
        return;
    }

    importCustomEmotes(plugin, event.channel, event.aux[0].to!uint);
}


// onCommandShoutout
/++
    Emits a shoutout to another streamer.

    Merely gives a link to their channel and echoes what game they last streamed
    (or are currently streaming).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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

    with (typeof(shoutout).ShoutoutState)
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
    .onEvent(IRCEvent.Type.SELFCHAN)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
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
void onCommandVanish(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    try
    {
        cast(void)timeoutUser(plugin, event.channel, event.sender.id, 1);
    }
    catch (ErrorJSONException e)
    {
        import kameloso.plugins.common : nameOf;
        enum pattern = "Failed to vanish <h>%s</> in <l>%s</> <t>(%s)";
        logger.warningf(pattern, nameOf(event.sender), event.channel, e.msg);
    }
}


// onCommandRepeat
/++
    Repeats a given message n number of times.

    Requires moderator privileges to work correctly.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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


// onCommandSubs
/++
    Reports the number of subscribers of the current channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("subs")
            .policy(PrefixPolicy.prefixed)
            .description("Reports the number of subscribers of the current channel.")
    )
)
void onCommandSubs(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.format : format;

    const room = event.channel in plugin.rooms;
    assert(room, "Tried to get the subscriber count of a channel for which there existed no room");

    try
    {
        enum pattern = "%s has %d subscribers.";
        const subs = getSubscribers(plugin, event.channel, Yes.totalOnly);
        immutable message = pattern.format(room.broadcasterDisplayName, subs[0].total);
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
    }
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
        const poll = createPoll(plugin, event.channel, title, durationString, choices);
        enum pattern = `Poll "%s" created.`;
        immutable message = pattern.format(poll.title);
        chan(plugin.state, event.channel, message);
    }
    catch (ErrorJSONException e)
    {
        import std.algorithm.searching : endsWith;

        if (e.msg.endsWith("is not a partner or affiliate"))
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
            throw e;
        }
    }
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
    }
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
        const polls = getPolls(plugin, event.channel);

        if (!polls.length)
        {
            enum message = "There are no active polls to end.";
            return chan(plugin.state, event.channel, message);
        }

        const endedPoll = endPoll(
            plugin,
            event.channel,
            polls[0].pollID,
            Yes.terminate);

        alias Status = typeof(endedPoll.status);

        if (endedPoll.status != Status.active)
        {
            import lu.conv : Enum;
            import std.format : format;

            enum pattern = "Poll ended; status %s";
            immutable message = pattern.format(Enum!Status.toString(endedPoll.status));
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum message = "Failed to end poll; status remains active";
            chan(plugin.state, event.channel, message);
        }
    }
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
    }
}


// onCommandNuke
/++
    Deletes recent messages containing a supplied word or phrase.

    Must be placed after [onAnyMessage] in the chain.

    See_Also:
        [TwitchPlugin.Room.lastNMessages]

        https://dev.twitch.tv/docs/api/reference/#delete-chat-messages
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("nuke")
            .policy(PrefixPolicy.prefixed)
            .description("Deletes recent messages containing a supplied word or phrase.")
            .addSyntax("$command [word or phrase]")
    )
)
void onCommandNuke(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : plurality, stripped, unquoted;
    import std.uni : toLower;

    void sendUsage()
    {
        import std.format : format;
        enum pattern = "Usage: %s%s [word or phrase]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length) return sendUsage();

    immutable phraseToLower = event.content
        .stripped
        .unquoted
        .toLower;
    if (!phraseToLower.length) return sendUsage();

    auto deleteEvent(const ref IRCEvent storedEvent)
    {
        version(PrintStacktraces)
        void printStacktrace(Exception e)
        {
            if (!plugin.state.settings.headless)
            {
                import std.stdio : stdout, writeln;
                writeln(e);
                stdout.flush();
            }
        }

        try
        {
            immutable response = deleteMessage(plugin, event.channel, storedEvent.id);

            if ((response.code >= 200) && (response.code < 300))
            {
                return true;
            }
            else
            {
                import kameloso.plugins.common : nameOf;

                enum pattern = "Failed to delete a message from <h>%s</> in <l>%s";
                logger.warningf(pattern, nameOf(storedEvent.sender), event.channel);

                version(PrintStacktraces)
                {
                    import std.stdio : stdout, writeln;
                    writeln(response.str);
                    writeln("code: ", response.code);
                    stdout.flush();
                }
                return false;
            }
        }
        /*catch (ErrorJSONException e)
        {
            if (e.json["message"].str == "You cannot delete the broadcaster's messages.")
            {
                // Should never happen as we filter by class_ before calling this...
                return true;
            }

            version(PrintStacktraces) printStacktrace(e);
            return false;
        }*/
        catch (Exception e)
        {
            version(PrintStacktraces) printStacktrace(e);
            return false;
        }
    }

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to nuke a word in a nonexistent room");

    uint numDeleted;

    foreach (ref IRCEvent storedEvent; room.lastNMessages)  // explicit IRCEvent required on lu <2.0.1
    {
        import std.algorithm.searching : canFind;
        import std.uni : asLowerCase;

        if (!storedEvent.id.length || (storedEvent.id == event.id)) continue;  // delete command event separately
        if (storedEvent.sender.class_ >= IRCUser.Class.operator) continue;  // DON'T nuke moderators

        if (storedEvent.content.asLowerCase.canFind(phraseToLower))
        {
            immutable success = deleteEvent(storedEvent);

            if (success)
            {
                storedEvent = IRCEvent.init;
                ++numDeleted;
            }
        }
    }

    if (numDeleted > 0)
    {
        // Delete the command event itself
        // Do it from within a foreach so we can clear the event by ref
        foreach (ref IRCEvent storedEvent; room.lastNMessages)  // as above
        {
            if (storedEvent.id != event.id) continue;

            immutable success = deleteEvent(storedEvent);

            if (success)
            {
                storedEvent = IRCEvent.init;
                //++numDeleted;  // Don't include in final count
            }
            break;
        }
    }

    enum pattern = "Deleted <l>%d</> %s containing \"<l>%s</>\"";
    immutable messageWord = numDeleted.plurality("message", "messages");
    logger.infof(pattern, numDeleted, messageWord, event.content.stripped);
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
    import std.algorithm.searching : startsWith;
    import std.concurrency : spawn;

    // Concatenate the Bearer and OAuth headers once.
    // This has to be done *after* connect's register
    immutable pass = plugin.state.bot.pass.startsWith("oauth:") ?
        plugin.state.bot.pass[6..$] :
        plugin.state.bot.pass;
    plugin.transient.authorizationBearer = "Bearer " ~ pass;

    // Initialise the bucket, just so that it isn't null
    plugin.responseBucket[0] = QueryResponse.init;
    plugin.responseBucket.remove(0);

    // Spawn the persistent worker.
    plugin.transient.persistentWorkerTid = spawn(
        &persistentQuerier,
        plugin.responseBucket,
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
        enum message = "That is not a (known) Twitch, BetterTTV, FrankerFaceZ or 7tv emote.";
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
    .onEvent(IRCEvent.Type.SELFCHAN)
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
        immutable user = getTwitchUser(plugin, givenName, 0, Yes.searchByDisplayName);

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
        [kameloso.plugins.twitch.api.setChannelTitle]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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
        setChannelTitle(plugin, event.channel, title);
        enum pattern = "Channel title set to: %s";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
    }
}


// onCommandSetGame
/++
    Changes the game of the current channel.

    See_Also:
        [kameloso.plugins.twitch.api.setChannelGame]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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
    import std.conv : to;
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
    immutable numberSupplied = (specified.length && specified.isNumeric);
    uint gameID = numberSupplied ? specified.to!uint : 0;  // mutable

    try
    {
        string name;  // mutable

        if (!numberSupplied)
        {
            immutable gameInfo = getTwitchGame(plugin, specified.encodeComponent);
            gameID = gameInfo.id;
            name = gameInfo.name;
        }
        else if (gameID == 0)
        {
            name = "(unset)";
        }
        else /*if (id.length)*/
        {
            immutable gameInfo = getTwitchGame(plugin, string.init, gameID);
            name = gameInfo.name;
        }

        setChannelGame(plugin, event.channel, gameID);
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
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
    }
}


// onCommandCommercial
/++
    Starts a commercial in the current channel.

    Note: Experimental, since we cannot try it out ourselves.

    See_Also:
        [kameloso.plugins.twitch.api.startCommercial]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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

    void sendNoOngoingStream()
    {
        enum message = "There is no ongoing stream.";
        chan(plugin.state, event.channel, message);
    }

    const room = event.channel in plugin.rooms;
    assert(room, "Tried to start a commercial in a nonexistent room");

    if (!room.stream.live) return sendNoOngoingStream();

    if (!lengthString.among!("30", "60", "90", "120", "150", "180"))
    {
        enum message = "Commercial duration must be one of 30, 60, 90, 120, 150 or 180.";
        return chan(plugin.state, event.channel, message);
    }

    try
    {
        startCommercial(plugin, event.channel, lengthString);
    }
    catch (ErrorJSONException e)
    {
        import std.algorithm.searching : endsWith;

        if (e.msg.endsWith("To start a commercial, the broadcaster must be streaming live."))
        {
            return sendNoOngoingStream();
        }
        else
        {
            throw e;
        }
    }
    catch (MissingBroadcasterTokenException e)
    {
        complainAboutMissingTokens(e);
    }
    catch (InvalidCredentialsException e)
    {
        complainAboutMissingTokens(e);
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


// initialise
/++
    Start any key generation terminal wizard(s) before connecting to the server.
 +/
void initialise(TwitchPlugin plugin)
{
    import kameloso.plugins.common.misc : IRCPluginInitialisationException;
    import kameloso.terminal : isTerminal;
    import std.algorithm.searching : endsWith;

    if (!isTerminal)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.transient.bell = string.init;
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
            // Headless mode is enabled, so a terminal wizard doesn't make sense
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
    Sets up a fiber to periodically cache followers.

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


// startRoomMonitors
/++
    Starts room monitors as [core.thread.fiber.Fiber|Fiber]s for a given channel.

    These detect new streams (and updates ongoing ones), updates chatters, and caches followers.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = String key of room to start the monitors of.
 +/
void startRoomMonitors(TwitchPlugin plugin, const string channelName)
in (channelName.length, "Tried to start room monitor with an empty channel name string")
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import std.datetime.systime : Clock;
    import core.time : Duration, MonoTime, hours, seconds;

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

                        plugin.transient.viewerTimesDirty = true;
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

        void reportCurrentGame(const TwitchPlugin.Room.Stream stream)
        {
            if (stream.gameID != 0)
            {
                enum pattern = "Current game: <l>%s";
                logger.logf(pattern, stream.gameName);
            }
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

                if (!streamFromServer.id)  // == TwitchPlugin.Room.Stream.init)
                {
                    // Stream down
                    if (room.stream.live)
                    {
                        // Was up but just ended
                        closeStream(room);
                        rotateStream(room);
                        logger.info("Stream ended.");

                        if (plugin.twitchSettings.watchtime && plugin.transient.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.transient.viewerTimesDirty = false;
                        }
                    }
                }
                else
                {
                    // Stream up
                    if (!room.stream.id)
                    {
                        // New stream!
                        room.stream = streamFromServer;
                        logger.info("Stream started.");
                        reportCurrentGame(streamFromServer);

                        /*if (plugin.twitchSettings.watchtime && plugin.transient.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.transient.viewerTimesDirty = false;
                        }*/
                    }
                    else if (room.stream.id == streamFromServer.id)
                    {
                        // Same stream running, just update it
                        room.stream.update(streamFromServer);
                    }
                    else /*if (room.stream.id != streamFromServer.id)*/
                    {
                        // New stream, but stale one exists. Rotate and insert
                        closeStream(room);
                        rotateStream(room);
                        room.stream = streamFromServer;
                        logger.info("Stream change detected.");
                        reportCurrentGame(streamFromServer);

                        if (plugin.twitchSettings.watchtime && plugin.transient.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.transient.viewerTimesDirty = false;
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

    // Clear and re-cache followers once every midnight
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
                room.followers = getFollowers(plugin, room.id);
                room.followersLastCached = now.toUnixTime();
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, (now.nextMidnight - now), Yes.yield);
        }
    }

    Fiber uptimeMonitorFiber = new Fiber(&uptimeMonitorDg, BufferSize.fiberStack);
    Fiber chatterMonitorFiber = new Fiber(&chatterMonitorDg, BufferSize.fiberStack);
    Fiber cacheFollowersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);

    // Detach by delaying zero seconds
    delay(plugin, uptimeMonitorFiber, Duration.zero);
    delay(plugin, chatterMonitorFiber, Duration.zero);
    delay(plugin, cacheFollowersFiber, Duration.zero);
}


// startValidator
/++
    Starts a validator routine.

    This will validate the API access token and output to the terminal for how
    much longer it is valid. If it has expired, it will exit the program.

    Note: Must be called from within a [core.thread.Fiber.Fiber|Fiber].

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startValidator(TwitchPlugin plugin)
in (Fiber.getThis(), "Tried to call `startValidator` from outside a fiber")
{
    import kameloso.plugins.common.delayawait : delay;
    import std.conv : to;
    import std.datetime.systime : Clock, SysTime;
    import std.json : JSONValue;
    import core.time : minutes;

    static immutable retryDelay = 1.minutes;
    JSONValue validationJSON;

    while (!plugin.transient.botID)
    {
        try
        {
            validationJSON = getValidation(plugin, plugin.state.bot.pass, Yes.async);
        }
        catch (TwitchQueryException e)
        {
            if (plugin.state.settings.headless)
            {
                //version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, Yes.yield);
            }
            else
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
            }
            continue;
        }
        catch (EmptyResponseException e)
        {
            if (plugin.state.settings.headless)
            {
                //version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, Yes.yield);
            }
            else
            {
                // HTTP query failed; just retry
                enum pattern = "Failed to validate Twitch API keys: <t>%s</>";
                logger.errorf(pattern, e.msg);
                version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, Yes.yield);
            }
            continue;
        }

        const userIDJSON = "user_id" in validationJSON;
        if (!userIDJSON)
        {
            // No key in response?
            delay(plugin, retryDelay, Yes.yield);
            continue;
        }

        plugin.transient.botID = userIDJSON.str.to!uint;  // ensures while loop break
        //break;
    }

    // Validation successful
    /+
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
     +/

    enum expiryMessage = "Twitch authorisation token expired";
    immutable expiresIn = validationJSON["expires_in"].integer;
    immutable now = Clock.currTime;
    immutable expiresWhen = SysTime.fromUnixTime(now.toUnixTime() + expiresIn);

    if (plugin.state.settings.headless)
    {
        void onExpiryHeadlessDg()
        {
            quit(plugin.state, expiryMessage);
        }

        immutable delta = (expiresWhen - now);
        delay(plugin, &onExpiryHeadlessDg, delta);
    }
    else
    {
        void onExpiryDg()
        {
            enum message = "Your Twitch authorisation token has expired. " ~
                "Run the program with <l>--set twitch.keygen/> to generate a new one.";
            logger.error(message);
            quit(plugin.state, expiryMessage);
        }

        generateExpiryReminders(
            plugin,
            expiresWhen,
            "Your Twitch authorisation token",
            &onExpiryDg);
    }
}


// startSaver
/++
    Starts a saver routine.

    This will save resources to disk periodically.

    Note: Must be called from within a [core.thread.Fiber.Fiber|Fiber].

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startSaver(TwitchPlugin plugin)
in (Fiber.getThis(), "Tried to call `startSaver` from outside a fiber")
{
    import kameloso.plugins.common.delayawait : delay;
    import core.time : hours;

    // How often to save `ecount`s and viewer times, to ward against losing information to crashes.
    static immutable savePeriodicity = 2.hours;

    // Delay initially
    delay(plugin, savePeriodicity, Yes.yield);

    // Periodically save ecounts and viewer times
    while (true)
    {
        if (plugin.twitchSettings.ecount &&
            plugin.transient.ecountDirty &&
            plugin.ecount.length)
        {
            saveResourceToDisk(plugin.ecount, plugin.ecountFile);
            plugin.transient.ecountDirty = false;
        }

        /+
            Only save watchtimes if there's at least one broadcast currently ongoing.
            Since we save at broadcast stop there won't be anything new to save otherwise.
            +/
        if (plugin.twitchSettings.watchtime && plugin.transient.viewerTimesDirty)
        {
            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
            plugin.transient.viewerTimesDirty = false;
        }

        delay(plugin, savePeriodicity, Yes.yield);
    }
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


// promoteUserFromBadges
/++
    Infers a user's class based on their badge(s).

    Params:
        class_ = Reference to the user's [dialect.defs.IRCUser.Class|class].
        badges = String of comma-separated badges.
        promoteModerators = Whether to promote moderators to
            [dialect.defs.IRCUser.Class.operator|operator].
        promoteVIPs = Whether to promote VIPs to
            [dialect.defs.IRCUser.Class.elevated|elevated].
 +/
void promoteUserFromBadges(
    ref IRCUser.Class class_,
    const string badges,
    const bool promoteModerators,
    const bool promoteVIPs) pure @safe
{
    import std.string : indexOf;
    import std.algorithm.iteration : splitter;

    if (class_ >= IRCUser.Class.operator) return;  // already as high as we go

    foreach (immutable badge; badges.splitter(','))
    {
        immutable slashPos = badge.indexOf('/');
        if (!slashPos) break;  // something's wrong

        immutable badgePart = badge[0..slashPos];

        switch (badgePart)
        {
        case "subscriber":
            if (class_ < IRCUser.Class.registered)
            {
                class_ = IRCUser.Class.registered;
            }
            break;  // Check next badge

        case "vip":
            if (promoteVIPs && (class_ < IRCUser.Class.elevated))
            {
                class_ = IRCUser.Class.elevated;
            }
            break;  // as above

        case "moderator":
            if (promoteModerators && (class_ < IRCUser.Class.operator))
            {
                class_ = IRCUser.Class.operator;
                return;  // We don't go any higher than moderator here
            }
            break;  // as above

        /+case "broadcaster":
            // This is already done by comparing the user's name to the channel
            // name in the calling function.

            if (class_ < IRCUser.Class.staff)
            {
                class_ = IRCUser.Class.staff;
            }
            return;  // No need to check more badges
         +/

        default:
            // Non-applicable badge
            break;
        }
    }
}

///
unittest
{
    import lu.conv : Enum;

    {
        enum badges = "subscriber/12,sub-gift-leader/1";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, false);
        enum expected = IRCUser.Class.registered;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "premium/1";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, false);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, false);
        enum expected = IRCUser.Class.registered;  // because promoteVIPs false
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, true, true);
        enum expected = IRCUser.Class.elevated;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, true, true);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, true);
        enum expected = IRCUser.Class.registered;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "broadcaster/1,subscriber/12,partner/1";
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, true);
        enum expected = IRCUser.Class.registered;  // not staff because broadcasters are identified elsewhere
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "moderator/1";  // no comma splitter test
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, true, true);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = "subscriber/1";
        auto class_ = IRCUser.Class.operator;
        promoteUserFromBadges(class_, badges, true, true);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.staff;
        promoteUserFromBadges(class_, badges, true, true);
        enum expected = IRCUser.Class.staff;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.anyone;
        promoteUserFromBadges(class_, badges, false, false);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), Enum!(IRCUser.Class).toString(class_));
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

    if (plugin.transient.persistentWorkerTid != Tid.init)
    {
        // It may not have been started if we're aborting very early.
        plugin.transient.persistentWorkerTid.send(ThreadMessage.teardown);
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

    if (plugin.twitchSettings.fakeChannelFromQueries && (event.type == IRCEvent.Type.QUERY))
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

    immutable isEmotePossibleEventType = event.type.among!
        (IRCEvent.Type.CHAN,
        IRCEvent.Type.EMOTE,
        IRCEvent.Type.SELFCHAN,
        IRCEvent.Type.SELFEMOTE);

    immutable eventCanContainEmotes =
        plugin.twitchSettings.customEmotes &&
        event.content.length &&
        isEmotePossibleEventType;

    version(TwitchCustomEmotesEverywhere)
    {
        // Always embed regardless of channel
        alias shouldEmbedEmotes = eventCanContainEmotes;
    }
    else
    {
        // Only embed if the event is in a home channel
        immutable isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel);
        immutable shouldEmbedEmotes = eventCanContainEmotes && isHomeChannel;
    }

    if (shouldEmbedEmotes)
    {
        import kameloso.plugins.twitch.emotes : embedCustomEmotes;

        const customEmotes = event.channel in plugin.customEmotesByChannel;

        // event.content is guaranteed to not be empty here
        embedCustomEmotes(
            event.content,
            event.emotes,
            customEmotes ? *customEmotes : null,
            plugin.customGlobalEmotes);

        if (event.target.nickname.length && event.aux[0].length)
        {
            embedCustomEmotes(
                event.aux[0],
                event.aux[$-2],
                customEmotes ? *customEmotes : null,
                plugin.customGlobalEmotes);
        }
    }

    version(TwitchPromoteEverywhere)
    {
        // No checks needed, always pass through and promote
    }
    else
    {
        version(TwitchCustomEmotesEverywhere)
        {
            // isHomeChannel was not declared above
            immutable isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel);
        }

        if (!isHomeChannel) return;
    }

    static void postprocessImpl(
        const TwitchPlugin plugin,
        const string channelName,
        ref IRCUser user)
    {
        if (user.class_ >= IRCUser.Class.staff)
        {
            // User is already staff or higher, no need to promote
            return;
        }

        if (user.class_ == IRCUser.Class.blacklist)
        {
            // Ignore blacklist for obvious reasons
            return;
        }

        if (plugin.twitchSettings.promoteBroadcasters)
        {
            // Already ensured channel has length in parent function
            assert(channelName.length, "Empty channelName in postprocess.postprocessImpl");

            if ((user.class_ < IRCUser.Class.staff) &&
                (user.nickname == channelName[1..$]))
            {
                // User is broadcaster but is not registered as staff
                user.class_ = IRCUser.Class.staff;
                return;
            }
        }

        if (user.badges.length)
        {
            // Infer class from the user's badge(s)
            promoteUserFromBadges(
                user.class_,
                user.badges,
                plugin.twitchSettings.promoteModerators,
                plugin.twitchSettings.promoteVIPs);
        }
    }

    /*if (event.sender.nickname.length)*/ postprocessImpl(plugin, event.channel, event.sender);
    if (event.target.nickname.length) postprocessImpl(plugin, event.channel, event.target);
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
    loadResources(plugin);

    if (plugin.twitchSettings.customEmotes)
    {
        import kameloso.plugins.twitch.emotes : importCustomEmotes;

        plugin.customGlobalEmotes = null;
        importCustomEmotes(plugin);

        foreach (immutable channelName, const room; plugin.rooms)
        {
            plugin.customEmotesByChannel.remove(channelName);
            importCustomEmotes(plugin, channelName, room.id);
        }
    }
}


// onBusMessage
/++
    Receives a passed [kameloso.thread.Boxed|Boxed] instance with the `"twitch"`
    header, and issues whispers based on its [kameloso.messaging.Message|Message]
    payload.

    Params:
        plugin = The current [TwitchPlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(
    TwitchPlugin plugin,
    const string header,
    shared Sendable content)
{
    import kameloso.messaging : Message;
    import kameloso.thread : Boxed;

    if (header != "twitch") return;

    auto message = cast(Boxed!Message)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    if (message.payload.event.type == IRCEvent.Type.QUERY)
    {
        plugin.whisperBuffer.put(message.payload);

        if (!plugin.transient.whispererRunning)
        {
            import kameloso.constants : BufferSize;
            import core.thread : Fiber;

            void whispererDg()
            {
                import kameloso.plugins.common.delayawait : delay;

                plugin.transient.whispererRunning = true;
                scope(exit) plugin.transient.whispererRunning = false;

                while (true)
                {
                    import core.time : msecs;

                    immutable untilNextSeconds = plugin.throttleline(plugin.whisperBuffer);
                    if (untilNextSeconds == 0.0) return;

                    immutable untilNextMsecs = cast(uint)(untilNextSeconds * 1000);
                    delay(plugin, untilNextMsecs.msecs, Yes.yield);
                }
            }

            Fiber whispererFiber = new Fiber(&whispererDg, BufferSize.fiberStack);
            whispererFiber.call();
        }
    }
    else
    {
        import lu.conv : Enum;
        enum pattern = "Unknown message type <l>%s</> sent as TwitchPlugin bus message";
        logger.errorf(Enum!(IRCEvent.Type).toString(message.payload.event.type));
    }
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
    import kameloso.constants : BufferSize;
    import kameloso.messaging : Message;
    import kameloso.terminal : TerminalToken;
    import lu.container : Buffer, CircularBuffer;
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
            /*immutable*/ uint _id;

        package:
            /++
                Whether or not the stream is currently ongoing.
             +/
            bool live; // = false;

            /++
                The numerical ID of the user/account of the channel owner.
             +/
            uint userID;

            /++
                The user/account name of the channel owner.
             +/
            string userLogin;

            /++
                The display name of the channel owner.
             +/
            string userDisplayName;

            /++
                The numerical ID of a game, as supplied by Twitch.
             +/
            uint gameID;

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
                Accessor to [_id].

                Returns:
                    This stream's numerical ID, as reported by Twitch.
             +/
            auto id() const
            {
                return _id;
            }

            /++
                Takes a second [Stream] and updates this one with values from it.

                Params:
                    updated =  A second [Stream] from which to inherit values.
             +/
            void update(const Stream updated)
            {
                assert(_id, "Stream not properly initialised");

                this.userDisplayName = updated.userDisplayName;
                this.gameID = updated.gameID;
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
                    id = This stream's numerical ID, as reported by Twitch.
             +/
            this(const uint id) pure @safe nothrow @nogc
            {
                this._id = id;
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

                json["id"] = JSONValue(this._id);
                json["gameID"] = JSONValue(this.gameID);
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

                auto stream = Stream(cast(uint)json["id"].integer);
                stream.gameID = cast(uint)json["gameID"].integer;
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
            assert(_uniqueID, "Room not properly initialised");
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
        uint id;

        /++
            Associative array of the [Follower]s of this channel, keyed by nickname.
         +/
        Follower[string] followers;

        /++
            UNIX timestamp of when [followers] was last cached.
         +/
        long followersLastCached;

        /++
            How many messages to keep in memory, to allow for nuking.
         +/
        enum messageMemory = 128;

        /++
            The last n messages sent in the channel, used by `nuke`.
         +/
        CircularBuffer!(IRCEvent, Yes.dynamic, messageMemory) lastNMessages;

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
        Transient state variables, aggregated in a struct.
     +/
    static struct TransientState
    {
        /++
            The thread ID of the persistent worker thread.
         +/
        Tid persistentWorkerTid;

        /++
            Authorisation token for the "Authorization: Bearer <token>".
         +/
        string authorizationBearer;

        /++
            The bot's numeric account/ID.
         +/
        uint botID;

        /++
            How long a Twitch HTTP query usually takes.

            It tries its best to self-balance the number based on how long queries
            actually take. Start off conservatively.
         +/
        long approximateQueryTime = 700;

        /++
            Effective bell after [kameloso.terminal.isTerminal] checks.
         +/
        string bell = "" ~ cast(char)(TerminalToken.bell);

        /++
            Whether or not [ecount] has been modified and there's a point in saving it to disk.
         +/
        bool ecountDirty;

        /++
            Whether or not [viewerTimesByChannel] has been modified and there's a
            point in saving it to disk.
         +/
        bool viewerTimesDirty;

        /++
            Whether or not a delegate sending whispers is currently running.
         +/
        bool whispererRunning;
    }

    /++
        Aggregate of values and state needed to rate-limit outgoing messages.
     +/
    static struct Throttle
    {
        private import core.time : MonoTime;

        /++
            Origo of x-axis (last sent message).
         +/
        MonoTime t0;

        /++
            y at t0 (ergo y at x = 0, weight at last sent message).
         +/
        double m = 0.0;

        /++
            By how much to bump y on sent message.
         +/
        enum bump = 1.0;

        /++
            Don't copy this, just keep one instance.
         +/
        @disable this(this);

        /++
            Resets the throttle values in-place.
         +/
        void reset()
        {
            // No need to reset t0, it will just exceed burst on next throttleline
            m = 0.0;
        }
    }

    /++
        All Twitch plugin settings.
     +/
    TwitchSettings twitchSettings;

    /++
        Transient state of this [TwitchPlugin] instance.
     +/
    TransientState transient;

    /++
        The throttle instance used to rate-limit outgoing whispers.
     +/
    Throttle throttle;

    /++
        Takes one or more lines from the passed buffer and sends them to the
        server as whispers.

        Sends to the server in a throttled fashion, based on a simple
        `y = k*x + m` graph.

        This is so we don't get kicked by the server for spamming, if a lot of
        lines are to be sent at once.

        Params:
            buffer = Buffer instance.
            immediate = Whether or not the line should just be sent straight away,
                ignoring throttling.

        Returns:
            A `double` of the the time in seconds remaining until the next message
            may be sent. If `0.0`, the buffer was emptied.

        See_Also:
            [kameloso.plugins.twitch.api.sendWhisper]
     +/
    auto throttleline(Buffer)
        (ref Buffer buffer,
        const Flag!"immediate" immediate = No.immediate)
    {
        import core.time : MonoTime;

        alias t = throttle;

        immutable now = MonoTime.currTime;
        immutable k = 1.2;
        immutable burst = 0.0;

        while (!buffer.empty)
        {
            if (!immediate)
            {
                /// Position on x-axis; how many msecs have passed since last message was sent
                immutable x = (now - t.t0).total!"msecs"/1000.0;
                /// Value of point on line
                immutable y = k*x + t.m;

                if (y > burst)
                {
                    t.t0 = now;
                    t.m = burst;
                    // Drop down
                }
                else if (y < 0.0)
                {
                    // Not yet time, delay
                    return -y/k;
                }

                // Record as sent and drop down to actually send
                t.m -= Throttle.bump;
            }

            if (!this.state.settings.headless)
            {
                enum pattern = "--> [%s] %s";
                logger.tracef(
                    pattern,
                    buffer.front.event.target.displayName,
                    buffer.front.event.content);
            }

            immutable responseCode = sendWhisper(
                this,
                buffer.front.event.target.id,
                buffer.front.event.content,
                buffer.front.caller);

            version(none)
            if (responseCode == 429)
            {
                import kameloso.plugins.common.delayawait : delay;
                import core.time : seconds;

                // 429 Too Many Requests
                // rate limited; delay and try again without popping?
                delay(plugin, 10.seconds, Yes.yield);
                continue;
            }

            buffer.popFront();
        }

        return 0.0;
    }

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
        The Twitch application ID for the kameloso bot.
     +/
    enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";

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
        API keys and tokens, keyed by channel.
     +/
    Credentials[string] secretsByChannel;

    /++
        Associative array of responses from async HTTP queries.
     +/
    shared QueryResponse[int] responseBucket;

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
        Buffer of messages to send as whispers.
     +/
    Buffer!(Message, No.dynamic, BufferSize.outbuffer) whisperBuffer;

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

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
        Import custom BetterTTV, FrankerFaceZ and 7tv emotes, allowing the Printer
        plugin to highlight them, much like it does official Twitch emotes.
        Imports both global and channel-specific emotes.
     +/
    bool bttvFFZ7tvEmotes = false;

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


// Mixins
mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;
mixin ModuleRegistration!(-5.priority);


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
        if (room.stream.up)
        {
            room.stream.activeViewers[event.sender.nickname] = true;
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


// onGlobalUserstate
/++
    Inherits the bots display name from a
    [dialect.defs.IRCEvent.Type.GLOBALUSERSTATE|GLOBALUSERSTATE]
    into [kameloso.pods.IRCBot.displayName|IRCBot.displayName].

    Additionally fetches global custom BetterTV, FrankerFaceZ and 7tv emotes
    if the settings say to do so.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.GLOBALUSERSTATE)
    .fiber(true)
)
void onGlobalUserstate(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    plugin.state.bot.displayName = event.target.displayName;
    plugin.state.updates |= IRCPluginState.Update.bot;

    if (plugin.twitchSettings.bttvFFZ7tvEmotes) importCustomGlobalEmotes(plugin);
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

    if (room.stream.up)
    {
        import std.datetime.systime : Clock;

        // We're leaving in the middle of a stream?
        // Close it and rotate, in case someone has a pointer to it
        // copied from nested functions in uptimeMonitorDg
        room.stream.up = false;
        room.stream.stopTime = Clock.currTime;
        room.stream.chattersSeen = null;
        room.previousStream = room.stream;
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
    import std.format : format;
    import core.time : msecs;

    if (room.stream.up)
    {
        import std.datetime.systime : Clock;

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;
        immutable delta = now - room.stream.startTime;
        immutable timestring = timeSince(delta);

        if (room.stream.maxViewerCount > 0)
        {
            enum pattern = "%s has been live for %s, currently with %d viewers. " ~
                "(Maximum this stream has so far been %d concurrent viewers.)";
            immutable message = pattern.format(
                room.broadcasterDisplayName,
                timestring,
                room.stream.viewerCount,
                room.stream.maxViewerCount);
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
        if (room.previousStream.idString.length)  // == Stream.init
        {
            import std.datetime.systime : SysTime;

            SysTime start = room.previousStream.startTime;
            SysTime stop = room.previousStream.stopTime;
            start.fracSecs = 0.msecs;
            stop.fracSecs = 0.msecs;
            immutable delta = (stop - start);
            immutable timestring = timeSince(delta);

            if (room.previousStream.maxViewerCount > 0)
            {
                enum pattern = "%s last streamed for %s " ~
                    "with a maximum of %d concurrent viewers.";
                immutable message = pattern.format(
                    room.broadcasterDisplayName,
                    timestring,
                    room.previousStream.maxViewerCount);
                chan(plugin.state, room.channelName, message);
            }
            else
            {
                enum pattern = "%s last streamed for %s.";
                immutable message = pattern.format(room.broadcasterDisplayName, timestring);
                chan(plugin.state, room.channelName, message);
            }
        }
        else
        {
            // No streams this session
            immutable message = room.broadcasterDisplayName ~ " is currently not streaming.";
            chan(plugin.state, room.channelName, message);
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

    void sendNoSuchUser(const string givenName)
    {
        immutable message = "No such user: " ~ givenName;
        chan(plugin.state, event.channel, message);
    }

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
        immutable user = getTwitchUser(plugin, givenName, string.init, Yes.searchByDisplayName);
        if (!user.nickname.length) return sendNoSuchUser(givenName);

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

    Additionally fetches custom BetterTV, FrankerFaceZ and 7tv emotes for the
    channel if the settings say to do so.
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
        initRoom(plugin, event.channel);
        room = event.channel in plugin.rooms;
    }

    room.id = event.aux;
    room.follows = getFollows(plugin, event.aux);
    room.followsLastCached = event.time;
    startRoomMonitorFibers(plugin, event.channel);

    if (plugin.twitchSettings.bttvFFZ7tvEmotes)
    {
        importCustomEmotes(plugin, room);
    }

    version(WithPersistenceService)
    {
        import kameloso.thread : ThreadMessage, sendable;
        import std.concurrency : send;

        immutable nickname = event.channel[1..$];
        auto broadcasterUser = nickname in plugin.state.users;

        if (!broadcasterUser)
        {
            // Fake a new user
            auto newUser = IRCUser(nickname, nickname, nickname ~ ".tmi.twitch.tv");
            newUser.account = nickname;
            newUser.class_ = IRCUser.Class.anyone;
            plugin.state.users[nickname] = newUser;
            broadcasterUser = nickname in plugin.state.users;
        }

        if (!broadcasterUser.displayName.length)
        {
            broadcasterUser.displayName = room.broadcasterDisplayName;
            IRCUser user = *broadcasterUser;  // dereference and copy
            plugin.state.mainThread.send(ThreadMessage.busMessage("persistence", sendable(user)));
        }
    }

    immutable userURL = "https://api.twitch.tv/helix/users?id=" ~ event.aux;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable userJSON = getTwitchData(plugin, userURL);
            room.broadcasterDisplayName = userJSON["display_name"].str;
            break;
        }
        catch (Exception e)
        {
            // Can be JSONException
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;  // It's in a Fiber but we get the backtrace anyway
        }
    }
}


// onGuestRoomState
/++
    Fetches custom BetterTV, FrankerFaceZ and 7tv emotes for guest channels if
    the settings say to do so.
 +/
version(TwitchCustomEmotesEverywhere)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.guest)
    .fiber(true)
)
void onGuestRoomState(TwitchPlugin plugin, const /*ref*/ IRCEvent event)
{
    if (!plugin.twitchSettings.bttvFFZ7tvEmotes) return;

    auto room = event.channel in plugin.rooms;

    if (!room)
    {
        // Race...
        initRoom(plugin, event.channel);
        room = event.channel in plugin.rooms;
    }

    room.id = event.aux;
    importCustomEmotes(plugin, room);
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
    import lu.string : nom, stripped;
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

    void sendNumTimesGTZero()
    {
        enum message = "Number of times must be greater than 0.";
        chan(plugin.state, event.channel, message);
    }

    if (!event.content.length || !event.content.count(' ')) return sendUsage();

    string slice = event.content.stripped;  // mutable
    immutable numTimesString = slice.nom(' ');

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
        return chan(plugin.state, event.channel, message);
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
    immutable message = ".delete " ~ event.id;
    chan(plugin.state, event.channel, message);
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
    import kameloso.constants : KamelosoInfo, Timeout;
    import arsd.http2 : HttpClient, HttpVerb, Uri;
    import lu.string : contains, nom, stripped;
    import std.format : format;
    import core.time : seconds;

    void sendUsage()
    {
        immutable pattern = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Usage: %s%s [YouTube link or video ID]" :
            "Usage: %s%s [Spotify link or track ID]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendMissingCredentials()
    {
        immutable channelMessage = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Missing Google API credentials and/or YouTube playlist ID." :
            "Missing Spotify API credentials and/or playlist ID.";
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
        enum pattern = "At least %d seconds must pass between song requests.";
        immutable message = pattern.format(TwitchPlugin.Room.minimumTimeBetweenSongRequests);
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
    else if (event.sender.class_ < plugin.twitchSettings.songrequestPermsNeeded)
    {
        return sendInsufficientPermissions();
    }

    if (event.sender.class_ < IRCUser.class_.operator)
    {
        const room = event.channel in plugin.rooms;
        assert(room, "Tried to make a song request in a nonexistent room");

        if (const lastRequestTimestamp = event.sender.nickname in room.songrequestHistory)
        {
            if ((event.time - *lastRequestTimestamp) < TwitchPlugin.Room.minimumTimeBetweenSongRequests)
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
        else if (!url.length ||
            url.contains(' ') ||
            (!url.contains("youtube.com/") &&
            !url.contains("youtu.be/")))
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
            //return logger.warning("Bad link parsing?");
            return sendInvalidURL();
        }

        try
        {
            import kameloso.plugins.twitch.google : addVideoToYouTubePlaylist;

            immutable json = addVideoToYouTubePlaylist(plugin, *creds, videoID);
            immutable title = json["snippet"]["title"].str;
            //immutable position = json["snippet"]["position"].integer;
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
        else if (!url.length ||
            url.contains(' ') ||
            !url.contains("spotify.com/track/"))
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
        else if (slice.contains("spotify.com/track/"))
        {
            slice.nom("spotify.com/track/");
            trackID = slice.nom!(Yes.inherit)('?');
        }
        else
        {
            //return logger.warning("Bad link parsing?");
            return sendInvalidURL();
        }

        try
        {
            import kameloso.plugins.twitch.spotify : addTrackToSpotifyPlaylist, getSpotifyTrackByID;
            import std.json : JSONType;

            immutable json = addTrackToSpotifyPlaylist(plugin, *creds, trackID);

            if ((json.type != JSONType.object)  || "snapshot_id" !in json)
            {
                return logger.error("An error occurred.\n", json.toPrettyString);
            }

            const trackJSON = getSpotifyTrackByID(*creds, trackID);
            immutable artist = trackJSON["artists"].array[0].object["name"].str;
            immutable track = trackJSON["name"].str;

            return sendAddedToSpotifyPlaylist(artist, track);
        }
        catch (ErrorJSONException e)
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
        return chan(plugin.state, event.channel, message);
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }
    catch (Exception e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }

    try
    {
        immutable responseJSON = createPoll(plugin, event.channel, title, durationString, choices);
        enum pattern = `Poll "%s" created.`;
        immutable message = pattern.format(responseJSON.array[0].object["title"].str);
        chan(plugin.state, event.channel, message);
    }
    catch (MissingBroadcasterTokenException e)
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
            version(WithVotesPlugin)
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
    import std.stdio : writeln;

    immutable pollInfoJSON = getPolls(plugin, event.channel);

    if (!pollInfoJSON.array.length)
    {
        enum message = "There are no active polls to end.";
        return chan(plugin.state, event.channel, message);
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
            if (!emotestring.length) continue;

            auto channelcount = event.channel in plugin.ecount;
            if (!channelcount)
            {
                plugin.ecount[event.channel][string.init] = 0L;
                channelcount = event.channel in plugin.ecount;
                (*channelcount).remove(string.init);
            }

            string slice = emotestring;  // mutable
            immutable id = slice.nom(':');

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
        if (room.stream.up)
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
    import lu.string : beginsWith;
    import std.concurrency : spawn;

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
    import lu.string : nom, stripped;
    import std.array : replace;
    import std.format : format;
    import std.conv  : to;

    if (!plugin.twitchSettings.ecount) return;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [emote]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
    }

    void sendNotATwitchEmote()
    {
        immutable message = plugin.twitchSettings.bttvFFZ7tvEmotes ?
            "That is not a Twitch, BetterTTV, FrankerFaceZ or 7tv emote." :
            "That is not a Twitch emote.";
        chan(plugin.state, event.channel, message);
    }

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
        // Undo replacements
        immutable dline = rawSlice.to!dstring;
        immutable emote = dline[start..end]
            .replace(dchar(';'), dchar(':'));

        // No real point using plurality since most emotes should have a count > 1
        enum pattern = "%s has been used %d times!";
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
        .nom(':')
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

    if (!plugin.useAPIFeatures) return;

    immutable unescapedTitle = event.content.stripped;

    if (!unescapedTitle.length)
    {
        enum pattern = "Usage: %s%s [title]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
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
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("game")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
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
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        return chan(plugin.state, event.channel, message);
    }

    const room = event.channel in plugin.rooms;
    assert(room, "Tried to start a commercial in a nonexistent room");

    if (!room.stream.up)
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
        room = Pointer to [TwitchPlugin.Room|Room] to import custom emotes for.
 +/
void importCustomEmotes(TwitchPlugin plugin, TwitchPlugin.Room* room)
in (room, "Tried to import custom emotes for a nonexistent room")
{
    try
    {
        getBTTVEmotes(plugin, room.customEmotes, room.id);
    }
    catch (TwitchQueryException e)
    {
        enum pattern = "Failed to fetch custom <l>BetterTTV</> emotes for channel <l>%s";
        logger.warningf(pattern, room.channelName);
        version(PrintStacktraces) logger.trace(e.info);
    }

    try
    {
        getFFZEmotes(plugin, room.customEmotes, room.id);
    }
    catch (TwitchQueryException e)
    {
        enum pattern = "Failed to fetch custom <l>FrankerFaceZ</> emotes for channel <l>%s";
        logger.warningf(pattern, room.channelName);
        version(PrintStacktraces) logger.trace(e.info);
    }

    try
    {
        get7tvEmotes(plugin, room.customEmotes, room.id);
    }
    catch (TwitchQueryException e)
    {
        enum pattern = "Failed to fetch custom <l>7tv</> emotes for channel <l>%s";
        logger.warningf(pattern, room.channelName);
        version(PrintStacktraces) logger.trace(e.info);
    }

    room.customEmotes.rehash();
}


// importCustomGlobalEmotes
/++
    Fetches custom global BetterTTV, FrankerFaceZ and 7tv emotes via API calls.

    Params:
        plugin = The current [TwitchPlugin].
 +/
void importCustomGlobalEmotes(TwitchPlugin plugin)
{
    try
    {
        getBTTVGlobalEmotes(plugin, plugin.customGlobalEmotes);
    }
    catch (TwitchQueryException e)
    {
        logger.warning("Failed to fetch global BetterTTV emotes");
        version(PrintStacktraces) logger.trace(e.info);
    }

    try
    {
        get7tvGlobalEmotes(plugin, plugin.customGlobalEmotes);
    }
    catch (TwitchQueryException e)
    {
        logger.warning("Failed to fetch global 7tv emotes");
        version(PrintStacktraces) logger.trace(e.info);
    }

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
    import std.algorithm.comparison : among;
    import std.array : Appender;
    import std.conv : to;
    import std.range : only;
    import std.string : indexOf;

    if (!event.type.among!(IRCEvent.Type.CHAN, IRCEvent.Type.EMOTE) || !event.content.length) return;

    static Appender!(char[]) sink;

    scope(exit)
    {
        if (sink.data.length)
        {
            event.emotes ~= sink.data;
            sink.clear();
        }
    }

    if (sink.capacity == 0)
    {
        sink.reserve(64);  // guesstimate
    }

    auto range = only(customEmotes, customGlobalEmotes);
    immutable dline = event.content.to!dstring;
    ptrdiff_t pos = dline.indexOf(' ');
    dstring previousEmote;  // mutable
    size_t prev;

    void checkWord(const dstring dword)
    {
        foreach (emoteMap; range)
        {
            import std.array : replace;
            import std.format : formattedWrite;

            if (dword == previousEmote)
            {
                enum pattern = ",%d-%d";
                immutable end = (pos == -1) ?
                    dline.length :
                    pos;

                sink.formattedWrite(pattern, prev, end-1);
                return;
            }

            if (!emoteMap.length) continue;

            if (dword in emoteMap)
            {
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
                return;
            }
        }
    }

    if (pos == -1)
    {
        // No bounding space, check entire (one-word) line
        return checkWord(dline);
    }

    while (pos != -1)
    {
        if (pos > prev)
        {
            checkWord(dline[prev..pos]);
        }

        prev = (pos + 1);
        if (prev >= dline.length) break;

        pos = dline.indexOf(' ', prev);
        if (pos == -1)
        {
            return checkWord(dline[prev..$]);
        }
    }
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
)
void onMyInfo(TwitchPlugin plugin)
{
    // Load ecounts.
    plugin.reload();
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
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.time : nextMidnight;
    import std.datetime.systime : Clock;

    void chatterMonitorDg()
    {
        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start chatter monitor delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;
        uint addedSinceLastRehash;

        while (plugin.useAPIFeatures)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            if (!room.stream.up)
            {
                delay(plugin, plugin.monitorUpdatePeriodicity, Yes.yield);
                continue;
            }

            try
            {
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

                        room.stream.chattersSeen[viewer] = true;

                        // continue early if we shouldn't monitor watchtime
                        if (!plugin.twitchSettings.watchtime) continue;

                        if (plugin.twitchSettings.watchtimeExcludesLurkers)
                        {
                            // Exclude lurkers from watchtime monitoring
                            if (viewer !in room.stream.activeViewers) continue;
                        }

                        enum periodicitySeconds = plugin.monitorUpdatePeriodicity.total!"seconds";

                        if (auto channelViewerTimes = room.channelName in plugin.viewerTimesByChannel)
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
                            plugin.viewerTimesByChannel[room.channelName][viewer] = periodicitySeconds;
                            ++addedSinceLastRehash;
                        }
                    }
                }
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, plugin.monitorUpdatePeriodicity, Yes.yield);
        }
    }

    void uptimeMonitorDg()
    {
        static void closeStream(TwitchPlugin.Room* room)
        {
            room.stream.up = false;
            room.stream.stopTime = Clock.currTime;
            room.stream.chattersSeen = null;
        }

        static void rotateStream(TwitchPlugin.Room* room)
        {
            room.previousStream = room.stream;
            room.stream = TwitchPlugin.Room.Stream.init;
        }

        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start chatter monitor delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;

        while (plugin.useAPIFeatures)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            try
            {
                auto streamFromServer = getStream(plugin, room.broadcasterName);  // must not be const nor immutable

                if (!streamFromServer.idString.length)  // == TwitchPlugin.Room.Stream.init)
                {
                    // Stream down
                    if (room.stream.up)
                    {
                        // Was up but just ended
                        closeStream(room);
                        rotateStream(room);

                        if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                        }
                    }
                }
                else
                {
                    // Stream up
                    if (room.stream.idString == streamFromServer.idString)
                    {
                        // Same stream running, just update it
                        room.stream.update(streamFromServer);
                    }
                    else
                    {
                        // New stream! Rotate and insert
                        closeStream(room);
                        rotateStream(room);
                        room.stream = streamFromServer;
                    }
                }
            }
            catch (Exception _)
            {
                // Just swallow the exception and retry next time
            }

            delay(plugin, plugin.monitorUpdatePeriodicity, Yes.yield);
        }
    }

    // Clear and re-cache follows once every midnight
    void cacheFollowersDg()
    {
        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start follower cache delegate on non-existing room");

        immutable idSnapshot = room.uniqueID;

        while (plugin.useAPIFeatures)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            immutable now = Clock.currTime;

            try
            {
                room.follows = getFollows(plugin, room.id);
                room.followsLastCached = now.toUnixTime;
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
    import core.thread : Fiber;

    void validatorDg()
    {
        import kameloso.constants : MagicErrorStrings;
        import std.datetime.systime : Clock, SysTime;

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
    import core.thread : Fiber;

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
            if (plugin.twitchSettings.watchtime && plugin.viewerTimesByChannel.length)
            {
                foreach (const room; plugin.rooms)
                {
                    if (room.stream.up)
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

    Fiber periodicallySaveFiber = new Fiber(&periodicallySaveDg, BufferSize.fiberStack);
    delay(plugin, periodicallySaveFiber, plugin.savePeriodicity);
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

    Additionally and optionally embeds custom BTTV/FrankerFaceZ/7tv emotes into the event.
 +/
void postprocess(TwitchPlugin plugin, ref IRCEvent event)
{
    if (!event.sender.nickname.length || !event.channel.length) return;

    version(TwitchCustomEmotesEverywhere)
    {
        // No checks needed
        if (const room = event.channel in plugin.rooms)
        {
            embedCustomEmotes(event, room.customEmotes, plugin.customGlobalEmotes);
        }
    }
    else
    {
        import std.algorithm.searching : canFind;

        // Only embed if the event is in a home channel
        immutable isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel);

        if (isHomeChannel)
        {
            if (const room = event.channel in plugin.rooms)
            {
                embedCustomEmotes(event, room.customEmotes, plugin.customGlobalEmotes);
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
    import std.file : exists, mkdir;
    import std.json : JSONException;
    import std.path : baseName, dirName;

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
                file.baseName ~ " is malformed",
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

    loadFile(ecountJSON, plugin.ecountFile);
    loadFile(viewersJSON, plugin.viewersFile);
    loadFile(secretsJSON, plugin.secretsFile);

    ecountJSON.save(plugin.ecountFile);
    viewersJSON.save(plugin.viewersFile);
    secretsJSON.save(plugin.secretsFile);
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
    Reloads the plugin, loading resources from disk.
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
    import core.time : hours, seconds;

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
        uint privateUniqueID;

    public:
        /++
            Representation of a broadcast (stream).
         +/
        static struct Stream
        {
        private:
            /++
                The unique ID of a stream, as supplied by Twitch.

                Cannot be made immutable or generated `opAssign`s break.
             +/
            /*immutable*/ string privateIDString;

        package:
            /++
                Whether or not the stream is currently ongoing.
             +/
            bool up; // = false;

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
                When the stream started.
             +/
            SysTime startTime;

            /++
                When the stream ended. Only set when the [Stream] is [TwitchPlugin.Room.previousStream].
             +/
            SysTime stopTime;

            /++
                How many people were viewing the stream the last time the monitor
                [core.thread.fiber.Fiber|Fiber] checked.
             +/
            long viewerCount;

            /++
                The maximum number of people seen watching this stream.
             +/
            long maxViewerCount;

            /++
                Users seen in the channel.
             +/
            bool[string] chattersSeen;

            /++
                Hashmap of active viewers (who have shown activity).
             +/
            bool[string] activeViewers;

            /++
                Accessor to [privateIDString].
             +/
            auto idString() const
            {
                return privateIDString;
            }

            /++
                Takes a second [Stream] and updates this one with values from it.
             +/
            void update(const Stream updated)
            {
                assert(privateIDString.length, "Stream not properly initialised");

                this.userDisplayName = updated.userDisplayName;
                this.gameIDString = updated.gameIDString;
                this.gameName = updated.gameName;
                this.title = updated.title;
                this.viewerCount = updated.viewerCount;

                if (this.viewerCount > this.maxViewerCount)
                {
                    this.maxViewerCount = this.viewerCount;
                }
            }

            /++
                Constructor.
             +/
            this(const string idString)
            {
                this.privateIDString = idString;
            }
        }

        /++
            Constructor taking a string (channel) name.
         +/
        this(const string channelName)
        {
            import std.random : uniform;

            this.channelName = channelName;
            this.broadcasterName = channelName[1..$];
            this.broadcasterDisplayName = this.broadcasterName;  // until we resolve it
            this.privateUniqueID = uniform(1, 10_000);
        }

        /++
            Accessor to [Room.privateUniqueID].
         +/
        auto uniqueID() const
        {
            assert((privateUniqueID > 0), "Room not properly initialised");
            return privateUniqueID;
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
            The preivous, ended stream.
         +/
        Stream previousStream;

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
        JSONValue[string] follows;

        /++
            UNIX timestamp of when [follows] was last cached.
         +/
        long followsLastCached;

        /++
            How many messages to keep in memory, to allow for nuking.
         +/
        enum messageMemory = 64;

        /++
            The last n messages sent in the channel, used by `nuke`.
         +/
        CircularBuffer!(IRCEvent, No.dynamic, messageMemory) lastNMessages;

        /++
            The minimum amount of time in seconds that must have passed between
            two song requests by one person.

            Users of class [dialect.defs.IRCUser.Class.operator|operator] or
            higher are exempt.
         +/
        enum minimumTimeBetweenSongRequests = 60;

        /++
            Song request history; UNIX timestamps keyed by nickname.
         +/
        long[string] songrequestHistory;

        /++
            Custom channel-specific BetterTTV, FrankerFaceZ and 7tv emotes, as
            fetched via API calls.
         +/
        bool[dstring] customEmotes;
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
        Global BetterTTV, FrankerFaceZ and 7tv emotes, as fetched via API calls.
     +/
    bool[dstring] customGlobalEmotes;

    /++
        [kameloso.terminal.TerminalToken.bell|TerminalToken.bell] as string,
        for use as bell.
     +/
    private enum bellString = "" ~ cast(char)(TerminalToken.bell);

    /++
        Effective bell after [kameloso.terminal.isTerminal] checks.
     +/
    string bell = bellString;

    /++
        The Twitch application ID for kameloso.
     +/
    enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";

    /++
        Authorisation token for the "Authorization: Bearer <token>".
     +/
    string authorizationBearer;

    /++
        Whether or not to use features requiring querying Twitch API.
     +/
    shared static bool useAPIFeatures = true;

    /++
        The bot's numeric account/ID.
     +/
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
        How often to poll the servers for various information about a channel.
     +/
    static immutable monitorUpdatePeriodicity = 60.seconds;

    /++
        How many times to retry a Twitch server query.
     +/
    enum delegateRetries = 3;

    /++
        Associative array of viewer times; seconds keyed by nickname keyed by channel.
     +/
    long[string][string] viewerTimesByChannel;

    /++
        API keys and tokens, keyed by channel.
     +/
    Credentials[string] secretsByChannel;

    /++
        The thread ID of the persistent worker thread.
     +/
    Tid persistentWorkerTid;

    /++
        The thread ID of the main thread, for access from threads.
     +/
    shared static Tid mainThread;

    /++
        Associative array of responses from async HTTP queries.
     +/
    shared QueryResponse[int] bucket;

    @Resource
    {
        version(Posix)
        {
            /++
                File to save emote counters to.
             +/
            string ecountFile = "twitch/ecount.json";

            /++
                File to save viewer times to.
             +/
            string viewersFile = "twitch/viewers.json";

            /++
                File to save API keys and tokens to.
             +/
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

    /++
        Emote counters associative array; counter longs keyed by emote ID string keyed by channel.
     +/
    long[string][string] ecount;

    /++
        Whether or not [ecount] has been modified and there's a point in saving it to disk.
     +/
    bool ecountDirty;

    /++
        How often to save `ecount`s and viewer times, to ward against losing information to crashes.
     +/
    static immutable savePeriodicity = 2.hours;


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
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return (
            (state.server.daemon == IRCServer.Daemon.twitch) ||
            (state.server.daemon == IRCServer.Daemon.unset)) &&
            (twitchSettings.enabled ||
                twitchSettings.keygen ||
                twitchSettings.superKeygen ||
                twitchSettings.googleKeygen ||
                twitchSettings.spotifyKeygen);
    }

    mixin IRCPluginImpl;
}

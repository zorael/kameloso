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
    [kameloso.plugins.quote|Quote] plugin for streamer quotes, the
    [kameloso.plugins.timer|Timer] plugin for timed announcements, the
    [kameloso.plugins.oneliner|Oneliner] plugin for oneliner commands, etc.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitch,
        [kameloso.plugins.twitch.api],
        [kameloso.plugins.twitch.common],
        [kameloso.plugins.twitch.providers.twitch],
        [kameloso.plugins.twitch.providers.google],
        [kameloso.plugins.twitch.providers.spotify],
        [kameloso.plugins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch;


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
    SongRequestMode songrequestMode = SongRequestMode.disabled;

    /++
        What level of user permissions are needed to issue song requests.
     +/
    IRCUser.Class songrequestPermsNeeded = IRCUser.Class.whitelist;

    /++
        Whether or not to interpret whispers received by someone whose channel is a
        home channel into a channel message in that channel.
     +/
    bool mapWhispersToChannel = false;

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

    /++
        How many worker threads to use, to offload the HTTP requests to.
     +/
    uint workerThreads = 3;

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

        /++
            Whether or not to import and apply custom emotes in all channels.
         +/
        bool customEmotesEverywhere = false;

        /++
            Whether or not to promote users in all channels.
         +/
        bool promoteEverywhere = false;
    }
}


// SRM
/++
    Song requests may be either disabled, or either in YouTube or Spotify mode.

    `SongRequestMode` abbreviated to fit into [kameloso.prettyprint.prettyprint]
    output formatting.
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
        Song requests relate to a Spotify playlist.
     +/
    spotify,
}

/++
    Alias to [SRM].
 +/
alias SongRequestMode = SRM;

private import kameloso.plugins;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch.api;
import kameloso.plugins.twitch.common;
import dialect.postprocessors.twitch;  // To trigger the module ctor
import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import kameloso.thread : Sendable;
import dialect.defs;
import lu.container : MutexedAA, RehashingAA;
import std.datetime.systime : SysTime;
import std.json : JSONValue;
import std.typecons : Flag, No, Yes;
import core.thread.fiber : Fiber;


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
            A new [Credentials] with values from the passed `json`.
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
    ulong id;

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
    Bells on certain messages depending on the current settings.

    Belling is useful with small audiences so you don't miss messages, but
    obviously only makes sense when run locally.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ANY)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onAnyMessage(TwitchPlugin plugin, const IRCEvent event)
{
    import std.algorithm.comparison : among;

    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    // Surely only events that carry content are interesting
    if (!event.content.length) return;

    bool activityDetected;
    bool shouldBell;
    bool canSkipImportantCheck;

    // bellOnMessage check
    if (event.type.among!
        (IRCEvent.Type.CHAN,
        IRCEvent.Type.EMOTE,
        IRCEvent.Type.QUERY))
    {
        activityDetected = (event.type != IRCEvent.Type.QUERY);
        shouldBell = plugin.twitchSettings.bellOnMessage;
        canSkipImportantCheck = true;
    }

    // bellOnImportant check
    if (!canSkipImportantCheck && event.type.among!
        (IRCEvent.Type.TWITCH_SUB,
        IRCEvent.Type.TWITCH_SUBGIFT,
        IRCEvent.Type.TWITCH_CHEER,
        IRCEvent.Type.TWITCH_DIRECTCHEER,
        IRCEvent.Type.TWITCH_REWARDGIFT,
        IRCEvent.Type.TWITCH_GIFTCHAIN,
        IRCEvent.Type.TWITCH_BULKGIFT,
        IRCEvent.Type.TWITCH_SUBUPGRADE,
        IRCEvent.Type.TWITCH_CHARITY,
        IRCEvent.Type.TWITCH_BITSBADGETIER,
        IRCEvent.Type.TWITCH_RITUAL,
        IRCEvent.Type.TWITCH_EXTENDSUB,
        IRCEvent.Type.TWITCH_GIFTRECEIVED,
        IRCEvent.Type.TWITCH_PAYFORWARD,
        IRCEvent.Type.TWITCH_RAID,
        IRCEvent.Type.TWITCH_CROWDCHANT,
        IRCEvent.Type.TWITCH_ANNOUNCEMENT,
        IRCEvent.Type.TWITCH_INTRO,
        IRCEvent.Type.TWITCH_MILESTONE))
    {
        activityDetected = true;
        shouldBell |= plugin.twitchSettings.bellOnImportant;
    }

    if (shouldBell)
    {
        import std.stdio : stdout, write;
        write(plugin.transient.bell);
        stdout.flush();
    }

    if (activityDetected)
    {
        // Record viewer as active
        if (auto room = event.channel.name in plugin.rooms)
        {
            if (room.stream.live)
            {
                room.stream.activeViewers[event.sender.nickname] = true;
            }

            room.lastNMessages.put(event);
        }
    }
}


// onEmoteBearingMessage
/++
    Increments emote counters.

    Update the annotation as we learn of more events that can carry emotes.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.TWITCH_MILESTONE)
    .onEvent(IRCEvent.Type.TWITCH_BITSBADGETIER)
    .onEvent(IRCEvent.Type.TWITCH_CHEER)
    .onEvent(IRCEvent.Type.TWITCH_ANNOUNCEMENT)
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_DIRECTCHEER)
    .onEvent(IRCEvent.Type.TWITCH_INTRO)
    .onEvent(IRCEvent.Type.TWITCH_RITUAL)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .onEvent(IRCEvent.Type.SELFEMOTE)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .chainable(true)
)
void onEmoteBearingMessage(TwitchPlugin plugin, const IRCEvent event)
{
    import std.algorithm.comparison : among;

    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    if (plugin.twitchSettings.ecount && event.emotes.length)
    {
        import lu.string : advancePast;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : count;
        import std.conv : to;

        auto channelcount = event.channel.name in plugin.ecount;

        if (!channelcount)
        {
            plugin.ecount[event.channel.name] = RehashingAA!(long[string]).init;
            plugin.ecount[event.channel.name][string.init] = 0L;
            channelcount = event.channel.name in plugin.ecount;
            (*channelcount).remove(string.init);
        }

        foreach (immutable emotestring; event.emotes.splitter('/'))
        {
            if (!emotestring.length) continue;

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
}


// onSelfjoin
/++
    Registers a new [TwitchPlugin.Room] as we join a channel, so there's
    always a state struct available.

    Simply invokes [getRoom] and discards the reuslts.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onSelfjoin(TwitchPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    cast(void)getRoom(plugin, event.channel);
}


// getRoom
/++
    Retrieves the pointer to a [TwitchPlugin.Room] by name, creating it first
    if one doesn't exist.

    Params:
        plugin = The current [TwitchPlugin].
        channel = [dialect.defs.IRCEvent.Channel|Channel] representing the
            [TwitchPlugin.Room] to create and/or retrieve.

    Returns:
        A pointer to a [TwitchPlugin.Room], newly-created or otherwise.
 +/
auto getRoom(TwitchPlugin plugin, const IRCEvent.Channel channel)
{
    auto room = channel.name in plugin.rooms;

    if (room)
    {
        if (!room.id) room.id = channel.id;
    }
    else
    {
        plugin.rooms[channel.name] = TwitchPlugin.Room(channel);
        room = channel.name in plugin.rooms;
        room.lastNMessages.resize(TwitchPlugin.Room.messageMemory);
    }

    return room;
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
void onUserstate(TwitchPlugin plugin, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    mixin(memoryCorruptionCheck);

    void registerOpMod()
    {
        if (auto channel = event.channel.name in plugin.state.channels)
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
        else
        {
            // When can this happen?
        }
    }

    if (event.target.class_ >= IRCUser.Class.operator)
    {
        // All is well
        registerOpMod();
    }
    else if (
        !plugin.twitchSettings.promoteBroadcasters &&
        event.target.badges.canFind("broadcaster/"))
    {
        // All is also well
        registerOpMod();
    }
    else if (
        !plugin.twitchSettings.promoteModerators &&
        event.target.badges.canFind("moderator/"))
    {
        // Likewise
        registerOpMod();
    }
    else
    {
        // It's a home channel yet we don't seem to be a moderator
        auto room = getRoom(plugin, event.channel);

        if (!room.sawUserstate)
        {
            // First USERSTATE; warn about not being mod
            room.sawUserstate = true;
            enum pattern = "The bot is not a moderator of home channel <l>%s</>. " ~
                "Consider elevating it to such to avoid being as rate-limited.";
            logger.warningf(pattern, event.channel.name);
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
void onGlobalUserstate(TwitchPlugin plugin, const IRCEvent _)
{
    import kameloso.plugins.twitch.emotes : importCustomEmotes;

    mixin(memoryCorruptionCheck);

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
void onSelfpart(TwitchPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    auto room = event.channel.name in plugin.rooms;

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

    plugin.rooms.remove(event.channel.name);
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
void onCommandUptime(TwitchPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    const room = event.channel.name in plugin.rooms;
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
    import core.time : Duration;

    if (room.stream.live)
    {
        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = Duration.zero;
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
void onCommandFollowAge(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : startsWith;

    mixin(memoryCorruptionCheck);

    auto room = event.channel.name in plugin.rooms;
    assert(room, "Tried to look up follow age in a nonexistent room");

    string slice = event.content.stripped;  // mutable
    if ((slice.length) && (slice[0] == '@')) slice = slice[1..$];

    immutable otherNameSpecified = slice.length &&
        !slice.among(event.sender.nickname, event.sender.displayName);

    void sendNoSuchUser(const string name)
    {
        immutable message = "No such user: " ~ name;
        chan(plugin.state, event.channel.name, message);
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
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum pattern = "You have been a follower for %s, since %s.";
            immutable message = pattern.format(timeline, datestamp);
            chan(plugin.state, event.channel.name, message);
        }
    }

    void reportNotAFollower(const string name)
    {
        if (otherNameSpecified)
        {
            import std.format : format;

            immutable user = getTwitchUser(plugin, name, 0, searchByDisplayName: true);
            if (!user.nickname.length) return sendNoSuchUser(name);

            enum pattern = "%s is currently not a follower.";
            immutable message = pattern.format(user.displayName);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            // Assume the user is asking about itself
            enum message = "You are currently not a follower.";
            chan(plugin.state, event.channel.name, message);
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
)
void onRoomState(TwitchPlugin plugin, const IRCEvent event)
{
    import kameloso.constants : BufferSize;
    import kameloso.thread : ThreadMessage, boxed;
    import core.thread.fiber : Fiber;

    mixin(memoryCorruptionCheck);

    auto room = getRoom(plugin, event.channel);

    // Cache channel name by its numeric ID
    plugin.channelNamesByID[event.channel.id] = event.channel.name;

    void onRoomStateDg()
    {
        /+
            Fetch the broadcaster's Twitch user through an API call and store it as
            a new IRCUser in the plugin.state.users AA, including its display name.
            Additionally send the user to other plugins by way of a message to be
            picked up by the main event loop.
         +/
        const twitchUser = getTwitchUser(plugin, string.init, room.id);
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
        plugin.state.messages ~= ThreadMessage.putUser(string.init, boxed(userCopy));

        /+
            Start room monitors for the channel. We can assume they have not already
            been started, as room was either null or room.id was set above.
         +/
        startRoomMonitors(plugin, event.channel.name);

        if (plugin.twitchSettings.customEmotes)
        {
            import kameloso.plugins.twitch.emotes : baseDelayBetweenImports;
            import kameloso.plugins.common.scheduling : delay;
            import kameloso.constants : BufferSize;
            import std.algorithm.searching : countUntil;

            void importEmotesDg()
            {
                import kameloso.plugins.twitch.emotes : importCustomEmotes;
                importCustomEmotes(
                    plugin: plugin,
                    channelName: event.channel.name,
                    id: room.id);
            }

            /+
                Stagger imports a bit.
             +/
            immutable homeIndex = plugin.state.bot.homeChannels.countUntil(event.channel.name);
            alias multiplier = homeIndex;
            immutable delayUntilImport = baseDelayBetweenImports * multiplier;

            auto importEmotesFiber = new Fiber(&importEmotesDg, BufferSize.fiberStack);
            delay(plugin, importEmotesFiber, delayUntilImport);
        }

        auto creds = event.channel.name in plugin.secretsByChannel;

        if (creds && creds.broadcasterKey.length)
        {
            void onExpiryDg()
            {
                enum pattern = "The broadcaster-level access token for channel <l>%s</> has expired. " ~
                    "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
                logger.errorf(pattern, event.channel.name);

                // Keep the old keys so the error message repeats next execution
                /*creds.broadcasterKey = string.init;
                creds.broadcasterBearerToken = string.init;
                //creds.broadcasterKeyExpiry = 0;  // keep it for reference
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);*/
            }

            try
            {
                import std.datetime.systime : SysTime;
                generateExpiryReminders(
                    plugin,
                    SysTime.fromUnixTime(creds.broadcasterKeyExpiry),
                    "The broadcaster-level authorisation token for channel <l>" ~ event.channel.name ~ "</>",
                    &onExpiryDg);
            }
            catch (InvalidCredentialsException _)
            {
                onExpiryDg();
            }
        }
    }

    auto onRoomStateFiber = new Fiber(&onRoomStateDg, BufferSize.fiberStack);
    onRoomStateFiber.call();
}


// onNonHomeRoomState
/++
    Fetches custom BetterTV, FrankerFaceZ and 7tv emotes for a any non-home channel iff
    version the relevant configuration bool is set.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(~ChannelPolicy.home)  // on all but homes
)
void onNonHomeRoomState(TwitchPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.twitch.emotes : baseDelayBetweenImports, importCustomEmotes;
    import kameloso.plugins.common.scheduling : delay;
    import std.algorithm.searching : countUntil;
    import core.thread.fiber : Fiber;
    import kameloso.constants : BufferSize;

    mixin(memoryCorruptionCheck);

    // Cache channel name by its numeric ID
    assert(event.channel.id);
    plugin.channelNamesByID[event.channel.id] = event.channel.name;

    if (!plugin.twitchSettings.customEmotes || !plugin.twitchSettings.customEmotesEverywhere) return;

    if (const customChannelEmotes = event.channel.name in plugin.customChannelEmotes)
    {
        if (customChannelEmotes.emotes.length)
        {
            // Already done
            return;
        }
    }

    /+
        Delay Fiber.getThis() first and then import
     +/
    immutable guestIndex = plugin.state.bot.guestChannels.countUntil(event.channel.name);

    immutable delayMultiplier = (guestIndex != -1) ?
        // It's a guest channel
        cast(uint)(plugin.state.bot.homeChannels.length + guestIndex) :

        // Channel joined via piped command or admin join command
        // Invent a delay based on the hash of the channel name
        // padded by the number of home and guest channels
        cast(uint)(plugin.state.bot.homeChannels.length +
            plugin.state.bot.guestChannels.length +
            (event.channel.name.hashOf % 5));

    void importDg()
    {
        importCustomEmotes(
            plugin: plugin,
            channelName: event.channel.name.idup,
            id: event.channel.id);
    }

    auto importFiber = new Fiber(&importDg, BufferSize.fiberStack);
    immutable delayUntilImport = baseDelayBetweenImports * delayMultiplier;
    delay(plugin, importFiber, delayUntilImport);
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
void onCommandShoutout(TwitchPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : idOf;
    import lu.string : SplitResults, splitInto, stripped;
    import std.algorithm.searching : startsWith;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [name of streamer] [optional number of times to spam]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendCountNotANumber()
    {
        enum message = "The passed count is not a number.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendInvalidStreamerName()
    {
        enum message = "Invalid streamer name.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoSuchUser(const string target)
    {
        immutable message = "No such user: " ~ target;
        chan(plugin.state, event.channel.name, message);
    }

    void sendUserHasNoChannel()
    {
        enum message = "Impossible error; user has no channel?";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNoShoutoutOfCurrentChannel()
    {
        enum message = "Can't give a shoutout to the current channel...";
        chan(plugin.state, event.channel.name, message);
    }

    void sendOtherError()
    {
        enum message = "An error occurred when preparing the shoutout.";
        chan(plugin.state, event.channel.name, message);
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

    if (login == event.channel.name[1..$])
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
        chan(plugin.state, event.channel.name, message);
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
void onCommandVanish(TwitchPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    try
    {
        cast(void)timeoutUser(plugin, event.channel.name, event.sender.id, 1);
    }
    catch (ErrorJSONException e)
    {
        import kameloso.plugins.common : nameOf;
        enum pattern = "Failed to vanish <l>%s</> in <l>%s</> <t>(%s)";
        logger.warningf(pattern, nameOf(event.sender), event.channel.name, e.msg);
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
void onCommandRepeat(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : count;
    import std.algorithm.comparison : min;
    import std.conv : ConvException, to;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [number of times] [text...]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNumTimesGTZero()
    {
        enum message = "Number of times must be greater than 0.";
        chan(plugin.state, event.channel.name, message);
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
            chan(plugin.state, event.channel.name, slice);
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
void onCommandSubs(TwitchPlugin plugin, const IRCEvent event)
{
    import std.format : format;

    mixin(memoryCorruptionCheck);

    const room = event.channel.name in plugin.rooms;
    assert(room, "Tried to get the subscriber count of a channel for which there existed no room");

    try
    {
        enum pattern = "%s has %d subscribers.";
        const subs = getSubscribers(plugin, event.channel.name, totalOnly: true);
        immutable message = pattern.format(room.broadcasterDisplayName, subs[0].total);
        chan(plugin.state, event.channel.name, message);
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
        [kameloso.plugins.twitch.providers.google.addVideoToYouTubePlaylist]
        [kameloso.plugins.twitch.providers.spotify.addTrackToSpotifyPlaylist]
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
void onCommandSongRequest(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : canFind;
    import std.format : format;
    import core.time : seconds;

    mixin(memoryCorruptionCheck);

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
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMissingCredentials()
    {
        immutable channelMessage = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Missing Google API credentials and/or YouTube playlist ID." :
            "Missing Spotify API credentials and/or Spotify playlist ID.";
        immutable terminalMessage = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            channelMessage ~ " Run the program with <l>--set twitch.googleKeygen</> to set it up." :
            channelMessage ~ " Run the program with <l>--set twitch.spotifyKeygen</> to set it up.";
        chan(plugin.state, event.channel.name, channelMessage);
        logger.error(terminalMessage);
    }

    void sendInvalidCredentials()
    {
        immutable message = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Invalid Google API credentials." :
            "Invalid Spotify API credentials.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendAtLastNSecondsMustPass()
    {
        import kameloso.time : timeSince;

        enum pattern = "At least %s must pass between song requests.";
        immutable duration = timeSince(minimumTimeBetweenSongRequests.seconds);
        immutable message = pattern.format(duration);
        chan(plugin.state, event.channel.name, message);
    }

    void sendInsufficientPermissions()
    {
        enum message = "You do not have the needed permissions to issue song requests.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendInvalidURL()
    {
        immutable message = (plugin.twitchSettings.songrequestMode == SongRequestMode.youtube) ?
            "Invalid YouTube video URL." :
            "Invalid Spotify track URL.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNonspecificError()
    {
        enum message = "A non-specific error occurred.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendAddedToYouTubePlaylist(const string title)
    {
        enum pattern = "%s added to playlist.";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel.name, message);
    }

    void sendAddedToSpotifyPlaylist(const string artist, const string track)
    {
        enum pattern = "%s - %s added to playlist.";
        immutable message = pattern.format(artist, track);
        chan(plugin.state, event.channel.name, message);
    }

    if (plugin.twitchSettings.songrequestMode == SongRequestMode.disabled) return;

    if (event.sender.class_ < plugin.twitchSettings.songrequestPermsNeeded)
    {
        return sendInsufficientPermissions();
    }

    auto room = event.channel.name in plugin.rooms;  // must be mutable for history
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
            url.canFind(' ') ||
            !url.canFind("youtube.com/", "youtu.be/"))
        {
            return sendUsage();
        }

        auto creds = event.channel.name in plugin.secretsByChannel;
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
        else if (slice.canFind("youtube.com/watch?v="))
        {
            slice.advancePast("youtube.com/watch?v=");
            videoID = slice.advancePast('&', inherit: true);
        }
        else if (slice.canFind("youtu.be/"))
        {
            slice.advancePast("youtu.be/");
            videoID = slice.advancePast('?', inherit: true);
        }
        else
        {
            //return logger.warning("Bad link parsing?");
            return sendInvalidURL();
        }

        void addYouTubeVideoDg()
        {
            try
            {
                import kameloso.plugins.twitch.providers.google : addVideoToYouTubePlaylist;
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

        retryDelegate(plugin, &addYouTubeVideoDg);
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
            url.canFind(' ') ||
            !url.canFind("spotify.com/track/"))
        {
            return sendUsage();
        }

        auto creds = event.channel.name in plugin.secretsByChannel;
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
        else if (slice.canFind("spotify.com/track/"))
        {
            slice.advancePast("spotify.com/track/");
            trackID = slice.advancePast('?', inherit: true);
        }
        else
        {
            return sendInvalidURL();
        }

        try
        {
            import kameloso.plugins.twitch.providers.spotify : addTrackToSpotifyPlaylist, getSpotifyTrackByID;
            import std.json : JSONType;

            immutable json = addTrackToSpotifyPlaylist(plugin, *creds, trackID);

            if ((json.type != JSONType.object) || ("snapshot_id" !in json))
            {
                logger.error("Unexpected JSON in Spotify response.");
                logger.trace(json.toPrettyString);
                return;
            }

            const trackJSON = getSpotifyTrackByID(
                plugin,
                *creds,
                trackID);
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
void onCommandStartPoll(TwitchPlugin plugin, const IRCEvent event)
{
    import kameloso.time : DurationStringException, asAbbreviatedDuration;
    import lu.string : splitWithQuotes;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.json : JSONType;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        import std.format : format;
        enum pattern = `Usage: %s%s "[poll title]" [duration] "[choice 1]" "[choice 2]" ...`;
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
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
        return chan(plugin.state, event.channel.name, message);
    }
    /*catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel.name, e.msg);
    }*/
    catch (Exception e)
    {
        return chan(plugin.state, event.channel.name, e.msg);
    }

    try
    {
        const poll = createPoll(plugin, event.channel.name, title, durationString, choices);
        enum pattern = `Poll "%s" created.`;
        immutable message = pattern.format(poll.title);
        chan(plugin.state, event.channel.name, message);
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

            chan(plugin.state, event.channel.name, message);
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
void onCommandEndPoll(TwitchPlugin plugin, const IRCEvent event)
{
    import std.json : JSONType;

    mixin(memoryCorruptionCheck);

    try
    {
        const polls = getPolls(plugin, event.channel.name);

        if (!polls.length)
        {
            enum message = "There are no active polls to end.";
            return chan(plugin.state, event.channel.name, message);
        }

        const endedPoll = endPoll(
            plugin,
            event.channel.name,
            polls[0].pollID,
            terminate: true);

        alias Status = typeof(endedPoll.status);

        if (endedPoll.status != Status.active)
        {
            import lu.conv : toString;
            import std.format : format;

            enum pattern = "Poll ended; status %s";
            immutable message = pattern.format(endedPoll.status.toString());
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "Failed to end poll; status remains active";
            chan(plugin.state, event.channel.name, message);
        }
    }
    catch (EmptyDataJSONException e)
    {
        enum message = "There are no active polls to end.";
        chan(plugin.state, event.channel.name, message);
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
void onCommandNuke(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : plurality, stripped, unquoted;
    import std.uni : toLower;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        import std.format : format;
        enum pattern = "Usage: %s%s [word or phrase]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    if (!event.content.length) return sendUsage();

    immutable phraseToLower = event.content
        .stripped
        .unquoted
        .toLower;
    if (!phraseToLower.length) return sendUsage();

    auto deleteEvent(const IRCEvent storedEvent)
    {
        version(PrintStacktraces)
        void printStacktrace(Exception e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                import std.stdio : stdout, writeln;
                writeln(e);
                stdout.flush();
            }
        }

        try
        {
            immutable response = deleteMessage(plugin, event.channel.name, storedEvent.id);

            if ((response.code >= 200) && (response.code < 300))
            {
                return true;
            }
            else
            {
                import kameloso.plugins.common : nameOf;

                enum pattern = "Failed to delete a message from <h>%s</> in <l>%s";
                logger.warningf(pattern, nameOf(storedEvent.sender), event.channel.name);

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
        catch (ErrorJSONException e)
        {
            logger.error(e.msg);

            if (e.json["message"].str == "You cannot delete the broadcaster's messages.")
            {
                // Should never happen as we filter by class_ before calling this...
                return false;
            }

            version(PrintStacktraces) printStacktrace(e);
            return false;
        }
        catch (Exception e)
        {
            version(PrintStacktraces) printStacktrace(e);
            return false;
        }
    }

    auto room = event.channel.name in plugin.rooms;
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
void onEndOfMOTD(TwitchPlugin plugin, const IRCEvent _)
{
    import std.algorithm.comparison : max;
    import std.algorithm.searching : startsWith;
    import std.concurrency : spawn;

    mixin(memoryCorruptionCheck);

    // Concatenate the Bearer and OAuth headers once.
    // This has to be done *after* connect's register
    immutable pass = plugin.state.bot.pass.startsWith("oauth:") ?
        plugin.state.bot.pass[6..$] :
        plugin.state.bot.pass;
    plugin.transient.authorizationBearer = "Bearer " ~ pass;

    // Use a minimum of one worker thread, regardless of setting
    plugin.transient.workerTids.length =
        max(plugin.twitchSettings.workerThreads, 1);

    foreach (ref workerTid; plugin.transient.workerTids)
    {
        import std.concurrency : Tid, spawn;

        if (workerTid != Tid.init) continue;  // to be safe

        workerTid = spawn(
            &persistentQuerier,
            plugin.responseBucket,
            plugin.state.connSettings.caBundleFile);
    }

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
void onCommandEcount(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast;
    import std.array : replace;
    import std.format : format;
    import std.conv  : to;

    mixin(memoryCorruptionCheck);

    if (!plugin.twitchSettings.ecount) return;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [emote]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNotATwitchEmote()
    {
        enum message = "That is not a (known) Twitch, BetterTTV, FrankerFaceZ or 7tv emote.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendResults(const long count)
    {
        // 425618:3-5,7-8/peepoLeave:9-18
        string slice = event.emotes;  // mutable
        slice.advancePast(':');

        immutable start = slice.advancePast('-').to!size_t;
        immutable end = slice
            .advancePast('/', inherit: true)
            .advancePast(',', inherit: true)
            .to!size_t + 1;  // upper-bound inclusive!

        string rawSlice = event.raw;  // mutable
        rawSlice.advancePast(event.channel.name);
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
        chan(plugin.state, event.channel.name, message);
    }

    if (!event.content.length)
    {
        return sendUsage();
    }
    else if (!event.emotes.length)
    {
        return sendNotATwitchEmote();
    }

    const channelcounts = event.channel.name in plugin.ecount;
    if (!channelcounts) return sendResults(0L);

    string slice = event.emotes;

    // Replace emote colons so as not to conflict with emote tag syntax
    immutable id = slice
        .advancePast(':')
        .replace(':', ';');

    const thisEmoteCount = id in *channelcounts;
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
void onCommandWatchtime(TwitchPlugin plugin, const IRCEvent event)
{
    import kameloso.time : timeSince;
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : startsWith;
    import std.format : format;
    import core.time : Duration;

    mixin(memoryCorruptionCheck);

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
        string givenName = slice.advancePast(' ', inherit: true);  // mutable
        if (givenName.startsWith('@')) givenName = givenName[1..$];
        immutable user = getTwitchUser(plugin, givenName, 0, searchByDisplayName: true);

        if (!user.nickname.length)
        {
            immutable message = "No such user: " ~ givenName;
            return chan(plugin.state, event.channel.name, message);
        }

        nickname = user.nickname;
        displayName = user.displayName;
    }

    void reportNoViewerTime()
    {
        enum pattern = "%s has not been watching this channel's streams.";
        immutable message = pattern.format(displayName);
        chan(plugin.state, event.channel.name, message);
    }

    void reportViewerTime(const Duration time)
    {
        enum pattern = "%s has been a viewer for a total of %s.";
        immutable message = pattern.format(displayName, timeSince(time));
        chan(plugin.state, event.channel.name, message);
    }

    void reportNoViewerTimeInvoker()
    {
        enum message = "You have not been watching this channel's streams.";
        chan(plugin.state, event.channel.name, message);
    }

    void reportViewerTimeInvoker(const Duration time)
    {
        enum pattern = "You have been a viewer for a total of %s.";
        immutable message = pattern.format(timeSince(time));
        chan(plugin.state, event.channel.name, message);
    }

    if (nickname == event.channel.name[1..$])
    {
        if (nameSpecified)
        {
            enum pattern = "%s is the streamer though...";
            immutable message = pattern.format(nickname);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "You are the streamer though...";
            chan(plugin.state, event.channel.name, message);
        }
        return;
    }
    else if (nickname == plugin.state.client.nickname)
    {
        enum message = "I've seen it all.";
        return chan(plugin.state, event.channel.name, message);
    }

    if (const channelViewerTimes = event.channel.name in plugin.viewerTimesByChannel)
    {
        if (const viewerTime = nickname in *channelViewerTimes)
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
void onCommandSetTitle(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    immutable unescapedTitle = event.content.stripped;

    if (!unescapedTitle.length)
    {
        enum pattern = "Usage: %s%s [title]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        return chan(plugin.state, event.channel.name, message);
    }

    immutable title = unescapedTitle.unquoted.replace(`"`, `\"`);

    try
    {
        setChannelTitle(plugin, event.channel.name, title);
        enum pattern = "Channel title set to: %s";
        immutable message = pattern.format(title);
        chan(plugin.state, event.channel.name, message);
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
void onCommandSetGame(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : stripped, unquoted;
    import std.array : replace;
    import std.conv : to;
    import std.format : format;
    import std.string : isNumeric;
    import std.uri : encodeComponent;

    mixin(memoryCorruptionCheck);

    immutable unescapedGameName = event.content.stripped;

    if (!unescapedGameName.length)
    {
        const channelInfo = getChannel(plugin, event.channel.name);

        enum pattern = "Currently playing game: %s";
        immutable gameName = channelInfo.gameName.length ?
            channelInfo.gameName :
            "(nothing)";
        immutable message = pattern.format(gameName);
        return chan(plugin.state, event.channel.name, message);
    }

    immutable specified = unescapedGameName.unquoted.replace(`"`, `\"`);
    immutable numberSupplied = (specified.length && specified.isNumeric);
    ulong gameID = numberSupplied ? specified.to!ulong : 0;  // mutable

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

        setChannelGame(plugin, event.channel.name, gameID);
        enum pattern = "Game set to: %s";
        immutable message = pattern.format(name);
        chan(plugin.state, event.channel.name, message);
    }
    catch (EmptyResponseException _)
    {
        enum message = "Empty response from server!";
        chan(plugin.state, event.channel.name, message);
    }
    catch (EmptyDataJSONException _)
    {
        enum message = "Could not find a game by that name; check spelling.";
        chan(plugin.state, event.channel.name, message);
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
void onCommandCommercial(TwitchPlugin plugin, const IRCEvent event)
{
    import lu.string : stripped;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : endsWith;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    string lengthString = event.content.stripped;  // mutable
    if (lengthString.endsWith('s')) lengthString = lengthString[0..$-1];

    if (!lengthString.length)
    {
        enum pattern = "Usage: %s%s [commercial duration; valid values are 30, 60, 90, 120, 150 and 180]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        return chan(plugin.state, event.channel.name, message);
    }

    void sendNoOngoingStream()
    {
        enum message = "There is no ongoing stream.";
        chan(plugin.state, event.channel.name, message);
    }

    const room = event.channel.name in plugin.rooms;
    assert(room, "Tried to start a commercial in a nonexistent room");

    if (!room.stream.live) return sendNoOngoingStream();

    if (!lengthString.among!("30", "60", "90", "120", "150", "180"))
    {
        enum message = "Commercial duration must be one of 30, 60, 90, 120, 150 or 180.";
        return chan(plugin.state, event.channel.name, message);
    }

    try
    {
        startCommercial(plugin, event.channel.name, lengthString);
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
        chan(plugin.state, event.channel.name, message);
    }
    catch (TwitchQueryException e)
    {
        if (e.code == 400) // Bad Request
        {
            chan(plugin.state, event.channel.name, e.msg);
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
    import kameloso.plugins.common : IRCPluginInitialisationException;
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

    if (someKeygenWanted || (!plugin.state.bot.pass.length && !plugin.state.coreSettings.force))
    {
        import kameloso.thread : ThreadMessage;
        import lu.json : JSONStorage;

        if (plugin.state.coreSettings.headless)
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
            (!plugin.state.bot.pass.length && !plugin.state.coreSettings.force))
        {
            import kameloso.plugins.twitch.providers.twitch : requestTwitchKey;
            requestTwitchKey(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.keygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.keygen");
            needSeparator = true;
        }

        if (plugin.twitchSettings.superKeygen)
        {
            import kameloso.plugins.twitch.providers.twitch : requestTwitchSuperKey;
            if (needSeparator) logger.trace(separator);
            requestTwitchSuperKey(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.superKeygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.superKeygen");
            needSeparator = true;
        }

        if (plugin.twitchSettings.googleKeygen ||
            plugin.twitchSettings.youtubeKeygen)
        {
            import kameloso.plugins.twitch.providers.google : requestGoogleKeys;
            if (needSeparator) logger.trace(separator);
            requestGoogleKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.twitchSettings.googleKeygen = false;
            plugin.twitchSettings.youtubeKeygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.googleKeygen");
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.youtubeKeygen");
            needSeparator = true;
        }

        if (plugin.twitchSettings.spotifyKeygen)
        {
            import kameloso.plugins.twitch.providers.spotify : requestSpotifyKeys;
            if (needSeparator) logger.trace(separator);
            requestSpotifyKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.spotifyKeygen");
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
void onMyInfo(TwitchPlugin plugin, const IRCEvent _)
{
    // Load ecounts and such.
    mixin(memoryCorruptionCheck);
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
    import kameloso.plugins.common.scheduling : delay;
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
                delay(plugin, monitorUpdatePeriodicity, yield: true);
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

            delay(plugin, monitorUpdatePeriodicity, yield: true);
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

            delay(plugin, monitorUpdatePeriodicity, yield: true);
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

            delay(plugin, (now.nextMidnight - now), yield: true);
        }
    }

    auto uptimeMonitorFiber = new Fiber(&uptimeMonitorDg, BufferSize.fiberStack);
    auto chatterMonitorFiber = new Fiber(&chatterMonitorDg, BufferSize.fiberStack);
    auto cacheFollowersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);

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

    Note: Must be called from within a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startValidator(TwitchPlugin plugin)
in (Fiber.getThis(), "Tried to call `startValidator` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : delay;
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
            validationJSON = getValidation(plugin, plugin.state.bot.pass, async: true);
        }
        catch (TwitchQueryException e)
        {
            if (plugin.state.coreSettings.headless)
            {
                //version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, yield: true);
            }
            else
            {
                import kameloso.constants : MagicErrorStrings;

                if (e.msg == MagicErrorStrings.sslLibraryNotFoundRewritten)
                {
                    enum sslMessage = "Failed to validate Twitch API keys: <l>" ~
                        cast(string)MagicErrorStrings.sslLibraryNotFoundRewritten ~
                        " <t>(is OpenSSL installed?)";
                    logger.warning(sslMessage);
                    logger.warning(cast(string)MagicErrorStrings.visitWikiOneliner);
                    logger.warning("Expect the Twitch plugin to largely break.");

                    version(Windows)
                    {
                        logger.warning(cast(string)MagicErrorStrings.getOpenSSLSuggestion);
                    }

                    logger.trace();
                    // Unrecoverable
                    return;
                }
                else
                {
                    enum pattern = "Failed to validate Twitch API keys: <l>%s</> (<l>%s</>) <t>(%d)";
                    logger.warningf(pattern, e.msg, e.error, e.code);
                }

                version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, yield: true);
            }
            continue;
        }
        catch (EmptyResponseException e)
        {
            if (plugin.state.coreSettings.headless)
            {
                //version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, yield: true);
            }
            else
            {
                // HTTP query failed; just retry
                enum pattern = "Failed to validate Twitch API keys: <t>%s</>";
                logger.errorf(pattern, e.msg);
                version(PrintStacktraces) logger.trace(e);
                delay(plugin, retryDelay, yield: true);
            }
            continue;
        }

        const userIDJSON = "user_id" in validationJSON;
        if (!userIDJSON)
        {
            // No key in response?
            delay(plugin, retryDelay, yield: true);
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

    if (plugin.state.coreSettings.headless)
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


// generateExpiryReminders
/++
    Generates and delays Twitch authorisation token expiry reminders.

    Params:
        plugin = The current [TwitchPlugin].
        expiresWhen = A [std.datetime.systime.SysTime|SysTime] of when the expiry occurs.
        what = The string of what kind of token is expiring.
        onExpiryDg = Delegate to call when the token expires.
 +/
void generateExpiryReminders(
    TwitchPlugin plugin,
    const SysTime expiresWhen,
    const string what,
    void delegate() onExpiryDg)
{
    import kameloso.plugins.common.scheduling : delay;
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
        enum pattern = "%s will expire in <l>%d days</> on <l>%4d-%02d-%02d";
        logger.infof(
            pattern,
            what,
            numDays,
            expiresWhen.year,
            cast(uint)expiresWhen.month,
            expiresWhen.day);
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
            enum pattern = "Warning: %s will expire " ~
                "in <l>%d %s and %d %s</> at <l>%4d-%02d-%02d %02d:%02d";
            logger.warningf(
                pattern,
                what,
                numDays, numDays.plurality("day", "days"),
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.year, cast(uint)expiresWhen.month, expiresWhen.day,
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "Warning: %s will expire " ~
                "in <l>%d %s</> at <l>%4d-%02d-%02d %02d:%02d";
            logger.warningf(
                pattern,
                what,
                numDays, numDays.plurality("day", "days"),
                expiresWhen.year, cast(uint)expiresWhen.month, expiresWhen.day,
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
            enum pattern = "WARNING: %s will expire " ~
                "in <l>%d %s and %d %s</> at <l>%02d:%02d";
            logger.warningf(
                pattern,
                what,
                numHours, numHours.plurality("hour", "hours"),
                numMinutes, numMinutes.plurality("minute", "minutes"),
                expiresWhen.hour, expiresWhen.minute);
        }
        else
        {
            enum pattern = "WARNING: %s will expire in <l>%d %s</> at <l>%02d:%02d";
            logger.warningf(
                pattern,
                what,
                numHours, numHours.plurality("hour", "hours"),
                expiresWhen.hour, expiresWhen.minute);
        }
    }

    void warnOnMinutesDg()
    {
        immutable numMinutes = untilExpiry.total!"minutes";
        if (numMinutes <= 0) return;

        // Less than an hour; warning
        enum pattern = "WARNING: %s will expire in <l>%d minutes</> at <l>%02d:%02d";
        logger.warningf(
            pattern,
            what,
            numMinutes,
            expiresWhen.hour,
            expiresWhen.minute);
    }

    void onTrueExpiry()
    {
        // Key expired
        onExpiryDg();
    }

    alias reminderPoints = AliasSeq!
        (14.days,
        7.days,
        3.days,
        1.days,
        12.hours,
        6.hours,
        1.hours,
        30.minutes,
        10.minutes,
        5.minutes);

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

    // Notify on expiry, maybe quit
    delay(plugin, &onTrueExpiry, trueExpiry);

    // Also announce once normally how much time is left
    if (trueExpiry >= 1.weeks) warnOnWeeksDg();
    else if (trueExpiry >= 1.days) warnOnDaysDg();
    else if (trueExpiry >= 1.hours) warnOnHoursDg();
    else /*if (trueExpiry >= 1.minutes)*/ warnOnMinutesDg();
}


// complainAboutMissingTokens
/++
    Helper function to complain about missing Twitch authorisation tokens..

    Params:
        base = The exception to complain about.
 +/
void complainAboutMissingTokens(const Exception base)
{
    import kameloso.common : logger;

    bool match;  // mutable

    if (const e = cast(MissingBroadcasterTokenException)base)
    {
        enum pattern = "Missing broadcaster-level API token for channel <l>%s</>.";
        logger.errorf(pattern, e.channelName);
        match = true;
    }
    else if (const e = cast(InvalidCredentialsException)base)
    {
        enum pattern = "The broadcaster-level API token for channel <l>%s</> has expired.";
        logger.errorf(pattern, e.channelName);
        match = true;
    }

    if (match)
    {
        enum superMessage = "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
        logger.error(superMessage);
    }
}


// startSaver
/++
    Starts a saver routine.

    This will save resources to disk periodically.

    Note: Must be called from within a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [TwitchPlugin].
 +/
void startSaver(TwitchPlugin plugin)
in (Fiber.getThis(), "Tried to call `startSaver` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : delay;
    import lu.array : pruneAA;
    import core.time : hours;

    // How often to save `ecount`s and viewer times, to ward against losing information to crashes.
    static immutable savePeriodicity = 2.hours;

    // Periodically save ecounts and viewer times
    while (true)
    {
        delay(plugin, savePeriodicity, yield: true);

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

        // Remove empty entries from the channel names cache
        // This will make the postprocessing routine reattempt lookups
        pruneAA(plugin.channelNamesByID);
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

    Returns:
        `true` if changes were made; `false` if not.
 +/
auto promoteUserFromBadges(
    ref IRCUser.Class class_,
    const string badges,
    //const bool promoteBroadcasters,
    const bool promoteModerators,
    const bool promoteVIPs) pure @safe
{
    import std.string : indexOf;
    import std.algorithm.comparison : among;
    import std.algorithm.iteration : splitter;

    if (class_ >= IRCUser.Class.operator) return false;  // already as high as we go

    bool retval;

    foreach (immutable badge; badges.splitter(','))
    {
        if (!badge.length) continue;

        // Optimise this a bit because it's such a hotspot
        if (!badge[0].among!('s', 'v', 'm', /*'b'*/)) continue;

        immutable slashPos = badge.indexOf('/');
        if (!slashPos) break;  // something's wrong

        immutable badgePart = badge[0..slashPos];

        with (IRCUser.Class)
        switch (badgePart)
        {
        case "subscriber":
            if (class_ < registered)
            {
                class_ = registered;
                retval = true;
            }
            break;  // Check next badge

        case "vip":
            if (promoteVIPs && (class_ < elevated))
            {
                class_ = elevated;
                retval = true;
            }
            break;  // as above

        case "moderator":
            if (promoteModerators && (class_ < operator))
            {
                class_ = operator;
                return true;  // We don't go any higher than moderator until we uncomment the below
            }
            break;  // as above

        /+case "broadcaster":
            // This is already done by comparing the user's name to the channel
            // name in the calling function.

            if (promoteBroadcasters && (class_ < staff))
            {
                class_ = staff;
                return true;
            }
            return;  // No need to check more badges
         +/

        default:
            // Non-applicable badge
            break;
        }
    }

    return retval;
}

///
unittest
{
    import lu.conv : toString;

    {
        enum badges = "subscriber/12,sub-gift-leader/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(changed);
        enum expected = IRCUser.Class.registered;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "premium/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(!changed);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(changed);
        enum expected = IRCUser.Class.registered;  // because promoteVIPs false
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.elevated;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, true);
        assert(changed);
        enum expected = IRCUser.Class.registered;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "broadcaster/1,subscriber/12,partner/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, true);
        assert(changed);
        enum expected = IRCUser.Class.registered;  // not staff because broadcasters are identified elsewhere
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "moderator/1";  // no comma splitter test
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = "subscriber/1";
        auto class_ = IRCUser.Class.operator;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(!changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.staff;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(!changed);
        enum expected = IRCUser.Class.staff;
        assert((class_ == expected), class_.toString());
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(!changed);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), class_.toString());
    }
}


// sortBadges
/++
    Sorts a comma-separated list of badges so that the badges in the `badgeOrder`
    array are placed first, in the order they appear in the array.

    Params:
        badges = A reference to the comma-separated string of badges to sort in place.
        badgeOrder = The order of badges to sort by.
 +/
void sortBadges(ref string badges, const string[] badgeOrder)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : countUntil;
    import std.algorithm.sorting : sort;
    import std.array : Appender, join;
    import std.string : indexOf;

    static Appender!(string[]) sink;
    scope(exit) sink.clear();

    size_t lastIndex;
    bool inOrder = true;
    auto range = badges.splitter(',');

    foreach (immutable badge; range)
    {
        if (!badge.length) continue;  // should never happen

        immutable slashIndex = badge.indexOf('/');

        if (slashIndex == -1)
        {
            // Malformed badges? should also never happen
            throw new Exception("Malformed badge was missing a slash: " ~ badge);
        }

        immutable badgeName = badge[0..slashIndex];

        if (inOrder)
        {
            immutable badgeIndex = badgeOrder.countUntil(badgeName);
            inOrder = (badgeIndex >= lastIndex);
            lastIndex = badgeIndex;
        }

        sink.put(badge);
    }

    // No need to do anything if the badges were already ordered
    if (inOrder) return;

    auto compareBadges(const string a, const string b)
    {
        // Slashes are guaranteed to be present, we already checked
        immutable aSlashIndex = a.indexOf('/');
        immutable bSlashIndex = b.indexOf('/');

        immutable aBadgeIndex = badgeOrder.countUntil(a[0..aSlashIndex]);
        immutable bBadgeIndex = badgeOrder.countUntil(b[0..bSlashIndex]);

        return size_t(aBadgeIndex) < size_t(bBadgeIndex);
    }

    // Insert it back into the original ref string
    badges = sink[]
        .sort!compareBadges
        .join(',');
}

///
unittest
{
    const string[4] badgeOrder =
    [
        "broadcaster",
        "moderator",
        "vip",
        "subscriber",
    ];

    {
        string badges = "subscriber/14,broadcaster/1";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "broadcaster/1,subscriber/14"), badges);
    }
    {
        string badges = "broadcaster/1,broadcaster/1";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "broadcaster/1,broadcaster/1"), badges);
    }
    {
        string badges = "subscriber/14,vip/1";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "vip/1,subscriber/14"), badges);
    }
    {
        string badges;
        sortBadges(badges, badgeOrder[]);
        assert(!badges.length, badges);
    }
    {
        string badges = "hirfharf/1,horfhorf/32";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "hirfharf/1,horfhorf/32"), badges);
    }
    {
        string badges = "subscriber/14,moderator/1";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "moderator/1,subscriber/14"), badges);
    }
    {
        string badges = "broadcaster/1,asdf/9999";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "broadcaster/1,asdf/9999"), badges);
    }
    {
        string badges = "subscriber/91,sub-gifter/25,broadcaster/1";
        sortBadges(badges, badgeOrder[]);
        assert((badges == "broadcaster/1,subscriber/91,sub-gifter/25"), badges);
    }
    {
        static immutable string[3] altBadgeOrder =
        [
            "a",
            "b",
            "c",
        ];

        string badges = "f/1,b/2,d/3,c/4,a/5,e/6";
        sortBadges(badges, altBadgeOrder[]);
        assert((badges == "a/5,b/2,c/4,f/1,d/3,e/6"), badges);
    }
}


// setup
/++
    Initialises the response bucket, else its internal [core.sync.mutex.Mutex|Mutex]
    will be null and cause a segfault when trying to lock it.
 +/
void setup(TwitchPlugin plugin)
{
    plugin.responseBucket.setup();
}


// teardown
/++
    De-initialises the plugin. Shuts down any persistent worker threads.
 +/
void teardown(TwitchPlugin plugin)
{
    import std.concurrency : Tid, send;

    foreach (workerTid; plugin.transient.workerTids)
    {
        import std.concurrency : Tid, prioritySend;

        if (workerTid == Tid.init) continue;
        workerTid.prioritySend(true);
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
auto postprocess(TwitchPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.comparison : among;
    import std.typecons : Ternary;

    if (plugin.twitchSettings.mapWhispersToChannel &&
        event.type.among!(IRCEvent.Type.QUERY, IRCEvent.Type.SELFQUERY))
    {
        import std.algorithm.searching : countUntil;

        alias pred = (channelName, senderNickname) => channelName.length && (senderNickname == channelName[1..$]);
        immutable channelIndex = plugin.state.bot.homeChannels.countUntil!pred(event.sender.nickname);

        if (channelIndex != -1)
        {
            event.type = IRCEvent.Type.CHAN;
            event.channel.name = plugin.state.bot.homeChannels[channelIndex];
            event.aux[0] = string.init;  // Whisper count
            event.target = IRCUser.init;
        }
    }
    else if (!event.channel.name.length)
    {
        return false;
    }

    Ternary isHomeChannel;

    /+
        Embed custom emotes.
     +/
    if (plugin.twitchSettings.customEmotes)
    {
        /+
            If the event is of a type that can contain custom emotes (which is any
            event with user input), embed them into the event's 'emotes` member.

            This is done only for events in home channels, unless the
            `customEmotesEverywhere` setting is enabled.
         +/
        immutable isEmotePossibleEventType = event.type.among!
            (IRCEvent.Type.CHAN,
            IRCEvent.Type.EMOTE,
            IRCEvent.Type.TWITCH_MILESTONE,
            IRCEvent.Type.TWITCH_BITSBADGETIER,
            IRCEvent.Type.TWITCH_CHEER,
            IRCEvent.Type.CLEARMSG,
            IRCEvent.Type.TWITCH_ANNOUNCEMENT,
            IRCEvent.Type.TWITCH_SUB,
            IRCEvent.Type.TWITCH_DIRECTCHEER,
            IRCEvent.Type.TWITCH_INTRO,
            IRCEvent.Type.TWITCH_RITUAL,
            IRCEvent.Type.SELFCHAN,
            IRCEvent.Type.SELFEMOTE);

        if (isEmotePossibleEventType &&
            (event.content.length || (event.target.nickname.length && event.altcontent.length)))
        {
            bool shouldEmbedCustomEmotes;

            if (plugin.twitchSettings.customEmotesEverywhere)
            {
                // Always embed regardless of channel
                shouldEmbedCustomEmotes = true;
            }
            else
            {
                import std.algorithm.searching : canFind;

                // Only embed if the event is in a home channel
                isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel.name);
                shouldEmbedCustomEmotes = (isHomeChannel == Ternary.yes);
            }

            if (shouldEmbedCustomEmotes)
            {
                import kameloso.plugins.twitch.emotes : embedCustomEmotes;

                const customChannelEmotes = event.channel.name in plugin.customChannelEmotes;
                const customEmotes = customChannelEmotes ? &customChannelEmotes.emotes : null;

                embedCustomEmotes(
                    content: event.content,
                    emotes: event.emotes,
                    customEmotes: customEmotes ? *customEmotes : null,
                    customGlobalEmotes: plugin.customGlobalEmotes);

                if (event.target.nickname.length && event.altcontent.length)
                {
                    embedCustomEmotes(
                        content: event.altcontent,
                        emotes: event.aux[$-2],
                        customEmotes: customEmotes ? *customEmotes : null,
                        customGlobalEmotes: plugin.customGlobalEmotes);
                }
            }
        }
    }

    /++
        Sort badges and infer user class based on them.
        Sort first so early returns don't skip the sorting.
     +/
    static bool postprocessImpl(
        /*const*/ TwitchPlugin plugin,
        ref IRCEvent event,
        ref IRCUser user,
        const bool isTarget)
    {
        import kameloso.thread : ThreadMessage, boxed;

        if (!user.nickname.length) return false;

        if (!isTarget && event.subchannel.id && !event.subchannel.name.length)
        {
            import std.conv : to;

            // Shared message
            immutable sharedChannelID = event.subchannel.id.to!ulong;

            if (const channelFromID = sharedChannelID in plugin.channelNamesByID)
            {
                if (channelFromID.length)
                {
                    // Found channel name in cache; insert into event.subchannel
                    event.subchannel.name = *channelFromID;
                }
            }
            else
            {
                import kameloso.plugins.common.scheduling : delay;
                import kameloso.constants : BufferSize;
                import core.thread.fiber : Fiber;
                import core.time : Duration;

                // We don't know the channel name, so look it up.

                void getChannelNameDg()
                {
                    /*if (plugin.state.coreSettings.trace)
                    {
                        enum pattern = "Querying server for channel name of user ID <l>%d</>...";
                        logger.infof(pattern, sharedChannelID);
                    }*/

                    scope(failure)
                    {
                        // getTwitchUser throws if the user ID is invalid
                        // plus we throw ourselves if the user ID does not have a channel
                        plugin.channelNamesByID.remove(sharedChannelID);
                    }

                    immutable twitchUser = getTwitchUser(
                        plugin,
                        id: sharedChannelID);

                    if (!twitchUser.nickname.length)
                    {
                        // Can this ever happen?
                        throw new Exception("Failed to resolve channel name from user ID");
                    }

                    immutable channelName = '#' ~ twitchUser.nickname;
                    plugin.channelNamesByID[sharedChannelID] = channelName;

                    if (plugin.state.coreSettings.trace)
                    {
                        enum pattern = "Resolved channel <l>%s</> from user ID <l>%d</>.";
                        logger.infof(pattern, channelName, sharedChannelID);
                    }
                }

                auto getChannelNameFiber = new Fiber(&getChannelNameDg, BufferSize.fiberStack);
                delay(plugin, getChannelNameFiber, Duration.zero);

                // Set an empty string so we don't do this again before the results are in
                plugin.channelNamesByID[sharedChannelID] = string.init;
            }
        }

        if (user.class_ == IRCUser.Class.blacklist)
        {
            // Ignore blacklist for obvious reasons
            return false;
        }

        if (user.badges.length)
        {
            // Move some badges to the front of the string, in order of importance
            static immutable string[4] badgeOrder =
            [
                "broadcaster",
                "moderator",
                "vip",
                "subscriber",
            ];

            sortBadges(user.badges, badgeOrder[]);
        }

        if (user.class_ >= IRCUser.Class.staff)
        {
            // User is already staff or higher, no need to promote
            return false;
        }

        if (plugin.twitchSettings.promoteBroadcasters)
        {
            // Already ensured channel has length in parent function
            if (user.nickname == event.channel.name[1..$])
            {
                // User is channel owner but is not registered as staff
                user.class_ = IRCUser.Class.staff;
                plugin.state.messages ~= ThreadMessage.putUser(event.channel.name, boxed(user));
                return true;
            }
        }

        if (user.badges.length)
        {
            /+
                Infer class from the user's badge(s).
                There's no sense in skipping this if promote{Moderators,VIPs} are false
                since it also always promotes subscribers.
             +/
            immutable changed = promoteUserFromBadges(
                user.class_,
                user.badges,
                //plugin.twitchSettings.promoteBroadcasters,
                plugin.twitchSettings.promoteModerators,
                plugin.twitchSettings.promoteVIPs);

            if (changed)
            {
                plugin.state.messages ~= ThreadMessage.putUser(event.channel.name, boxed(user));
                return true;
            }
        }

        return false;
    }

    if (!plugin.twitchSettings.promoteEverywhere && (isHomeChannel == Ternary.unknown))
    {
        import std.algorithm.searching : canFind;
        isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel.name);
    }

    if (plugin.twitchSettings.promoteEverywhere || (isHomeChannel == Ternary.yes))
    {
        /+
            Badges may change on some events, and the promotion hysteresis in
            `postprocessImpl` may prevent it from becoming picked up.
            Reset the user's updated timestamp to force a re-promotion.
         +/
        if (event.type.among!
            (IRCEvent.Type.TWITCH_SUB,
            IRCEvent.Type.TWITCH_SUBUPGRADE,
            IRCEvent.Type.TWITCH_SUBGIFT,
            IRCEvent.Type.TWITCH_BITSBADGETIER,
            IRCEvent.Type.TWITCH_EXTENDSUB))
        {
            event.sender.updated = 1L;
        }
        else if (event.type == IRCEvent.Type.TWITCH_GIFTRECEIVED)
        {
            event.target.updated = 1L;
        }

        bool shouldCheckMessages;
        shouldCheckMessages |= postprocessImpl(plugin, event, event.sender, isTarget: false);
        shouldCheckMessages |= postprocessImpl(plugin, event, event.target, isTarget: true);
        return shouldCheckMessages;
    }

    return false;
}


// initResources
/++
    Reads and writes resource files to disk, ensure that they're there and properly formatted.
 +/
void initResources(TwitchPlugin plugin)
{
    import kameloso.plugins.common : IRCPluginInitialisationException;
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
void saveResourceToDisk(/*const*/ RehashingAA!(long[string])[string] aa, const string filename)
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
    import core.memory : GC;

    GC.disable();
    scope(exit) GC.enable();

    JSONStorage ecountJSON;
    long[string][string] tempEcount;
    ecountJSON.load(plugin.ecountFile);
    tempEcount.populateFromJSON(ecountJSON);
    plugin.ecount = null;

    foreach (immutable channelName, channelCounts; tempEcount)
    {
        plugin.ecount[channelName] = RehashingAA!(long[string])(channelCounts);
    }

    JSONStorage viewersJSON;
    long[string][string] tempViewers;
    viewersJSON.load(plugin.viewersFile);
    tempViewers.populateFromJSON(viewersJSON);
    plugin.viewerTimesByChannel = null;

    foreach (immutable channelName, channelViewers; tempViewers)
    {
        plugin.viewerTimesByChannel[channelName] = RehashingAA!(long[string])(channelViewers);
    }

    JSONStorage secretsJSON;
    secretsJSON.load(plugin.secretsFile);
    plugin.secretsByChannel = null;

    foreach (immutable channelName, credsJSON; secretsJSON.storage.object)
    {
        plugin.secretsByChannel[channelName] = Credentials.fromJSON(credsJSON);
    }

    plugin.secretsByChannel.rehash();
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

        foreach (immutable channelName, ref customEmotes; plugin.customChannelEmotes)
        {
            import kameloso.plugins.twitch.emotes : baseDelayBetweenImports;
            import kameloso.plugins.common.scheduling : delay;
            import kameloso.constants : BufferSize;
            import std.algorithm.searching : countUntil;
            import core.thread.fiber : Fiber;
            import core.time : seconds;

            //plugin.customChannelEmotes[channelName].emotes = null;
            customEmotes.emotes = null;

            void importDg()
            {
                // Can't reuse the customEmotes pointer as it changes while looping
                importCustomEmotes(
                    plugin: plugin,
                    channelName: channelName,
                    id: plugin.customChannelEmotes[channelName].id);
            }

            uint delayMultiplier;
            immutable homeIndex = plugin.state.bot.homeChannels.countUntil(channelName);

            if (homeIndex != -1)
            {
                delayMultiplier = cast(uint)homeIndex;
            }
            else
            {
                immutable guestIndex = plugin.state.bot.guestChannels.countUntil(channelName);

                if (guestIndex != -1)
                {
                    // Channel joined via piped command or admin join command
                    delayMultiplier = cast(uint)(plugin.state.bot.homeChannels.length + guestIndex);
                }
                else
                {
                    // Invent a delay based on the hash of the channel name
                    // padded by the number of home and guest channels
                    delayMultiplier = cast(uint)
                        (plugin.state.bot.homeChannels.length +
                        plugin.state.bot.guestChannels.length +
                        (channelName.hashOf % 5));
                }
            }

            auto importFiber = new Fiber(&importDg, BufferSize.fiberStack);
            immutable delayUntilImport = baseDelayBetweenImports * delayMultiplier;
            delay(plugin, importFiber, delayUntilImport);
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
    /*shared*/ Sendable content)
{
    import kameloso.messaging : Message;
    import kameloso.thread : Boxed;

    if (header != "twitch") return;

    const message = cast(Boxed!Message)content;

    if (!message)
    {
        enum pattern = "The <l>%s</> plugin received an invalid bus message: expected type <l>%s";
        logger.errorf(pattern, plugin.name, typeof(message).stringof);
        return;
    }

    if (message.payload.event.type == IRCEvent.Type.QUERY)
    {
        plugin.whisperBuffer.put(message.payload);

        if (!plugin.transient.whispererRunning)
        {
            import kameloso.constants : BufferSize;
            import core.thread.fiber : Fiber;

            void whispererDg()
            {
                import kameloso.plugins.common.scheduling : delay;

                plugin.transient.whispererRunning = true;
                scope(exit) plugin.transient.whispererRunning = false;

                while (true)
                {
                    import core.time : msecs;

                    immutable untilNextSeconds = plugin.throttleline(plugin.whisperBuffer);
                    if (untilNextSeconds == 0.0) return;

                    immutable untilNextMsecs = cast(uint)(untilNextSeconds * 1000);
                    delay(plugin, untilNextMsecs.msecs, yield: true);
                }
            }

            auto whispererFiber = new Fiber(&whispererDg, BufferSize.fiberStack);
            whispererFiber.call();
        }
    }
    else
    {
        import lu.conv : toString;
        enum pattern = "Unknown message type <l>%s</> sent as TwitchPlugin bus message";
        logger.errorf(pattern, message.payload.event.type.toString());
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
            /*immutable*/ ulong _id;

        package:
            /++
                Whether or not the stream is currently ongoing.
             +/
            bool live; // = false;

            /++
                The numerical ID of the user/account of the channel owner.
             +/
            ulong userID;

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
            ulong gameID;

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
            RehashingAA!(bool[string]) chattersSeen;

            /++
                Hashmap of active viewers (who have shown activity).
             +/
            RehashingAA!(bool[string]) activeViewers;

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
            this(const ulong id) pure @safe nothrow @nogc
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
            Constructor taking a [dialect.defs.IRCEvent.Channel|Channel] instance.

            Params:
                channel = The channel to initialise this [Room] with.
         +/
        this(const IRCEvent.Channel channel) /*pure nothrow @nogc*/ @safe
        {
            import std.random : uniform;

            this.channelName = channel.name;
            this.broadcasterName = channelName[1..$];
            this.broadcasterDisplayName = this.broadcasterName;  // until we resolve it
            this.id = channel.id;
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
        ulong id;

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
    private:
        import std.concurrency : Tid;

    public:
        /++
            The thread IDs of the persistent worker threads.
         +/
        Tid[] workerTids;

        /++
            The index of the next worker thread to use.
         +/
        size_t currentWorkerTidIndex;

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
        const bool immediate = false)
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

            if (!this.state.coreSettings.headless)
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
                import kameloso.plugins.common.scheduling : delay;
                import core.time : seconds;

                // 429 Too Many Requests
                // rate limited; delay and try again without popping?
                delay(plugin, 10.seconds, yield: true);
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
        Custom emotes for a channel.

        Made into a struct so we can keep track of the channel ID.
     +/
    static struct CustomChannelEmotes
    {
        /++
            String name of the channel.
         +/
        string channelName;

        /++
            The channel's numerical Twitch ID.
         +/
        ulong id;

        /++
            Emote AA.
         +/
        bool[dstring] emotes;
    }

    /++
        Custom channel-specific BetterTTV, FrankerFaceZ and 7tv emotes, as
        fetched via API calls.
     +/
    CustomChannelEmotes[string] customChannelEmotes;

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
    RehashingAA!(long[string])[string] viewerTimesByChannel;

    /++
        API keys and tokens, keyed by channel.
     +/
    Credentials[string] secretsByChannel;

    /++
        Channel names cached by their numeric user IDs.
     +/
    string[ulong] channelNamesByID;

    /++
        Associative array of responses from async HTTP queries.
     +/
    MutexedAA!(QueryResponse[int]) responseBucket;

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
    RehashingAA!(long[string])[string] ecount;

    /++
        Buffer of messages to send as whispers.
     +/
    Buffer!(Message, No.dynamic, BufferSize.outbuffer) whisperBuffer;

    /++
        Returns the next worker thread ID to use, cycling through them.
     +/
    auto getNextWorkerTid()
    in (transient.workerTids.length, "Tried to get a worker Tid when there were none")
    {
        if (transient.currentWorkerTidIndex >= transient.workerTids.length)
        {
            transient.currentWorkerTidIndex = 0;
        }

        return transient.workerTids[transient.currentWorkerTidIndex++];
    }

    // isEnabled
    /++
        Override
        [kameloso.plugins.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
        and inject a server check, so this plugin only works on Twitch, in addition
        to doing nothing when [TwitchSettings.enabled] is false.

        If a keygen is requested, this overrides all other checks.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    override public bool isEnabled() const pure nothrow @nogc
    {
        immutable wantKeygen =
            (twitchSettings.keygen ||
            twitchSettings.superKeygen ||
            twitchSettings.googleKeygen ||
            twitchSettings.youtubeKeygen ||
            twitchSettings.spotifyKeygen);

        return (
            wantKeygen ||  // Always enabled if we want to generate keys
            (twitchSettings.enabled &&
                (state.server.daemon == IRCServer.Daemon.twitch) ||
                (state.server.daemon == IRCServer.Daemon.unset)));
    }

    mixin IRCPluginImpl;
}

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
        [kameloso.plugins.twitch.api.actions],
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

import kameloso.plugins.twitch.api.actions;
import kameloso.plugins.twitch.common;
import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import kameloso.net :
    EmptyDataJSONException,
    EmptyResponseException,
    ErrorJSONException,
    HTTPQueryException,
    UnexpectedJSONException;
import kameloso.thread : Sendable;
import dialect.defs;
import dialect.postprocessors.twitch;  // To trigger the module ctor
import std.datetime.systime : SysTime;
import std.typecons : Flag, No, Yes;
import core.thread.fiber : Fiber;
import core.time : Duration;


// Credentials
/++
    Credentials needed to access APIs like that of Google and Spotify.

    See_Also:
        https://console.cloud.google.com/apis/credentials
 +/
package struct Credentials
{
    /++
        JSON schema for the credentials file.
     +/
    static struct JSONSchema
    {
        string broadcasterKey;  ///
        string broadcasterBearerToken;  ///
        long broadcasterKeyExpiry;  ///
        string googleClientID;  ///
        string googleClientSecret;  ///
        string googleAccessToken;  ///
        string googleRefreshToken;  ///
        string youtubePlaylistID;  ///
        string spotifyClientID;  ///
        string spotifyClientSecret;  ///
        string spotifyAccessToken;  ///
        string spotifyRefreshToken;  ///
        string spotifyPlaylistID;  ///

        /++
            Returns a [std.json.JSONValue|JSONValue] object with the same data as this one.
         +/
        auto asJSONValue() const
        {
            import std.json : JSONValue;

            JSONValue json;
            json.object = null;
            json["broadcasterKey"] = this.broadcasterKey;
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
            json["broadcasterBearerToken"] = this.broadcasterBearerToken;
            return json;
        }
    }

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
        Constructor.
     +/
    this(const JSONSchema schema)
    {
        this.broadcasterKey = schema.broadcasterKey;
        this.googleClientID = schema.googleClientID;
        this.googleClientSecret = schema.googleClientSecret;
        this.googleAccessToken = schema.googleAccessToken;
        this.googleRefreshToken = schema.googleRefreshToken;
        this.youtubePlaylistID = schema.youtubePlaylistID;
        this.spotifyClientID = schema.spotifyClientID;
        this.spotifyClientSecret = schema.spotifyClientSecret;
        this.spotifyAccessToken = schema.spotifyAccessToken;
        this.spotifyRefreshToken = schema.spotifyRefreshToken;
        this.spotifyPlaylistID = schema.spotifyPlaylistID;
        this.broadcasterBearerToken = schema.broadcasterBearerToken;
        this.broadcasterKeyExpiry = schema.broadcasterKeyExpiry;
    }

    /++
        Returns a [JSONSchema] object with the same data as this one.
     +/
    auto asSchema() const
    {
        JSONSchema schema;
        schema.broadcasterKey = this.broadcasterKey;
        schema.googleClientID = this.googleClientID;
        schema.googleClientSecret = this.googleClientSecret;
        schema.googleAccessToken = this.googleAccessToken;
        schema.googleRefreshToken = this.googleRefreshToken;
        schema.youtubePlaylistID = this.youtubePlaylistID;
        schema.spotifyClientID = this.spotifyClientID;
        schema.spotifyClientSecret = this.spotifyClientSecret;
        schema.spotifyAccessToken = this.spotifyAccessToken;
        schema.spotifyRefreshToken = this.spotifyRefreshToken;
        schema.spotifyPlaylistID = this.spotifyPlaylistID;
        schema.broadcasterBearerToken = this.broadcasterBearerToken;
        schema.broadcasterKeyExpiry = this.broadcasterKeyExpiry;
        return schema;
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
        JSON schema for the follower object.
     +/
    static struct JSONSchema
    {
        string user_id;  ///
        string user_name;  ///
        string user_login;  ///
        string followed_at;  ///
    }

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

    /++
        Constructor.
     +/
    this(const JSONSchema schema)
    {
        import std.conv : to;

        this.id = schema.user_id.to!ulong;
        this.displayName = schema.user_name;
        this.login = schema.user_login;
        this.when = SysTime.fromISOExtString(schema.followed_at);
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
        shouldBell = plugin.settings.bellOnMessage;
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
        shouldBell |= plugin.settings.bellOnImportant;
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

    if (plugin.settings.ecount && event.emotes.length)
    {
        import lu.string : advancePast;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : count;
        import std.conv : to;

        auto channelcount = event.channel.name in plugin.ecount;

        if (!channelcount)
        {
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
    cast(void) getRoom(plugin, event.channel);
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
    mixin(memoryCorruptionCheck);

    if (event.channel.name !in plugin.state.channels)
    {
        // Race?
        plugin.state.channels[event.channel.name] = IRCChannel(event.channel);
    }

    if (event.target.class_ < IRCUser.Class.operator)
    {
        // If we're here, we're not an operator and yet it's a home channel
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
)
void onGlobalUserstate(TwitchPlugin plugin, const IRCEvent _)
{
    import kameloso.plugins.twitch.emotes : Delays, importCustomEmotesImpl;
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.constants : BufferSize;
    import core.thread.fiber : Fiber;

    mixin(memoryCorruptionCheck);

    if (plugin.settings.customEmotes)
    {
        void importCustomEmotesDg()
        {
            importCustomEmotesImpl(plugin);
        }

        // Delay importing just a bit to cosmetically stagger the terminal output
        auto importCustomEmotesFiber = new Fiber(&importCustomEmotesDg, BufferSize.fiberStack);
        delay(plugin, importCustomEmotesFiber, Delays.initialDelayBeforeImports);
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
        room.stream.endedAt = Clock.currTime;
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
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.datetime.systime : Clock, SysTime;
    import std.file : readText;
    import std.format : format;
    import std.stdio : File, writeln;
    import core.time : Duration;

    if (room.stream.live)
    {
        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = Duration.zero;
        immutable delta = (now - room.stream.startedAt);
        immutable timestring = timeSince!(7, 1)(delta);

        if (room.stream.viewerCountMax > 0)
        {
            enum pattern = "%s has been live streaming %s for %s, currently with %d viewers. " ~
                "(Maximum this stream has so far been %d concurrent viewers.)";
            immutable message = pattern.format(
                room.broadcasterDisplayName,
                room.stream.gameName,
                timestring,
                room.stream.viewerCount,
                room.stream.viewerCountMax);
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
    immutable content = plugin.streamHistoryFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    auto json = content.deserialize!(TwitchPlugin.Room.Stream.JSONSchema[]);

    if (!json.length)
    {
        // No streams this session and none on record
        immutable message = room.broadcasterDisplayName ~ " is currently not streaming.";
        return chan(plugin.state, room.channelName, message);
    }

    const previousStream = TwitchPlugin.Room.Stream(json[$-1]);
    immutable delta = (previousStream.endedAt - previousStream.startedAt);
    immutable timestring = timeSince!(7, 1)(delta);
    immutable gameName = previousStream.gameName.length ?
        previousStream.gameName :
        "something";

    if (previousStream.viewerCountMax > 0)
    {
        enum pattern = "%s is currently not streaming. " ~
            "Last streamed %s on %4d-%02d-%02d for %s, " ~
            "with a maximum of %d concurrent viewers.";
        immutable message = pattern.format(
            room.broadcasterDisplayName,
            gameName,
            previousStream.endedAt.year,
            cast(uint) previousStream.endedAt.month,
            previousStream.endedAt.day,
            timestring,
            previousStream.viewerCountMax);
        return chan(plugin.state, room.channelName, message);
    }
    else
    {
        enum pattern = "%s is currently not streaming. " ~
            "Last streamed %s on %4d-%02d-%02d for %s.";
        immutable message = pattern.format(
            room.broadcasterDisplayName,
            gameName,
            previousStream.endedAt.year,
            cast(uint) previousStream.endedAt.month,
            previousStream.endedAt.day,
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

    if (event.sender.class_ < IRCUser.Class.elevated)
    {
        // Not elevated or higher, so not allowed to query for others
        slice = string.init;
    }

    immutable otherNameSpecified = slice.length &&
        !slice.among(event.sender.nickname, event.sender.displayName);

    void sendNoSuchUser(const string name)
    {
        immutable message = "No such user: " ~ name;
        chan(plugin.state, event.channel.name, message);
    }

    void sendCannotFollowSelf()
    {
        enum message = "You cannot follow yourself.";
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
            months[cast(uint) follower.when.month-1],
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

            immutable results = getUser(
                plugin: plugin,
                name: name,
                searchByDisplayName: true);

            if (results.success)
            {
                enum pattern = "%s is currently not a follower.";
                immutable message = pattern.format(results.displayName);
                chan(plugin.state, event.channel.name, message);
            }
            else
            {
                sendNoSuchUser(name);
            }
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

    immutable name = slice.length ?
        slice :
        event.sender.nickname;

    if (name == event.channel.name[1..$])
    {
        return sendCannotFollowSelf();
    }

    if (!room.followers.length)
    {
        /+
            Followers have not yet been cached!
            This can technically happen, though practically the caching is
            done immediately after joining so there should be no time for
            !followage queries to sneak in.
            Just abort.
         +/
        return;
    }

    immutable found = reportFromCache(name);  // mutable for reuse
    if (found) return;

    // No matches and/or not enough time has passed since last recache
    reportNotAFollower(name);
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
    import std.format : format;
    import std.datetime.systime : Clock;
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
        immutable results = getUser(plugin, string.init, room.id);

        if (!results.success)
        {
            // No such user? Something is deeply wrong
            return;
        }

        room.broadcasterDisplayName = results.displayName;
        auto storedUser = results.login in plugin.state.users;

        if (!storedUser)
        {
            // Forge a new IRCUser
            auto newUser = IRCUser(
                results.login,
                results.login,
                results.login ~ ".tmi.twitch.tv");
            newUser.account = newUser.nickname;
            newUser.class_ = IRCUser.Class.anyone;
            newUser.displayName = results.displayName;
            newUser.id = results.id;
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

        if (plugin.settings.customEmotes)
        {
            import kameloso.plugins.twitch.emotes : Delays;
            import kameloso.plugins.common.scheduling : delay;
            import kameloso.constants : BufferSize;
            import std.algorithm.searching : countUntil;

            void importEmotesDg()
            {
                import kameloso.plugins.twitch.emotes : importCustomEmotesImpl;
                importCustomEmotesImpl(
                    plugin: plugin,
                    channelName: event.channel.name,
                    id: room.id);
            }

            /+
                Stagger imports a bit.
             +/
            immutable homeIndex = plugin.state.bot.homeChannels.countUntil(event.channel.name);
            immutable delayUntilImport = homeIndex * Delays.delayBetweenImports;
            auto importEmotesFiber = new Fiber(&importEmotesDg, BufferSize.fiberStack);
            delay(plugin, importEmotesFiber, delayUntilImport);
        }

        auto creds = event.channel.name in plugin.secretsByChannel;

        if (creds && creds.broadcasterKey.length)
        {
            enum pattern = "Elevated authorisation key for channel <l>%s</>";
            immutable what = pattern.format(event.channel.name);

            void onExpiryDg()
            {
                enum pattern = "The elevated authorisation key for channel <l>%s</> has expired. " ~
                    "Run the program with <l>--set twitch.superKeygen</> to generate a new one.";
                logger.errorf(pattern, event.channel.name);

                // Keep the old keys so the error message repeats next execution
                /*creds.broadcasterKey = string.init;
                creds.broadcasterBearerToken = string.init;
                //creds.broadcasterKeyExpiry = 0;  // keep it for reference
                saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);*/
            }

            void onFirstValidationDg(Duration expiresIn) @system
            {
                if (!plugin.state.coreSettings.headless)
                {
                    immutable now = Clock.currTime;
                    immutable expiresWhen = (now + expiresIn);

                    generateExpiryReminders(
                        plugin,
                        expiresWhen,
                        what);
                }
            }

            startValidator(
                plugin: plugin,
                authToken: creds.broadcasterKey,
                what: what,
                onFirstValidationDg: &onFirstValidationDg,
                onExpiryDg: &onExpiryDg);
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
    import kameloso.plugins.twitch.emotes : Delays, importCustomEmotesImpl;
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.constants : BufferSize;
    import std.algorithm.searching : countUntil;
    import core.thread.fiber : Fiber;
    import core.time : Duration, seconds;

    mixin(memoryCorruptionCheck);

    // Cache channel name by its numeric ID
    assert(event.channel.id);
    plugin.channelNamesByID[event.channel.id] = event.channel.name;

    if (!plugin.settings.customEmotes || !plugin.settings.customEmotesEverywhere) return;

    if (const customChannelEmotes = event.channel.name in plugin.customChannelEmotes)
    {
        if (customChannelEmotes.emotes.length)
        {
            // Already done
            return;
        }
    }

    /+
        Stagger imports a bit.
     +/
    Duration delayUntilImport;
    immutable guestIndex = plugin.state.bot.guestChannels.countUntil(event.channel.name);

    if (guestIndex != -1)
    {
        // It's a guest channel, pad it behind home channels
        immutable start = plugin.state.bot.homeChannels.length;
        delayUntilImport = start.seconds + (guestIndex * Delays.delayBetweenImports);
    }
    else
    {
        // Channel joined via piped command or admin join command
        // Invent a delay based on the hash of the channel name
        // padded by the number of home and guest channels
        immutable start = (plugin.state.bot.homeChannels.length + plugin.state.bot.guestChannels.length);
        delayUntilImport = start.seconds + ((event.channel.name.hashOf % 5) * Delays.delayBetweenImports);
    }

    void importDg()
    {
        importCustomEmotesImpl(
            plugin: plugin,
            channelName: event.channel.name.idup,
            id: event.channel.id);
    }

    auto importFiber = new Fiber(&importDg, BufferSize.fiberStack);
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
        immutable message = "No such user " ~ target ~ " (or the user has never streamed)";
        chan(plugin.state, event.channel.name, message);
    }

    /*void sendUserHasNoChannel()
    {
        enum message = "Impossible error; user has no channel?";
        chan(plugin.state, event.channel.name, message);
    }*/

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

    void sendNTimes(const string message, const uint numTimes)
    {
        foreach (immutable i; 0..numTimes)
        {
            chan(plugin.state, event.channel.name, message);
        }
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

    const getChannelResults = getChannel(
        plugin: plugin,
        channelName: login);

    if (!getChannelResults.success)
    {
        if (!getChannelResults.id)
        {
            return sendNoSuchUser(login);
        }
        else
        {
            return sendOtherError();
        }
    }

    immutable getUserResults = getUser(
        plugin: plugin,
        name: login);

    if (!getUserResults.success)
    {
        // getChannel succeeded but getUser of the same login failed
        // Something must have happened traffic-wise; abort
        return sendOtherError();
    }

    const getStreamResults = getStream(plugin, login);

    if (getStreamResults.success)
    {
        // User has streamed before
        if (getChannelResults.gameID)
        {
            // Channel has set a game set (id != 0)
            immutable playingPattern = getStreamResults.stream.live ?
                " (currently playing %s)" :
                " (last seen playing %s)";

            immutable pattern = "Shoutout to %s! Visit them at https://twitch.tv/%s !" ~ playingPattern;
            immutable message = pattern.format(
                getUserResults.displayName,
                login,
                getChannelResults.gameName);

            sendNTimes(message, numTimes);
        }
        else
        {
            // Channel has not set a game (id == 0)
            enum pattern = "Shoutout to %s! Visit them at https://twitch.tv/%s !";
            immutable message = pattern.format(
                getUserResults.displayName,
                login);

            sendNTimes(message, numTimes);
        }
    }
    else
    {
        // User exists but simply has never streamed before
        enum pattern = "Shoutout to %s! Visit them at https://twitch.tv/%s !";
        immutable message = pattern.format(
            getUserResults.displayName,
            login);

        sendNTimes(message, numTimes);
    }
}


// onCommandVanish
/++
    Hides a user's messages (making them "disappear") by briefly timing them out.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.anyone)
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

    const results = timeoutUser(plugin, event.channel.name, event.sender.id, 1);

    if (!results.success)
    {
        if (results.alreadyBanned || results.targetIsBroadcaster)
        {
            // It failed but with good reason
        }
        else
        {
            import kameloso.plugins.common : nameOf;
            enum pattern = "Failed to vanish <l>%s</> in <l>%s</>: <l>%s</> (<t>%d</>)";
            logger.warningf(pattern, nameOf(event.sender), event.channel.name, results.error, results.code);
        }
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
    .permissionsRequired(Permissions.operator)
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
        const results = getSubscribers(plugin, event.channel.name, totalOnly: true);

        if (results.success)
        {
            enum pattern = "%s has %d subscribers.";
            immutable message = pattern.format(room.broadcasterDisplayName, results.totalNumSubscribers);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "Failed to get subscriber count.";
            chan(plugin.state, event.channel.name, message);
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
    import kameloso.plugins.twitch.api : retryDelegate;
    import lu.string : advancePast, stripped, unquoted;
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
        immutable pattern = (plugin.settings.songrequestMode == SongRequestMode.youtube) ?
            "Usage: %s%s [YouTube link or video ID]" :
            "Usage: %s%s [Spotify link or track ID]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendMissingCredentials()
    {
        immutable channelMessage = (plugin.settings.songrequestMode == SongRequestMode.youtube) ?
            "Missing Google API credentials and/or YouTube playlist ID." :
            "Missing Spotify API credentials and/or Spotify playlist ID.";
        immutable terminalMessage = (plugin.settings.songrequestMode == SongRequestMode.youtube) ?
            channelMessage ~ " Run the program with <l>--set twitch.googleKeygen</> to set it up." :
            channelMessage ~ " Run the program with <l>--set twitch.spotifyKeygen</> to set it up.";
        chan(plugin.state, event.channel.name, channelMessage);
        logger.error(terminalMessage);
    }

    void sendInvalidCredentials()
    {
        immutable message = (plugin.settings.songrequestMode == SongRequestMode.youtube) ?
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
        immutable message = (plugin.settings.songrequestMode == SongRequestMode.youtube) ?
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
        enum pattern = `"%s" added to playlist.`;
        immutable message = pattern.format(title.unquoted);
        chan(plugin.state, event.channel.name, message);
    }

    void sendAddedToSpotifyPlaylist(const string artist, const string track)
    {
        enum pattern = `%s - "%s" added to playlist.`;
        immutable message = pattern.format(artist, track.unquoted);
        chan(plugin.state, event.channel.name, message);
    }

    if (plugin.settings.songrequestMode == SongRequestMode.disabled) return;

    if (event.sender.class_ < plugin.settings.songrequestPermsNeeded)
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

    if (plugin.settings.songrequestMode == SongRequestMode.youtube)
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

                immutable results = addVideoToYouTubePlaylist(plugin, *creds, videoID);

                if (!results.success)
                {
                    return sendNonspecificError();
                }

                room.songrequestHistory[event.sender.nickname] = event.time;
                return sendAddedToYouTubePlaylist(results.title);
            }
            catch (InvalidCredentialsException _)
            {
                return sendInvalidCredentials();
            }
            // Let other exceptions fall through
        }

        retryDelegate(plugin, &addYouTubeVideoDg);
    }
    else if (plugin.settings.songrequestMode == SongRequestMode.spotify)
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

        void addSpotifyTrackDg()
        {
            try
            {
                import kameloso.plugins.twitch.providers.spotify : addTrackToSpotifyPlaylist, getSpotifyTrackByID;

                immutable addResults = addTrackToSpotifyPlaylist(plugin, *creds, trackID);

                if (!addResults.success)
                {
                    return sendNonspecificError();
                }

                immutable getTrackResults = getSpotifyTrackByID(
                    plugin,
                    *creds,
                    trackID);

                if (getTrackResults.success)
                {
                    room.songrequestHistory[event.sender.nickname] = event.time;
                    sendAddedToSpotifyPlaylist(getTrackResults.artist, getTrackResults.name);
                }
                else
                {
                    // Failed for some reason
                    sendNonspecificError();
                }

            }
            catch (InvalidCredentialsException _)
            {
                sendInvalidCredentials();
            }
            // Let other exceptions fall through
        }

        retryDelegate(plugin, &addSpotifyTrackDg);
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
        const results = createPoll(plugin, event.channel.name, title, durationString, choices);

        if (results.success)
        {
            enum pattern = `Poll "%s" created.`;
            immutable message = pattern.format(results.poll.title);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            if (results.permissionDenied)
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
                enum message = "Failed to create poll.";
                chan(plugin.state, event.channel.name, message);
            }
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
    mixin(memoryCorruptionCheck);

    try
    {
        const getResults = getPolls(plugin, event.channel.name);

        if (!getResults.success)
        {
            enum message = "Failed to get polls.";
            return chan(plugin.state, event.channel.name, message);
        }

        if (!getResults.polls.length)
        {
            enum message = "There are no active polls to end.";
            return chan(plugin.state, event.channel.name, message);
        }

        const endResults = endPoll(
            plugin: plugin,
            channelName: event.channel.name,
            pollID: getResults.polls[0].pollID,
            terminate: true);

        if (endResults.success)
        {
            alias Status = typeof(endResults.poll.status);

            if (endResults.poll.status != Status.active)
            {
                import lu.conv : toString;
                import std.format : format;

                enum pattern = "Poll ended; status %s";
                immutable message = pattern.format(endResults.poll.status.toString);
                chan(plugin.state, event.channel.name, message);
            }
            else
            {
                enum message = "Failed to end poll; status remains active";
                chan(plugin.state, event.channel.name, message);
            }
        }
        else
        {
            enum message = "Failed to end poll.";
            chan(plugin.state, event.channel.name, message);
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
        try
        {
            immutable results = deleteMessage(plugin, event.channel.name, storedEvent.id);

            if (results.success)
            {
                return true;
            }
            else
            {
                if (results.isFromBroadcaster)
                {
                    // Should never happen as we filter by class_ before calling this...
                    return true;
                }
                else
                {
                    import kameloso.plugins.common : nameOf;

                    enum pattern = "Failed to delete a message from <h>%s</> in <l>%s</>: %s";
                    logger.warningf(
                        pattern,
                        nameOf(storedEvent.sender),
                        event.channel.name,
                        results.error);
                    return false;
                }
            }
        }
        catch (Exception e)
        {
            version(PrintStacktraces) logger.trace(e);
            return false;
        }
    }

    auto room = event.channel.name in plugin.rooms;
    assert(room, "Tried to nuke a word in a nonexistent room");

    uint numDeleted;

    foreach (ref storedEvent; room.lastNMessages)  // explicit IRCEvent required on lu <2.0.1
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

    // Delete the command event itself
    // Do it from within a foreach so we can clear the event by ref
    foreach (ref storedEvent; room.lastNMessages)  // as above
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
    import std.algorithm.searching : startsWith;
    import std.datetime.systime : Clock;

    mixin(memoryCorruptionCheck);

    void onFirstValidationDg(Duration expiresIn) @system
    {
        if (!plugin.state.coreSettings.headless)
        {
            immutable now = Clock.currTime;
            immutable expiresWhen = (now + expiresIn);

            generateExpiryReminders(
                plugin,
                expiresWhen,
                "Your Twitch authorisation key");
        }
    }

    void onIDKnownDg(ulong id) @system
    {
        plugin.transient.botID = id;
    }

    void onExpiryDg() @system
    {
        if (!plugin.state.coreSettings.headless)
        {
            enum message = "Your Twitch authorisation key has expired. " ~
                "Run the program with <l>--set twitch.keygen</> to generate a new one.";
            logger.error(message);
        }

        enum expiryMessage = "Twitch authorisation key expired";
        quit(plugin.state, expiryMessage);
    }

    // Concatenate the Bearer and OAuth headers once.
    // This has to be done *after* connect's register
    immutable key = plugin.state.bot.pass.startsWith("oauth:") ?
        plugin.state.bot.pass[6..$] :
        plugin.state.bot.pass;
    plugin.transient.authorizationBearer = "Bearer " ~ key;

    startValidator(
        plugin: plugin,
        authToken: key,  // Not plugin.transient.authorizationBearer
        what: "Twitch authorisation key",
        onFirstValidationDg: &onFirstValidationDg,
        onIDKnownDg: &onIDKnownDg,
        onExpiryDg: &onExpiryDg);

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

    if (!plugin.settings.ecount) return;

    void sendUsage()
    {
        enum pattern = "Usage: %s%s [emote]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
    }

    void sendNotATwitchEmote()
    {
        enum message = "That is not a known emote.";
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

    if (!plugin.settings.watchtime) return;

    string slice = event.content.stripped;  // mutable
    string nickname;
    string displayName;
    immutable nameSpecified = (slice.length > 0);

    if (!nameSpecified || (event.sender.class_ < IRCUser.Class.elevated))
    {
        // Assume the user is asking about itself
        // or doesn't have the privileges to ask about others
        nickname = event.sender.nickname;
        displayName = event.sender.displayName;
    }
    else
    {
        string name = slice.advancePast(' ', inherit: true);  // mutable
        if (name.startsWith('@')) name = name[1..$];

        immutable user = getUser(
            plugin: plugin,
            name: name,
            searchByDisplayName: true);

        if (!user.login.length)
        {
            immutable message = "No such user: " ~ name;
            return chan(plugin.state, event.channel.name, message);
        }

        nickname = user.login;
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
        immutable results = setChannelTitle(plugin, event.channel.name, title);

        if (results.success)
        {
            enum pattern = "Channel title set to: %s";
            immutable message = pattern.format(title);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "Failed to set title.";
            chan(plugin.state, event.channel.name, message);
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
    .addCommand(
        IRCEventHandler.Command()
            .word("game")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
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
        const results = getChannel(plugin, event.channel.name);

        if (results.success)
        {
            enum pattern = "Currently playing game: %s";
            immutable gameName = results.gameName.length ?
                results.gameName :
                "(nothing)";
            immutable message = pattern.format(gameName);
            return chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "Failed to get current game.";
            return chan(plugin.state, event.channel.name, message);
        }
    }

    immutable specified = unescapedGameName.unquoted.replace(`"`, `\"`);
    immutable numberSupplied = (specified.length && specified.isNumeric);
    ulong gameID = numberSupplied ? specified.to!ulong : 0;  // mutable

    try
    {
        string name;  // mutable
        bool success;

        if (!numberSupplied)
        {
            immutable results = getGame(plugin, specified.encodeComponent);

            if (results.success)
            {
                gameID = results.id;
                name = results.name;
                success = true;
            }
        }
        else if (gameID == 0)
        {
            name = "(unset)";
            success = true;
        }
        else /*if (id.length)*/
        {
            immutable results = getGame(
                plugin: plugin,
                id: gameID);

            if (results.success)
            {
                name = results.name;
                success = true;
            }
        }

        if (!success)
        {
            enum message = "Could not find a game by that name; check spelling.";
            return chan(plugin.state, event.channel.name, message);
        }

        immutable results = setChannelGame(plugin, event.channel.name, gameID);

        if (results.success)
        {
            enum pattern = "Game set to: %s";
            immutable message = pattern.format(name);
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            enum message = "Failed to set game.";
            chan(plugin.state, event.channel.name, message);
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
        immutable results = startCommercial(plugin, event.channel.name, lengthString);

        if (!results.success)
        {
            if (results.error == "To start a commercial, the broadcaster must be streaming live.")
            {
                return sendNoOngoingStream();
            }
            else
            {
                enum message = "Failed to start commercial.";
                chan(plugin.state, event.channel.name, message);
            }
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


// initialise
/++
    Start any key generation terminal wizard(s) before connecting to the server.
 +/
void initialise(TwitchPlugin plugin)
{
    import kameloso.terminal : isTerminal;
    import lu.string : strippedRight;
    import std.algorithm.searching : endsWith;

    if (!isTerminal)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.transient.bell = string.init;
    }

    immutable someKeygenWanted =
        plugin.settings.keygen ||
        plugin.settings.superKeygen ||
        plugin.settings.googleKeygen ||
        plugin.settings.youtubeKeygen ||
        plugin.settings.spotifyKeygen;

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
        import asdf.serialization : deserialize;
        import std.file : readText;

        if (plugin.state.coreSettings.headless)
        {
            // Headless mode is enabled, so a terminal wizard doesn't make sense
            return;
        }

        // Some keygen, reload to load secrets so existing ones are read
        // Not strictly needed for normal keygen but for everything else
        immutable content = plugin.secretsFile.readText.strippedRight;

        version(PrintStacktraces)
        {
            scope(failure)
            {
                import std.json : parseJSON;
                import std.stdio : writeln;

                writeln(content);
                try writeln(content.parseJSON.toPrettyString);
                catch (Exception _) {}
            }
        }

        auto json = content.deserialize!(Credentials.JSONSchema[string]);

        foreach (immutable channelName, creds; json)
        {
            plugin.secretsByChannel[channelName] = Credentials(creds);
        }

        bool needSeparator;
        enum separator = "---------------------------------------------------------------------";

        // Automatically keygen if no pass
        if (plugin.settings.keygen ||
            (!plugin.state.bot.pass.length && !plugin.state.coreSettings.force))
        {
            import kameloso.plugins.twitch.providers.twitch : requestTwitchKey;
            requestTwitchKey(plugin);
            if (*plugin.state.abort) return;
            plugin.settings.keygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.keygen");
            needSeparator = true;
        }

        if (plugin.settings.superKeygen)
        {
            import kameloso.plugins.twitch.providers.twitch : requestTwitchSuperKey;
            if (needSeparator) logger.trace(separator);
            requestTwitchSuperKey(plugin);
            if (*plugin.state.abort) return;
            plugin.settings.superKeygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.superKeygen");
            needSeparator = true;
        }

        if (plugin.settings.googleKeygen ||
            plugin.settings.youtubeKeygen)
        {
            import kameloso.plugins.twitch.providers.google : requestGoogleKeys;
            if (needSeparator) logger.trace(separator);
            requestGoogleKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.settings.googleKeygen = false;
            plugin.settings.youtubeKeygen = false;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.googleKeygen");
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.youtubeKeygen");
            needSeparator = true;
        }

        if (plugin.settings.spotifyKeygen)
        {
            import kameloso.plugins.twitch.providers.spotify : requestSpotifyKeys;
            if (needSeparator) logger.trace(separator);
            requestSpotifyKeys(plugin);
            if (*plugin.state.abort) return;
            plugin.state.messages ~= ThreadMessage.popCustomSetting("twitch.spotifyKeygen");
            plugin.settings.spotifyKeygen = false;
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

        uint newChattersSinceLastRehash;
        enum rehashThreshold = 128;

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
                    auto results = getBotList(plugin);  // must be mutable

                    if (results.success)
                    {
                        botBlacklist = results.bots;
                        lastBotUpdateTime = now;
                    }
                    else
                    {
                        // Failed for some reason, retry next time
                        delay(plugin, monitorUpdatePeriodicity, yield: true);
                        continue;
                    }
                }

                const chatters = getChatters(plugin, room.broadcasterName);

                const string[][7-1] chattersByCategory =
                [
                    //chatters.broadcaster,
                    chatters.moderators,
                    chatters.vips,
                    chatters.staff,
                    chatters.admins,
                    chatters.globalMods,
                    chatters.viewers,
                ];

                foreach (const chattersInCategory; chattersByCategory[])
                {
                    foreach (const viewer; chattersInCategory)
                    {
                        import std.algorithm.searching : canFind, endsWith;

                        if (viewer.endsWith("bot") ||
                            botBlacklist.canFind(viewer) ||
                            (viewer == plugin.state.client.nickname))
                        {
                            continue;
                        }

                        if (viewer !in room.stream.chattersSeen)
                        {
                            room.stream.chattersSeen[viewer] = true;
                            ++newChattersSinceLastRehash;
                        }

                        // continue early if we shouldn't monitor watchtime
                        if (!plugin.settings.watchtime) continue;

                        if (plugin.settings.watchtimeExcludesLurkers)
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

            if (newChattersSinceLastRehash >= rehashThreshold)
            {
                room.stream.chattersSeen.rehash();
                newChattersSinceLastRehash = 0;
            }

            delay(plugin, monitorUpdatePeriodicity, yield: true);
        }
    }

    void uptimeMonitorDg()
    {
        static void closeStream(TwitchPlugin.Room* room)
        {
            room.stream.live = false;
            room.stream.endedAt = Clock.currTime;
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
                auto results = getStream(plugin, room.broadcasterName);  // must not be const nor immutable

                if (!results.success)
                {
                    // Failed to get stream info, retry next time
                    delay(plugin, monitorUpdatePeriodicity, yield: true);
                    continue;
                }

                if (!results.stream.id)  // == TwitchPlugin.Room.Stream.init)
                {
                    // Stream down
                    if (room.stream.live)
                    {
                        // Was up but just ended
                        closeStream(room);
                        rotateStream(room);
                        logger.info("Stream ended.");

                        if (plugin.settings.watchtime && plugin.transient.viewerTimesDirty)
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
                        room.stream = results.stream;
                        logger.info("Stream started.");
                        reportCurrentGame(results.stream);

                        /*if (plugin.settings.watchtime && plugin.transient.viewerTimesDirty)
                        {
                            saveResourceToDisk(plugin.viewerTimesByChannel, plugin.viewersFile);
                            plugin.transient.viewerTimesDirty = false;
                        }*/
                    }
                    else if (room.stream.id == results.stream.id)
                    {
                        // Same stream running, just update it
                        room.stream.update(results.stream);
                    }
                    else
                    {
                        // New stream, but stale one exists. Rotate and insert
                        closeStream(room);
                        rotateStream(room);
                        room.stream = results.stream;
                        logger.info("Stream change detected.");
                        reportCurrentGame(results.stream);

                        if (plugin.settings.watchtime && plugin.transient.viewerTimesDirty)
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
                /*if (plugin.state.coreSettings.trace)
                {
                    enum pattern = "Fetching followers of channel <l>%s</> ...";
                    logger.infof(pattern, channelName);
                }*/

                auto results = getFollowers(plugin, room.id);  // must be mutable

                if (results.success)
                {
                    room.followers = results.followers;
                    room.followersLastCached = now.toUnixTime();

                    if (!results.followers.length)
                    {
                        // No followers, so don't output anything
                    }
                    else
                    {
                        if (plugin.state.coreSettings.trace)
                        {
                            enum pattern = "Cached <l>%,d</> followers of channel <l>%s";
                            logger.infof(pattern, results.followers.length, channelName);
                        }
                    }
                }
                else
                {
                    // Failed to get followers, retry next time
                    if (plugin.state.coreSettings.trace)
                    {
                        enum pattern = "Failed to fetch followers of channel <l>%s";
                        logger.warningf(pattern, channelName);
                    }
                }

                // Drop down
            }
            catch (Exception e)
            {
                version(PrintStacktraces) logger.trace(e);
                // Just swallow the exception and retry next time
            }

            immutable untilNextMidnight = (now.nextMidnight - now);
            delay(plugin, untilNextMidnight, yield: true);
        }
    }

    // Re-import custom emotes once every three days
    void reimportEmotesDg()
    {
        import kameloso.plugins.twitch.emotes : importCustomEmotesImpl;
        import kameloso.time : nextMidnight;
        import core.time : days, hours;

        auto room = channelName in plugin.rooms;
        assert(room, "Tried to start emote reimport delegate on non-existing room");

        enum nDays = 1;
        static immutable minimumDelay = 1.hours;

        immutable idSnapshot = room.uniqueID;

        {
            // Initial delay
            immutable now = Clock.currTime;
            immutable untilMidnightInNDays = (now.nextMidnight(nDays) - now);
            immutable recentlyConnected = (untilMidnightInNDays < minimumDelay);
            immutable untilMidnightAdjusted = recentlyConnected ?
                (untilMidnightInNDays + 1.days) :  // Skip first day
                untilMidnightInNDays;
            delay(plugin, untilMidnightAdjusted, yield: true);
        }

        while (true)
        {
            room = channelName in plugin.rooms;
            if (!room || (room.uniqueID != idSnapshot)) return;

            importCustomEmotesImpl(
                plugin: plugin,
                channelName: channelName,
                id: plugin.customChannelEmotes[channelName].id);

            immutable now = Clock.currTime;
            immutable untilMidnightInNDays = (now.nextMidnight(nDays) - now);
            delay(plugin, untilMidnightInNDays, yield: true);
        }
    }

    auto uptimeMonitorFiber = new Fiber(&uptimeMonitorDg, BufferSize.fiberStack);
    auto chatterMonitorFiber = new Fiber(&chatterMonitorDg, BufferSize.fiberStack);
    auto cacheFollowersFiber = new Fiber(&cacheFollowersDg, BufferSize.fiberStack);
    auto reimportEmotesFiber = new Fiber(&reimportEmotesDg, BufferSize.fiberStack);

    uptimeMonitorFiber.call();
    chatterMonitorFiber.call();
    cacheFollowersFiber.call();
    reimportEmotesFiber.call();
}


// startValidator
/++
    Starts a validator routine.

    This will validate the API access token and output to the terminal for how
    much longer it is valid. It will call delegates based upon what it finds.

    Note: Must be called from within a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [TwitchPlugin].
        authToken = Twitch authorisation key to validate.
        what = A string description (noun) describing the key being validated.
        onFirstValidationDg = Delegate to call when the first validation is done.
        onIDKnownDg = Delegate to call when the user ID is known.
        onExpiryDg = Delegate to call when the token is expired.
 +/
void startValidator(
    TwitchPlugin plugin,
    const string authToken,
    const string what,
    void delegate(Duration) onFirstValidationDg = null,
    void delegate(ulong) onIDKnownDg = null,
    void delegate() onExpiryDg = null)
in (Fiber.getThis(), "Tried to call `startValidator` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : delay;
    import std.algorithm.searching : startsWith;
    import std.conv : to;
    import std.datetime.systime : Clock;
    import core.time : minutes;

    /*
        From https://dev.twitch.tv/docs/authentication/validate-tokens/

        "Any third-party app that calls the Twitch APIs and maintains an OAuth
        session must call the /validate endpoint to verify that the access token
        is still valid. This includes web apps, mobile apps, desktop apps,
        extensions, and chatbots. Your app must validate the OAuth token when
        it starts and on an hourly basis thereafter."
     */

    static immutable periodicity = 59.minutes;
    static immutable retryDelay = 1.minutes;

    // Validation needs an "Authorization: OAuth xxx" header, as opposed to the
    // "Authorization: Bearer xxx" used everywhere else.
    immutable key = authToken.startsWith("oauth:") ?
        authToken["oauth:".length..$] :
        authToken;
    immutable authorisationHeader = "OAuth " ~ key;

    bool firstLoop = true;

    while (true)
    {
        try
        {
            immutable results = getValidation(
                plugin: plugin,
                authorisationHeader: authorisationHeader,
                async: true);

            if (firstLoop)
            {
                if (onIDKnownDg) onIDKnownDg(results.userID);
                if (onFirstValidationDg) onFirstValidationDg(results.expiresIn);
                if (onExpiryDg) delay(plugin, onExpiryDg, results.expiresIn);

                firstLoop = false;
            }

            // Validated, repeat next period as per requirements
            delay(plugin, periodicity, yield: true);
            continue;
        }
        catch (HTTPQueryException e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                import kameloso.constants : MagicErrorStrings;

                if (e.msg == MagicErrorStrings.sslLibraryNotFoundRewritten)
                {
                    enum sslPattern = "%s failed to validate: <l>" ~
                        cast(string) MagicErrorStrings.sslLibraryNotFoundRewritten ~
                        " <t>(is OpenSSL installed?)";
                    logger.warningf(sslPattern, what);
                    logger.warning(cast(string) MagicErrorStrings.visitWikiOneliner);
                    logger.warning("Expect the Twitch plugin to largely break.");

                    version(Windows)
                    {
                        logger.warning(cast(string) MagicErrorStrings.getOpenSSLSuggestion);
                    }

                    logger.trace();
                    // Unrecoverable
                    return;
                }
                else
                {
                    enum pattern = "%s failed to validate: <l>%s</> (<l>%s</>) <t>(%d)";
                    logger.warningf(pattern, what, e.msg, e.error, e.code);
                }

                version(PrintStacktraces) logger.trace(e);
            }

            // Drop down to retry
        }
        catch (EmptyResponseException e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                // HTTP query failed; just retry
                enum pattern = "%s failed to validate with an empty response from server: <t>%s</>";
                logger.errorf(pattern, what, e.msg);
                version(PrintStacktraces) logger.trace(e);
            }

            // Drop down to retry
        }
        catch (InvalidCredentialsException e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                enum pattern = "%s invalid or revoked: <t>%s</>";
                logger.errorf(pattern, what, e.msg);
                version(PrintStacktraces) logger.trace(e);
            }

            // Unrecoverable
            if (onExpiryDg) onExpiryDg();
            return;
        }
        catch (UnexpectedJSONException e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                enum pattern = "%s failed to validate with an unexpected response: <t>%s</>";
                logger.errorf(pattern, what, e.msg);
                version(PrintStacktraces) logger.trace(e);
            }

            // Drop down to retry
        }
        catch (Exception e)
        {
            if (!plugin.state.coreSettings.headless)
            {
                enum pattern = "%s failed to validate with an exception thrown: <t>%s</>";
                logger.errorf(pattern, what, e.msg);
                version(PrintStacktraces) logger.trace(e);
            }
        }

        // Retry
        delay(plugin, retryDelay, yield: true);
        continue;
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
    void delegate() onExpiryDg = null)
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
            cast(uint) expiresWhen.month,
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
                expiresWhen.year, cast(uint) expiresWhen.month, expiresWhen.day,
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
                expiresWhen.year, cast(uint) expiresWhen.month, expiresWhen.day,
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
        if (onExpiryDg) onExpiryDg();
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

    if (const e = cast(MissingBroadcasterTokenException) base)
    {
        enum pattern = "Missing elevated API key for channel <l>%s</>.";
        logger.errorf(pattern, e.channelName);
        match = true;
    }
    else if (const e = cast(InvalidCredentialsException) base)
    {
        enum pattern = "The elevated API key for channel <l>%s</> has expired.";
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

        if (plugin.settings.ecount &&
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
        if (plugin.settings.watchtime && plugin.transient.viewerTimesDirty)
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
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = plugin.streamHistoryFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    auto streams = content.deserialize!(TwitchPlugin.Room.Stream.JSONSchema[]);

    JSONValue json;
    json.array = null;

    foreach (const schema; streams)
    {
        json.array ~= schema.asJSONValue;
    }

    json.array ~= stream.asSchema.asJSONValue;

    immutable serialised = json.toPrettyString;
    File(plugin.streamHistoryFile, "w").writeln(serialised);
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
    import std.algorithm.comparison : among;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : countUntil;

    if (class_ >= IRCUser.Class.operator) return false;  // already as high as we go

    bool retval;

    foreach (immutable badge; badges.splitter(','))
    {
        if (!badge.length) continue;

        // Optimise this a bit because it's such a hotspot
        if (!badge[0].among!('s', 'v', 'm', /*'b'*/)) continue;

        immutable slashPos = badge.countUntil('/');
        if (slashPos == -1) break;  // something's wrong, should never happen

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
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "premium/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(!changed);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(changed);
        enum expected = IRCUser.Class.registered;  // because promoteVIPs false
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "subscriber/12,vip/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.elevated;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "moderator/1,subscriber/3012";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, true);
        assert(changed);
        enum expected = IRCUser.Class.registered;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "broadcaster/1,subscriber/12,partner/1";
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, true);
        assert(changed);
        enum expected = IRCUser.Class.registered;  // not staff because broadcasters are identified elsewhere
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "moderator/1";  // no comma splitter test
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = "subscriber/1";
        auto class_ = IRCUser.Class.operator;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(!changed);
        enum expected = IRCUser.Class.operator;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.staff;
        immutable changed = promoteUserFromBadges(class_, badges, true, true);
        assert(!changed);
        enum expected = IRCUser.Class.staff;
        assert((class_ == expected), class_.toString);
    }
    {
        enum badges = string.init;
        auto class_ = IRCUser.Class.anyone;
        immutable changed = promoteUserFromBadges(class_, badges, false, false);
        assert(!changed);
        enum expected = IRCUser.Class.anyone;
        assert((class_ == expected), class_.toString);
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
void sortBadges(ref string badges, const string[] badgeOrder) @safe
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : countUntil;
    import std.algorithm.sorting : sort;
    import std.array : Appender, join;

    static Appender!(string[]) sink;
    scope(exit) sink.clear();

    size_t lastIndex;
    bool inOrder = true;
    auto range = badges.splitter(',');

    // The number behind the slash can sometimes be text
    // predictions/NAH\sNEVER,subscriber/1,predictions/pink-2,premium/1
    // predictions/YEP\sLETSGOOO,subscriber/16,predictions/blue-1,sub-gifter/10

    foreach (immutable badge; range)
    {
        if (!badge.length) continue;  // should never happen

        immutable slashIndex = badge.countUntil('/');

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
        immutable aSlashIndex = a.countUntil('/');
        immutable bSlashIndex = b.countUntil('/');
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


// teardown
/++
    De-initialises the plugin. Shuts down any persistent worker threads.
 +/
void teardown(TwitchPlugin plugin)
{
    if (plugin.settings.ecount && plugin.ecount.length)
    {
        // Might as well always save on exit. Ignore dirty flag.
        saveResourceToDisk(plugin.ecount, plugin.ecountFile);
    }

    if (plugin.settings.watchtime && plugin.viewerTimesByChannel.length)
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

    Params:
        plugin = The current [TwitchPlugin].
        event = The [dialect.defs.IRCEvent|IRCEvent] to modify.

    Returns:
        `true` if the event was processed in a way that warrants the main loop
        checking for messages; `false` if not.
 +/
auto postprocess(TwitchPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.comparison : among;
    import std.typecons : Ternary;

    if (event.type.among!(IRCEvent.Type.QUERY, IRCEvent.Type.SELFQUERY))
    {
        /+
            This is a whisper on a Twitch server.

            Whispers are aggressively throttled. So as to not exceed the
            daily allowed number of messages on whispers to unique users,
            drop everything that doesn't come from an admin, unless we're
            mapping whispers to that channel.
         +/

        bool wasMappedToChannel;

        if (plugin.settings.mapWhispersToChannel)
        {
            import std.algorithm.searching : countUntil;

            alias pred = (channelName, senderNickname) => channelName.length && (senderNickname == channelName[1..$]);
            immutable channelIndex = plugin.state.bot.homeChannels.countUntil!pred(event.sender.nickname);

            if (channelIndex != -1)
            {
                event.type = IRCEvent.Type.CHAN;
                event.channel.name = plugin.state.bot.homeChannels[channelIndex];
                event.count[0].nullify();  // Zero out whisper count
                event.aux[0] = string.init;  // Also zero out the old way of storing it
                event.target = IRCUser.init;
                wasMappedToChannel = true;
            }
        }

        if (!wasMappedToChannel && (event.type != IRCEvent.Type.SELFQUERY))
        {
            if (event.sender.class_ != IRCUser.Class.admin)
            {
                // Drop the event.
                event.type = IRCEvent.Type.UNSET;
            }

            // It's a whisper, so this function has nothing else to do with it.
            return false;
        }
    }

    if (!event.channel.name.length)
    {
        // This function only deals with postprocessing channel messages.
        return false;
    }

    Ternary isHomeChannel;

    /+
        Embed custom emotes.
     +/
    if (plugin.settings.customEmotes)
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

        immutable mayHaveEmotes =
            (event.sender.nickname.length &&
            event.content.length);

        immutable mayHaveAltEmotes =
            (event.target.nickname.length &&
            event.altcontent.length);

        if (isEmotePossibleEventType && (mayHaveEmotes || mayHaveAltEmotes))
        {
            bool shouldEmbedCustomEmotes;

            if (plugin.settings.customEmotesEverywhere)
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

                if (mayHaveEmotes)
                {
                    embedCustomEmotes(
                        content: event.content,
                        emotes: event.emotes,
                        customEmotes: (customEmotes ? *customEmotes : null),
                        customGlobalEmotes: plugin.customGlobalEmotes);
                }

                if (mayHaveAltEmotes)
                {
                    embedCustomEmotes(
                        content: event.altcontent,
                        emotes: event.aux[$-2],  // magic number, see printer formatMessageColoured
                        customEmotes: (customEmotes ? *customEmotes : null),
                        customGlobalEmotes: plugin.customGlobalEmotes);
                }
            }
        }
    }

    /++
        Resolves the subchannel ID to a channel name.
     +/
    static void resolveSubchannel(
        /*const*/ TwitchPlugin plugin,
        ref IRCEvent event)
    in (event.subchannel.id && !event.subchannel.name.length)
    {
        import kameloso.constants : BufferSize;
        import core.thread.fiber : Fiber;

        if (const channelFromID = event.subchannel.id in plugin.channelNamesByID)
        {
            if (channelFromID.length)
            {
                // Found channel name in cache; insert into event.subchannel
                event.subchannel.name = *channelFromID;
            }
            else
            {
                // Do nothing; a request is already in progress
            }
            return;
        }

        // We don't know the channel name, so look it up.
        void getChannelNameDg()
        {
            // Snapshot the id because event is a reference
            immutable id = event.subchannel.id;

            /*if (plugin.state.coreSettings.trace)
            {
                enum pattern = "Querying server for channel name of user ID <l>%d</>...";
                logger.infof(pattern, id);
            }*/

            scope(failure)
            {
                // Just in case
                plugin.channelNamesByID.remove(id);
            }

            immutable results = getUser(
                plugin: plugin,
                id: id);

            if (!results.success)
            {
                // Abort the request but reset the cache entry
                plugin.channelNamesByID.remove(id);
                return;
            }

            immutable channelName = '#' ~ results.login;
            plugin.channelNamesByID[id] = channelName;

            if (plugin.state.coreSettings.trace)
            {
                enum pattern = "Resolved channel <l>%s</> from user ID <l>%d</>.";
                logger.infof(pattern, channelName, id);
            }
        }

        // Set an empty string so we don't return early above again before the results are in
        plugin.channelNamesByID[event.subchannel.id] = string.init;

        auto getChannelNameFiber = new Fiber(&getChannelNameDg, BufferSize.fiberStack);
        getChannelNameFiber.call();
    }

    /++
        Sort badges and infer user class based on them.
        Sort first so early returns don't skip the sorting.
     +/
    static bool postprocessImpl(
        /*const*/ TwitchPlugin plugin,
        const IRCEvent event,
        ref IRCUser user)
    {
        import kameloso.thread : ThreadMessage, boxed;

        if (!user.nickname.length) return false;

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

        if (plugin.settings.promoteBroadcasters)
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
                //plugin.settings.promoteBroadcasters,
                plugin.settings.promoteModerators,
                plugin.settings.promoteVIPs);

            if (changed)
            {
                plugin.state.messages ~= ThreadMessage.putUser(event.channel.name, boxed(user));
                return true;
            }
        }

        return false;
    }

    if (event.subchannel.id && !event.subchannel.name.length)
    {
        // Shared message
        resolveSubchannel(plugin, event);
    }

    if (!plugin.settings.promoteEverywhere && (isHomeChannel == Ternary.unknown))
    {
        import std.algorithm.searching : canFind;
        isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel.name);
    }

    if (plugin.settings.promoteEverywhere || (isHomeChannel == Ternary.yes))
    {
        /+
            Reset the user's updated timestamp to force anything update-aware
            to pick up the change.
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
        shouldCheckMessages |= postprocessImpl(plugin, event, event.sender);
        shouldCheckMessages |= postprocessImpl(plugin, event, event.target);
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
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;
    import std.traits : isArray, isAssociativeArray;

    /+
        This is not generic enough to use elsewhere but it does the job here well enough.
     +/
    void readAndWriteBack(T)
        (const string filename,
        const string fileDescription)
    {
        immutable content = filename.readText.strippedRight;

        if (!content.length)
        {
            static if (isArray!T)
            {
                File(filename, "w").writeln("[]");
            }
            else
            {
                File(filename, "w").writeln("{}");
            }
            return;
        }

        version(PrintStacktraces)
        {
            scope(failure)
            {
                import std.json : parseJSON;
                import std.stdio : writeln;

                writeln(content);
                try writeln(content.parseJSON.toPrettyString);
                catch (Exception _) {}
            }
        }

        try
        {
            const deserialised = content.deserialize!T;

            static if (__traits(compiles, JSONValue(deserialised)))
            {
                immutable serialised = JSONValue(deserialised).toPrettyString;
            }
            else static if (isAssociativeArray!T)
            {
                JSONValue json;
                json.object = null;

                foreach (immutable channelName, const schema; deserialised)
                {
                    json[channelName] = schema.asJSONValue;
                }

                immutable serialised = json.toPrettyString;
            }
            else static if (isArray!T)
            {
                JSONValue json;
                json.array = null;

                foreach (const schema; deserialised)
                {
                    json ~= schema.asJSONValue;
                }

                immutable serialised = json.toPrettyString;
            }
            else
            {
                enum message = "Unsupported type for Twitch resource serialisation";
                static assert(0, message);
            }

            File(filename, "w").writeln(serialised);
        }
        catch (SerdeException e)
        {
            version(PrintStacktraces) logger.trace(e);

            throw new IRCPluginInitialisationException(
            message: fileDescription ~ " file is malformed",
            pluginName: plugin.name,
            malformedFilename: filename);
        }
    }

    readAndWriteBack!(long[string][string])
        (plugin.ecountFile,
        fileDescription: "ecount");

    readAndWriteBack!(long[string][string])
        (plugin.viewersFile,
        fileDescription: "Viewers");

    readAndWriteBack!(Credentials.JSONSchema[string])
        (plugin.secretsFile,
        fileDescription: "Secrets");

    readAndWriteBack!(TwitchPlugin.Room.Stream.JSONSchema[])
        (plugin.streamHistoryFile,
        fileDescription: "Stream history");
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
void saveResourceToDisk(/*const*/ long[string][string] aa, const string filename)
{
    import asdf.serialization : serializeToJsonPretty;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable serialised = JSONValue(aa).toPrettyString;
    File(filename, "w").writeln(serialised);
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
    json.object = null;

    foreach (immutable channelName, creds; aa)
    {
        json[channelName] = creds.asSchema.asJSONValue;
    }

    immutable serialised = json.toPrettyString;
    File(filename, "w").writeln(serialised);
}


// loadResources
/++
    Loads all resources from disk.
 +/
void loadResources(TwitchPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;
    import core.memory : GC;

    version(PrintStacktraces)
    {
        static void printContent(const string content)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    GC.disable();
    scope(exit) GC.enable();

    {
        immutable content = plugin.ecountFile.readText.strippedRight;

        version(PrintStacktraces)
        {
            scope(failure) printContent(content);
        }

        plugin.ecount = content.deserialize!(long[string][string]);
    }
    {
        immutable content = plugin.viewersFile.readText.strippedRight;

        version(PrintStacktraces)
        {
            scope(failure) printContent(content);
        }

        plugin.viewerTimesByChannel = content.deserialize!(long[string][string]);
    }
    {
        immutable content = plugin.secretsFile.readText.strippedRight;

        version(PrintStacktraces)
        {
            scope(failure) printContent(content);
        }

        auto creds = content.deserialize!(Credentials.JSONSchema[string]);

        plugin.secretsByChannel = null;

        foreach (immutable channelName, channelCreds; creds)
        {
            plugin.secretsByChannel[channelName] = Credentials(channelCreds);
        }
    }
}


// reimportCustomEmotes
/++
    Re-imports custom emotes for all channels for which we have previously
    imported them.

    Params:
        plugin = The current [TwitchPlugin].
 +/
void reimportCustomEmotes(TwitchPlugin plugin)
{
    import kameloso.plugins.twitch.emotes : importCustomEmotesImpl;

    plugin.customGlobalEmotes = null;
    importCustomEmotesImpl(plugin);

    foreach (immutable channelName, ref customEmotes; plugin.customChannelEmotes)
    {
        import kameloso.plugins.twitch.emotes : Delays;
        import kameloso.plugins.common.scheduling : delay;
        import kameloso.constants : BufferSize;
        import std.algorithm.searching : countUntil;
        import core.thread.fiber : Fiber;
        import core.time : Duration, seconds;

        //plugin.customChannelEmotes[channelName].emotes = null;
        customEmotes.emotes = null;

        void importDg()
        {
            // Can't reuse the customEmotes pointer as it changes while looping
            importCustomEmotesImpl(
                plugin: plugin,
                channelName: channelName,
                id: plugin.customChannelEmotes[channelName].id);
        }

        /+
            Stagger imports a bit.
         +/
        Duration delayUntilImport;

        immutable homeIndex = plugin.state.bot.homeChannels.countUntil(channelName);

        if (homeIndex != -1)
        {
            // It's a home channel
            delayUntilImport = homeIndex * Delays.delayBetweenImports;
        }
        else
        {
            immutable guestIndex = plugin.state.bot.guestChannels.countUntil(channelName);

            if (guestIndex != -1)
            {
                // Channel joined via piped command or admin join command
                immutable start = plugin.state.bot.homeChannels.length;
                delayUntilImport = start.seconds + (guestIndex * Delays.delayBetweenImports);
            }
            else
            {
                // Invent a delay based on the hash of the channel name
                // padded by the number of home and guest channels
                immutable start = (plugin.state.bot.homeChannels.length + plugin.state.bot.guestChannels.length);
                delayUntilImport = start.seconds + ((channelName.hashOf % 5) * Delays.delayBetweenImports);
            }
        }

        auto importFiber = new Fiber(&importDg, BufferSize.fiberStack);
        delay(plugin, importFiber, delayUntilImport);
    }
}


// reload
/++
    Reloads the plugin, loading resources from disk and re-importing custom emotes.
 +/
void reload(TwitchPlugin plugin)
{
    loadResources(plugin);

    if (plugin.settings.customEmotes)
    {
        reimportCustomEmotes(plugin);
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
    import kameloso.constants : BufferSize;
    import kameloso.messaging : Message;
    import kameloso.thread : Boxed;

    if (header != "twitch") return;

    const message = cast(Boxed!Message) content;

    if (!message)
    {
        enum pattern = "The <l>%s</> plugin received an invalid bus message: expected type <l>%s";
        logger.errorf(pattern, plugin.name, typeof(message).stringof);
        return;
    }

    if (message.payload.properties & Message.Property.whisper)
    {
        plugin.whisperBuffer.put(message.payload);

        if (!plugin.transient.whispererRunning)
        {
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

                    immutable untilNextMsecs = cast(uint) (untilNextSeconds * 1000);
                    delay(plugin, untilNextMsecs.msecs, yield: true);
                }
            }

            auto whispererFiber = new Fiber(&whispererDg, BufferSize.fiberStack);
            whispererFiber.call();
        }
    }
    else if (message.payload.properties & Message.Property.announcement)
    {
        void sendAnnouncementDg()
        {
            sendAnnouncement(
                plugin,
                message.payload.event.channel.id,
                message.payload.event.content,
                message.payload.event.aux[0]);
        }

        auto sendAnnouncementFiber = new Fiber(&sendAnnouncementDg, BufferSize.fiberStack);
        sendAnnouncementFiber.call();
    }
    else
    {
        import lu.conv : toString;
        enum pattern = "Unknown message properties of <l>%s</> sent as TwitchPlugin bus message";
        logger.errorf(pattern, message.payload.event.type.toString);
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
    import kameloso.net : HTTPQueryResponse;
    import kameloso.terminal : TerminalToken;
    import lu.container : Buffer, CircularBuffer, MutexedAA;
    import std.conv : to;
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
            import asdf.serialization : serdeIgnore, serdeOptional;

            /++
                The unique ID of a stream, as supplied by Twitch.

                Cannot be made immutable or generated `opAssign`s break.
             +/
            /*immutable*/ ulong _id;

        package:
            @serdeOptional
            static struct JSONSchema
            {
                /*
                {
                    "data": [
                        {
                            "game_id": "506415",
                            "game_name": "Sekiro: Shadows Die Twice",
                            "id": "47686742845",
                            "is_mature": false,
                            "language": "en",
                            "started_at": "2022-12-26T16:47:58Z",
                            "tag_ids": [
                                "6ea6bca4-4712-4ab9-a906-e3336a9d8039"
                            ],
                            "tags": [
                                "darksouls",
                                "voiceactor",
                                "challengerunner",
                                "chill",
                                "rpg",
                                "survival",
                                "creativeprofanity",
                                "simlish",
                                "English"
                            ],
                            "thumbnail_url": "https:\/\/static-cdn.jtvnw.net\/previews-ttv\/live_user_lobosjr-{width}x{height}.jpg",
                            "title": "it's been so long! | fresh run",
                            "type": "live",
                            "user_id": "28640725",
                            "user_login": "lobosjr",
                            "user_name": "LobosJr",
                            "viewer_count": 2341
                        }
                    ],
                    "pagination": {
                        "cursor": "eyJiIjp7IkN1cnNvciI6ImV5SnpJam95TXpReExqUTBOelV3T1RZMk9URXdORFFzSW1RaU9tWmhiSE5sTENKMElqcDBjblZsZlE9PSJ9LCJhIjp7IkN1cnNvciI6IiJ9fQ"
                    }
                }
                 */
                /*
                {
                    "data": [
                        {
                        "id": "ed961efd-8a3f-4cf5-a9d0-e616c590cd2a",
                        "broadcaster_id": "141981764",
                        "broadcaster_name": "TwitchDev",
                        "broadcaster_login": "twitchdev",
                        "title": "Heads or Tails?",
                        "choices": [
                            {
                            "id": "4c123012-1351-4f33-84b7-43856e7a0f47",
                            "title": "Heads",
                            "votes": 0,
                            "channel_points_votes": 0,
                            "bits_votes": 0
                            },
                            {
                            "id": "279087e3-54a7-467e-bcd0-c1393fcea4f0",
                            "title": "Tails",
                            "votes": 0,
                            "channel_points_votes": 0,
                            "bits_votes": 0
                            }
                        ],
                        "bits_voting_enabled": false,
                        "bits_per_vote": 0,
                        "channel_points_voting_enabled": true,
                        "channel_points_per_vote": 100,
                        "status": "TERMINATED",
                        "duration": 1800,
                        "started_at": "2021-03-19T06:08:33.871278372Z",
                        "ended_at": "2021-03-19T06:11:26.746889614Z"
                        }
                    ]
                }
                 */
                /*
                {
                    "data": [],
                    "pagination": {}
                }
                 */

                string game_id;
                string game_name;
                string id;
                string started_at;
                string[] tags;
                string title;
                string type;
                string user_id;
                string user_login;
                string user_name;
                long viewer_count;
                long viewer_count_max;

                @serdeOptional
                {
                    string ended_at;
                    long duration;
                }

                @serdeIgnore
                {
                    string[] tag_ids;
                    string thumbnail_url;
                    bool is_mature;
                    string language;
                }

                /++
                    Returns this [JSONSchema] as a [std.json.JSONValue|JSONValue].
                 +/
                auto asJSONValue() const
                {
                    import std.json : JSONValue;

                    JSONValue json;
                    json.object = null;
                    json["game_id"] = this.game_id;
                    json["game_name"] = this.game_name;
                    json["id"] = this.id;
                    json["started_at"] = this.started_at;
                    json["tags"] = this.tags.dup;
                    json["title"] = this.title;
                    json["type"] = this.type;
                    json["user_id"] = this.user_id;
                    json["user_login"] = this.user_login;
                    json["user_name"] = this.user_name;
                    json["viewer_count"] = this.viewer_count;
                    json["viewer_count_max"] = this.viewer_count_max;
                    json["ended_at"] = this.ended_at;
                    json["duration"] = this.duration;
                    return json;
                }
            }

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
            SysTime startedAt;

            /++
                When the stream ended.
             +/
            SysTime endedAt;

            /++
                How long the stream had been running after terminating it.
             +/
            Duration duration;

            /++
                How many people were viewing the stream the last time the monitor
                [core.thread.fiber.Fiber|Fiber] checked.
             +/
            long viewerCount;

            /++
                The maximum number of people seen watching this stream.
             +/
            long viewerCountMax;

            /++
                Status of the stream, when it has ended. Can be one of
                "`TERMINATED`" and "`ARCHIVED`".
             +/
            string status;

            /++
                Users seen in the channel.
             +/
            bool[string] chattersSeen;

            /++
                Hashmap of active viewers (who have shown activity).
             +/
            bool[string] activeViewers;

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
                Constructor.
             +/
            this(const JSONSchema schema)
            {
                import core.time : seconds;

                this._id = schema.id.to!ulong;
                this.userID = schema.user_id.to!ulong;
                this.userLogin = schema.user_login;
                this.userDisplayName = schema.user_name;
                this.gameID = schema.game_id.to!ulong;
                this.gameName = schema.game_name;
                this.title = schema.title;
                this.startedAt = SysTime.fromISOExtString(schema.started_at);
                this.status = schema.type;
                this.viewerCount = schema.viewer_count;
                this.viewerCountMax = schema.viewer_count_max;
                this.tags = schema.tags.dup;
                this.duration = schema.duration.seconds;

                if (schema.ended_at.length)
                {
                    this.endedAt = SysTime.fromISOExtString(schema.ended_at);
                }
                else
                {
                    this.live = true;
                }
            }

            /++
                Returns a [JSONSchema] representation of this stream.
             +/
            auto asSchema() const
            {
                JSONSchema schema;

                schema.id = this._id.to!string;
                schema.user_id = this.userID.to!string;
                schema.user_login = this.userLogin;
                schema.user_name = this.userDisplayName;
                schema.game_id = this.gameID.to!string;
                schema.game_name = this.gameName;
                schema.title = this.title;
                schema.started_at = this.startedAt.toISOExtString;
                schema.type = this.status;
                schema.viewer_count = this.viewerCount;
                schema.viewer_count_max = this.viewerCountMax;
                schema.tags = this.tags.dup;
                schema.duration = this.duration.total!"seconds";

                if (this.endedAt != SysTime.init)
                {
                    schema.ended_at = this.endedAt.toISOExtString;
                }

                return schema;
            }

            /++
                Takes a second [Stream] and updates this one with values from it.

                Params:
                    updated =  A second [Stream] from which to inherit values.
             +/
            void update(const Stream updated)
            {
                assert(_id, "Stream not properly initialised");

                this.gameID = updated.gameID;
                this.gameName = updated.gameName;
                this.title = updated.title;
                this.viewerCount = updated.viewerCount;
                this.tags = updated.tags.dup;
                this.endedAt = updated.endedAt;
                this.status = updated.status;

                if (this.viewerCount > this.viewerCountMax)
                {
                    this.viewerCountMax = this.viewerCount;
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
        /++
            Authorisation token for the "Authorization: Bearer <token>".
         +/
        string authorizationBearer;

        /++
            The bot's numeric account/ID.
         +/
        ulong botID;

        /++
            Effective bell after [kameloso.terminal.isTerminal] checks.
         +/
        string bell = "" ~ cast(char) (TerminalToken.bell);

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
    TwitchSettings settings;

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

    /++
        How many times to retry a Twitch server query.
     +/
    enum delegateRetries = 10;

    /++
        Associative array of viewer times; seconds keyed by nickname keyed by channel.
     +/
    long[string][string] viewerTimesByChannel;

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
    MutexedAA!(HTTPQueryResponse[int]) responseBucket;

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
    long[string][string] ecount;

    /++
        Buffer of messages to send as whispers.
     +/
    Buffer!(Message, No.dynamic, BufferSize.outbuffer) whisperBuffer;

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
            (this.settings.keygen ||
            this.settings.superKeygen ||
            this.settings.googleKeygen ||
            this.settings.youtubeKeygen ||
            this.settings.spotifyKeygen);

        return (
            wantKeygen ||  // Always enabled if we want to generate keys
            (this.settings.enabled &&
                (this.state.server.daemon == IRCServer.Daemon.twitch) ||
                (this.state.server.daemon == IRCServer.Daemon.unset)));
    }

    mixin IRCPluginImpl;
}

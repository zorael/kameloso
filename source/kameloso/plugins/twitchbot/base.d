/++
    This is an example Twitch streamer bot. It supports querying uptime or how
    long a streamer has been live, follower age queries, and
    timered announcements. It can also emit some terminal bells on certain
    events, to draw attention.

    One immediately obvious venue of expansion is expression bans, such as if a
    message has too many capital letters, etc. There is no protection from spam yet.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitchbot
        [kameloso.plugins.common.core]
        [kameloso.plugins.common.misc]
 +/
@("twitchbot")
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


/// All Twitch bot plugin runtime settings.
@Settings struct TwitchBotSettings
{
private:
    import lu.uda : Unserialisable;

public:
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// Whether or not to bell on every message.
    bool bellOnMessage = false;

    /// Whether or not to bell on important events, like subscriptions.
    bool bellOnImportant = false;

    /// Whether or not broadcasters are always implicitly class [dialect.defs.IRCUser.Class.staff].
    bool promoteBroadcasters = true;

    /++
        Whether or not moderators are always implicitly (at least) class
        [dialect.defs.IRCUser.Class.operator].
     +/
    bool promoteModerators = true;

    /++
        Whether or not VIPs are always implicitly (at least) class
        [dialect.defs.IRCUser.Class.whitelist].
     +/
    bool promoteVIPs = true;

    version(Windows)
    {
        /++
            Whether to use one persistent worker for Twitch queries or to use separate subthreads.

            It's a trade-off. A single worker thread obviously spawns fewer threads,
            which makes it a better choice on Windows systems where creating such is
            comparatively expensive. On the other hand, it's also slower (likely due to
            concurrency message passing overhead).
         +/
        bool singleWorkerThread = true;
    }
    else
    {
        /// Ditto
        bool singleWorkerThread = false;
    }

    /++
        Whether or not to start a captive session for generating a Twitch
        authorisation key. Should not be permanently set in the configuration file!
     +/
    @Unserialisable bool keygen = false;
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

    Creates the timer [core.thread.fiber.Fiber]s that there are definitions for in
    [TwitchBotPlugin.timerDefsByChannel].

    Params:
        plugin = The current [TwitchBotPlugin].
        channelName = The name of the channel we're supposedly joining.
 +/
void handleSelfjoin(TwitchBotPlugin plugin, const string channelName)
in (channelName.length, "Tried to handle SELFJOIN with an empty channel string")
{
    if (channelName in plugin.rooms) return;

    plugin.rooms[channelName] = TwitchBotPlugin.Room(channelName);

    // Apply the timer definitions we have stored
    const timerDefs = channelName in plugin.timerDefsByChannel;

    if (timerDefs && timerDefs.length)
    {
        auto room = channelName in plugin.rooms;

        foreach (const timerDef; *timerDefs)
        {
            room.timers ~= plugin.createTimerFiber(timerDef, channelName);
        }
    }
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
        import kameloso.common : Tint;

        logger.warningf("The bot is not a moderator of home channel %s%s%s. " ~
            "Consider elevating it to such to avoid being as rate-limited.",
            Tint.log, event.channel, Tint.warning);
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


// onCommandTimer
/++
    Adds, deletes, lists or clears timers for the specified target channel.

    Changes are persistently saved to the [TwitchBotPlugin.timersFile] file.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("timer")
            .policy(PrefixPolicy.prefixed)
            .description("Adds, removes, lists or clears timered lines.")
            .syntax("$command [add|del|list|clear]")
    )
)
void onCommandTimer(TwitchBotPlugin plugin, const ref IRCEvent event)
{
    return handleTimerCommand(plugin, event, event.channel);
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
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("start")
            .policy(PrefixPolicy.prefixed)
            .description("Marks the start of a broadcast.")
    )
)
void onCommandStart(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to start a broadcast on a nonexistent room");

    if (room.broadcast.active)
    {
        version(TwitchAPIFeatures)
        {
            immutable streamer = room.broadcasterDisplayName;
        }
        else
        {
            import kameloso.plugins.common.misc : nameOf;
            immutable streamer = plugin.nameOf(event.channel[1..$]);
        }

        chan(plugin.state, event.channel, streamer ~ " is already live.");
        return;
    }

    room.broadcast = typeof(room.broadcast).init;
    room.broadcast.startTime = event.time;
    room.broadcast.active = true;
    chan(plugin.state, event.channel, "Broadcast start registered!");

    version(TwitchAPIFeatures)
    {
        import core.thread : Fiber;

        void periodicalChattersCheckDg()
        {
            while (room.broadcast.active)
            {
                import kameloso.plugins.common.delayawait : delay;
                import std.json : JSONType;

                immutable chattersJSON = getChatters(plugin, event.channel[1..$]);
                if (chattersJSON.type != JSONType.object) return;

                foreach (immutable viewerJSON; chattersJSON["chatters"]["viewers"].array)
                {
                    immutable viewer = viewerJSON.str;
                    if (viewer == plugin.state.client.nickname) continue;
                    room.broadcast.chattersSeen[viewer] = true;
                }

                // Don't count the bot nor the broadcaster as a viewer.
                immutable chatterCount = cast(int)chattersJSON["chatter_count"].integer;
                immutable int numCurrentViewers = chattersJSON["chatters"]["broadcaster"].array.length ?
                    (chatterCount - 2) :  // sans broadcaster + bot
                    (chatterCount - 1);   // sans only bot

                if (numCurrentViewers > room.broadcast.maxConcurrentChatters)
                {
                    room.broadcast.maxConcurrentChatters = numCurrentViewers;
                }

                delay(plugin, plugin.chattersCheckPeriodicity, Yes.yield);
            }
        }

        Fiber chattersCheckFiber =
            new Fiber(&twitchTryCatchDg!periodicalChattersCheckDg, BufferSize.fiberStack);
        chattersCheckFiber.call();
    }
}


// onCommandStop
/++
    Marks the stop of a broadcast.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
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

    version(TwitchAPIFeatures)
    {
        room.broadcast.numViewersLastStream = room.broadcast.chattersSeen.length;
        room.broadcast.chattersSeen = typeof(room.broadcast.chattersSeen).init;
    }

    chan(plugin.state, event.channel, "Broadcast ended!");
    reportStreamTime(plugin, *room, Yes.justNowEnded);
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

        // Remove fractional seconds from the current timestamp
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
            // There was at least one stream this session (we have a stop timestamp)
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

            // No streams this session
            chan(plugin.state, room.name, streamer ~ " is currently not streaming.");
        }
    }
}


// onCommandFollowAge
/++
    Implements "Follow Age", or the ability to query the server how long you
    (or a specified user) have been a follower of the current channel.

    Lookups are done asynchronously in subthreads.
 +/
version(TwitchAPIFeatures)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("followage")
            .policy(PrefixPolicy.prefixed)
            .description("Queries the server for how long you have been a follower " ~
                "of the current channel. Optionally takes a nickname parameter, " ~
                "to query for someone else.")
            .syntax("$command [optional nickname]")
    )
)
void onCommandFollowAge(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : nom, stripped;
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
            immutable givenName = slice.nom!(Yes.inherit)(' ');

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

            immutable when = SysTime.fromISOExtString(followingUserJSON["followed_at"].str);
            immutable diff = Clock.currTime - when;
            immutable timeline = diff.timeSince!(7, 3);
            immutable datestamp = "%s %d"
                .format(months[cast(int)when.month-1], when.year);

            if (nameSpecified)
            {
                enum pattern = "%s has been a follower for %s, since %s.";
                chan(plugin.state, event.channel, pattern
                    .format(fromDisplayName, timeline, datestamp));
            }
            else
            {
                enum pattern = "You have been a follower for %s, since %s.";
                chan(plugin.state, event.channel, pattern.format(timeline, datestamp));
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
            chan(plugin.state, event.channel, pattern.format(fromDisplayName));
        }
        else
        {
            enum pattern = "You are currently not a follower.";
            chan(plugin.state, event.channel, pattern);
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
version(TwitchAPIFeatures)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ROOMSTATE)
    .channelPolicy(ChannelPolicy.home)
)
void onRoomState(TwitchBotPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.datetime.systime : Clock, SysTime;
    import std.json : JSONType, parseJSON;

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
version(TwitchAPIFeatures)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.SELFCHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("shoutout")
            .policy(PrefixPolicy.prefixed)
            .description("Emits a shoutout to another streamer.")
            .syntax("$command [name of streamer]")
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
    import lu.string : stripped;
    import std.format : format;
    import std.json : JSONType, parseJSON;

    string slice = event.content.stripped;  // mutable
    if (slice.length && (slice[0] == '@')) slice = slice[1..$];

    if (!slice.length)
    {
        chan(plugin.state, event.channel, "Usage: %s%s [name of streamer]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    immutable nickname = idOf(plugin, slice);

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
            chan(plugin.state, event.channel, "No such user: " ~ slice);
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

        immutable broadcasterName = channelJSON["broadcaster_name"].str;
        immutable gameName = channelJSON["game_name"].str;
        immutable lastSeenPlayingPattern = gameName.length ?
            " (last seen playing %s)" : "%s";

        chan(plugin.state, event.channel,
            ("Shoutout to %s! Visit them at https://twitch.tv/%s!" ~ lastSeenPlayingPattern)
                .format(broadcasterName, login, gameName));
    }

    Fiber shoutoutFiber = new Fiber(&twitchTryCatchDg!shoutoutQueryDg, BufferSize.fiberStack);
    shoutoutFiber.call();
}


// onAnyMessage
/++
    Performs various actions on incoming messages.

    * Bells on any message, if the [TwitchBotSettings.bellOnMessage] setting is set.
    * Bumps the message counter for the channel, used by timers.

    Belling is useful with small audiences, so you don't miss messages.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .onEvent(IRCEvent.Type.EMOTE)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
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

    // Don't do any more than bell on whispers
    if (event.type == IRCEvent.Type.QUERY) return;

    auto room = event.channel in plugin.rooms;

    if (!room)
    {
        // Race...
        plugin.handleSelfjoin(event.channel);
        room = event.channel in plugin.rooms;
    }

    ++room.messageCount;
}


// onEndOfMOTD
/++
    Sets up various things after we have successfully
    logged onto the server.

    Has to be done at MOTD, as we only know whether we're on Twitch after
    RPL_MYINFO or so.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMOTD(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    // Timers use a specialised function
    plugin.populateTimers(plugin.timersFile);

    version(TwitchAPIFeatures)
    {
        import lu.string : beginsWith;
        import std.concurrency : Tid;

        if (!plugin.useAPIFeatures) return;

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

                if (expiresIn == 0L)
                {
                    import kameloso.messaging : quit;
                    import std.typecons : Flag, No, Yes;

                    // Expired.
                    logger.error("Error: Your Twitch authorisation key has expired.");
                    quit!(Yes.priority)(plugin.state, string.init, Yes.quiet);
                }
                else
                {
                    immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime + expiresIn);
                    immutable now = Clock.currTime;

                    if ((expiresWhen - now) > 1.weeks)
                    {
                        // More than a week away, just .info
                        enum pattern = "Your Twitch authorisation key will expire on " ~
                            "%s%02d-%02d-%02d%s.";
                        logger.infof!pattern( Tint.log, expiresWhen.year,
                            expiresWhen.month, expiresWhen.day, Tint.info);
                    }
                    else
                    {
                        // A week or less; warning
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

                // Something is deeply wrong.
                logger.errorf("Failed to validate Twitch API keys: %s (%s%s%s) (%2$s%5$s%4$s)",
                    e.msg, Tint.log, e.error, Tint.error, curlErrorStrings[e.errorCode]);

                if (e.errorCode == CurlError.ssl_cacert)
                {
                    // Peer certificate cannot be authenticated with given CA certificates
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


// onCAP
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the CAP events.

    We can't do it in [start] since the calls to save and exit would go unheard,
    as [start] happens before the main loop starts. It would then immediately
    fail to read if too much time has passed, and nothing would be saved.
 +/
version(TwitchAPIFeatures)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CAP)
)
void onCAP(TwitchBotPlugin plugin)
{
    import kameloso.plugins.twitchbot.keygen;
    if (plugin.twitchBotSettings.keygen) return plugin.generateKey();
}


// reload
/++
    Reloads resources from disk.
 +/
void reload(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch) return;

    plugin.timerDefsByChannel = typeof(plugin.timerDefsByChannel).init;
    plugin.populateTimers(plugin.timersFile);
}


// initResources
/++
    Reads and writes the file of timers to disk, ensuring
    that they're there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import kameloso.plugins.common.misc : IRCPluginInitialisationException;
    import lu.json : JSONStorage;
    import std.file : exists;
    import std.json : JSONException;
    import std.path : baseName;
    import std.stdio : File;

    JSONStorage timersJSON;

    try
    {
        timersJSON.load(plugin.timersFile);
    }
    catch (JSONException e)
    {
        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.timersFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    timersJSON.save(plugin.timersFile);
}


// onMyInfo
/++
    Sets up a Fiber to periodically call timer [core.thread.fiber.Fiber]s with a
    periodicity of [TwitchBotPlugin.timerPeriodicity].

    Cannot be done on [dialect.defs.IRCEvent.Type.RPL_WELCOME] as the server
    daemon isn't known by then.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_MYINFO)
)
void onMyInfo(TwitchBotPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import core.thread : Fiber;

    void periodicDg()
    {
        import kameloso.common : nextMidnight;
        import std.datetime.systime : Clock;

        version(TwitchAPIFeatures)
        {
            // Schedule next follow cache update to next midnight
            long nextCacheUpdate = Clock.currTime.nextMidnight.toUnixTime;
        }

        top:
        while (true)
        {
            // Walk through channels, trigger fibers
            foreach (immutable channelName, room; plugin.rooms)
            {
                foreach (timer; room.timers)
                {
                    if (!timer || (timer.state != Fiber.State.HOLD))
                    {
                        logger.error("Dead or busy timer Fiber in channel ", channelName);
                        continue;
                    }

                    timer.call();
                }
            }

            version(TwitchAPIFeatures)
            {
                immutable now = Clock.currTime;
                immutable nowInUnix = now.toUnixTime;

                // Early yield if we shouldn't clean up
                if (nowInUnix < nextCacheUpdate)
                {
                    delay(plugin, plugin.timerPeriodicity, Yes.yield);
                    continue top;
                }

                nextCacheUpdate = now.nextMidnight.toUnixTime;

                version(TwitchAPIFeatures)
                {
                    // Clear and re-cache follows once as often as we prune

                    void cacheFollowsAnewDg()
                    {
                        foreach (immutable channelName, room; plugin.rooms)
                        {
                            room.follows = getFollows(plugin, room.id);
                        }
                    }

                    Fiber cacheFollowsAnewFiber =
                        new Fiber(&twitchTryCatchDg!cacheFollowsAnewDg, BufferSize.fiberStack);
                    cacheFollowsAnewFiber.call();
                }
            }
            else
            {
                delay(plugin, plugin.timerPeriodicity, Yes.yield);
                continue top;
            }
        }
    }

    Fiber periodicFiber = new Fiber(&periodicDg, BufferSize.fiberStack);
    delay(plugin, periodicFiber, plugin.timerPeriodicity);
}


// start
/++
    Disables the bell if we're not running inside a terminal.
 +/
void start(TwitchBotPlugin plugin)
{
    import kameloso.terminal : isTTY;

    if (!isTTY)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.bell = string.init;
    }
}


// teardown
/++
    De-initialises the plugin. Shuts down any persistent worker threads.
 +/
version(TwitchAPIFeatures)
void teardown(TwitchBotPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : Tid, send;

    if (plugin.twitchBotSettings.singleWorkerThread &&
        (plugin.persistentWorkerTid != Tid.init))
    {
        // It may not have been started if we're aborting very early.
        plugin.persistentWorkerTid.send(ThreadMessage.Teardown());
    }
}


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent] and modifies the sender and
    target class based on their badges (and the current settings).
 +/
void postprocess(TwitchBotPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!event.sender.nickname.length || !event.channel.length) return;
    else if (!plugin.state.bot.homeChannels.canFind(event.channel)) return;

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

    if (event.sender.badges.length) postprocessImpl(plugin, event, event.sender);
    if (event.target.badges.length) postprocessImpl(plugin, event, event.target);
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
    import core.time : seconds;

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

            version(TwitchAPIFeatures)
            {
                /// Users seen in the channel.
                bool[string] chattersSeen;

                /// How many users were max seen as in the channel at the same time.
                int maxConcurrentChatters;

                /// How many users visited the channel during the last stream.
                size_t numViewersLastStream;
            }
        }

        /// Constructor taking a string (channel) name.
        this(const string name) @safe pure nothrow @nogc
        {
            this.name = name;
        }

        /// Name of the channel.
        string name;

        /// Struct instance representing the current broadcast.
        Broadcast broadcast;

        /// ID of the currently ongoing vote, if any (otherwise 0).
        int voteInstance;

        /++
            A counter of how many messages we have seen in the channel.

            Used by timers to know when enough activity has passed to warrant
            re-announcing timers.
         +/
        ulong messageCount;

        /// Timer [core.thread.fiber.Fiber]s.
        Fiber[] timers;

        version(TwitchAPIFeatures)
        {
            /// Display name of the broadcaster.
            string broadcasterDisplayName;

            /// Broadcaster user/account/room ID (not name).
            string id;

            /// A JSON list of the followers of the channel.
            JSONValue[string] follows;
        }
    }

    /// All Twitch Bot plugin settings.
    TwitchBotSettings twitchBotSettings;

    /// Array of active bot channels' state.
    Room[string] rooms;

    /// Timer definition arrays, keyed by channel string.
    TimerDefinition[][string] timerDefsByChannel;

    /// Filename of file with timer definitions.
    @Resource string timersFile = "twitchtimers.json";

    /++
        How often to check whether timers should fire, in seconds. A smaller
        number means better precision.
     +/
    static immutable timerPeriodicity = 5.seconds;

    /// [kameloso.terminal.TerminalToken.bell] as string, for use as bell.
    private enum bellString = ("" ~ cast(char)(TerminalToken.bell));

    /// Effective bell after [kameloso.terminal.isTTY] checks.
    string bell = bellString;

    version(TwitchAPIFeatures)
    {
        import std.concurrency : Tid;

        /// The Twitch application ID for kameloso.
        enum clientID = "tjyryd2ojnqr8a51ml19kn1yi2n0v1";

        /// Authorisation token for the "Authorization: Bearer <token>".
        string authorizationBearer;

        /// Whether or not to use features requiring querying Twitch API.
        bool useAPIFeatures = true;

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
            The divisor of how much to wait before retrying a query, after the timed waited
            turned out to be a bit short.
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
            How many seconds before a Twitch query response times out. Does not
            affect the actual HTTP request, just how long we wait for it to arrive.
         +/
        enum queryResponseTimeout = 15;

        /++
            How big a buffer to preallocate when doing HTTP API queries.
         +/
        enum queryBufferSize = 4096;

        /++
            When broadcasting, how often to check and enumerate chatters.
         +/
        static immutable chattersCheckPeriodicity = 180.seconds;

        /// The thread ID of the persistent worker thread.
        Tid persistentWorkerTid;

        /// Associative array of responses from async HTTP queries.
        shared QueryResponse[string] bucket;
    }


    // isEnabled
    /++
        Override [kameloso.plugins.common.core.IRCPluginImpl.isEnabled] and inject
        a server check, so this plugin only works on Twitch, in addition
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

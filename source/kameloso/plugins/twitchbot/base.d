/++
    This is an example Twitch streamer bot. It supports querying uptime or how
    long a streamer has been live, banned phrases, timered announcements and
    voting.

    It can also emit some terminal bells on certain events, to draw attention.

    One immediately obvious venue of expansion is expression bans, such as if a
    message has too many capital letters, etc. There is no protection from spam yet.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#twitchbot
 +/
module kameloso.plugins.twitchbot.base;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

version(Web) version = TwitchAPIFeatures;

private:

import kameloso.plugins.twitchbot.api;
import kameloso.plugins.twitchbot.timers;

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
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
    bool bellOnImportant = true;

    /// Whether or not to filter URLs in user messages.
    bool filterURLs = false;

    /// Whether or not to employ phrase bans.
    bool phraseBans = true;

    /// Whether or not to match ban phrases case-sensitively.
    bool phraseBansObeyCase = true;

    /// Whether or not a link permit should be for one link only or for any number in 60 seconds.
    bool permitOneLinkOnly = true;

    /// Whether or not broadcasters are always implicitly class `dialect.defs.IRCUser.Class.staff`.
    bool promoteBroadcasters = true;

    /// Whether or not to use features dependent on the Twitch API.
    bool enableAPIFeatures = true;

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


// onCommandPermit
/++
    Permits a user to post links for a hardcoded 60 seconds.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "permit")
@Description("Permits a specified user to post links for a brief period of time.",
    "$command [target user]")
void onCommandPermit(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : idOf, nameOf;
    import dialect.common : isValidNickname;
    import lu.string : stripped;
    import std.format : format;

    if (!plugin.twitchBotSettings.filterURLs)
    {
        chan(plugin.state, event.channel, "Links are not being filtered.");
        return;
    }

    string slice = event.content.stripped;  // mutable
    if (slice.length && (slice[0] == '@')) slice = slice[1..$];

    if (!slice.length)
    {
        chan(plugin.state, event.channel, "Usage: %s%s [nickname]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to handle permits on nonexistent room");

    immutable nickname = idOf(plugin, slice);

    if (!nickname.isValidNickname(plugin.state.server))
    {
        chan(plugin.state, event.channel, "Invalid streamer name.");
        return;
    }

    immutable name = nameOf(plugin, nickname);

    room.linkPermits[nickname] = event.time;

    if (nickname in room.linkBans)
    {
        // Was or is timed out, remove it just in case
        room.linkBans.remove(nickname);
        chan(plugin.state, event.channel, "/untimeout " ~ nickname);
    }

    immutable pattern = plugin.twitchBotSettings.permitOneLinkOnly ?
        "@%s, you are now allowed to post a link for 60 seconds." :
        "@%s, you are now allowed to post links for 60 seconds.";

    chan(plugin.state, event.channel, pattern.format(name));
}


// onImportant
/++
    Bells on any important event, like subscriptions, cheers and raids, if the
    `TwitchBotSettings.bellOnImportant` setting is set.
 +/
@Chainable
@(IRCEvent.Type.TWITCH_SUB)
@(IRCEvent.Type.TWITCH_SUBGIFT)
@(IRCEvent.Type.TWITCH_CHEER)
@(IRCEvent.Type.TWITCH_REWARDGIFT)
@(IRCEvent.Type.TWITCH_RAID)
@(IRCEvent.Type.TWITCH_UNRAID)
@(IRCEvent.Type.TWITCH_GIFTCHAIN)
@(IRCEvent.Type.TWITCH_BULKGIFT)
@(IRCEvent.Type.TWITCH_SUBUPGRADE)
@(IRCEvent.Type.TWITCH_CHARITY)
@(IRCEvent.Type.TWITCH_BITSBADGETIER)
@(IRCEvent.Type.TWITCH_RITUAL)
@(IRCEvent.Type.TWITCH_EXTENDSUB)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
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
    Registers a new `TwitchBotPlugin.Room` as we join a channel, so there's
    always a state struct available.

    Simply passes on execution to `handleSelfjoin`.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.home)
package void onSelfjoin(TwitchBotPlugin plugin, const IRCEvent event)
{
    return plugin.handleSelfjoin(event.channel);
}


// handleSelfjoin
/++
    Registers a new `TwitchBotPlugin.Room` as we join a channel, so there's
    always a state struct available.

    Creates the timer `core.thread.fiber.Fiber`s that there are definitions for in
    `TwitchBotPlugin.timerDefsByChannel`.

    Params:
        plugin = The current `TwitchBotPlugin`.
        channelName = The name of the channel we're supposedly joining.
 +/
package void handleSelfjoin(TwitchBotPlugin plugin, const string channelName)
in (channelName.length, "Tried to handle SELFJOIN with an empty channel string")
{
    if (channelName in plugin.rooms) return;

    plugin.rooms[channelName] = TwitchBotPlugin.Room.init;

    // Apply the timer definitions we have stored
    const timerDefs = channelName in plugin.timerDefsByChannel;
    if (!timerDefs || !timerDefs.length) return;

    auto room = channelName in plugin.rooms;

    foreach (const timerDef; *timerDefs)
    {
        room.timers ~= plugin.createTimerFiber(timerDef, channelName);
    }
}


// onSelfpart
/++
    Removes a channel's corresponding `TwitchBotPlugin.Room` when we leave it.

    This resets all that channel's transient state.
 +/
@(IRCEvent.Type.SELFPART)
@(ChannelPolicy.home)
void onSelfpart(TwitchBotPlugin plugin, const IRCEvent event)
{
    plugin.rooms.remove(event.channel);
}


// onCommandPhrase
/++
    Bans, unbans, lists or clears banned phrases for the current channel.

    Changes are persistently saved to the `TwitchBotPlugin.bannedPhrasesFile` file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "phrase")
@Description("Adds, removes, lists or clears phrases from the list of banned such.",
    "$command [ban|unban|list|clear]")
void onCommandPhrase(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handlePhraseCommand(plugin, event, event.channel);
}


// handlePhraseCommand
/++
    Bans, unbans, lists or clears banned phrases for the specified target channel.

    Params:
        plugin = The current `TwitchBotPlugin`.
        event = The triggering `dialect.defs.IRCEvent`.
        targetChannel = The channel we're handling phrase bans for.
 +/
void handlePhraseCommand(TwitchBotPlugin plugin, const IRCEvent event, const string targetChannel)
in (targetChannel.length, "Tried to handle phrases with an empty target channel string")
{
    import lu.string : contains, nom;
    import std.format : format;

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "ban":
    case "add":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s %s [phrase]"
                .format(plugin.state.settings.prefix, event.aux, verb));
            return;
        }

        plugin.bannedPhrasesByChannel[targetChannel] ~= slice;
        saveResourceToDisk(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
        privmsg(plugin.state, event.channel, event.sender.nickname, "New phrase ban added.");
        break;

    case "unban":
    case "del":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s %s [phrase index]"
                .format(plugin.state.settings.prefix, event.aux, verb));
            return;
        }

        if (auto phrases = targetChannel in plugin.bannedPhrasesByChannel)
        {
            import lu.string : stripped;
            import std.algorithm.iteration : splitter;
            import std.conv : ConvException, to;

            if (slice == "*") goto case "clear";

            try
            {
                ptrdiff_t i = slice.stripped.to!ptrdiff_t - 1;

                if ((i >= 0) && (i < phrases.length))
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    *phrases = (*phrases).remove!(SwapStrategy.unstable)(i);
                }
                else
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Phrase ban index %s out of range. (max %d)"
                        .format(slice, phrases.length));
                    return;
                }
            }
            catch (ConvException e)
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "Invalid phrase ban index: " ~ slice);
                //version(PrintStacktraces) logger.trace(e);
                return;
            }

            if (!phrases.length) plugin.bannedPhrasesByChannel.remove(targetChannel);
            saveResourceToDisk(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
            privmsg(plugin.state, event.channel, event.sender.nickname, "Phrase ban removed.");
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No banned phrases registered for this channel.");
        }
        break;

    case "list":
        if (const phrases = targetChannel in plugin.bannedPhrasesByChannel)
        {
            import lu.string : stripped;
            import std.algorithm.comparison : min;

            enum toDisplay = 10;
            enum maxLineLength = 100;

            ptrdiff_t start;

            if (slice.length)
            {
                import std.conv : ConvException, to;

                try
                {
                    start = slice.stripped.to!ptrdiff_t - 1;

                    if ((start < 0) || (start >= phrases.length))
                    {
                        privmsg(plugin.state, event.channel, event.sender.nickname,
                            "Invalid phrase index or out of bounds.");
                        return;
                    }
                }
                catch (ConvException e)
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Usage: %s%s %s [optional starting position number]"
                        .format(plugin.state.settings.prefix, event.aux, verb));
                    //version(PrintStacktraces) logger.trace(e.info);
                    return;
                }
            }

            size_t end = min(start+toDisplay, phrases.length);

            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Currently banned phrases (%d-%d of %d)"
                .format(start+1, end, phrases.length));

            foreach (immutable i, const phrase; (*phrases)[start..end])
            {
                immutable maxLen = min(phrase.length, maxLineLength);
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "%d: %s%s".format(start+i+1, phrase[0..maxLen],
                    (phrase.length > maxLen) ? " ...  [truncated]" : string.init));
            }
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No banned phrases registered for this channel.");
        }
        break;

    case "clear":
        plugin.bannedPhrasesByChannel.remove(targetChannel);
        saveResourceToDisk(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
        privmsg(plugin.state, event.channel, event.sender.nickname, "All banned phrases cleared.");
        break;

    default:
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [ban|unban|list|clear]"
            .format(plugin.state.settings.prefix, event.aux));
        break;
    }
}


// onCommandTimer
/++
    Adds, deletes, lists or clears timers for the specified target channel.

    Changes are persistently saved to the `TwitchBotPlugin.timersFile` file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "timer")
@Description("Adds, removes, lists or clears timered lines.",
    "$command [add|del|list|clear]")
void onCommandTimer(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handleTimerCommand(plugin, event, event.channel);
}


// onCommandEnableDisable
/++
    Toggles whether or not the bot should operate in this channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "enable")
@BotCommand(PrefixPolicy.prefixed, "disable")
@Description("Toggles the Twitch bot in the current channel.")
void onCommandEnableDisable(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (event.aux == "enable")
    {
        plugin.rooms[event.channel].enabled = true;
        chan(plugin.state, event.channel, "Bot enabled!");
    }
    else /*if (event.aux == "disable")*/
    {
        plugin.rooms[event.channel].enabled = false;
        chan(plugin.state, event.channel, "Bot disabled.");
    }
}


// onCommandUptime
/++
    Reports how long the streamer has been streaming.

    Technically, how much time has passed since `!start` was issued.

    The streamer's name is divined from the `plugin.state.users` associative
    array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "uptime")
@Description("Reports how long the streamer has been streaming.")
void onCommandUptime(TwitchBotPlugin plugin, const IRCEvent event)
{
    const room = event.channel in plugin.rooms;
    assert(room, "Tried to process `onCommandUptime` on a nonexistent room");

    version(TwitchAPIFeatures)
    {
        immutable streamer = room.broadcasterDisplayName;
    }
    else
    {
        import kameloso.plugins.common : nameOf;
        immutable streamer = plugin.nameOf(event.channel[1..$]);
    }

    if (room.broadcast.active)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock, SysTime;
        import std.format : format;

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;

        immutable delta = now - SysTime.fromUnixTime(room.broadcast.start);
        bool sent;

        version(TwitchAPIFeatures)
        {
            if (room.broadcast.chattersSeen.length)
            {
                enum pattern = "%s has been live for %s, so far with %d unique viewers. " ~
                    "(max at any one time has so far been %d viewers)";

                chan(plugin.state, event.channel, pattern.format(streamer, delta,
                    room.broadcast.chattersSeen.length,
                    room.broadcast.maxConcurrentChatters));
                sent = true;
            }
        }

        if (!sent)
        {
            chan(plugin.state, event.channel, "%s has been live for %s."
                .format(streamer, delta));
        }
    }
    else
    {
        if (room.broadcast.stop)
        {
            import std.datetime.systime : SysTime;
            import std.format : format;
            import core.time : msecs;

            auto end = SysTime.fromUnixTime(room.broadcast.stop);
            end.fracSecs = 0.msecs;
            immutable delta = end - SysTime.fromUnixTime(room.broadcast.start);

            chan(plugin.state, event.channel, ("%s is currently not streaming. " ~
                "Previous session ended %02d-%02d-%02d %02d:%02d with an uptime of %s.")
                .format(streamer, end.year, end.month, end.day, end.hour, end.minute, delta));
        }
        else
        {
            chan(plugin.state, event.channel, streamer ~ " is currently not streaming.");
        }
    }
}


// onCommandStart
/++
    Marks the start of a broadcast, for later uptime queries.

    Consecutive calls to `!start` are ignored.

    The streamer's name is divined from the `plugin.state.users` associative
    array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "start")
@Description("Marks the start of a broadcast.")
void onCommandStart(TwitchBotPlugin plugin, const IRCEvent event)
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
            import kameloso.plugins.common : nameOf;
            immutable streamer = plugin.nameOf(event.channel[1..$]);
        }

        chan(plugin.state, event.channel, streamer ~ " is already live.");
        return;
    }

    room.broadcast = typeof(room.broadcast).init;
    room.broadcast.start = event.time;
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

        Fiber chattersCheckFiber = new Fiber(&periodicalChattersCheckDg, 32_768);
        chattersCheckFiber.call();
    }
}


// onCommandStop
/++
    Marks the stop of a broadcast.

    The streamer's name is divined from the `plugin.state.users` associative
    array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "stop")
@Description("Marks the stop of a broadcast.")
void onCommandStop(TwitchBotPlugin plugin, const IRCEvent event)
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
    room.broadcast.stop = event.time;

    chan(plugin.state, event.channel, "Broadcast ended!");
    plugin.reportStopTime(event);
}


// onAutomaticStop
/++
    Automatically signals a stream stop when a host starts.

    This is generally done as the last thing after a stream session, so it makes
    sense to automate `onCommandStop`.
 +/
@(ChannelPolicy.home)
@(IRCEvent.Type.TWITCH_HOSTSTART)
void onAutomaticStop(TwitchBotPlugin plugin, const IRCEvent event)
{
    return onCommandStop(plugin, event);
}


// reportStopTime
/++
    Reports how long the recently ongoing, now ended broadcast lasted.
 +/
void reportStopTime(TwitchBotPlugin plugin, const IRCEvent event)
in ((event != IRCEvent.init), "Tried to report stop time to an empty IRCEvent")
{
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import core.time : msecs;

    const room = event.channel in plugin.rooms;
    assert(room, "Tried to report broadcast stop time on a nonexistent room");

    auto end = SysTime.fromUnixTime(room.broadcast.stop);
    end.fracSecs = 0.msecs;
    immutable delta = end - SysTime.fromUnixTime(room.broadcast.start);

    version(TwitchAPIFeatures)
    {
        enum pattern = "%s streamed for %s, with %d unique viewers. " ~
            "(max at any one time was %d viewers)";

        immutable streamer = room.broadcasterDisplayName;
        chan(plugin.state, event.channel, pattern.format(streamer, delta,
            room.broadcast.chattersSeen.length,
            room.broadcast.maxConcurrentChatters));
    }
    else
    {
        import kameloso.plugins.common : nameOf;

        enum pattern = "%s streamed for %s.";

        immutable streamer = plugin.nameOf(event.channel[1..$]);
        chan(plugin.state, event.channel, pattern.format(streamer, delta));
    }
}


// onLink
/++
    Parses a message to see if the message contains one or more URLs.

    It uses a simple state machine in `kameloso.common.findURLs`. If the Webtitles
    plugin has been compiled in, (version `WithWebtitlesPlugin`) it will try to
    send them to it for lookups and reporting.

    Operators, whitelisted and admin users are so far allowed to trigger this, as are
    any user who has been given a temporary permit via `onCommandPermit`.
    Those without permission will have the message deleted and be served a timeout.
 +/
@Chainable
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onLink(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.common : findURLs;
    import lu.string : beginsWith;
    import std.algorithm.searching : canFind;
    import std.format : format;

    version(WithWebtitlesPlugin)
    {
        // Webtitles soft-disables itself on Twitch servers to allow us to filter links.
        // It's still desirable to have their titles echoed however, when a link
        // was allowed. So pass allowed links as bus messages to it.

        void passToWebtitles(string[] urls)
        {
            import kameloso.plugins.common : EventURLs;
            import kameloso.thread : ThreadMessage, busMessage;
            import std.concurrency : send;

            auto eventAndURLs = EventURLs(event, urls);

            plugin.state.mainThread.send(ThreadMessage.BusMessage(),
                "webtitles", busMessage(eventAndURLs));
        }
    }
    else
    {
        // No Webtitles so just abort if we're not filtering
        if (!plugin.twitchBotSettings.filterURLs) return;
    }

    string[] urls = findURLs(event.content);  // mutable so nom works
    if (!urls.length) return;

    version(WithWebtitlesPlugin)
    {
        if (!plugin.twitchBotSettings.filterURLs)
        {
            // Not filtering but Webtitles available; pass to it to emulate it
            // not being soft-disabled.
            return passToWebtitles(urls);
        }
    }

    bool allowed;

    with (IRCUser.Class)
    final switch (event.sender.class_)
    {
    case unset:
    case blacklist:
    case anyone:
        auto room = event.channel in plugin.rooms;
        assert(room, "Tried to parse a link in a nonexistent room");

        if (const permitTimestamp = event.sender.nickname in room.linkPermits)
        {
            allowed = (event.time - *permitTimestamp) <= 60;

            if (allowed && plugin.twitchBotSettings.permitOneLinkOnly)
            {
                // Reset permit since only one link was permitted
                room.linkPermits.remove(event.sender.nickname);
            }
        }
        break;

    case whitelist:
    case operator:
    case staff:
    case admin:
        allowed = true;
        break;
    }

    if (allowed)
    {
        version(WithWebtitlesPlugin)
        {
            // Pass to Webtitles if available
            passToWebtitles(urls);
        }

        return;
    }

    static immutable int[3] durations = [ 5, 60, 3600 ];
    static immutable int[3] gracePeriods = [ 300, 600, 7200 ];
    static immutable string[3] messages =
    [
        "Stop posting links.",
        "Really, no links!",
        "Go cool off.",
    ];

    auto room = event.channel in plugin.rooms;
    assert(room, "Tried to get bans of a nonexistent room");

    auto ban = event.sender.nickname in room.linkBans;

    immediate(plugin.state, "PRIVMSG %s :/delete %s".format(event.channel, event.id));

    if (ban)
    {
        immutable banEndTime = ban.timestamp + durations[ban.offense] + gracePeriods[ban.offense];

        if (banEndTime > event.time)
        {
            ban.timestamp = event.time;
            if (ban.offense < 2) ++ban.offense;
        }
        else
        {
            // Force a new ban
            ban = null;
        }
    }

    if (!ban)
    {
        TwitchBotPlugin.Room.Ban newBan;
        newBan.timestamp = event.time;
        room.linkBans[event.sender.nickname] = newBan;
        ban = event.sender.nickname in room.linkBans;
    }

    chan!(Yes.priority)(plugin.state, event.channel, "/timeout %s %ds %s"
        .format(event.sender.nickname, durations[ban.offense], messages[ban.offense]));
}


// onFollowAge
/++
    Implements "Follow Age", or the ability to query the server how long you
    (or a specified user) have been a follower of the current channel.

    Lookups are done asynchronously in subthreads.
 +/
version(TwitchAPIFeatures)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "followage")
@Description("Queries the server for how long you have been a follower of the " ~
    "current channel. Optionally takes a nickname parameter, to query for someone else.",
    "$command [optional nickname]")
void onFollowAge(TwitchBotPlugin plugin, const IRCEvent event)
{
    import lu.string : nom, stripped;
    import std.conv : to;
    import std.json : JSONValue;
    import core.thread : Fiber;

    if (!plugin.useAPIFeatures) return;

    void dg()
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
            immutable timeline = diff.timeSince!(No.abbreviate, 7, 3);
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

    Fiber fiber = new Fiber(&dg, 32_768);
    fiber.call();
}


// onRoomState
/++
    Records the room ID of a home channel, and queries the Twitch servers for
    the display name of its broadcaster.
 +/
version(TwitchAPIFeatures)
@(IRCEvent.Type.ROOMSTATE)
@(ChannelPolicy.home)
void onRoomState(TwitchBotPlugin plugin, const IRCEvent event)
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

    Fiber getDisplayNameFiber = new Fiber(&getDisplayNameDg, 32_768);
    getDisplayNameFiber.call();

    // Always cache as soon as possible, before we get any !followage requests
    void cacheFollowsDg()
    {
        room.follows = getFollows(plugin, room.id);
    }

    Fiber cacheFollowsFiber = new Fiber(&cacheFollowsDg, 32_768);
    cacheFollowsFiber.call();
}


// onCommandShoutout
/++
    Emits a shoutout to another streamer.

    Merely gives a link to their channel and echoes what game they last streamed.
 +/
version(TwitchAPIFeatures)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "shoutout")
@BotCommand(PrefixPolicy.prefixed, "so", Yes.hidden)
@Description("Emits a shoutout to another streamer.", "$command [name of streamer]")
void onCommandShoutout(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : idOf;
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

    Fiber shoutoutFiber = new Fiber(&shoutoutQueryDg, 32_768);
    shoutoutFiber.call();
}


// onAnyMessage
/++
    Performs various actions on incoming messages.

    * Bells on any message, if the `TwitchBotSettings.bellOnMessage` setting is set.
    * Detects and deals with banned phrases.
    * Bumps the message counter for the channel, used by timers.

    Belling is useful with small audiences, so you don't miss messages.

    Note: This is annotated `kameloso.plugins.common.core.Terminating` and must be
    placed after all other handlers with these `dialect.defs.IRCEvent.Type` annotations.
    This lets us know the banned phrase wasn't part of a command (as it would
    otherwise not reach this point).
 +/
@Terminating
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.EMOTE)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onAnyMessage(TwitchBotPlugin plugin, const IRCEvent event)
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
    assert(room, "Tried to process `onAnyMessage` on a nonexistent room");

    ++room.messageCount;

    with (IRCUser.Class)
    final switch (event.sender.class_)
    {
    case unset:
    case blacklist:
    case anyone:
        // Drop down, continue to phrase bans
        break;

    case whitelist:
    case operator:
    case staff:
    case admin:
        // Nothing more to do
        return;
    }

    const bannedPhrases = event.channel in plugin.bannedPhrasesByChannel;
    if (!bannedPhrases) return;

    foreach (immutable phrase; *bannedPhrases)
    {
        import lu.string : contains;
        import std.algorithm.searching : canFind;
        import std.format : format;
        import std.uni : asLowerCase;

        // Try not to allocate two whole new strings
        immutable match = plugin.twitchBotSettings.phraseBansObeyCase ?
            event.content.contains(phrase) :
            event.content.asLowerCase.canFind(phrase.asLowerCase);

        if (!match) continue;

        static immutable int[3] durations = [ 5, 60, 3600 ];
        static immutable int[3] gracePeriods = [ 300, 600, 7200 ];

        auto ban = event.sender.nickname in room.phraseBans;

        immediate(plugin.state, "PRIVMSG %s :/delete %s".format(event.channel, event.id));

        if (ban)
        {
            immutable banEndTime = ban.timestamp + durations[ban.offense] + gracePeriods[ban.offense];

            if (banEndTime > event.time)
            {
                ban.timestamp = event.time;
                if (ban.offense < 2) ++ban.offense;
            }
            else
            {
                // Force a new ban
                ban = null;
            }
        }

        if (!ban)
        {
            TwitchBotPlugin.Room.Ban newBan;
            newBan.timestamp = event.time;
            room.phraseBans[event.sender.nickname] = newBan;
            ban = event.sender.nickname in room.phraseBans;
        }

        chan!(Yes.priority)(plugin.state, event.channel, "/timeout %s %ds"
            .format(event.sender.nickname, durations[ban.offense]));
        return;
    }
}


// onEndOfMOTD
/++
    Populate the banned phrases array after we have successfully
    logged onto the server.

    Has to be done at MOTD, as we only know whether we're on Twitch after
    RPL_MYINFO or so.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMOTD(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    JSONStorage channelBannedPhrasesJSON;
    channelBannedPhrasesJSON.load(plugin.bannedPhrasesFile);
    plugin.bannedPhrasesByChannel.populateFromJSON(channelBannedPhrasesJSON);
    plugin.bannedPhrasesByChannel.rehash();

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
                import lu.string : beginsWith;

                // Something is deeply wrong.
                logger.error("Failed to validate API keys: ", Tint.log, e.error);

                if (e.error.beginsWith("Peer certificate cannot be " ~
                    "authenticated with given CA certificates"))
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

        Fiber validationFiber = new Fiber(&validationDg, 32_768);
        validationFiber.call();
    }
}


// onCAP
/++
    Start the captive key generation routine at the earliest possible moment,
    which are the CAP events.

    We can't do it in `start` since the calls to save and exit would go unheard,
    as `start` happens before the main loop starts. It would then immediately
    fail to read if too much time has passed, and nothing would be saved.
 +/
version(TwitchAPIFeatures)
@(IRCEvent.Type.CAP)
void onCAP(TwitchBotPlugin plugin)
{
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

    JSONStorage channelBannedPhrasesJSON;
    channelBannedPhrasesJSON.load(plugin.bannedPhrasesFile);
    plugin.bannedPhrasesByChannel = typeof(plugin.bannedPhrasesByChannel).init;
    plugin.bannedPhrasesByChannel.populateFromJSON(channelBannedPhrasesJSON);
    plugin.bannedPhrasesByChannel.rehash();

    plugin.timerDefsByChannel = typeof(plugin.timerDefsByChannel).init;
    plugin.populateTimers(plugin.timersFile);
}


// saveResourceToDisk
/++
    Saves the passed resource to disk, but in JSON format.

    This is used with the associative arrays for banned phrases.

    Example:
    ---
    plugin.bannedPhrasesByChannel["#channel"] ~= "kameloso";
    plugin.bannedPhrasesByChannel["#channel"] ~= "hirrsteff";

    saveResource(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
    ---

    Params:
        resource = The JSON-convertible resource to save.
        filename = Filename of the file to write to.
 +/
void saveResourceToDisk(Resource)(const Resource resource, const string filename)
in (filename.length, "Tried to save resources to an empty filename")
{
    import lu.json : JSONStorage;
    import std.json : JSONValue;

    JSONStorage storage;

    storage = JSONValue(resource);
    storage.save!(JSONStorage.KeyOrderStrategy.adjusted)(filename);
}


// initResources
/++
    Reads and writes the file of banned phrases and timers to disk, ensuring
    that they're there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.file : exists;
    import std.json : JSONException;
    import std.path : baseName;
    import std.stdio : File;

    JSONStorage bannedPhrasesJSON;

    try
    {
        bannedPhrasesJSON.load(plugin.bannedPhrasesFile);
    }
    catch (JSONException e)
    {
        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(plugin.bannedPhrasesFile.baseName ~ " may be malformed.");
    }

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

    bannedPhrasesJSON.save(plugin.bannedPhrasesFile);
    timersJSON.save(plugin.timersFile);
}


// onMyInfo
/++
    Sets up a Fiber to periodically call timer `core.thread.fiber.Fiber`s with a
    periodicity of `TwitchBotPlugin.timerPeriodicity`.

    Cannot be done on `dialect.defs.IRCEvent.Type.RPL_WELCOME` as the server
    daemon isn't known by then.
 +/
@(IRCEvent.Type.RPL_MYINFO)
void onMyInfo(TwitchBotPlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import core.thread : Fiber;

    void periodicDg()
    {
        import kameloso.common : nextMidnight;
        import std.datetime.systime : Clock;

        // Schedule next prune to next midnight
        long nextPrune = Clock.currTime.nextMidnight.toUnixTime;

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

            immutable now = Clock.currTime;
            immutable nowInUnix = now.toUnixTime;

            // Early yield if we shouldn't clean up
            if (nowInUnix < nextPrune)
            {
                delay(plugin, plugin.timerPeriodicity, No.msecs, Yes.yield);
                continue top;
            }
            else
            {
                nextPrune = now.nextMidnight.toUnixTime;
            }

            // Walk through channels, prune stale bans and permits
            foreach (immutable channelName, room; plugin.rooms)
            {
                static void pruneByTimestamp(T)(ref T aa, const long now, const uint gracePeriod)
                {
                    string[] garbage;

                    foreach (immutable key, const entry; aa)
                    {
                        static if (is(typeof(entry) : long))
                        {
                            immutable maxEndTime = entry + gracePeriod;
                        }
                        else
                        {
                            immutable maxEndTime = entry.timestamp + gracePeriod;
                        }

                        if (now > maxEndTime)
                        {
                            garbage ~= key;
                        }
                    }

                    foreach (immutable key; garbage)
                    {
                        aa.remove(key);
                    }
                }

                pruneByTimestamp(room.linkBans, nowInUnix, 7200);
                pruneByTimestamp(room.linkPermits, nowInUnix, 60);
                pruneByTimestamp(room.phraseBans, nowInUnix, 7200);
            }

            version(TwitchAPIFeatures)
            {
                // Clear and re-cache follows once as often as we prune

                void cacheFollowsAnewDg()
                {
                    foreach (immutable channelName, room; plugin.rooms)
                    {
                        if (!room.enabled) continue;
                        room.follows = getFollows(plugin, room.id);
                    }
                }

                Fiber cacheFollowsAnewFiber = new Fiber(&cacheFollowsAnewDg, 32_768);
                cacheFollowsAnewFiber.call();
            }
        }
    }

    Fiber periodicFiber = new Fiber(&periodicDg, 32_768);
    delay(plugin, periodicFiber, plugin.timerPeriodicity);
}


// start
/++
    Disables the bell if we're not running inside a terminal. Snapshots
    `TwitchBotSettings.enableAPIFeatures` into `TwitchBotPlugin` so it can be
    disabled without modifying settings.
 +/
void start(TwitchBotPlugin plugin)
{
    import kameloso.terminal : isTTY;

    if (!isTTY)
    {
        // Not a TTY so replace our bell string with an empty one
        plugin.bell = string.init;
    }

    version(TwitchAPIFeatures)
    {
        plugin.useAPIFeatures = plugin.twitchBotSettings.enableAPIFeatures;
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
            long start;

            /// UNIX timestamp of when broadcasting ended.
            long stop;

            version(TwitchAPIFeatures)
            {
                /// Users seen in the channel.
                bool[string] chattersSeen;

                /// How many users were max seen as in the channel at the same time.
                int maxConcurrentChatters;
            }
        }

        /// Aggregate of a ban action.
        static struct Ban
        {
            long timestamp;  /// When this ban was triggered.
            uint offense;  /// How many consecutive bans have been fired.
        }

        /// Toggle of whether or not the bot should operate in this channel.
        bool enabled = true;

        /// Struct instance representing the current broadcast.
        Broadcast broadcast;

        /// ID of the currently ongoing vote, if any (otherwise 0).
        int voteInstance;

        /// Phrase ban actions keyed by offending nickname.
        Ban[string] phraseBans;

        /// Link ban actions keyed by offending nickname.
        Ban[string] linkBans;

        /// Users permitted to post links (for a brief time).
        long[string] linkPermits;

        /++
            A counter of how many messages we have seen in the channel.

            Used by timers to know when enough activity has passed to warrant
            re-announcing timers.
         +/
        ulong messageCount;

        /// Timer `core.thread.fiber.Fiber`s.
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

    /// Associative array of banned phrases; phrases array keyed by channel.
    string[][string] bannedPhrasesByChannel;

    /// Filename of file with banned phrases.
    @Resource string bannedPhrasesFile = "twitchphrases.json";

    /// Timer definition arrays, keyed by channel string.
    TimerDefinition[][string] timerDefsByChannel;

    /// Filename of file with timer definitions.
    @Resource string timersFile = "twitchtimers.json";

    /++
        How often to check whether timers should fire, in seconds. A smaller
        number means better precision.
     +/
    enum timerPeriodicity = 10;

    /// `kameloso.terminal.TerminalToken.bell` as string, for use as bell.
    private enum bellString = ("" ~ cast(char)(TerminalToken.bell));

    /// Effective bell after `kameloso.terminal.isTTY` checks.
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
        enum chattersCheckPeriodicity = 180;

        /// The thread ID of the persistent worker thread.
        Tid persistentWorkerTid;

        /// Associative array of responses from async HTTP queries.
        shared QueryResponse[string] bucket;
    }


    // isEnabled
    /++
        Override `kameloso.plugins.common.core.IRCPluginImpl.isEnabled` and inject
        a server check, so this plugin only works on Twitch, in addition
        to doing nothing when `twitchbotSettings.enabled` is false.

        Returns:
            `true` if this plugin should react to events; `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return ((state.server.daemon == IRCServer.Daemon.twitch) ||
            (state.server.daemon == IRCServer.Daemon.unset)) &&
            (twitchBotSettings.enabled || twitchBotSettings.keygen);
    }


    // onEvent
    /++
        Override `kameloso.plugins.common.core.IRCPluginImpl.onEvent` and inject a server check, so this
        plugin does nothing on non-Twitch servers. Also filters `dialect.defs.IRCEvent.Type.CHAN`
        events to only trigger on active channels (that have its `Channel.enabled`
        set to true).

        The function to call is `kameloso.plugins.common.core.IRCPluginImpl.onEventImpl`.

        Params:
            event = Parsed `dialect.defs.IRCEvent` to pass onto
                `kameloso.plugins.common.core.IRCPluginImpl.onEventImpl`
                after verifying we should process the event.
     +/
    override public void onEvent(IRCEvent event)
    {
        if (this.twitchBotSettings.promoteBroadcasters)
        {
            if (event.sender.nickname.length && event.channel.length &&
                (event.sender.nickname == event.channel[1..$]) &&
                (event.sender.class_ < IRCUser.Class.staff))
            {
                // Sender is broadcaster but is not registered as staff
                event.sender.class_ = IRCUser.Class.staff;
            }
        }

        if ((event.type == IRCEvent.Type.CHAN) || (event.type == IRCEvent.Type.SELFCHAN))
        {
            import lu.string : beginsWith;

            immutable prefix = this.state.settings.prefix;

            if (event.content.beginsWith(prefix) &&
                (event.content.length > prefix.length))
            {
                // Specialcase prefixed "enable"
                if (event.content[prefix.length..$] == "enable")
                {
                    // Always pass through
                    return onEventImpl(event);
                }
                else
                {
                    // Only pass through if the channel is enabled
                    if (const room = event.channel in rooms)
                    {
                        if (room.enabled) return onEventImpl(event);
                    }
                    return;
                }
            }
            /*else if (event.content.beginsWith(this.state.client.nickname))
            {
                import kameloso.common : stripSeparatedPrefix;

                immutable tail = event.content
                    .stripSeparatedPrefix(this.state.client.nickname);

                // Specialcase "nickname: enable"
                if (tail == "enable")
                {
                    // Always pass through
                    return onEventImpl(event);
                }
                else
                {
                    // Only pass through if the channel is enabled
                    if (const room = event.channel in rooms)
                    {
                        if (room.enabled) return onEventImpl(event);
                    }
                }
            }*/
            else
            {
                // Normal non-command channel message
                return onEventImpl(event);
            }
        }
        else
        {
            // Other event
            return onEventImpl(event);
        }
    }

    mixin IRCPluginImpl;
}

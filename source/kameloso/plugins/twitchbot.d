/++
 +  This is an example Twitch streamer bot. It supports querying uptime or how
 +  long a streamer has been live, banned phrases, timered announcements and
 +  voting.
 +
 +  It can also emit some terminal bells on certain events, to draw attention.
 +
 +  One immediately obvious venue of expansion is expression bans, such as if a
 +  message has too many capital letters, etc. There is no protection from spam yet.
 +
 +  See the GitHub wiki for more information about available commands:<br>
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#twitchbot
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import core.thread : Fiber;
import std.typecons : Flag, No, Yes;


/// All Twitch bot plugin runtime settings.
@Settings struct TwitchBotSettings
{
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
}


// onCommandPermit
/++
 +  Permits a user to post links for a hardcoded 60 seconds.
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
    import lu.string : stripped;
    import std.format : format;
    import std.uni : toLower;

    if (!plugin.twitchBotSettings.filterURLs)
    {
        chan(plugin.state, event.channel, "Links are not being filtered.");
        return;
    }

    string nickname = event.content.stripped.toLower;

    if (!nickname.length)
    {
        chan(plugin.state, event.channel, "Usage: %s%s [nickname]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    if (nickname[0] == '@') nickname = nickname[1..$];

    auto channel = event.channel in plugin.activeChannels;

    channel.linkPermits[nickname] = event.time;

    if (nickname in channel.linkBans)
    {
        // Was or is timed out, remove it just in case
        channel.linkBans.remove(nickname);
        chan(plugin.state, event.channel, "/timeout " ~ nickname ~ " 0");
    }

    string target = nickname;

    if (auto user = nickname in plugin.state.users)
    {
        target = user.displayName;
    }

    immutable pattern = plugin.twitchBotSettings.permitOneLinkOnly ?
        "@%s, you are now allowed to post a link for 60 seconds." :
        "@%s, you are now allowed to post links for 60 seconds.";

    chan(plugin.state, event.channel, pattern.format(target));
}


// onImportant
/++
 +  Bells on any important event, like subscriptions, cheers and raids, if the
 +  `TwitchBotSettings.bellOnImportant` setting is set.
 +/
@(Chainable)
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

    write(cast(char)TerminalToken.bell);
    stdout.flush();
}


// onSelfjoin
/++
 +  Registers a new `TwitchBotPlugin.Channel` as we join a channel, so there's
 +  always a state struct available.
 +
 +  Simply passes on execution to `handleSelfjoin`.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.home)
void onSelfjoin(TwitchBotPlugin plugin, const IRCEvent event)
{
    return plugin.handleSelfjoin(event.channel);
}


// handleSelfjoin
/++
 +  Registers a new `TwitchBotPlugin.Channel` as we join a channel, so there's
 +  always a state struct available.
 +
 +  Creates the timer `core.thread.Fiber`s that there are definitions for in
 +  `TwitchBotPlugin.timerDefsByChannel`.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      channelName = The name of the channel we're supposedly joining.
 +/
void handleSelfjoin(TwitchBotPlugin plugin, const string channelName)
in (channelName.length, "Tried to handle SELFJOIN with an empty channel string")
{
    if (channelName in plugin.activeChannels) return;

    plugin.activeChannels[channelName] = TwitchBotPlugin.Channel.init;

    // Apply the timer definitions we have stored
    const timerDefs = channelName in plugin.timerDefsByChannel;
    if (!timerDefs || !timerDefs.length) return;

    auto channel = channelName in plugin.activeChannels;

    foreach (const timerDef; *timerDefs)
    {
        channel.timers ~= plugin.createTimerFiber(timerDef, channelName);
    }
}


// createTimerFiber
/++
 +  Given a `TimerDefinition` and a string channel name, creates a
 +  `core.thread.Fiber` that implements the timer.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      timerDef = Definition of the timer to apply.
 +      channelName = String channel to which the timer belongs.
 +/
Fiber createTimerFiber(TwitchBotPlugin plugin, const TimerDefinition timerDef,
    const string channelName)
{
    void dg()
    {
        import kameloso.plugins.common : nameOf;
        import std.datetime.systime : Clock;

        const channel = channelName in plugin.activeChannels;

        /// When this timer Fiber was created.
        immutable creation = Clock.currTime.toUnixTime;

        /// The channel message count at last successful trigger.
        ulong lastMessageCount = channel.messageCount;

        /// The timestamp at the last successful trigger.
        long lastTimestamp = creation;

        /// Whether or not stagger has passed, so we don't evaluate it every single time.
        bool staggerDone;

        immutable streamer = plugin.nameOf(channelName[1..$]);

        while (true)
        {
            if (!staggerDone)
            {
                immutable now = Clock.currTime.toUnixTime;

                if ((now - creation) < timerDef.stagger)
                {
                    // Reset counters so it starts fresh after stagger
                    lastMessageCount = channel.messageCount;
                    lastTimestamp = now;
                    Fiber.yield();
                    continue;
                }
            }

            // Avoid evaluating current unix time after stagger is done
            staggerDone = true;

            if (channel.messageCount < (lastMessageCount + timerDef.messageCountThreshold))
            {
                Fiber.yield();
                continue;
            }

            immutable now = Clock.currTime.toUnixTime;

            if ((now - lastTimestamp) < timerDef.timeThreshold)
            {
                Fiber.yield();
                continue;
            }

            if (channel.enabled)
            {
                import std.array : replace;
                import std.conv : text;
                import std.random : uniform;

                immutable line = timerDef.line
                    .replace("$streamer", streamer)
                    .replace("$channel", channelName[1..$])
                    .replace("$bot", plugin.state.client.nickname)
                    .replace("$random", uniform!"[]"(0, 100).text);

                chan(plugin.state, channelName, line);
            }

            // If channel is disabled, silently fizzle but keep updating counts

            lastMessageCount = channel.messageCount;
            lastTimestamp = now;

            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&dg, 32_768);
}


// onSelfpart
/++
 +  Removes a channel's corresponding `TwitchBotPlugin.Channel` when we leave it.
 +
 +  This resets all that channel's transient state.
 +/
@(IRCEvent.Type.SELFPART)
@(ChannelPolicy.home)
void onSelfpart(TwitchBotPlugin plugin, const IRCEvent event)
{
    plugin.activeChannels.remove(event.channel);
}


// onCommandPhrase
/++
 +  Bans, unbans, lists or clears banned phrases for the current channel.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.bannedPhrasesFile` file.
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
 +  Bans, unbans, lists or clears banned phrases for the specified target channel.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      targetChannel = The channel we're handling phrase bans for.
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
                //version(PrintStacktraces) logger.trace(e.toString);
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
 +  Adds, deletes, lists or clears timers for the specified target channel.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.timersFile` file.
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


// handleTimerCommand
/++
 +  Adds, deletes, lists or clears timers for the specified target channel.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      targetChannels = The channel we're handling timers for.
 +/
void handleTimerCommand(TwitchBotPlugin plugin, const IRCEvent event, const string targetChannel)
in (targetChannel.length, "Tried to handle timers with an empty target channel string")
{
    import lu.string : SplitResults, contains, nom, splitInto;
    import std.format : format;

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    void sendUsage(const string verb = "[add|del|list|clear]")
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s %s [message threshold] [time threshold] [stagger seconds] [text]"
            .format(plugin.state.settings.prefix, event.aux, verb));
    }

    switch (verb)
    {
    case "add":
        import std.algorithm.searching : count;
        import std.conv : ConvException, to;

        if (slice.count(' ') < 3)
        {
            /*privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: add [message threshold] [time threshold] [stagger seconds] [text]");*/
            //                                 1                2                 3
            return sendUsage(verb);
        }

        TimerDefinition timerDef;

        string rawMessageCountThreshold;
        string rawTimeThreshold;
        string rawStagger;

        immutable results = slice.splitInto(rawMessageCountThreshold, rawTimeThreshold, rawStagger);
        if (results != SplitResults.overrun) return sendUsage(verb);

        try
        {
            timerDef.messageCountThreshold = rawMessageCountThreshold.to!int;
            timerDef.timeThreshold = rawTimeThreshold.to!int;
            timerDef.stagger = rawStagger.to!int;
            timerDef.line = slice;
        }
        catch (ConvException e)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid parameters.");
            return sendUsage(verb);
        }

        if ((timerDef.messageCountThreshold < 0) ||
            (timerDef.timeThreshold < 0) || (timerDef.stagger < 0))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Arguments for message count threshold, timer threshold and stagger " ~
                "must all be positive numbers.");
            return;
        }
        else if ((timerDef.messageCountThreshold == 0) && (timerDef.timeThreshold == 0))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "A timer cannot have a message threshold *and* a time threshold of zero.");
            return;
        }

        plugin.timerDefsByChannel[targetChannel] ~= timerDef;
        plugin.timerDefsToJSON.save(plugin.timersFile);
        plugin.activeChannels[targetChannel].timers ~=
            plugin.createTimerFiber(timerDef, targetChannel);
        privmsg(plugin.state, event.channel, event.sender.nickname, "New timer added.");
        break;

    case "del":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s del [timer index]".format(plugin.state.settings.prefix, event.aux));
            return;
        }

        if (auto timerDefs = targetChannel in plugin.timerDefsByChannel)
        {
            import lu.string : stripped;
            import std.algorithm.iteration : splitter;
            import std.conv : ConvException, to;

            auto channel = targetChannel in plugin.activeChannels;

            if (slice == "*") goto case "clear";

            try
            {
                ptrdiff_t i = slice.stripped.to!ptrdiff_t - 1;

                if ((i >= 0) && (i < channel.timers.length))
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    *timerDefs = (*timerDefs).remove!(SwapStrategy.unstable)(i);
                    channel.timers = channel.timers.remove!(SwapStrategy.unstable)(i);
                }
                else
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Timer index %s out of range. (max %d)"
                        .format(slice, channel.timers.length));
                    return;
                }
            }
            catch (ConvException e)
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "Invalid timer index: " ~ slice);
                //version(PrintStacktraces) logger.trace(e.info);
                return;
            }

            if (!channel.timers.length) plugin.timerDefsByChannel.remove(targetChannel);
            plugin.timerDefsToJSON.save(plugin.timersFile);
            privmsg(plugin.state, event.channel, event.sender.nickname, "Timer removed.");
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No timers registered for this channel.");
        }
        break;

    case "list":
        if (const timers = targetChannel in plugin.timerDefsByChannel)
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

                    if ((start < 0) || (start >= timers.length))
                    {
                        privmsg(plugin.state, event.channel, event.sender.nickname,
                            "Invalid timer index or out of bounds.");
                        return;
                    }
                }
                catch (ConvException e)
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Usage: %s%s list [optional starting position number]"
                        .format(plugin.state.settings.prefix, event.aux));
                    return;
                }
            }

            immutable end = min(start+toDisplay, timers.length);

            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Current timers (%d-%d of %d)"
                .format(start+1, end, timers.length));

            foreach (immutable i, const timer; (*timers)[start..end])
            {
                immutable maxLen = min(timer.line.length, maxLineLength);
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "%d: %s%s (%d:%d:%d)".format(start+i+1, timer.line[0..maxLen],
                    (timer.line.length > maxLen) ? " ...  [truncated]" : string.init,
                    timer.messageCountThreshold, timer.timeThreshold, timer.stagger));
            }
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No timers registered for this channel.");
        }
        break;

    case "clear":
        plugin.activeChannels[targetChannel].timers.length = 0;
        plugin.timerDefsByChannel.remove(targetChannel);
        plugin.timerDefsToJSON.save(plugin.timersFile);
        privmsg(plugin.state, event.channel, event.sender.nickname, "All timers cleared.");
        break;

    default:
        return sendUsage();
    }
}


// onCommandEnableDisable
/++
 +  Toggles whether or not the bot should operate in this channel.
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
        plugin.activeChannels[event.channel].enabled = true;
        chan(plugin.state, event.channel, "Streamer bot enabled!");
    }
    else /*if (event.aux == "disable")*/
    {
        plugin.activeChannels[event.channel].enabled = false;
        chan(plugin.state, event.channel, "Streamer bot disabled.");
    }
}


// onCommandUptime
/++
 +  Reports how long the streamer has been streaming.
 +
 +  Technically, how much time has passed since `!start` was issued.
 +
 +  The streamer's name is divined from the `plugin.state.users` associative
 +  array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "uptime")
@Description("Reports how long the streamer has been streaming.")
void onCommandUptime(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.plugins.common : nameOf;

    immutable broadcastStart = plugin.activeChannels[event.channel].broadcastStart;
    immutable streamer = plugin.nameOf(event.channel[1..$]);

    if (broadcastStart > 0L)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock, SysTime;
        import std.format : format;

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;

        immutable delta = now - SysTime.fromUnixTime(broadcastStart);

        chan(plugin.state, event.channel, "%s has been live for %s."
            .format(streamer, delta));
    }
    else
    {
        chan(plugin.state, event.channel, streamer ~ " is currently not streaming.");
    }
}


// onCommandStart
/++
 +  Marks the start of a broadcast, for later uptime queries.
 +
 +  Consecutive calls to `!start` are ignored.
 +
 +  The streamer's name is divined from the `plugin.state.users` associative
 +  array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "start")
@Description("Marks the start of a broadcast.")
void onCommandStart(TwitchBotPlugin plugin, const IRCEvent event)
{
    auto channel = event.channel in plugin.activeChannels;

    if (channel.broadcastStart != 0L)
    {
        import kameloso.plugins.common : nameOf;

        immutable streamer = plugin.nameOf(event.channel[1..$]);
        chan(plugin.state, event.channel, streamer ~ " is already live.");
        return;
    }

    channel.broadcastStart = event.time;
    chan(plugin.state, event.channel, "Broadcast start registered!");
}


// onCommandStop
/++
 +  Marks the stop of a broadcast.
 +
 +  The streamer's name is divined from the `plugin.state.users` associative
 +  array by looking at the entry for the nickname this channel corresponds to.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "stop")
@Description("Marks the stop of a broadcast.")
void onCommandStop(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (plugin.activeChannels[event.channel].broadcastStart == 0L)
    {
        chan(plugin.state, event.channel, "Broadcast was never registered as started...");
        return;
    }

    plugin.reportStopTime(event);
}


// onAutomaticStop
/++
 +  Automatically signals a stream stop when a host starts.
 +
 +  This is generally done as the last thing after a stream session, so it makes
 +  sense to automate `onCommandStop`.
 +/
@(ChannelPolicy.home)
@(IRCEvent.Type.TWITCH_HOSTSTART)
void onAutomaticStop(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (plugin.activeChannels[event.channel].broadcastStart == 0L) return;
    plugin.reportStopTime(event);
}


// reportStopTime
/++
 +  Reports how long the recently ongoing, now ended broadcast lasted.
 +/
void reportStopTime(TwitchBotPlugin plugin, const IRCEvent event)
in ((event != IRCEvent.init), "Tried to report stop time to an empty IRCEvent")
{
    import kameloso.plugins.common : nameOf;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import core.time : msecs;

    auto channel = event.channel in plugin.activeChannels;

    auto now = Clock.currTime;
    now.fracSecs = 0.msecs;
    const delta = now - SysTime.fromUnixTime(channel.broadcastStart);
    channel.broadcastStart = 0L;

    immutable streamer = plugin.nameOf(event.channel[1..$]);

    chan(plugin.state, event.channel, "Broadcast ended. %s streamed for %s."
        .format(streamer, delta));
}


// onLink
/++
 +  Parses a message to see if the message contains one or more URLs.
 +
 +  It uses a simple state machine in `kameloso.common.findURLs`. If the Webtitles
 +  plugin has been compiled in, (version `WithWebtitlesPlugin`) it will try to
 +  send them to it for lookups and reporting.
 +
 +  Operators, whitelisted and admin users are so far allowed to trigger this, as are
 +  any user who has been given a temporary permit via `onCommandPermit`.
 +  Those without permission will have the message deleted and be served a timeout.
 +/
@(Chainable)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onLink(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.common : findURLs;
    import lu.string : beginsWith;
    import std.algorithm.searching : canFind;

    if (!plugin.twitchBotSettings.filterURLs) return;

    string[] urls = findURLs(event.content);  // mutable so nom works
    if (!urls.length) return;

    bool allowed;

    with (IRCUser.Class)
    final switch (event.sender.class_)
    {
    case unset:
    case blacklist:
    case anyone:
        if (const permitTimestamp = event.sender.nickname in
            plugin.activeChannels[event.channel].linkPermits)
        {
            allowed = (event.time - *permitTimestamp) <= 60;

            if (allowed && plugin.twitchBotSettings.permitOneLinkOnly)
            {
                // Reset permit since only one link was permitted
                plugin.activeChannels[event.channel].linkPermits.remove(event.sender.nickname);
            }
        }
        break;

    case whitelist:
    case operator:
    case admin:
        allowed = true;
        break;
    }

    if (!allowed)
    {
        import std.format : format;

        static immutable int[3] durations = [ 5, 60, 3600 ];
        static immutable int[3] gracePeriods = [ 300, 600, 7200 ];
        static immutable string[3] messages =
        [
            "Stop posting links.",
            "Really, no links!",
            "Go cool off.",
        ];

        auto channel = event.channel in plugin.activeChannels;
        auto ban = event.sender.nickname in channel.linkBans;

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
            TwitchBotPlugin.Channel.Ban newBan;
            newBan.timestamp = event.time;
            channel.linkBans[event.sender.nickname] = newBan;
            ban = event.sender.nickname in channel.linkBans;
        }

        chan!(Yes.priority)(plugin.state, event.channel, "/timeout %s %d"
            .format(event.sender.nickname, durations[ban.offense]));
        chan!(Yes.priority)(plugin.state, event.channel, "@%s, %s"
            .format(event.sender.nickname, messages[ban.offense]));
        return;
    }

    version(WithWebtitlesPlugin)
    {
        import kameloso.thread : ThreadMessage, busMessage;
        import std.concurrency : send;
        import std.typecons : Tuple;

        alias EventAndURLs = Tuple!(IRCEvent, string[]);
        auto eventAndURLs = EventAndURLs(event, urls);

        plugin.state.mainThread.send(ThreadMessage.BusMessage(),
            "webtitles", busMessage(eventAndURLs));
    }
}


// onAnyMessage
/++
 +  Performs various actions on incoming messages.
 +
 +  * Bells on any message, if the `TwitchBotSettings.bellOnMessage` setting is set.
 +  * Detects and deals with banned phrases.
 +  * Bumps the message counter for the channel, used by timers.
 +
 +  Belling is useful with small audiences, so you don't miss messages.
 +
 +  Note: This is annotated `kameloso.plugins.core.Terminating` and must be
 +  placed after all other handlers with these `dialect.defs.IRCEvent.Type` annotations.
 +  This lets us know the banned phrase wasn't part of a command (as it would
 +  otherwise not reach this point).
 +/
@(Terminating)
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

        write(cast(char)TerminalToken.bell);
        stdout.flush();
    }

    // Don't do any more than bell on whispers
    if (event.type == IRCEvent.Type.QUERY) return;

    auto channel = event.channel in plugin.activeChannels;
    ++channel.messageCount;

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
    case admin:
        // Nothing more to do
        return;
    }

    if (const bannedPhrases = event.channel in plugin.bannedPhrasesByChannel)
    {
        foreach (immutable phrase; *bannedPhrases)
        {
            import lu.string : contains;
            import std.algorithm.searching : canFind;
            import std.uni : asLowerCase;

            // Try not to allocate two whole new strings
            immutable match = plugin.twitchBotSettings.phraseBansObeyCase ?
                event.content.contains(phrase) :
                event.content.asLowerCase.canFind(phrase.asLowerCase);

            if (match)
            {
                import std.format : format;

                static immutable int[3] durations = [ 5, 60, 3600 ];
                static immutable int[3] gracePeriods = [ 300, 600, 7200 ];

                auto ban = event.sender.nickname in channel.phraseBans;

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
                    TwitchBotPlugin.Channel.Ban newBan;
                    newBan.timestamp = event.time;
                    channel.phraseBans[event.sender.nickname] = newBan;
                    ban = event.sender.nickname in channel.phraseBans;
                }

                chan!(Yes.priority)(plugin.state, event.channel, "/timeout %s %d"
                    .format(event.sender.nickname, durations[ban.offense]));
                return;
            }
        }
    }
}


// onEndOfMotd
/++
 +  Populate the banned phrases array after we have successfully
 +  logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    with (plugin)
    {
        JSONStorage channelBannedPhrasesJSON;
        channelBannedPhrasesJSON.load(bannedPhrasesFile);
        bannedPhrasesByChannel.populateFromJSON(channelBannedPhrasesJSON);
        bannedPhrasesByChannel.rehash();

        // Timers use a specialised function
        plugin.populateTimers(plugin.timersFile);
    }
}


// reload
/++
 +  Reloads resources from disk.
 +/
void reload(TwitchBotPlugin plugin)
{
    if (plugin.state.server.daemon != IRCServer.Daemon.twitch) return;

    logger.info("Reloading Twitch bot resources from disk.");

    plugin.bannedPhrasesByChannel = typeof(plugin.bannedPhrasesByChannel).init;
    plugin.onEndOfMotd();
}


// saveResourceToDisk
/++
 +  Saves the passed resource to disk, but in JSON format.
 +
 +  This is used with the associative arrays for banned phrases.
 +
 +  Example:
 +  ---
 +  plugin.bannedPhrasesByChannel["#channel"] ~= "kameloso";
 +  plugin.bannedPhrasesByChannel["#channel"] ~= "hirrsteff";
 +
 +  saveResource(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
 +  ---
 +
 +  Params:
 +      resource = The JSON-convertible resource to save.
 +      filename = Filename of the file to write to.
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
 +  Reads and writes the file of banned phrases and timers to disk, ensuring
 +  that they're there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage bannedPhrasesJSON;

    try
    {
        bannedPhrasesJSON.load(plugin.bannedPhrasesFile);
    }
    catch (JSONException e)
    {
        version(PrintStacktraces) logger.trace(e.toString);
        throw new IRCPluginInitialisationException(plugin.bannedPhrasesFile.baseName ~ " may be malformed.");
    }

    JSONStorage timersJSON;

    try
    {
        timersJSON.load(plugin.timersFile);
    }
    catch (JSONException e)
    {
        version(PrintStacktraces) logger.trace(e.toString);
        throw new IRCPluginInitialisationException(plugin.timersFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    bannedPhrasesJSON.save(plugin.bannedPhrasesFile);
    timersJSON.save(plugin.timersFile);
}


// periodically
/++
 +  Periodically calls timer `core.thread.Fiber`s with a periodicity of
 +  `TwitchBotPlugin.timerPeriodicity`.
 +/
void periodically(TwitchBotPlugin plugin, const long now)
{
    if ((plugin.state.server.daemon != IRCServer.Daemon.unset) &&
        (plugin.state.server.daemon != IRCServer.Daemon.twitch))
    {
        // Known to not be a Twitch server
        plugin.state.nextPeriodical = now + 315_569_260L;
        return;
    }

    // Walk through channels, trigger fibers
    foreach (immutable channelName, channel; plugin.activeChannels)
    {
        foreach (timer; channel.timers)
        {
            if (!timer || (timer.state != Fiber.State.HOLD))
            {
                logger.error("Dead or busy timer Fiber in channel ", channelName);
                continue;
            }

            timer.call();
        }
    }

    // Schedule next
    plugin.state.nextPeriodical = now + plugin.timerPeriodicity;

    // Early abort if we shouldn't clean up
    if (now < plugin.nextPrune) return;

    // Walk through channels, prune stale bans and permits
    foreach (immutable channelName, channel; plugin.activeChannels)
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

        pruneByTimestamp(channel.linkBans, now, 7200);
        pruneByTimestamp(channel.linkPermits, now, 60);
        pruneByTimestamp(channel.phraseBans, now, 7200);
    }

    import std.datetime : DateTime;
    import std.datetime.systime : Clock, SysTime;

    immutable currTime = Clock.currTime;

    // Schedule next prune to next midnight
    plugin.nextPrune = SysTime(DateTime(currTime.year, currTime.month,
        currTime.day, 0, 0, 0), currTime.timezone)
        .roll!"days"(1)
        .toUnixTime;
}


// start
/++
 +  Starts the plugin after successful connect, rescheduling the next
 +  `.periodical` to trigger after hardcoded 60 seconds.
 +/
void start(TwitchBotPlugin plugin)
{
    import std.datetime.systime : Clock;
    plugin.state.nextPeriodical = Clock.currTime.toUnixTime + 60;
}


// TimerDefinition
/++
 +  Definitions of a Twitch timer.
 +/
struct TimerDefinition
{
    /// The timered line to send to the channel.
    string line;

    /++
     +  How many messages must have been sent since the last announce before we
     +  will allow another one.
     +/
    int messageCountThreshold;

    /++
     +  How many seconds must have passed since the last announce before we will
     +  allow another one.
     +/
    int timeThreshold;

    /// Delay in seconds before the timer comes into effect.
    int stagger;
}


// populateTimers
/++
 +  Populates the `TwitchBotPlugin.timerDefsByChannel` associative array with
 +  the timer definitions in the passed JSON file.
 +
 +  This reads the JSON values from disk and creates the `TimerDefinition`s
 +  appropriately.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      filename = Filename of the JSON file to read definitions from.
 +/
void populateTimers(TwitchBotPlugin plugin, const string filename)
in (filename.length, "Tried to populate timers from an empty filename")
{
    import std.conv : to;
    import std.format : format;
    import std.json : JSONType;

    JSONStorage timersJSON;
    timersJSON.load(filename);

    bool errored;

    foreach (immutable channel, const channelTimersJSON; timersJSON.object)
    {
        if (channelTimersJSON.type != JSONType.array)
        {
            logger.errorf("Twitch timer file malformed! Invalid channel timers " ~
                "list type for %s: `%s`", channel, channelTimersJSON.type);
            errored = true;
            continue;
        }

        plugin.timerDefsByChannel[channel] = typeof(plugin.timerDefsByChannel[channel]).init;

        foreach (timerArrayEntry; channelTimersJSON.array)
        {
            if (timerArrayEntry.type != JSONType.object)
            {
                logger.errorf("Twitch timer file malformed! Invalid timer type " ~
                    "for %s: `%s`", channel, timerArrayEntry.type);
                errored = true;
                continue;
            }

            TimerDefinition timer;

            timer.line = timerArrayEntry["line"].str;
            timer.messageCountThreshold = timerArrayEntry["messageCountThreshold"].integer.to!int;
            timer.timeThreshold = timerArrayEntry["timeThreshold"].integer.to!int;
            timer.stagger = timerArrayEntry["stagger"].integer.to!int;

            plugin.timerDefsByChannel[channel] ~= timer;
        }
    }

    if (errored)
    {
        logger.warning("Errors encountered; all timers were not read.");
    }
}


import lu.json : JSONStorage;

// timerDefsToJSON
/++
 +  Expresses the `FiberDefinition` associative array (`TwitchBotPlugin.fiberDefsByChannel`)
 +  in JSON form, for easier saving to and loading from disk.
 +
 +  Using `std.json.JSONValue` directly fails with an error.
 +/
JSONStorage timerDefsToJSON(TwitchBotPlugin plugin)
{
    import std.json : JSONType, JSONValue;

    JSONStorage json;
    json.reset();

    foreach (immutable channelName, channelTimers; plugin.timerDefsByChannel)
    {
        if (!channelTimers.length) continue;

        json[channelName] = null;  // quirk to initialise it as a JSONType.object

        foreach (const timer; channelTimers)
        {
            JSONValue value;
            value = null;  // as above

            if (json[channelName].type != JSONType.array)
            {
                json[channelName].array = null;
            }

            value["line"] = timer.line;
            value["messageCountThreshold"] = timer.messageCountThreshold;
            value["timeThreshold"] = timer.timeThreshold;
            value["stagger"] = timer.stagger;
            json[channelName].array ~= value;
        }
    }

    return json;
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Catches bus messages with a "`home (add|del)`" header requesting to add or
 +  remove home channels.
 +
 +  This is to allow for home channels to be added on the fly without leaving them first.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
void onBusMessage(TwitchBotPlugin plugin, const string header, shared Sendable content)
{
    import kameloso.thread : BusMessage;

    if ((header != "home add") || (header != "home del")) return;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    immutable channel = message.payload;

    switch (header)
    {
    case "home add":
        return plugin.handleSelfjoin(channel);

    case "home del":
        plugin.activeChannels.remove(channel);
        break;

    default:
        assert(0, "Unexpected Twitch bot bus message header: " ~ header);
    }
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;


public:


// TwitchBotPlugin
/++
 +  The Twitch Bot plugin is an example Twitch streamer bot. It contains some
 +  basic tools for streamers, and the audience thereof.
 +/
final class TwitchBotPlugin : IRCPlugin
{
private:
    /// Contained state of a channel, so that there can be several alongside each other.
    struct Channel
    {
        /// Aggregate of a ban action.
        struct Ban
        {
            long timestamp;  /// When this ban was triggered.
            uint offense;  /// How many consecutive bans have been fired.
        }

        /// Toggle of whether or not the bot should operate in this channel.
        bool enabled = true;

        /// ID of the currently ongoing vote, if any (otherwise 0).
        int voteInstance;

        /// UNIX timestamp of when broadcasting started.
        long broadcastStart;

        /// Phrase ban actions keyed by offending nickname.
        Ban[string] phraseBans;

        /// Link ban actions keyed by offending nickname.
        Ban[string] linkBans;

        /// Users permitted to post links (for a brief time).
        long[string] linkPermits;

        /++
         +  A counter of how many messages we have seen in the channel.
         +
         +  Used by timers to know when enough activity has passed to warrant
         +  re-announcing timers.
         +/
        ulong messageCount;

        /// Timer `core.thread.Fiber`s.
        Fiber[] timers;
    }

    /// All Twitch Bot plugin settings.
    TwitchBotSettings twitchBotSettings;

    /// Array of active bot channels' state.
    Channel[string] activeChannels;

    /// Associative array of banned phrases; phrases array keyed by channel.
    string[][string] bannedPhrasesByChannel;

    /// Filename of file with banned phrases.
    @Resource string bannedPhrasesFile = "twitchphrases.json";

    /// Timer definition arrays, keyed by channel string.
    TimerDefinition[][string] timerDefsByChannel;

    /// Filename of file with timer definitions.
    @Resource string timersFile = "twitchtimers.json";

    /// When to next clear expired permits and bans.
    long nextPrune;

    /++
     +  How often to check whether timers should fire, in seconds. A smaller
     +  number means better precision.
     +/
    enum timerPeriodicity = 10;

    mixin IRCPluginImpl;


    /++
     +  Override `kameloso.plugins.core.IRCPluginImpl.onEvent` and inject a server check, so this
     +  plugin does nothing on non-Twitch servers. Also filters `dialect.defs.IRCEvent.Type.CHAN`
     +  events to only trigger on active channels (that have its `Channel.enabled`
     +  set to true).
     +
     +  The function to call is `kameloso.plugins.core.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.core.IRCPluginImpl.onEventImpl`
     +          after verifying we should process the event.
     +/
    public void onEvent(const IRCEvent event)
    {
        if (state.server.daemon != IRCServer.Daemon.twitch)
        {
            // Daemon known and not Twitch
            return;
        }

        if (event.type == IRCEvent.Type.CHAN)
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
                    if (const channel = event.channel in activeChannels)
                    {
                        if (channel.enabled) return onEventImpl(event);
                    }
                    return;
                }
            }
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
}

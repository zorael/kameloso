/++
 +  This is an example Twitch streamer bot. It supports basic authentication,
 +  allowing for channel-specific regulars that are not necessarily in the
 +  whitelist nor are Twitch moderators, querying uptime or how long a streamer
 +  has been live, banned phrases and timered announcements. If run in a
 +  local terminal it can also emit some terminal bells on certain events, to
 +  draw attention.
 +
 +  One immediately obvious venue of expansion is expression bans, such as if a
 +  message has too many capital letters, etc. There is no protection from spam yet.
 +
 +  See the GitHub wiki for more information about available commands:
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#twitchbot
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.common;
import dialect.defs;
import kameloso.messaging;
import kameloso.common : logger, settings;

import core.thread : Fiber;
import std.typecons : Flag, No, Yes;


/// All Twitch bot plugin runtime settings.
struct TwitchBotSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// Whether or not to bell on every message.
    bool bellOnMessage = false;

    /// Whether or not to bell on important events, like subscriptions.
    bool bellOnImportant = true;

    /// Whether or not to do reminders at the end of vote durations.
    bool voteReminders = true;

    /// Whether or not regulars are impliictly whitelisted.
    bool regularsAreWhitelisted = true;

    /// Whether or not to match ban phrases case-sensitively.
    bool bannedPhrasesObeyCase = true;

    /// How long a user should be timed out if they send a banned phrase.
    int bannedPhraseTimeout = 60;
}


// onAnyMessage
/++
 +  Bells on any message, if the `TwitchBotSettings.bellOnMessage` setting is set.
 +
 +  This is useful with small audiences, so you don't miss messages.
 +
 +  Also bump the message counter for the channel, to be used by timers.
 +/
@(Chainable)
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

    // Don't trigger on whispers
    if (event.type == IRCEvent.Type.QUERY) return;

    if (auto channel = event.channel in plugin.activeChannels)
    {
        ++channel.messageCount;
    }

    if (const bannedPhrases = event.channel in plugin.bannedPhrasesByChannel)
    {
        import lu.string : contains;
        import std.algorithm.searching : canFind;

        if (const channelRegulars = event.channel in plugin.regularsByChannel)
        {
            if ((*channelRegulars).canFind(event.sender.nickname)) return;
        }

        if ((event.sender.nickname == plugin.state.client.nickname) ||
            plugin.state.client.admins.canFind(event.sender.nickname) ||
            event.sender.badges.contains("mode"/*rator*/))
        {
            return;
        }

        foreach (immutable phrase; *bannedPhrases)
        {
            import std.algorithm.comparison : equal;
            import std.uni : asLowerCase;

            // Try not to allocate two whole new strings
            immutable match = plugin.twitchBotSettings.bannedPhrasesObeyCase ?
                event.content.contains(phrase) :
                event.content.asLowerCase.equal(phrase.asLowerCase);

            if (match)
            {
                import std.format : format;

                // Will using immediate here trigger spam detection?
                immediate(plugin.state, "PRIVMSG %s :.delete %s".format(event.channel, event.id));
                //chan!(Yes.priority)(plugin.state, event.channel, ".delete " ~ event.id);
                chan!(Yes.priority)(plugin.state, event.channel, ".timeout %s %d Banned phrase"
                    .format(event.sender.nickname, plugin.twitchBotSettings.bannedPhraseTimeout));
                break;
            }
        }
    }
}


// onUserState
/++
 +  On `IRCEvent.Type.USERSTATE` events, manually catch if we seem to be a moderator,
 +  and update the `TwitchBotPlugin.state.channels` associative array to add us
 +  as an operator if so.
 +
 +  We can use this later to speed up messages, as moderators and broadcasters
 +  aren't as rate-limited as normal users are.
 +
 +  Sadly we receives one of these every time we send a message. So this is a hotspot.
 +/
@(IRCEvent.Type.USERSTATE)
@(PrivilegeLevel.ignore) // Sender is server
@(ChannelPolicy.home)
void onUserState(TwitchBotPlugin plugin, const IRCEvent event)
{
    import lu.string : contains;

    // We're implicitly moderator if we match the channel name, so exempt that case

    if ((event.channel[1..$] != plugin.state.client.nickname) &&
        event.target.badges.contains("mode"/*rator*/))
    {
        import std.algorithm.searching : canFind;
        auto channel = event.channel in plugin.state.channels;

        if (!(*channel).ops.canFind(plugin.state.client.nickname))
        {
            channel.ops ~= plugin.state.client.nickname;
        }
    }
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
 +  Creates the timer `core.thread.Fiber`s that there are definitions for in
 +  `TwitchBotPlugin.timerDefsByChannel`.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.home)
void onSelfjoin(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (event.channel in plugin.activeChannels) return;

    plugin.activeChannels[event.channel] = TwitchBotPlugin.Channel.init;
    auto channel = event.channel in plugin.activeChannels;

    const timerDefs = event.channel in plugin.timerDefsByChannel;
    if (!timerDefs || !(*timerDefs).length) return;

    foreach (const timerDef; *timerDefs)
    {
        channel.timers ~= plugin.createTimerFiber(timerDef, event.channel);
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
    string nickname = channelName[1..$];
    if (const streamer = nickname in plugin.state.users)
    {
        if (streamer.alias_.length) nickname = streamer.alias_;
    }

    void dg()
    {
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

                immutable line = timerDef.line
                    .replace("$streamer", nickname)
                    .replace("$channel", channelName[1..$]);
                chan(plugin.state, channelName, line);
            }

            // If channel is disabled, silently fizzle but keep updating counts

            lastMessageCount = channel.messageCount;
            lastTimestamp = now;

            Fiber.yield();
            //continue;
        }
    }

    return new Fiber(&dg);
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


// onCommandPhraseChan
/++
 +  Bans, unbans, lists or clears banned phrases for the current channel.
 +  `dialect.defs.IRCEvent.Type.CHAN` wrapper.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.bannedPhrasesFile` file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "phrase")
@Description("Adds, removes, lists or clears phrases from the list of banned such.",
    "$command [target channel if query] [ban|unban|list|clear]")
void onCommandPhraseChan(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handlePhraseCommand(plugin, event, event.channel);
}


// onCommandPhraseQuery
/++
 +  Bans, unbans, lists or clears banned phrases for the specified target channel.
 +  `dialect.defs.IRCEvent.Type.QUERY` wrapper.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.bannedPhrasesFile` file.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.prefixed, "phrase")
@Description("Adds, removes, lists or clears phrases from the list of banned such.",
    "$command [target channel if query] [ban|unban|list|clear]")
void onCommandPhraseQuery(TwitchBotPlugin plugin, const IRCEvent event)
{
    import lu.string : nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    string slice = event.content;  // mutable
    immutable targetChannel = slice.nom!(Yes.inherit)(' ');

    if (!targetChannel.length || (targetChannel[0] != '#'))
    {
        query(plugin.state, event.sender.nickname,
            "Usage: %s [channel] [ban|unban|list|clear]".format(event.aux));
        return;
    }

    IRCEvent modifiedEvent = event;
    modifiedEvent.content = slice;

    return handlePhraseCommand(plugin, modifiedEvent, targetChannel.toLower);
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
                "Usage: %s [phrase]".format(verb));
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
                "Usage: %s [phrase index]".format(verb));
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
                        "Usage: %s [optional starting position number]"
                        .format(verb));
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
            "Available actions: ban, unban, list, clear");
        break;
    }
}


// onCommandTimerChan
/++
 +  Adds, deletes, lists or clears timers for the specified target channel.
 +  `dialect.defs.IRCEvent.Type.CHAN` wrapper.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.timersFile` file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "timer")
@Description("Adds, removes, lists or clears timered lines.",
    "$command [target channel if query] [add|del|list|clear]")
void onCommandTimerChan(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handleTimerCommand(plugin, event, event.channel);
}


// onCommandTimerQuery
/++
 +  Adds, deletes, lists or clears timers for the specified target channel.
 +  `dialect.defs.IRCEvent.Type.QUERY` wrapper.
 +
 +  Changes are persistently saved to the `TwitchBotPlugin.timersFile` file.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.prefixed, "timer")
@Description("Adds, removes, lists or clears timered lines.",
    "$command [target channel if query] [add|del|list|clear]")
void onCommandTimerQuery(TwitchBotPlugin plugin, const IRCEvent event)
{
    import lu.string : nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    string slice = event.content;  // mutable
    immutable targetChannel = slice.nom!(Yes.inherit)(' ');

    if (!targetChannel.length || (targetChannel[0] != '#'))
    {
        query(plugin.state, event.sender.nickname,
            "Usage: %s [channel] [add|del|list|clear]".format(event.aux));
        return;
    }

    IRCEvent modifiedEvent = event;
    modifiedEvent.content = slice;

    return handleTimerCommand(plugin, modifiedEvent, targetChannel.toLower);
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
{
    import lu.string : contains, nom;
    import std.format : format;

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        import std.algorithm.searching : count;
        import std.conv : ConvException, to;

        if (slice.count(' ') < 3)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: add [message threshold] [time threshold] [stagger seconds] [text]");
            //                                 1                2                 3
            return;
        }

        TimerDefinition timerDef;

        try
        {
            timerDef.messageCountThreshold = slice.nom(' ').to!int;
            timerDef.timeThreshold = slice.nom(' ').to!int;
            timerDef.stagger = slice.nom(' ').to!int;
            timerDef.line = slice;
        }
        catch (ConvException e)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid parameters.");
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: add [message threshold] [time threshold] [stagger time] [text]");
            return;
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
                "A timer cannot have a message *and* a time threshold of zero.");
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
            privmsg(plugin.state, event.channel, event.sender.nickname, "Usage: del [timer index]");
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
                        "Usage: list [optional starting position number]");
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
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Available actions: add, del, list, clear");
        break;
    }
}


// onCommandEnableDisable
/++
 +  Toggles whether or not the bot should operate in this channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
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
    immutable broadcastStart = plugin.activeChannels[event.channel].broadcastStart;

    string nickname = event.channel[1..$];

    if (const streamer = nickname in plugin.state.users)
    {
        if (streamer.alias_.length) nickname = streamer.alias_;
    }

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
            .format(nickname, delta));
    }
    else
    {
        chan(plugin.state, event.channel, nickname ~ " is currently not streaming.");
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "start")
@Description("Marks the start of a broadcast.")
void onCommandStart(TwitchBotPlugin plugin, const IRCEvent event)
{
    import std.datetime.systime : Clock;

    auto channel = event.channel in plugin.activeChannels;

    if (channel.broadcastStart != 0L)
    {
        string nickname = event.channel[1..$];

        if (const streamer = nickname in plugin.state.users)
        {
            if (streamer.alias_.length) nickname = streamer.alias_;
        }

        chan(plugin.state, event.channel, nickname ~ " is already live.");
        return;
    }

    channel.broadcastStart = Clock.currTime.toUnixTime;
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
@(PrivilegeLevel.admin)
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
{
    import core.time : msecs;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    auto channel = event.channel in plugin.activeChannels;

    auto now = Clock.currTime;
    now.fracSecs = 0.msecs;
    const delta = now - SysTime.fromUnixTime(channel.broadcastStart);
    channel.broadcastStart = 0L;

    string nickname = event.channel[1..$];

    if (const streamer = nickname in plugin.state.users)
    {
        if (streamer.alias_.length) nickname = streamer.alias_;
    }

    chan(plugin.state, event.channel, "Broadcast ended. %s streamed for %s."
        .format(nickname, delta));
}


// onCommandStartVote
/++
 +  Instigates a vote.
 +
 +  A duration and two or more voting options have to be passed.
 +
 +  Implemented as a `core.thread.Fiber`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "vote")
@BotCommand(PrefixPolicy.prefixed, "poll")
@Description("Starts a vote.", "$command [seconds] [choice1] [choice2] ...")
void onCommandStartVote(TwitchBotPlugin plugin, const IRCEvent event)
in ((event.channel in plugin.activeChannels), "Tried to start a vote in what is probably a non-home channel")
do
{
    import lu.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;
    import std.uni : toLower;

    auto channel = event.channel in plugin.activeChannels;

    if (channel.voteInstance > 0)
    {
        chan(plugin.state, event.channel, "A vote is already in progress!");
        return;
    }

    if (event.content.count(' ') < 2)
    {
        chan(plugin.state, event.channel, "Need one duration and at least two options.");
        return;
    }

    long dur;
    string slice = event.content;

    try
    {
        dur = slice.nom!(Yes.decode)(' ').to!long;
    }
    catch (ConvException e)
    {
        chan(plugin.state, event.channel, "Duration must be a positive number.");
        return;
    }

    if (dur <= 0)
    {
        chan(plugin.state, event.channel, "Duration must be a positive number.");
        return;
    }

    /// Available vote options and their vote counts.
    uint[string] voteChoices;

    /// Which users have already voted.
    bool[string] votedUsers;

    /// What the choices were originally named before lowercasing.
    string[string] origChoiceNames;

    foreach (immutable rawChoice; slice.splitter(" "))
    {
        import lu.string : strippedRight;

        // Strip any trailing commas
        immutable choice = rawChoice.strippedRight(',');
        if (!choice.length) continue;
        immutable lower = choice.toLower;

        origChoiceNames[lower] = choice;
        voteChoices[lower] = 0;
    }

    if (!voteChoices.length)
    {
        chan(plugin.state, event.channel, "Need at least two unique vote choices.");
        return;
    }

    import kameloso.thread : CarryingFiber;
    import std.format : format;
    import std.random : uniform;

    /// Unique vote instance identifier
    immutable id = uniform(1, 10_000);

    void dg()
    {
        if (channel.voteInstance != id) return;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        if (thisFiber.payload == IRCEvent.init)
        {
            // Invoked by timer, not by event
            import std.algorithm.iteration : sum;
            import std.algorithm.sorting : sort;
            import std.array : array;

            immutable total = cast(double)voteChoices.byValue.sum;

            if (total > 0)
            {
                chan(plugin.state, event.channel, "Voting complete, results:");

                auto sorted = voteChoices.byKeyValue.array.sort!((a,b) => a.value < b.value);

                foreach (const result; sorted)
                {
                    import lu.string : plurality;

                    immutable noun = result.value.plurality("vote", "votes");
                    immutable double voteRatio = cast(double)result.value / total;
                    immutable double votePercentage = 100 * voteRatio;

                    chan(plugin.state, event.channel, "%s : %d %s (%.1f%%)"
                        .format(origChoiceNames[result.key], result.value, noun, votePercentage));
                }
            }
            else
            {
                chan(plugin.state, event.channel, "Voting complete, no one voted.");
            }

            channel.voteInstance = 0;

            // End Fiber
            return;
        }

        // Triggered by an event
        immutable vote = thisFiber.payload.content;
        immutable nickname = thisFiber.payload.sender.nickname;

        if (!vote.length || vote.contains!(Yes.decode)(' '))
        {
            // Not a vote; yield and await a new event
        }
        else if (nickname in votedUsers)
        {
            // User already voted and we don't support revotes for now
        }
        else if (auto ballot = vote.toLower in voteChoices)
        {
            // Valid entry, increment vote count
            ++(*ballot);
            votedUsers[nickname] = true;
        }

        // Yield and await a new event
        Fiber.yield();
        return dg();
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg);

    plugin.awaitEvent(fiber, IRCEvent.Type.CHAN);
    plugin.delayFiber(fiber, dur);
    channel.voteInstance = id;

    void dgReminder()
    {
        if (channel.voteInstance != id) return;

        auto thisFiber = cast(CarryingFiber!int)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        chan(plugin.state, event.channel, "%d seconds! (%-(%s, %))"
            .format(thisFiber.payload, voteChoices.byKey));
    }

    if (plugin.twitchBotSettings.voteReminders)
    {
        // Warn once at 30 seconds remaining if the vote was for at least 60 seconds
        // Warn once at 10 seconds if the vote was for at least 20 seconds

        if (dur >= 60)
        {
            auto reminder30 = new CarryingFiber!int(&dgReminder);
            reminder30.payload = 30;
            plugin.delayFiber(reminder30, dur-30);
        }

        if (dur >= 20)
        {
            auto reminder10 = new CarryingFiber!int(&dgReminder);
            reminder10.payload = 10;
            plugin.delayFiber(reminder10, dur-10);
        }
    }

    chan(plugin.state, event.channel,
        "Voting commenced! Please place your vote for one of: %-(%s, %) (%d seconds)"
        .format(voteChoices.byKey, dur));
}


// onCommandAbortVote
/++
 +  Aborts an ongoing vote.
 +
 +  Vote instances are uniquely identified by the UNIX timestamp of when it
 +  started. There may be an arbitrary number of Fibers queued to trigger as the
 +  duration comes to a close. By setting the `TwitchBotPlugin.Channel.voteInstance`
 +  ID variable to 0 we invalidate all such Fibers, which rely on that ID being
 +  equal to the ID they themselves have stored in their closures.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "abortvote")
@BotCommand(PrefixPolicy.prefixed, "abortpoll")
@Description("Aborts an ongoing vote.")
void onCommandAbortVote(TwitchBotPlugin plugin, const IRCEvent event)
in ((event.channel in plugin.activeChannels), "Tried to abort a vote in what is probably a non-home channel")
do
{
    auto channel = event.channel in plugin.activeChannels;

    if (channel.voteInstance > 0)
    {
        channel.voteInstance = 0;
        chan(plugin.state, event.channel, "Vote aborted.");
    }
    else
    {
        chan(plugin.state, event.channel, "There is no ongoing vote.");
    }
}


// onCommandRegularChan
/++
 +  Adds, lists and removes regulars to/from the current channel.
 +
 +  Merely passes the event onto `handleRegularCommand` with the current channel
 +  as the target channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "regular")
@Description("Adds or removes a Twitch regulars to/from the current channel. (Channel message wrapper)",
    "$command [add|del|list] [nickname]")
void onCommandRegularChan(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handleRegularCommand(plugin, event, event.channel);
}


// onCommandRegularQuery
/++
 +  Adds, lists and removes regulars to/from the specified channel.
 +
 +  Merely passes the event onto `handleRegularCommand` with the specified channel
 +  as the target channel.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.prefixed, "regular")
@Description("Adds or removes a Twitch regulars to/from the current channel. (Whisper wrapper)",
    "$command [add|del|list] [nickname]")
void onCommandRegularQuery(TwitchBotPlugin plugin, const IRCEvent event)
{
    import lu.string : nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;

    string slice = event.content;  // mutable
    immutable targetChannel = slice.nom!(Yes.inherit)(' ');

    if (!targetChannel.length || (targetChannel[0] != '#'))
    {
        query(plugin.state, event.sender.nickname,
            "Usage: %s [channel] [add|del|list] [nickname]".format(event.aux));
        return;
    }

    IRCEvent modifiedEvent = event;
    modifiedEvent.content = slice;

    return handleRegularCommand(plugin, modifiedEvent, targetChannel.toLower);
}


// handleRegularCommand
/++
 +  Implements adding, listing and removing regulars for a channel.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      targetChannel = The channel we're adding/listing/removing regulars to/from.
 +/
void handleRegularCommand(TwitchBotPlugin plugin, const IRCEvent event, string targetChannel)
{
    import lu.string : contains, nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.uni : toLower;

    if (!event.content.length || (event.content.count(' ') > 1))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: [add|del|list] [nickname]");
            //                    1
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s [nickname]".format(verb));
            return;
        }

        immutable nickname = slice.toLower;

        if (auto regularArray = targetChannel in plugin.regularsByChannel)
        {
            import std.algorithm.searching : canFind;

            if ((*regularArray).canFind(nickname))
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    slice ~ " is already a channel regular.");
                return;
            }
            else
            {
                *regularArray ~= nickname;
                // Drop down for report
            }
        }
        else
        {
            plugin.regularsByChannel[targetChannel] ~= nickname;
            // Drop down for report
        }

        saveResourceToDisk(plugin.regularsByChannel, plugin.regularsFile);
        privmsg(plugin.state, event.channel, event.sender.nickname,
            slice ~ " is now a regular.");
        break;

    case "del":
        if (!slice.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s [nickname]".format(verb));
            return;
        }

        immutable nickname = slice.toLower;

        if (auto regularArray = targetChannel in plugin.regularsByChannel)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            import std.algorithm.searching : countUntil;

            immutable index = (*regularArray).countUntil(nickname);

            if (index != -1)
            {
                *regularArray = (*regularArray).remove!(SwapStrategy.unstable)(index);
                saveResourceToDisk(plugin.regularsByChannel, plugin.regularsFile);
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "Regular removed.");
            }
            else
            {
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "No such regular: " ~ slice);
            }
        }
        break;

    case "list":
        if (const regularList = targetChannel in plugin.regularsByChannel)
        {
            import std.format : format;
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Current regulars: %-(%s, %)".format(*regularList));
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "There are no regulars registered for this channel.");
        }
        break;

    default:
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Available actions: add, del, list");
        break;
    }
}


// onEndOfMotd
/++
 +  Populate the regulars and phrases array after we have successfully
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
        JSONStorage channelRegularsJSON;
        channelRegularsJSON.load(regularsFile);
        regularsByChannel.populateFromJSON!(Yes.lowercaseValues)(channelRegularsJSON);
        regularsByChannel.rehash();

        JSONStorage channelBannedPhrasesJSON;
        channelBannedPhrasesJSON.load(bannedPhrasesFile);
        bannedPhrasesByChannel.populateFromJSON(channelBannedPhrasesJSON);
        bannedPhrasesByChannel.rehash();

        // Timers use a specialised function
        plugin.populateTimers(plugin.timersFile);
    }
}


// saveResourceToDisk
/++
 +  Saves the passed resource to disk, but in JSON format.
 +
 +  This is used with the associative arrays for regulars and banned phrases.
 +
 +  Example:
 +  ---
 +  plugin.regularsByChannel["#channel"] ~= "kameloso";
 +  plugin.regularsByChannel["#channel"] ~= "hirrsteff";
 +
 +  saveResource(plugin.regularsByChannel, plugin.regularsFile);
 +  ---
 +
 +  Params:
 +      resource = The JSON-convertible resource to save.
 +      filename = Filename of the file to write to.
 +/
void saveResourceToDisk(Resource)(const Resource resource, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    File(filename, "w").writeln(JSONValue(resource).toPrettyString);
}


// initResources
/++
 +  Reads and writes the file of regulars, phrases and timers to disk, ensuring
 +  that they're there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage regularsJSON;

    try
    {
        regularsJSON.load(plugin.regularsFile);
    }
    catch (JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.regularsFile.baseName ~ " may be malformed.");
    }

    JSONStorage bannedPhrasesJSON;

    try
    {
        bannedPhrasesJSON.load(plugin.bannedPhrasesFile);
    }
    catch (JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.bannedPhrasesFile.baseName ~ " may be malformed.");
    }

    JSONStorage timersJSON;

    try
    {
        timersJSON.load(plugin.timersFile);
    }
    catch (JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.timersFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    regularsJSON.save(plugin.regularsFile);
    bannedPhrasesJSON.save(plugin.bannedPhrasesFile);
    timersJSON.save(plugin.timersFile);
}


// periodically
/++
 +  Periodically calls timer `core.thread.Fiber`s with a periodicity of
 +  `TwitchBotPlugin.timerPeriodicity`.
 +/
void periodically(TwitchBotPlugin plugin)
{
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime.toUnixTime;

    if ((plugin.state.client.server.daemon != IRCServer.Daemon.unset) &&
        (plugin.state.client.server.daemon != IRCServer.Daemon.twitch))
    {
        // Known to not be a Twitch server
        plugin.state.nextPeriodical = now + 315_569_260L;
        return;
    }

    foreach (immutable channelName, channel; plugin.activeChannels)
    {
        if (!channel.timers.length) continue;

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

    plugin.state.nextPeriodical = now + plugin.timerPeriodicity;
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
{
    import std.conv : to;
    import std.format : format;
    import std.json : JSONType;

    JSONStorage timersJSON;
    timersJSON.load(filename);

    foreach (immutable channel, const channelTimersJSON; timersJSON.object)
    {
        assert((channelTimersJSON.type == JSONType.array),
            "Twitch timer json file malformed! Invalid channel timers list type for %s: %s"
            .format(channel, channelTimersJSON.type));

        plugin.timerDefsByChannel[channel] = typeof(plugin.timerDefsByChannel[channel]).init;

        foreach (timerArrayEntry; channelTimersJSON.array)
        {
            assert((timerArrayEntry.type == JSONType.object),
                "Twitch timer json file malformed! Invalid timer type for %s: %s"
                .format(channel, timerArrayEntry.type));

            TimerDefinition timer;

            timer.line = timerArrayEntry["line"].str;
            timer.messageCountThreshold = timerArrayEntry["messageCountThreshold"].integer.to!int;
            timer.timeThreshold = timerArrayEntry["timeThreshold"].integer.to!int;
            timer.stagger = timerArrayEntry["stagger"].integer.to!int;

            plugin.timerDefsByChannel[channel] ~= timer;
        }
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


// postprocess
/++
 +  Postprocesses `dialect.defs.IRCEvent`s, changing the user classes to
 +  reflect whether or not a user is a regular.
 +
 +  The Persistence service doesn't have access to `TwitchBotPlugin.regularsByChannel`
 +  and so cannot set a user's class to `IRCUser.Class.whitelist` if it's in there.
 +  So we do it as a postprocessing step *before* Persistence.
 +
 +  Special care has to be taken inside Persistence to not make it overwrite this
 +  change with whatever it has stored for this particular user.
 +/
void postprocess(TwitchBotPlugin plugin, ref IRCEvent event)
{
    import std.algorithm.searching : canFind;
    import std.range : only;

    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;
    if (!event.sender.nickname.length && !event.target.nickname.length) return;
    if (event.channel.length && (event.channel !in plugin.activeChannels)) return;

    foreach (user; only(&event.sender, &event.target))
    {
        if (event.channel.length && (user.nickname == event.channel[1..$]))
        {
            user.class_ = IRCUser.Class.admin;
        }
        else if (user.badges.canFind("mode"/*rator*/))
        {
            user.class_ = IRCUser.Class.admin;
        }
        else if (plugin.twitchBotSettings.regularsAreWhitelisted)
        {
            if (const channelRegulars = event.channel in plugin.regularsByChannel)
            {
                if ((*channelRegulars).canFind(user.nickname))
                {
                    user.class_ = plugin.state.client.admins.canFind(user.nickname) ?
                        IRCUser.Class.admin : IRCUser.Class.whitelist;
                }
            }
        }
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
        /// Toggle of whether or not the bot should operate in this channel.
        bool enabled = true;

        /// ID of the currently ongoing vote, if any (otherwise 0).
        int voteInstance;

        /// UNIX timestamp of when broadcasting started.
        long broadcastStart;

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
    @Settings TwitchBotSettings twitchBotSettings;

    /// Array of active bot channels' state.
    Channel[string] activeChannels;

    /// Associative array of regulars; nickname array keyed by channel.
    string[][string] regularsByChannel;

    /// Filename of file with regulars.
    @Resource string regularsFile = "twitchregulars.json";

    /// Associative array of banned phrases; phrases array keyed by channel.
    string[][string] bannedPhrasesByChannel;

    /// Filename of file with banned phrases.
    @Resource string bannedPhrasesFile = "twitchphrases.json";

    /// Timer definition arrays, keyed by channel string.
    TimerDefinition[][string] timerDefsByChannel;

    /// Filename of file with timer definitions.
    @Resource string timersFile = "twitchtimers.json";

    /++
     +  How often to check whether timers should fire, in seconds. A smaller
     +  number means better precision.
     +/
    enum timerPeriodicity = 10;

    mixin IRCPluginImpl;


    /++
     +  Override `kameloso.plugins.common.IRCPluginImpl.onEvent` and inject a server check, so this
     +  plugin does nothing on non-Twitch servers. Also filters `dialect.defs.IRCEvent.Type.CHAN`
     +  events to only trigger on active channels (that have its `Channel.enabled`
     +  set to true).
     +
     +  The function to call is `kameloso.plugins.common.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.common.IRCPluginImpl.onEventImpl`
     +          after verifying we should process the event.
     +/
    public void onEvent(const IRCEvent event)
    {
        if ((state.client.server.daemon != IRCServer.Daemon.unset) &&
            (state.client.server.daemon != IRCServer.Daemon.twitch))
        {
            // Daemon known and not Twitch
            return;
        }

        if (event.type == IRCEvent.Type.CHAN)
        {
            import lu.string : beginsWith;

            if (event.content.beginsWith(settings.prefix) &&
                (event.content.length > settings.prefix.length))
            {
                // Specialcase prefixed "enable"
                if (event.content[settings.prefix.length..$] == "enable")
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

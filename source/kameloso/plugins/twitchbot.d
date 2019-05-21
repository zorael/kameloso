/++
 +  This is an example Twitch streamer bot. It supports basic authentication,
 +  allowing for administrators that are not necessarily in the whitelist nor are
 +  Twitch moderators, querying uptime or how long a streamer has been streaming,
 +  as well as custom (non-hardcoded) oneliner commands.
 +
 +  One immediately obvious venue of expansion is expression bans, such as if a
 +  message has too many capital letters, contains banned words, etc. There is
 +  no protection from spam yet either.
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;
import kameloso.common : logger, settings;

import std.typecons : Flag, No, Yes;


/// All Twitch bot plugin runtime settings.
struct TwitchBotSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = false;

    /// Whether or not to bell on every message.
    bool bellOnMessage = false;

    /// Whether or not to bell on important events, like subscriptions.
    bool bellOnImportant = true;

    /// Whether or not to do reminders at the end of vote durations.
    bool voteReminders = true;

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
 +/
@(Chainable)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.WHISPER)
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
    if (event.type == IRCEvent.Type.WHISPER) return;

    if (const bannedPhrases = event.channel in plugin.bannedPhrasesByChannel)
    {
        import kameloso.string : contains;
        import std.algorithm.searching : canFind;

        if (const channelAdmins = event.channel in plugin.adminsByChannel)
        {
            if ((*channelAdmins).canFind(event.sender.nickname)) return;
        }
        else if ((event.sender.nickname == plugin.state.client.nickname) ||
            plugin.state.client.admins.canFind(event.sender.nickname) ||
            event.sender.badges.contains("moderator"))
        {
            return;
        }

        foreach (immutable phrase; *bannedPhrases)
        {
            if (event.content.contains(phrase))
            {
                import std.format : format;

                chan!(Yes.priority)(plugin.state, event.channel, ".delete " ~ event.id);
                chan!(Yes.priority)(plugin.state, event.channel, ".timeout %s %d Banned phrase"
                    .format(event.sender.nickname, plugin.twitchBotSettings.bannedPhraseTimeout));
                break;
            }
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
@(IRCEvent.Type.TWITCH_PURCHASE)
@(IRCEvent.Type.TWITCH_RAID)
@(IRCEvent.Type.TWITCH_GIFTUPGRADE)
@(IRCEvent.Type.TWITCH_CHARITY)
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
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.home)
void onSelfjoin(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (event.channel !in plugin.activeChannels)
    {
        plugin.activeChannels[event.channel] = TwitchBotPlugin.Channel.init;
    }
}


// onSelfpart
/++
 +  Removes a channel's corresponding `TwitchBotPlugin.Channel` when we leave it.
 +
 +  This resets all that channel's state, except for oneliners and administrators.
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
 +  `IRCEvent.Type.CHAN` wrapper.
 +
 +  Changes are persistently saved to the `twitchphrases.json` file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "phrase")
@Description("Adds, removes, lists or clears phrases from the list of banned such. (Channel message wrapper)")
void onCommandPhraseChan(TwitchBotPlugin plugin, const IRCEvent event)
{
    return handlePhraseCommand(plugin, event, event.channel);
}


// onCommandPhraseWhisper
/++
 +  Bans, unbans, lists or clears banned phrases for the specified target channel.
 +  `IRCEvent.Type.WHISPER` wrapper.
 +
 +  Changes are persistently saved to the `twitchphrases.json` file.
 +/
@(IRCEvent.Type.WHISPER)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.prefixed, "phrase")
@Description("Adds, removes, lists or clears phrases from the list of banned such. (Whisper wrapper)")
void onCommandPhraseWhisper(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : nom;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    string slice = event.content;  // mutable
    immutable targetChannel = slice.nom!(Yes.inherit)(' ');

    if (!targetChannel.length)
    {
        query(plugin.state, event.sender.nickname,
            "Usage: %s%s [channel] [ban|unban|list|clear]"
            .format(settings.prefix, event.aux));
        return;
    }

    IRCEvent modifiedEvent = event;
    modifiedEvent.content = slice;

    return handlePhraseCommand(plugin, modifiedEvent, targetChannel);
}


// handlePhraseCommand
/++
 +  Bans, unbans, lists or clears banned phrases for the specified target channel.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      event = The triggering `kameloso.irc.defs.IRCEvent`.
 +      targetChannel = The channel we're handling phrase bans for.
 +/
void handlePhraseCommand(TwitchBotPlugin plugin, const IRCEvent event, const string targetChannel)
{
    import kameloso.string : contains, nom;
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
                "Usage: %s%s %s [phrase or substring of phrase]"
                .format(settings.prefix, event.aux, verb));
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
                "Usage: %s%s %s [phrase num 1] [phrase num 2] [phrase num 3] ..."
                .format(settings.prefix, event.aux, verb));
            return;
        }

        if (auto phrases = targetChannel in plugin.bannedPhrasesByChannel)
        {
            import std.algorithm.iteration : splitter;

            if (slice == "*")
            {
                plugin.bannedPhrasesByChannel.remove(targetChannel);
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    "All banned phrases removed.");
                return;
            }

            size_t[] garbage;

            foreach (immutable istr; slice.splitter(" "))
            {
                import std.conv : ConvException, to;

                try
                {
                    ptrdiff_t i = istr.to!size_t - 1;

                    if ((i > 0) && (i < phrases.length))
                    {
                        garbage ~= i;
                    }
                    else
                    {
                        privmsg(plugin.state, event.channel, event.sender.nickname,
                            "Phrase index %s out of range. (max %d)"
                            .format(istr, phrases.length));
                        return;
                    }
                }
                catch (ConvException e)
                {
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Invalid phrase index: " ~ istr);
                    privmsg(plugin.state, event.channel, event.sender.nickname,
                        "Usage: %s%s %s [phrase num 1] [phrase num 2] [phrase num 3] ..."
                        .format(settings.prefix, event.aux, verb));
                    return;
                }
            }

            immutable originalNum = phrases.length;

            foreach_reverse (immutable i; garbage)
            {
                import std.algorithm.mutation : SwapStrategy, remove;
                *phrases = (*phrases).remove!(SwapStrategy.unstable)(i);
            }

            immutable numRemoved = (originalNum - phrases.length);
            saveResourceToDisk(plugin.bannedPhrasesByChannel, plugin.bannedPhrasesFile);
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "%d/%d phrase bans removed.".format(numRemoved, originalNum));

            if (!phrases.length) plugin.bannedPhrasesByChannel.remove(targetChannel);
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
            import std.algorithm.comparison : min;

            enum toDisplay = 10;
            enum maxLineLength = 64;

            ptrdiff_t start;

            if (slice.length)
            {
                import std.conv : ConvException, to;

                try
                {
                    start = slice.to!ptrdiff_t - 1;

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
                        "Usage: %s%s list [optional starting position number]"
                        .format(settings.prefix, event.aux));
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
                    "%d: %s%s".format(start+i+1, phrase, (maxLen < phrase.length) ?
                    " ...  [truncated]" : string.init));
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
            "Usage: %s%s [ban|unban|list|clear]".format(settings.prefix, event.aux));
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

        chan(plugin.state, event.channel, "%s has been streaming for %s."
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

        chan(plugin.state, event.channel, nickname ~ " is already streaming.");
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
    import core.time : msecs;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    auto channel = event.channel in plugin.activeChannels;

    if (channel.broadcastStart == 0L)
    {
        chan(plugin.state, event.channel, "Broadcast was never registered as started...");
        return;
    }

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
{
    import kameloso.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;
    import std.uni : toLower;

    auto channel = event.channel in plugin.activeChannels;
    assert(channel, "Tried to start a vote in what is probably a non-home channel");

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
        import kameloso.string : strippedRight;

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
    import core.thread : Fiber;
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
                    import kameloso.string : plurality;

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

        chan(plugin.state, event.channel, "%d seconds!".format(thisFiber.payload));
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
        .format(voteChoices.keys, dur));
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
{
    auto channel = event.channel in plugin.activeChannels;
    assert(channel, "Tried to abort a vote in what is probably a non-home channel");

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


// onCommandModifyOneliner
/++
 +  Adds or removes a oneliner to/from the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "oneliner")
@Description("Adds or removes a oneliner command, or list all available.",
    "$command [add|del] [text]")
void onCommandModifyOneliner(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.typecons : No, Yes;

    if (!event.content.length)
    {
        chan(plugin.state, event.channel, "Usage: %s%s [add|del] [trigger] [text]"
            .format(settings.prefix, event.aux));
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        if (slice.contains!(Yes.decode)(' '))
        {
            immutable trigger = slice.nom!(Yes.decode)(' ');

            plugin.onelinersByChannel[event.channel][trigger] = slice;
            saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

            chan(plugin.state, event.channel, "Oneliner %s%s added."
                .format(settings.prefix, trigger));
        }
        else
        {
            chan(plugin.state, event.channel, "Usage: %s%s add [trigger] [text]"
                .format(settings.prefix, event.aux));
        }
        return;

    case "del":
        if (slice.length)
        {
            plugin.onelinersByChannel[event.channel].remove(slice);
            saveResourceToDisk(plugin.onelinersByChannel, plugin.onelinerFile);

            chan(plugin.state, event.channel, "Oneliner %s%s removed."
                .format(settings.prefix, slice));
        }
        else
        {
            chan(plugin.state, event.channel, "Usage: %s%s del [trigger]"
                .format(settings.prefix, event.aux));
        }
        return;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [add|del] [trigger] [text]"
            .format(settings.prefix, event.aux));
        break;
    }
}


// onCommandCommands
/++
 +  Sends a list of the current oneliners to the channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "commands")
@Description("Lists all available oneliners.")
void onCommandCommands(TwitchBotPlugin plugin, const IRCEvent event)
{
    import std.format : format;

    auto channelOneliners = event.channel in plugin.onelinersByChannel;

    if (channelOneliners && channelOneliners.length)
    {
        chan(plugin.state, event.channel, ("Available commands: %-(" ~ settings.prefix ~ "%s, %)")
            .format(channelOneliners.keys));
    }
    else
    {
        chan(plugin.state, event.channel, "There are no commands available right now.");
    }
}


// onCommandAdmin
/++
 +  Adds, lists and removes administrators from a channel.
 +
 +  * `!admin add nickname` adds `nickname` as an administrator.
 +  * `!admin del nickname` removes `nickname` as an administrator.
 +  * `!admin list` lists all administrators.
 +
 +  Only one nickname at a time. Only the current channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "admin")
@Description("Adds or removes a Twitch administrator to/from the current channel.",
    "$command [add|del|list] [nickname]")
void onCommandAdmin(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.uni : toLower;

    if (!event.content.length || (event.content.count(' ') > 1))
    {
        chan(plugin.state, event.channel, "Usage: %s%s [add|del|list] [nickname]"
            .format(settings.prefix, event.aux));
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit, Yes.decode)(' ');

    switch (verb)
    {
    case "add":
        if (slice.length)
        {
            immutable nickname = slice.toLower;

            if (auto adminArray = event.channel in plugin.adminsByChannel)
            {
                import std.algorithm.searching : canFind;

                if ((*adminArray).canFind(nickname))
                {
                    chan(plugin.state, event.channel, slice ~ " is already a bot administrator.");
                    return;
                }
                else
                {
                    *adminArray ~= nickname;
                    // Drop down for report
                }
            }
            else
            {
                plugin.adminsByChannel[event.channel] ~= nickname;
                // Drop down for report
            }

            saveResourceToDisk(plugin.adminsByChannel, plugin.adminsFile);
            chan(plugin.state, event.channel, slice ~ " is now an administrator.");
        }
        else
        {
            chan(plugin.state, event.channel, "Usage: %s%s [add] [nickname]"
                .format(settings.prefix, event.aux));
        }
        break;

    case "del":
        if (slice.length)
        {
            immutable nickname = slice.toLower;

            if (auto adminArray = event.channel in plugin.adminsByChannel)
            {
                import std.algorithm.mutation : SwapStrategy, remove;
                import std.algorithm.searching : countUntil;

                immutable index = (*adminArray).countUntil(nickname);

                if (index != -1)
                {
                    *adminArray = (*adminArray).remove!(SwapStrategy.unstable)(index);
                    saveResourceToDisk(plugin.adminsByChannel, plugin.adminsFile);
                    chan(plugin.state, event.channel, "Administrator removed.");
                }
                else
                {
                    chan(plugin.state, event.channel, "No such administrator: " ~ slice);
                }
            }
        }
        else
        {
            chan(plugin.state, event.channel, "Usage: %s%s [del] [nickname]"
                .format(settings.prefix, event.aux));
        }
        break;

    case "list":
        if (const adminList = event.channel in plugin.adminsByChannel)
        {
            import std.format : format;
            chan(plugin.state, event.channel, "Current administrators: %-(%s, %)"
                .format(*adminList));
        }
        else
        {
            chan(plugin.state, event.channel, "There are no administrators registered for this channel.");
        }
        break;

    default:
        chan(plugin.state, event.channel, "Usage: %s%s [add|del|list] [nickname]"
            .format(settings.prefix, event.aux));
        break;
    }
}


// onOneliner
/++
 +  Responds to oneliners.
 +
 +  Responses are stored in `TwitchBotPlugin.onelinersByChannel`.
 +/
@(Chainable)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onOneliner(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : beginsWith, contains, nom;

    if (!event.content.beginsWith(settings.prefix)) return;

    string slice = event.content;
    slice.nom(settings.prefix);

    if (const channelOneliners = event.channel in plugin.onelinersByChannel)
    {
        // Insert .toLower here if we want case-insensitive oneliners
        //import std.uni : toLower;
        if (const response = slice/*.toLower*/ in *channelOneliners)
        {
            chan(plugin.state, event.channel, *response);
        }
    }
}


// onEndOfMotd
/++
 +  Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(TwitchBotPlugin plugin)
{
    import kameloso.json : JSONStorage, populateFromJSON;
    import std.typecons : Flag, No, Yes;

    with (plugin)
    {
        JSONStorage channelOnelinerJSON;
        channelOnelinerJSON.load(onelinerFile);
        //onelinersByChannel.clear();
        onelinersByChannel.populateFromJSON(channelOnelinerJSON);
        onelinersByChannel.rehash();

        JSONStorage channelAdminsJSON;
        channelAdminsJSON.load(adminsFile);
        //adminsByChannel.clear();
        adminsByChannel.populateFromJSON!(Yes.lowercaseValues)(channelAdminsJSON);
        adminsByChannel.rehash();

        JSONStorage channelBannedPhrasesJSON;
        channelBannedPhrasesJSON.load(bannedPhrasesFile);
        //bannedPhrasesByChannel.clear();
        bannedPhrasesByChannel.populateFromJSON(channelBannedPhrasesJSON);
        bannedPhrasesByChannel.rehash();
    }
}


// saveResourceToDisk
/++
 +  Saves the passed resource to disk, but in `JSON` format.
 +
 +  This is used with the associative arrays for administrators, oneliners and
 +  banned phrases.
 +
 +  Example:
 +  ---
 +  plugin.adminsByChannel["#channel"] ~= "kameloso";
 +  plugin.adminsByChannel["#channel"] ~= "hirrsteff";
 +
 +  saveResource(plugin.adminsByChannel, plugin.adminsFile);
 +  ---
 +
 +  Params:
 +      resource = The `JSON`-convertible resource to save.
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
 +  Reads and writes the file of oneliners and administrators to disk, ensuring
 +  that they're there and properly formatted.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONException;
    import std.path : baseName;

    JSONStorage onelinerJSON;

    try
    {
        onelinerJSON.load(plugin.onelinerFile);
    }
    catch (JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.onelinerFile.baseName ~ " may be malformed.");
    }

    JSONStorage adminsJSON;

    try
    {
        adminsJSON.load(plugin.adminsFile);
    }
    catch (JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.adminsFile.baseName ~ " may be malformed.");
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

    // Let other Exceptions pass.

    onelinerJSON.save(plugin.onelinerFile);
    adminsJSON.save(plugin.adminsFile);
    bannedPhrasesJSON.save(plugin.bannedPhrasesFile);
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
    }

    /// Array of active bot channels' state.
    Channel[string] activeChannels;

    /// Associative array of oneliners, keyed by trigger word keyed by channel name.
    string[string][string] onelinersByChannel;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "twitchliners.json";

    /// Associative array of administrators; nickname array keyed by channel.
    string[][string] adminsByChannel;

    /// Filename of file with administrators.
    @Resource string adminsFile = "twitchadmins.json";

    /// Associative array of banned phrases; phrases array keyed by channel.
    string[][string] bannedPhrasesByChannel;

    /// Filename of file with banned phrases.
    @Resource string bannedPhrasesFile = "twitchphrases.json";

    /// All Twitch Bot plugin settings.
    @Settings TwitchBotSettings twitchBotSettings;

    mixin IRCPluginImpl;

    /++
     +  Override `IRCPluginImpl.allow` and inject a user check, so we can support
     +  channel-specific admins.
     +
     +  It is also possible to leverage the whitelist for this, but it would
     +  block much of the bot from being used by those who fall under the
     +  `anyone` category.
     +
     +  Params:
     +      event = `kameloso.irc.defs.IRCEvent` to allow, or not.
     +      privilegeLevel = `PrivilegeLevel` of the handler in question.
     +
     +  Returns:
     +      `true` if the event should be allowed to trigger, `false` if not.
     +/
    import kameloso.plugins.common : FilterResult, PrivilegeLevel;
    FilterResult allow(const IRCEvent event, const PrivilegeLevel privilegeLevel)
    {
        with (PrivilegeLevel)
        final switch (privilegeLevel)
        {
        case ignore:
        case anyone:
        case registered:
        case whitelist:
            // Fallback to original, unchanged behaviour
            return allowImpl(event, privilegeLevel);

        case admin:
            // Let pass if the sender is in `adminsByChannel[event.channel]`
            if (const channelAdmins = event.channel in adminsByChannel)
            {
                import std.algorithm.searching : canFind;

                return ((*channelAdmins).canFind(event.sender.nickname)) ?
                    FilterResult.pass : allowImpl(event, privilegeLevel);
            }
            else
            {
                goto case whitelist;
            }
        }
    }

    /++
     +  Override `IRCPluginImpl.onEvent` and inject a server check, so this
     +  plugin does nothing on non-Twitch servers. Also filters `IRCEvent.Type.CHAN`
     +  events to only trigger on active channels (that have its `Channel.enabled`
     +  set to true).
     +
     +  The function to call is `IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to pass onto `onEventImpl`
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
            import kameloso.string : beginsWith;

            if (event.content.beginsWith(settings.prefix) &&
                (event.content.length > settings.prefix.length))
            {
                import std.uni : toLower;

                // Prefixed command. Use .toLower for now
                // We only need "enable"
                if (event.content[settings.prefix.length..$].toLower == "enable")
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
                // Normal non-command channnel message
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

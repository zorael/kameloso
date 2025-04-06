/++
    The Poll plugin offers the ability to hold votes/polls in a channel. Any
    number of choices is supported, as long as they're more than one.

    Cheating by changing nicknames is warded against.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#poll,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.poll;

version(WithPollPlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;


// PollSettings
/++
    All Poll plugin runtime settings aggregated.
 +/
@Settings struct PollSettings
{
    /++
        Whether or not this plugin should react to any events.
     +/
    @Enabler bool enabled = true;

    /++
        Whether or not only votes placed by online users count.
     +/
    bool onlyOnlineUsersCount = true;

    /++
        Whether or not poll choices may start with the command prefix.

        There's no check in place that a prefixed choice won't conflict with a
        command, so make it opt-in at your own risk.
     +/
    bool forbidPrefixedChoices = true;

    /++
        User level required to vote.
     +/
    IRCUser.Class minimumPermissionsNeeded = IRCUser.Class.anyone;
}


// Poll
/++
    Embodies the notion of a channel poll.
 +/
struct Poll
{
private:
    import lu.container : RehashingAA;
    import std.datetime.systime : SysTime;

public:
    /++
        JSON schema for serialising and deserialising a poll.
     +/
    static struct JSONSchema
    {
        long start;  ///
        long end;  ///
        uint[string] voteCounts;  ///
        string[string] origChoiceNames;  ///
        string[] sortedChoices;  ///
        string[string] votes;  ///
        uint uniqueID;  ///
    }

    /++
        Timestamp of when the poll was created.
     +/
    SysTime start;

    /++
        Timestamp of when the poll is to end.
     +/
    SysTime end;

    /++
        Current vote tallies.
     +/
    uint[string] voteCounts;

    /++
        Map of the original names of the choices keyed by what they were simplified to.
     +/
    string[string] origChoiceNames;

    /++
        Choices, sorted in alphabetical order.
     +/
    string[] sortedChoices;

    /++
        Individual votes, keyed by nicknames of the people who placed them.
     +/
    RehashingAA!(string[string]) votes;

    /++
        Unique identifier to help fibers know if the poll they belong to is stale
        or has been replaced.
     +/
    uint uniqueID;

    /++
        Constructor.
     +/
    this(/*const*/ JSONSchema schema)
    {
        this.start = SysTime.fromUnixTime(schema.start);
        this.end = SysTime.fromUnixTime(schema.end);
        this.voteCounts = schema.voteCounts;
        this.origChoiceNames = schema.origChoiceNames;
        this.sortedChoices = schema.sortedChoices;
        this.votes = schema.votes;
        this.uniqueID = schema.uniqueID;
        this.votes.rehash();
    }

    /++
        Returns a [JSONSchema] of this poll.
     +/
    auto asSchema() /*const*/
    {
        JSONSchema schema;
        schema.start = this.start.toUnixTime();
        schema.end = this.end.toUnixTime();
        schema.voteCounts = this.voteCounts;
        schema.origChoiceNames = this.origChoiceNames;
        schema.sortedChoices = this.sortedChoices;
        schema.votes = this.votes.aaOf;
        schema.uniqueID = this.uniqueID;
        return schema;
    }
}


// onCommandPoll
/++
    Instigates a poll or stops an ongoing one.

    If starting one a duration and two or more voting choices have to be passed.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("poll")
            .policy(PrefixPolicy.prefixed)
            .description(`Starts or stops a poll. Pass "abort" to abort, or "end" to end early.`)
            .addSyntax("$command [duration] [choice 1] [choice 2] ...")
            .addSyntax("$command abort")
            .addSyntax("$command end")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("vote")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandPoll(PollPlugin plugin, const IRCEvent event)
{
    import kameloso.time : DurationStringException, asAbbreviatedDuration, timeSince;
    import lu.string : stripped;
    import std.algorithm.searching : count;
    import std.algorithm.sorting : sort;
    import std.conv : ConvException;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;
    import std.random : uniform;
    import core.time : Duration;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        if (event.sender.class_ < IRCUser.Class.operator)
        {
            enum message = "You are not authorised to start new polls.";
            chan(plugin.state, event.channel.name, message);
        }
        else
        {
            import std.format : format;

            enum pattern = "Usage: <b>%s%s<b> [duration] [choice1] [choice2] ...";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            chan(plugin.state, event.channel.name, message);
        }
    }

    void sendNoOngoingPoll()
    {
        enum message = "There is no ongoing poll.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendPollAborted()
    {
        enum message = "Poll aborted.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendSyntaxHelp()
    {
        enum message = "Need one duration and at least two choices.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendMalformedDuration()
    {
        enum message = "Malformed duration.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNegativeDuration()
    {
        enum message = "Duration must not be negative.";
        chan(plugin.state, event.channel.name, message);
    }

    void sendNeedTwoUniqueChoices()
    {
        enum message = "Need at least two unique poll choices.";
        chan(plugin.state, event.channel.name, message);
    }

    const currentPoll = event.channel.name in plugin.channelPolls;

    switch (event.content)
    {
    case string.init:
        if (currentPoll)
        {
            goto case "status";
        }
        else
        {
            return (event.sender.class_ < IRCUser.Class.operator) ?
                sendNoOngoingPoll() :
                sendUsage();
        }

    case "status":
        if (!currentPoll) return sendNoOngoingPoll();
        return reportStatus(plugin, event.channel.name, *currentPoll);

    case "abort":
        if (!currentPoll) return sendNoOngoingPoll();

        plugin.channelPolls.remove(event.channel.name);
        return sendPollAborted();

    case "end":
        if (!currentPoll) return sendNoOngoingPoll();

        reportEndResults(plugin, event.channel.name, *currentPoll);
        plugin.channelPolls.remove(event.channel.name);
        return;

    default:
        // Drop down
        break;
    }

    if (event.content.count(' ') < 2)
    {
        return sendSyntaxHelp();
    }

    Poll poll;
    Duration duration;
    string slice = event.content.stripped;  // mutable

    try
    {
        import lu.string : advancePast;
        duration = slice.advancePast(' ').asAbbreviatedDuration;
    }
    catch (ConvException _)
    {
        return sendMalformedDuration();
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel.name, e.msg);
    }
    catch (Exception e)
    {
        chan(plugin.state, event.channel.name, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        return;
    }

    if (duration <= Duration.zero)
    {
        return sendNegativeDuration();
    }

    auto choicesVoldemort = getPollChoices(plugin, event.channel.name, slice);  // must be mutable
    if (!choicesVoldemort.success) return;

    if (choicesVoldemort.choices.length < 2)
    {
        return sendNeedTwoUniqueChoices();
    }

    poll.start = Clock.currTime;
    poll.end = (poll.start + duration);
    poll.uniqueID = uniform(1, uint.max);
    poll.voteCounts = choicesVoldemort.choices;
    poll.origChoiceNames = choicesVoldemort.origChoiceNames;
    poll.sortedChoices = poll.voteCounts
        .keys
        .sort
        .release;
    plugin.channelPolls[event.channel.name] = poll;

    generatePollFiber(plugin, event.channel.name, poll);
    generateVoteReminders(plugin, event.channel.name, poll);
    generateEndFiber(plugin, event.channel.name, poll);

    immutable timeInWords = duration.timeSince!(7, 0);
    enum pattern = "<b>Voting commenced!<b> Please place your vote for one of: " ~
        "%-(<b>%s<b>, %)<b> (%s)";  // extra <b> needed outside of %-(%s, %)
    immutable message = pattern.format(poll.sortedChoices, timeInWords);
    chan(plugin.state, event.channel.name, message);
}


// getPollChoices
/++
    Sifts out unique choice words from a string.

    Params:
        plugin = The current [PollPlugin].
        channelName = The name of the channel the poll belongs to.
        slice = Mutable slice of the input.

    Returns:
        A Voldemort struct with members `choices` and `origChoiceNames` representing
        the choices found in the input string.
 +/
auto getPollChoices(
    PollPlugin plugin,
    const string channelName,
    const string slice)
{
    import lu.string : splitWithQuotes;
    import std.format : format;

    void sendChoiceMustNotStartWithPrefix()
    {
        enum pattern = `Poll choices may not start with the command prefix ("%s").`;
        immutable message = pattern.format(plugin.state.coreSettings.prefix);
        chan(plugin.state, channelName, message);
    }

    void sendDuplicateChoice(const string choice)
    {
        enum pattern = `Duplicate choice: "<b>%s<b>"`;
        immutable message = pattern.format(choice);
        chan(plugin.state, channelName, message);
    }

    static struct PollChoices
    {
        bool success;
        uint[string] choices;
        string[string] origChoiceNames;
    }

    PollChoices result;

    foreach (immutable rawChoice; splitWithQuotes(slice))
    {
        import lu.string : strippedRight;
        import std.algorithm.searching : startsWith;
        import std.uni : toLower;

        if (plugin.settings.forbidPrefixedChoices &&
            rawChoice.startsWith(plugin.state.coreSettings.prefix))
        {
            /*return*/ sendChoiceMustNotStartWithPrefix();
            return result;
        }

        // Strip any trailing commas, unless the choice is literally just commas
        // We can tell if the comma-stripped string is empty
        immutable strippedChoice = rawChoice.strippedRight(',');
        immutable choice = strippedChoice.length ?
            strippedChoice :
            rawChoice;

        if (!choice.length) continue;

        immutable lower = choice.toLower;
        if (lower in result.origChoiceNames)
        {
            /*return*/ sendDuplicateChoice(choice);
            return result;
        }

        result.origChoiceNames[lower] = choice;
        result.choices[lower] = 0;
    }

    result.success = true;
    return result;
}


// generatePollFiber
/++
    Implementation function for generating a poll fiber.

    Params:
        plugin = The current [PollPlugin].
        channelName = Name of the channel the poll belongs to.
        poll = The [Poll] to generate a fiber for.
 +/
void generatePollFiber(
    PollPlugin plugin,
    const string channelName,
    Poll poll)
{
    import kameloso.plugins.common.scheduling : await;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import std.format : format;
    import core.thread.fiber : Fiber;

    // Take into account people leaving or changing nicknames on non-Twitch servers
    // On Twitch NICKs and QUITs don't exist, and PARTs are unreliable.
    // ACCOUNTs also aren't a thing.
    static immutable IRCEvent.Type[4] nonTwitchVoteEventTypes =
    [
        IRCEvent.Type.NICK,
        IRCEvent.Type.PART,
        IRCEvent.Type.QUIT,
        IRCEvent.Type.ACCOUNT,
    ];

    void pollDg()
    {
        scope(exit)
        {
            import kameloso.plugins.common.scheduling : unawait;

            unawait(plugin, nonTwitchVoteEventTypes[]);
            unawait(plugin, IRCEvent.Type.CHAN);

            const currentPoll = channelName in plugin.channelPolls;
            if (currentPoll && (currentPoll.uniqueID == poll.uniqueID))
            {
                // Only remove it if it's the same poll as when the delegate started
                plugin.channelPolls.remove(channelName);
            }
        }

        while (true)
        {
            import kameloso.plugins.common : idOf;

            auto currentPoll = channelName in plugin.channelPolls;
            if (!currentPoll || (currentPoll.uniqueID != poll.uniqueID)) return;

            auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
            immutable thisEvent = thisFiber.payload;

            if (!thisEvent.sender.nickname.length) // == IRCEvent.init
            {
                // Invoked by timer, not by event
                // Should never happen now
                logger.error("Poll fiber invoked via delay");
                Fiber.yield();
                continue;
            }

            if (thisEvent.sender.class_ < plugin.settings.minimumPermissionsNeeded)
            {
                // User not authorised to vote. Yield and await a new event
                Fiber.yield();
                continue;
            }

            immutable id = idOf(thisEvent.sender);

            // Triggered by an event
            with (IRCEvent.Type)
            switch (thisEvent.type)
            {
            case NICK:
                if (auto previousVote = id in currentPoll.votes)
                {
                    immutable newID = idOf(thisEvent.target);

                    if (id != newID)
                    {
                        currentPoll.votes[newID] = *previousVote;
                        currentPoll.votes.remove(id);
                    }
                }
                break;

            case CHAN:
                import lu.string : stripped;
                import std.uni : toLower;

                if (thisEvent.channel.name != channelName) break;

                immutable vote = thisEvent.content.stripped.toLower;

                if (auto ballot = vote in currentPoll.voteCounts)
                {
                    if (auto previousVote = id in currentPoll.votes)
                    {
                        if (*previousVote != vote)
                        {
                            // User changed their mind
                            --currentPoll.voteCounts[*previousVote];
                            ++(*ballot);
                            currentPoll.votes[id] = vote;
                        }
                        else
                        {
                            // User is double-voting the same choice, ignore
                        }
                    }
                    else
                    {
                        // New user
                        // Valid entry, increment vote count
                        // Record user as having voted
                        ++(*ballot);
                        currentPoll.votes[id] = vote;
                    }
                }
                break;

            case ACCOUNT:
                if (!thisEvent.sender.account.length)
                {
                    // User logged out
                    // Old account is in aux[0]; move vote to nickname if necessary
                    if (thisEvent.aux[0] != thisEvent.sender.nickname)
                    {
                        if (const previousVote = thisEvent.aux[0] in currentPoll.votes)
                        {
                            currentPoll.votes[thisEvent.sender.nickname] = *previousVote;
                            currentPoll.votes.remove(thisEvent.aux[0]);
                        }
                    }
                }
                else if (thisEvent.sender.account != thisEvent.sender.nickname)
                {
                    if (const previousVote = thisEvent.sender.nickname in currentPoll.votes)
                    {
                        // Move the old entry to a new one with the account as key
                        currentPoll.votes[thisEvent.sender.account] = *previousVote;
                        currentPoll.votes.remove(thisEvent.sender.nickname);
                    }
                }
                break;

            case PART:
            case QUIT:
                if (plugin.settings.onlyOnlineUsersCount)
                {
                    if (auto previousVote = id in currentPoll.votes)
                    {
                        --currentPoll.voteCounts[*previousVote];
                        currentPoll.votes.remove(id);
                    }
                }
                break;

            default:
                assert(0, "Unexpected IRCEvent type seen in poll delegate");
            }

            // Yield and await a new event
            Fiber.yield();
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&pollDg, BufferSize.fiberStack);

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        await(plugin, fiber, nonTwitchVoteEventTypes[]);
    }

    await(plugin, fiber, IRCEvent.Type.CHAN);
}


// reportEndResults
/++
    Reports the result of a [Poll], as if it just ended.

    Params:
        plugin = The current [PollPlugin].
        channelName = Name of the channel the poll belongs to.
        poll = The [Poll] that just ended.
 +/
void reportEndResults(
    PollPlugin plugin,
    const string channelName,
    const Poll poll)
{
    import std.algorithm.iteration : sum;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.format : format;

    immutable total = cast(double)poll.voteCounts
        .byValue
        .sum;

    if (total == 0)
    {
        enum message = "Voting complete, no one voted.";
        return chan(plugin.state, channelName, message);
    }

    enum completeMessage = "Voting complete! Here are the results:";
    chan(plugin.state, channelName, completeMessage);

    auto sorted = poll.voteCounts
        .byKeyValue
        .array
        .sort!((a, b) => a.value < b.value);

    foreach (const result; sorted)
    {
        if (result.value == 0)
        {
            enum pattern = "<b>%s<b> : 0 votes";
            immutable message = pattern.format(poll.origChoiceNames[result.key]);
            chan(plugin.state, channelName, message);
        }
        else
        {
            import lu.string : plurality;

            immutable noun = result.value.plurality("vote", "votes");
            immutable double voteRatio = cast(double)result.value / total;
            immutable double votePercentage = 100 * voteRatio;

            enum pattern = "<b>%s<b> : %d %s (%.1f%%)";
            immutable message = pattern.format(
                poll.origChoiceNames[result.key],
                result.value,
                noun,
                votePercentage);
            chan(plugin.state, channelName, message);
        }
    }
}


// reportStatus
/++
    Reports the status of a [Poll], mid-progress.

    Params:
        plugin = The current [PollPlugin].
        channelName = The channel the poll belongs to.
        poll = The [Poll] that is still ongoing.
 +/
void reportStatus(
    PollPlugin plugin,
    const string channelName,
    const Poll poll)
{
    import kameloso.time : timeSince;
    import std.datetime.systime : Clock;
    import std.format : format;

    immutable delta = (poll.end - Clock.currTime);
    immutable timeInWords = delta.timeSince!(7, 0);

    enum pattern = "There is an ongoing poll! Place your vote for one of: %-(<b>%s<b>, %)<b> (%s)";
    immutable message = pattern.format(poll.sortedChoices, timeInWords);
    chan(plugin.state, channelName, message);
}


// generateVoteReminders
/++
    Generates some vote reminder fibers.

    Params:
        plugin = The current [PollPlugin].
        channelName = The channel the poll belongs to.
        poll = [Poll] to generate reminders for.
 +/
void generateVoteReminders(
    PollPlugin plugin,
    const string channelName,
    const Poll poll)
{
    import std.datetime.systime : Clock;
    import std.meta : AliasSeq;
    import core.time : Duration, days, hours, minutes, seconds;

    void reminderDg(const Duration reminderPoint)
    {
        import lu.string : plurality;
        import std.format : format;

        if (reminderPoint == Duration.zero) return;

        const currentPoll = channelName in plugin.channelPolls;
        if (!currentPoll || (currentPoll.uniqueID != poll.uniqueID)) return;  // Aborted or replaced

        enum pattern = "<b>%d<b> %s left to vote! (%-(<b>%s<b>, %)<b>)";
        immutable numSeconds = reminderPoint.total!"seconds";

        if ((numSeconds % (24*3600)) == 0)
        {
            // An even day
            immutable numDays = cast(int)(numSeconds / (24*3600));
            immutable message = pattern.format(
                numDays,
                numDays.plurality("day", "days"),
                poll.sortedChoices);
            chan(plugin.state, channelName, message);
        }
        else if ((numSeconds % 3600) == 0)
        {
            // An even hour
            immutable numHours = cast(int)(numSeconds / 3600);
            immutable message = pattern.format(
                numHours,
                numHours.plurality("hour", "hours"),
                poll.sortedChoices);
            chan(plugin.state, channelName, message);
        }
        else if ((numSeconds % 60) == 0)
        {
            // An even minute
            immutable numMinutes = cast(int)(numSeconds / 60);
            immutable message = pattern.format(
                numMinutes,
                numMinutes.plurality("minute", "minutes"),
                poll.sortedChoices);
            chan(plugin.state, channelName, message);
        }
        else
        {
            enum secondsPattern = "<b>%d<b> seconds! (%-(<b>%s<b>, %)<b>)";
            immutable message = secondsPattern.format(numSeconds, poll.sortedChoices);
            chan(plugin.state, channelName, message);
        }
    }

    // Warn about the poll ending at certain points, depending on how long the duration is.

    alias reminderPoints = AliasSeq!
        (7.days,
        3.days,
        2.days,
        1.days,
        12.hours,
        6.hours,
        3.hours,
        1.hours,
        30.minutes,
        10.minutes,
        5.minutes,
        2.minutes,
        30.seconds,
        10.seconds);

    immutable duration = (poll.end - poll.start);
    immutable remaining = (poll.end - Clock.currTime);

    foreach (immutable reminderPoint; reminderPoints)
    {
        if (duration >= (reminderPoint * 2))
        {
            immutable untilReminder = (remaining - reminderPoint);

            if (untilReminder > Duration.zero)
            {
                import kameloso.plugins.common.scheduling : delay;
                delay(plugin, (() => reminderDg(reminderPoint)), untilReminder);
            }
        }
    }
}


// generateEndFiber
/++
    Generates a fiber that ends a poll, reporting end results and cleaning up.

    Params:
        plugin = The current [PollPlugin].
        channelName = The channel the poll belongs to.
        poll = [Poll] to generate end fiber for.
 +/
void generateEndFiber(
    PollPlugin plugin,
    const string channelName,
    const Poll poll)
{
    import kameloso.plugins.common.scheduling : await, delay, unawait;
    import kameloso.thread : CarryingFiber;
    import kameloso.constants : BufferSize;
    import std.datetime.systime : Clock;
    import core.thread.fiber : Fiber;

    void endPollDg()
    {
        scope(exit) plugin.channelPolls.remove(channelName);

        const currentPoll = channelName in plugin.channelPolls;
        if (!currentPoll || (currentPoll.uniqueID != poll.uniqueID)) return;

        if (channelName in plugin.state.channels)
        {
            return reportEndResults(plugin, channelName, *currentPoll);
        }

        scope(exit) unawait(plugin, IRCEvent.Type.SELFJOIN);
        await(plugin, IRCEvent.Type.SELFJOIN, yield: true);

        while (true)
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            if (thisFiber.payload.channel.name == channelName)
            {
                return reportEndResults(plugin, channelName, *currentPoll);
            }

            Fiber.yield();
        }
    }

    Fiber endFiber = new CarryingFiber!IRCEvent(&endPollDg, BufferSize.fiberStack);
    immutable remaining = (poll.end - Clock.currTime);
    delay(plugin, endFiber, remaining);
}


// serialisePolls
/++
    Serialises ongoing [Poll]s to disk.
 +/
void serialisePolls(PollPlugin plugin)
{
    import asdf.serialization : serializeToJsonPretty;
    import std.stdio : File, writeln;

    if (!plugin.channelPolls.length) return;

    Poll.JSONSchema[string] json;

    foreach (immutable channelName, /*const*/ poll; plugin.channelPolls)
    {
        json[channelName] = poll.asSchema;
    }

    immutable serialised = json.serializeToJsonPretty!"    ";
    File(plugin.pollTempFile, "w").write(serialised);
}


// deserialisePolls
/++
    Deserialises [Poll]s from disk.
 +/
void deserialisePolls(PollPlugin plugin)
{
    import asdf.serialization : deserialize, serializeToJsonPretty;
    import std.file : readText;
    import std.stdio : File, writeln;

    auto polls = plugin.pollTempFile
        .readText
        .deserialize!(Poll.JSONSchema[string]);

    foreach (immutable channelName, /*const*/ schema; polls)
    {
        auto poll = Poll(schema);
        plugin.channelPolls[channelName] = poll;
        generatePollFiber(plugin, channelName, poll);
        generateVoteReminders(plugin, channelName, poll);
        generateEndFiber(plugin, channelName, poll);
    }
}


// onWelcome
/++
    Deserialises [Poll]s saved to disk upon successfully registering to the server,
    restoring any ongoing polls.

    The temporary file is removed immediately afterwards.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PollPlugin plugin, const IRCEvent _)
{
    import std.file : exists, remove;

    mixin(memoryCorruptionCheck);

    if (plugin.pollTempFile.exists)
    {
        deserialisePolls(plugin);
        remove(plugin.pollTempFile);
    }
}


// onSelfjoin
/++
    Registers a channel entry in
    [kameloso.plugins.IRCPluginState.channels|IRCPluginState.channels]
    upon joining one.

    This would normally be done using
    [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness], but we
    only need the channel registration and not the whole user tracking, so just
    copy/paste these bits.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
)
void onSelfjoin(PollPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.channel.name in plugin.state.channels) return;

    plugin.state.channels[event.channel.name] = IRCChannel.init;
    plugin.state.channels[event.channel.name].name = event.channel.name;
}


// onSelfpart
/++
    De-registers a channel entry in
    [kameloso.plugins.IRCPluginState.channels|IRCPluginState.channels]
    upon parting from one.

    This would normally be done using
    [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness], but we
    only need the channel registration and not the whole user tracking, so just
    copy/paste these bits.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFPART)
)
void onSelfpart(PollPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    plugin.state.channels.remove(event.channel.name);
}


// teardown
/++
    Tears down the [PollPlugin], serialising any ongoing [Poll]s to file, so they
    aren't lost to the ether.
 +/
void teardown(PollPlugin plugin)
{
    if (!plugin.channelPolls.length) return;
    serialisePolls(plugin);
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(PollPlugin _, Selftester s)
{
    s.send("poll");
    s.expect("Usage: ${prefix}poll [duration] [choice1] [choice2] ...");

    s.send("poll arf");
    s.expect("Need one duration and at least two choices.");

    s.send("poll arf urf hirf");
    s.expect("Malformed duration.");

    s.send("poll 5s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (5 seconds)");
    s.expect("Voting complete, no one voted.");

    s.send("poll 7 snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (7 seconds)");
    s.sendPlain("snek");

    s.expect("Voting complete! Here are the results:");
    s.expect("snik : 0 votes");
    s.expect("snek : 1 vote (100.0%)");

    s.send("poll 1h2m3s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik " ~
        "(1 hour, 2 minutes and 3 seconds)");

    s.send("poll end");
    s.expect("Voting complete, no one voted.");

    s.send("poll 1d23h59m59s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik " ~
        "(1 day, 23 hours, 59 minutes and 59 seconds)");

    s.send("poll abort");
    s.expect("Poll aborted.");

    s.send("poll abort");
    s.expect("There is no ongoing poll.");

    s.send("poll end");
    s.expect("There is no ongoing poll.");

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!PollPlugin;

public:


// PollPlugin
/++
    The Poll plugin offers the ability to hold votes/polls in a channel.
 +/
final class PollPlugin : IRCPlugin
{
private:
    /++
        All Poll plugin settings.
     +/
    PollSettings settings;

    /++
        Active polls by channel.
     +/
    Poll[string] channelPolls;

    /++
        Temporary file to store ongoing polls to, between connections
        (and executions of the program).
     +/
    @Resource pollTempFile = "polls.json";

    mixin IRCPluginImpl;
}

/++
    The Poll plugin offers the ability to hold votes/polls in a channel. Any
    number of choices is supported, as long as they're more than one.

    Cheating by changing nicknames is warded against.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#poll
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.poll;

version(WithPollPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.time : Duration;


// PollSettings
/++
    All Poll plugin runtime settings aggregated.
 +/
@Settings struct PollSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// Whether or not only votes placed by online users count.
    bool onlyOnlineUsersCount = true;

    /++
        Whether or not poll choices may start with the command prefix.

        There's no check in place that a prefixed choice won't conflict with a
        command, so make it opt-in at your own risk.
     +/
    bool forbidPrefixedChoices = true;

    /++
        Whether or not only users who have authenticated with services may vote.
     +/
    bool onlyRegisteredMayVote = false;
}


// Poll
/++
    Embodies the notion of a channel poll.
 +/
struct Poll
{
private:
    import std.datetime.systime : SysTime;

    /++
        Timestamp of when the poll was created.
     +/
    SysTime start;

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
    string[string] votes;

    /++
        Poll duration.
     +/
    Duration duration;

    /++
        Unique identifier to help Fibers know if the poll they belong to is stale
        or has been replaced.
     +/
    int uniqueID;
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
            .addSyntax("$command [duration] [choice1] [choice2] ...")
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
void onCommandPoll(PollPlugin plugin, const ref IRCEvent event)
{
    import kameloso.time : DurationStringException, abbreviatedDuration;
    import std.algorithm.searching : count;
    import std.conv : ConvException;

    void sendUsage()
    {
        if (event.sender.class_ < IRCUser.Class.operator)
        {
            enum message = "You are not authorised to start new polls.";
            chan(plugin.state, event.channel, message);
        }
        else
        {
            import std.format : format;

            enum pattern = "Usage: <b>%s%s<b> [duration] [choice1] [choice2] ...";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
            chan(plugin.state, event.channel, message);
        }
    }

    void sendNoOngoingPoll()
    {
        enum message = "There is no ongoing poll.";
        chan(plugin.state, event.channel, message);
    }

    const currentPoll = event.channel in plugin.channelPolls;

    switch (event.content)
    {
    case string.init:
        if (currentPoll)
        {
            goto case "status";
        }
        else
        {
            // Can't use a tertiary or it fails to build with older compilers
            // Error: variable operator used before set
            if (event.sender.class_ < IRCUser.Class.operator)
            {
                sendNoOngoingPoll();
            }
            else
            {
                sendUsage();
            }
        }

    case "status":
        if (!currentPoll) return sendNoOngoingPoll();
        return reportStatus(plugin, *currentPoll, event);

    case "abort":
        if (!currentPoll) return sendNoOngoingPoll();

        plugin.channelPolls.remove(event.channel);
        enum message = "Poll aborted.";
        return chan(plugin.state, event.channel, message);

    case "end":
        if (!currentPoll) return sendNoOngoingPoll();

        reportEndResults(plugin, *currentPoll, event);
        plugin.channelPolls.remove(event.channel);
        return;

    default:
        // Drop down
        break;
    }

    if (event.content.count(' ') < 2)
    {
        enum message = "Need one duration and at least two choices.";
        return chan(plugin.state, event.channel, message);
    }

    Poll poll;
    string slice = event.content;  // mutable

    try
    {
        import lu.string : nom;
        poll.duration = abbreviatedDuration(slice.nom!(Yes.decode)(' '));
    }
    catch (ConvException e)
    {
        enum message = "Malformed duration.";
        return chan(plugin.state, event.channel, message);
    }
    catch (DurationStringException e)
    {
        return chan(plugin.state, event.channel, e.msg);
    }
    catch (Exception e)
    {
        chan(plugin.state, event.channel, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        return;
    }

    if (poll.duration <= Duration.zero)
    {
        enum message = "Duration must not be negative.";
        return chan(plugin.state, event.channel, message);
    }

    auto choicesVoldemort = getPollChoices(plugin, event, slice);  // must be mutable
    if (!choicesVoldemort.success) return;

    if (choicesVoldemort.choices.length < 2)
    {
        enum message = "Need at least two unique poll choices.";
        return chan(plugin.state, event.channel, message);
    }

    poll.voteCounts = choicesVoldemort.choices;
    poll.origChoiceNames = choicesVoldemort.origChoiceNames;

    return pollImpl(
        plugin,
        event,
        poll);
}


// getPollChoices
/++
    Sifts out unique choice words from a string.

    Params:
        slice = Input string.

    Returns:
        A Voldemort struct with members `choices` and `origChoiceNames` representing
        the choices found in the input string.
 +/
auto getPollChoices(
    PollPlugin plugin,
    const ref IRCEvent event,
    const string slice)
{
    import std.algorithm.iteration : splitter;

    static struct PollChoices
    {
        bool success;
        uint[string] choices;
        string[string] origChoiceNames;
    }

    PollChoices result;

    foreach (immutable rawChoice; slice.splitter(' '))
    {
        import lu.string : beginsWith, strippedRight;
        import std.format : format;
        import std.uni : toLower;

        if (plugin.pollSettings.forbidPrefixedChoices && rawChoice.beginsWith(plugin.state.settings.prefix))
        {
            enum pattern = `Poll choices may not start with the command prefix ("%s").`;
            immutable message = pattern.format(plugin.state.settings.prefix);
            chan(plugin.state, event.channel, message);
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
            enum pattern = `Duplicate choice: "<b>%s<b>"`;
            immutable message = pattern.format(choice);
            chan(plugin.state, event.channel, message);
            return result;
        }

        result.origChoiceNames[lower] = choice;
        result.choices[lower] = 0;
    }

    result.success = true;
    return result;
}


// pollImpl
/++
    Implementation function for generating a poll Fiber.

    Params:
        plugin = The current [PollPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        dur = Vote/poll [core.time.Duration|Duration].
        choices = Associative array of vote tally by poll choice string key.
        origChoiceNames = Original names of the keys in `choices` before
            [std.uni.toLower|toLower] was called on them.
 +/
void pollImpl(
    PollPlugin plugin,
    const /*ref*/ IRCEvent event,
    Poll poll)
{
    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import kameloso.time : timeSince;
    import std.algorithm.sorting : sort;
    import std.datetime.systime : Clock;
    import std.format : format;
    import std.random : uniform;
    import core.thread : Fiber;

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
            import kameloso.plugins.common.delayawait : unawait;
            unawait(plugin, nonTwitchVoteEventTypes[]);
            unawait(plugin, IRCEvent.Type.CHAN);
            plugin.channelPolls.remove(event.channel);
        }

        while (true)
        {
            import kameloso.plugins.common.misc : idOf;

            auto currentPoll = event.channel in plugin.channelPolls;
            if (!currentPoll || (currentPoll.uniqueID != poll.uniqueID)) return;

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
            immutable thisEvent = thisFiber.payload;

            if (!thisEvent.sender.nickname.length) // == IRCEvent.init
            {
                // Invoked by timer, not by event
                // Should never happen now
                logger.error("Poll Fiber invoked via delay");
                Fiber.yield();
                continue;
            }

            if (plugin.pollSettings.onlyRegisteredMayVote &&
                (thisEvent.sender.class_ < IRCUser.Class.registered))
            {
                // User not authorised to vote. Yield and await a new event
                Fiber.yield();
                continue;
            }

            immutable id = idOf(thisEvent.sender);

            // Triggered by an event
            with (IRCEvent.Type)
            switch (event.type)
            {
            case NICK:
                if (auto previousVote = id in currentPoll.votes)
                {
                    immutable newID = idOf(thisEvent.target);
                    currentPoll.votes[newID] = *previousVote;
                    currentPoll.votes.remove(id);
                }
                break;

            case CHAN:
                import lu.string : contains, stripped;
                import std.uni : toLower;

                if (thisEvent.channel != event.channel) break;

                immutable vote = thisEvent.content.stripped;

                if (!vote.length || vote.contains!(Yes.decode)(' '))
                {
                    // Not a vote; drop down to yield and await a new event
                    break;
                }

                immutable lowerVote = vote.toLower;

                if (auto ballot = lowerVote in currentPoll.voteCounts)
                {
                    if (auto previousVote = id in currentPoll.votes)
                    {
                        if (*previousVote != lowerVote)
                        {
                            // User changed their mind
                            --currentPoll.voteCounts[*previousVote];
                            ++(*ballot);
                            currentPoll.votes[id] = lowerVote;
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
                        currentPoll.votes[id] = lowerVote;
                    }
                }
                break;

            case ACCOUNT:
                if (!thisEvent.sender.account.length)
                {
                    // User logged out
                    // Old account is in aux; move vote to nickname if necessary
                    if (thisEvent.aux != thisEvent.sender.nickname)
                    {
                        if (const previousVote = thisEvent.aux in currentPoll.votes)
                        {
                            currentPoll.votes[thisEvent.sender.nickname] = *previousVote;
                            currentPoll.votes.remove(thisEvent.aux);
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
                if (plugin.pollSettings.onlyOnlineUsersCount)
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

    void endPollDg()
    {
        scope(exit) plugin.channelPolls.remove(event.channel);

        const currentPoll = event.channel in plugin.channelPolls;
        if (!currentPoll || (currentPoll.uniqueID != poll.uniqueID)) return;
        reportEndResults(plugin, *currentPoll, event);
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&pollDg, BufferSize.fiberStack);
    Fiber endFiber = new Fiber(&endPollDg, BufferSize.fiberStack);

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        await(plugin, fiber, nonTwitchVoteEventTypes[]);
    }

    await(plugin, fiber, IRCEvent.Type.CHAN);
    delay(plugin, endFiber, poll.duration);

    poll.start = Clock.currTime;
    poll.uniqueID = uniform(1, 10_000);
    poll.sortedChoices = poll.voteCounts
        .keys
        .sort
        .release;
    plugin.channelPolls[event.channel] = poll;

    generateVoteReminders(plugin, event, poll);

    immutable timeInWords = poll.duration.timeSince!(7, 0);
    enum pattern = "<b>Voting commenced!<b> Please place your vote for one of: " ~
        "%-(<b>%s<b>, %)<b> (%s)";  // extra <b> needed outside of %-(%s, %)
    immutable message = pattern.format(poll.sortedChoices, timeInWords);
    chan(plugin.state, event.channel, message);
}


// reportEndResults
/++
    Reports the result of a [Poll], as if it just ended.

    Params:
        plugin = The current [PollPlugin].
        poll = The [Poll] that just ended.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
 +/
void reportEndResults(
    PollPlugin plugin,
    const Poll poll,
    const ref IRCEvent event)
{
    import std.algorithm.iteration : sum;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.format : format;

    immutable total = cast(double)poll.voteCounts.byValue.sum;

    if (total == 0)
    {
        enum message = "Voting complete, no one voted.";
        return chan(plugin.state, event.channel, message);
    }

    enum completeMessage = "Voting complete! Here are the results:";
    chan(plugin.state, event.channel, completeMessage);

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
            chan(plugin.state, event.channel, message);
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
            chan(plugin.state, event.channel, message);
        }
    }
}


// reportStatus
/++
    Reports the status of a [Poll], mid-progress.

    Params:
        plugin = The current [PollPlugin].
        poll = The [Poll] that is still ongoing.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
 +/
void reportStatus(
    PollPlugin plugin,
    const Poll poll,
    const ref IRCEvent event)
{
    import kameloso.time : timeSince;
    import std.datetime.systime : Clock;
    import std.format : format;

    immutable now = Clock.currTime;
    immutable end = (poll.start + poll.duration);
    immutable delta = (end - now);
    immutable timeInWords = delta.timeSince!(7,0);

    enum pattern = "There is an ongoing poll! Place your vote for one of: %-(<b>%s<b>, %)<b> (%s)";
    immutable message = pattern.format(poll.sortedChoices, timeInWords);
    chan(plugin.state, event.channel, message);
}


// generateVoteReminders
/++
    Generates some vote reminder Fibers.

    Params:
        plugin = The current [PollPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        uniqueID = Unique vote identifier, used as key in [PollPlugin.channelVoteInstances].
        dur = Vote/poll [core.time.Duration|Duration].
        sortedChoices = A sorted `string[]` list of all poll choices.
 +/
void generateVoteReminders(
    PollPlugin plugin,
    const /*ref*/ IRCEvent event,
    const Poll poll)
{
    import std.meta : AliasSeq;
    import core.time : days, hours, minutes, seconds;

    void reminderDg(const Duration reminderPoint)
    {
        import lu.string : plurality;
        import std.format : format;

        if (reminderPoint == Duration.zero) return;

        const currentPoll = event.channel in plugin.channelPolls;
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
            chan(plugin.state, event.channel, message);
        }
        else if ((numSeconds % 3600) == 0)
        {
            // An even hour
            immutable numHours = cast(int)(numSeconds / 3600);
            immutable message = pattern.format(
                numHours,
                numHours.plurality("hour", "hours"),
                poll.sortedChoices);
            chan(plugin.state, event.channel, message);
        }
        else if ((numSeconds % 60) == 0)
        {
            // An even minute
            immutable numMinutes = cast(int)(numSeconds / 60);
            immutable message = pattern.format(
                numMinutes,
                numMinutes.plurality("minute", "minutes"),
                poll.sortedChoices);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum secondsPattern = "<b>%d<b> seconds! (%-(<b>%s<b>, %)<b>)";
            immutable message = secondsPattern.format(numSeconds, poll.sortedChoices);
            chan(plugin.state, event.channel, message);
        }
    }

    // Warn about the poll ending at certain points, depending on how long the duration is.

    alias reminderPoints = AliasSeq!(
        7.days,
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
        10.seconds,
    );

    foreach (immutable reminderPoint; reminderPoints)
    {
        if (poll.duration >= (reminderPoint * 2))
        {
            import kameloso.plugins.common.delayawait : delay;
            immutable delta = (poll.duration - reminderPoint);
            delay(plugin, (() => reminderDg(reminderPoint)), delta);
        }
    }
}


mixin MinimalAuthentication;
mixin ModuleRegistration;

public:


// PollPlugin
/++
    The Vote plugin offers the ability to hold votes/polls in a channel.
 +/
final class PollPlugin : IRCPlugin
{
private:
    /// All Poll plugin settings.
    PollSettings pollSettings;

    /++
        Active polls by channel.
     +/
    Poll[string] channelPolls;

    mixin IRCPluginImpl;
}

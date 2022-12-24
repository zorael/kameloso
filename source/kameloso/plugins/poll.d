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

    if (!event.content.length)
    {
        import std.format : format;

        enum pattern = "Usage: %s%s [duration] [choice1] [choice2] ...";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        return chan(plugin.state, event.channel, message);
    }

    switch (event.content)
    {
    case "abort":
    case "stop":
        const currentPollInstance = event.channel in plugin.channelVoteInstances;

        if (currentPollInstance)
        {
            plugin.channelVoteInstances.remove(event.channel);
            chan(plugin.state, event.channel, "Poll aborted.");
        }
        else
        {
            chan(plugin.state, event.channel, "There is no ongoing poll.");
        }
        return;

    case "end":
        auto currentPollInstance = event.channel in plugin.channelVoteInstances;

        if (currentPollInstance)
        {
            // Signal that the poll should end early by giving the poll instance
            // a value of -1. Catch it later in the poll Fiber delegate.
            *currentPollInstance = PollPlugin.endPollEarlyMagicNumber;
        }
        else
        {
            chan(plugin.state, event.channel, "There is no ongoing poll.");
        }
        return;

    default:
        break;
    }

    if (event.channel in plugin.channelVoteInstances)
    {
        return chan(plugin.state, event.channel, "A poll is already in progress!");
    }

    if (event.content.count(' ') < 2)
    {
        return chan(plugin.state, event.channel, "Need one duration and at least two choices.");
    }

    Duration dur;
    string slice = event.content;  // mutable

    try
    {
        import lu.string : nom;
        dur = abbreviatedDuration(slice.nom!(Yes.decode)(' '));
    }
    catch (ConvException e)
    {
        return chan(plugin.state, event.channel, "Duration must be a positive number.");
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

    if (dur <= Duration.zero)
    {
        return chan(plugin.state, event.channel, "Duration must not be negative.");
    }

    auto choicesVoldemort = getPollChoices(plugin, event, slice);  // mutable

    if (!choicesVoldemort.success) return;

    if (choicesVoldemort.choices.length < 2)
    {
        return chan(plugin.state, event.channel, "Need at least two unique poll choices.");
    }

    return pollImpl(
        plugin,
        event,
        dur,
        choicesVoldemort.choices,
        choicesVoldemort.origChoiceNames);
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
auto getPollChoices(PollPlugin plugin, const ref IRCEvent event, const string slice)
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
            enum pattern = `Duplicate choice: "%s"`;
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
    const Duration dur,
    /*const*/ uint[string] choices,
    const string[string] origChoiceNames)
{
    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.plugins.common.misc : idOf;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import kameloso.time : timeSince;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import std.random : uniform;
    import core.thread : Fiber;

    /// Unique poll instance identifier
    immutable uniqueID = uniform(1, 10_000);

    void reportResults()
    {
        import std.algorithm.iteration : sum;
        import std.array : array;

        immutable total = cast(double)choices.byValue.sum;

        if (total == 0)
        {
            return chan(plugin.state, event.channel, "Voting complete, no one voted.");
        }

        chan(plugin.state, event.channel, "Voting complete, results:");

        auto sorted = choices
            .byKeyValue
            .array
            .sort!((a, b) => a.value < b.value);

        foreach (const result; sorted)
        {
            if (result.value == 0)
            {
                enum pattern = "<b>%s<b> : 0 votes";
                immutable message = pattern.format(origChoiceNames[result.key]);
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
                    origChoiceNames[result.key],
                    result.value,
                    noun,
                    votePercentage);
                chan(plugin.state, event.channel, message);
            }
        }
    }

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

    void cleanup()
    {
        import kameloso.plugins.common.delayawait : unawait;

        unawait(plugin, nonTwitchVoteEventTypes[]);
        unawait(plugin, IRCEvent.Type.CHAN);
        plugin.channelVoteInstances.remove(event.channel);
    }

    void pollDg()
    {
        scope(exit) cleanup();

        /// Which users have already voted.
        string[string] votedUsers;

        while (true)
        {
            const currentPollInstance = event.channel in plugin.channelVoteInstances;

            if (!currentPollInstance)
            {
                return;  // Aborted
            }
            else if (*currentPollInstance == PollPlugin.endPollEarlyMagicNumber)
            {
                // Magic number, end early
                return reportResults();
            }
            else if (*currentPollInstance != uniqueID)
            {
                return;  // Different poll started
            }

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
            immutable thisEvent = thisFiber.payload;

            if (thisEvent == IRCEvent.init)
            {
                // Invoked by timer, not by event
                return reportResults();  // End Fiber
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
                if (auto previousVote = id in votedUsers)
                {
                    immutable newID = idOf(thisEvent.target);
                    votedUsers[newID] = *previousVote;
                    votedUsers.remove(id);
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

                if (auto ballot = lowerVote in choices)
                {
                    if (auto previousVote = id in votedUsers)
                    {
                        if (*previousVote != lowerVote)
                        {
                            // User changed their mind
                            --choices[*previousVote];
                            ++(*ballot);
                            votedUsers[id] = lowerVote;
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
                        votedUsers[id] = lowerVote;
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
                        if (const previousVote = thisEvent.aux in votedUsers)
                        {
                            votedUsers[thisEvent.sender.nickname] = *previousVote;
                            votedUsers.remove(thisEvent.aux);
                        }
                    }
                }
                else if (thisEvent.sender.account != thisEvent.sender.nickname)
                {
                    if (const previousVote = thisEvent.sender.nickname in votedUsers)
                    {
                        // Move the old entry to a new one with the account as key
                        votedUsers[thisEvent.sender.account] = *previousVote;
                        votedUsers.remove(thisEvent.sender.nickname);
                    }
                }
                break;

            case PART:
            case QUIT:
                if (plugin.pollSettings.onlyOnlineUsersCount)
                {
                    if (auto previousVote = id in votedUsers)
                    {
                        --choices[*previousVote];
                        votedUsers.remove(id);
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
    delay(plugin, fiber, dur);
    plugin.channelVoteInstances[event.channel] = uniqueID;

    const sortedChoices = choices
        .keys
        .sort
        .release;

    generateVoteReminders(plugin, event, uniqueID, dur, sortedChoices);

    immutable timeInWords = dur.timeSince!(7, 0);
    enum pattern = "<b>Voting commenced!<b> Please place your vote for one of: " ~
        "%-(<b>%s<b>, %)<b> (%s)";  // extra <b> needed outside of %-(%s, %)
    immutable message = pattern.format(sortedChoices, timeInWords);
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
    const uint uniqueID,
    const Duration dur,
    const string[] sortedChoices)
{
    import std.meta : AliasSeq;
    import core.time : days, hours, minutes, seconds;

    void reminderDg(const Duration reminderPoint)
    {
        import lu.string : plurality;
        import std.format : format;

        if (reminderPoint == Duration.zero) return;

        const currentPollInstance = event.channel in plugin.channelVoteInstances;
        if (!currentPollInstance || (*currentPollInstance != uniqueID)) return;  // Aborted

        enum pattern = "<b>%d<b> %s left to vote! (%-(<b>%s<b>, %)<b>)";
        immutable numSeconds = reminderPoint.total!"seconds";

        if ((numSeconds % (24*3600)) == 0)
        {
            // An even day
            immutable numDays = cast(int)(numSeconds / (24*3600));
            immutable message = pattern.format(
                numDays,
                numDays.plurality("day", "days"),
                sortedChoices);
            chan(plugin.state, event.channel, message);
        }
        else if ((numSeconds % 3600) == 0)
        {
            // An even hour
            immutable numHours = cast(int)(numSeconds / 3600);
            immutable message = pattern.format(
                numHours,
                numHours.plurality("hour", "hours"),
                sortedChoices);
            chan(plugin.state, event.channel, message);
        }
        else if ((numSeconds % 60) == 0)
        {
            // An even minute
            immutable numMinutes = cast(int)(numSeconds / 60);
            immutable message = pattern.format(
                numMinutes,
                numMinutes.plurality("minute", "minutes"),
                sortedChoices);
            chan(plugin.state, event.channel, message);
        }
        else
        {
            enum secondsPattern = "<b>%d<b> seconds! (%-(<b>%s<b>, %)<b>)";
            immutable message = secondsPattern.format(numSeconds, sortedChoices);
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
        if (dur >= (reminderPoint * 2))
        {
            import kameloso.plugins.common.delayawait : delay;
            immutable delta = (dur - reminderPoint);
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

    /// Magic number to use to signal that a poll is to end.
    enum endPollEarlyMagicNumber = -1;

    /++
        An unique identifier for an ongoing channel poll, as set by
        [onCommandVote] and monitored inside its [core.thread.fiber.Fiber|Fiber]'s closures.
     +/
    int[string] channelVoteInstances;

    mixin IRCPluginImpl;
}

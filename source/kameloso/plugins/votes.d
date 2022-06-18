/++
    The Votes plugin offers the ability to hold votes/polls in a channel. Any
    number of choices is supported, as long as they're more than one.

    Cheating by changing nicknames is warded against.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#votes
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.votes;

version(WithVotesPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.common : expandTags, logger;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.time : Duration;


/++
    All Votes plugin runtime settings aggregated.
 +/
@Settings struct VotesSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// Whether or not only votes placed by online users count.
    bool onlyOnlineUsersCount = true;

    /++
        Whether or not vote choices may start with the command prefix.

        There's no check in place that a prefixed choice won't conflict with a
        command, so make it opt-in at your own risk.
     +/
    bool forbidPrefixedChoices = true;

    /++
        Whether or not only users who have authenticated with services may vote.
     +/
    bool onlyRegisteredMayVote = false;
}


// onCommandVote
/++
    Instigates a vote or stops an ongoing one.

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
            .description(`Starts or stops a vote. Pass "abort" to abort, or "end" to end early.`)
            .addSyntax("$command [duration] [choice1] [choice2] ...")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("vote")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandVote(VotesPlugin plugin, const ref IRCEvent event)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException;

    if (!event.content.length)
    {
        import std.format : format;

        enum pattern = "Usage: %s%s [duration] [choice1] [choice2] ...";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux);
        chan(plugin.state, event.channel, message);
        return;
    }

    switch (event.content)
    {
    case "abort":
    case "stop":
        const currentVoteInstance = event.channel in plugin.channelVoteInstances;

        if (currentVoteInstance)
        {
            plugin.channelVoteInstances.remove(event.channel);
            chan(plugin.state, event.channel, "Vote aborted.");
        }
        else
        {
            chan(plugin.state, event.channel, "There is no ongoing vote.");
        }
        return;

    case "end":
        auto currentVoteInstance = event.channel in plugin.channelVoteInstances;

        if (currentVoteInstance)
        {
            // Signal that the vote should end early by giving the vote instance
            // a value of -1. Catch it later in the vote Fiber delegate.
            *currentVoteInstance = VotesPlugin.endVoteEarlyMagicNumber;
        }
        else
        {
            chan(plugin.state, event.channel, "There is no ongoing vote.");
        }
        return;

    default:
        break;
    }

    if (event.channel in plugin.channelVoteInstances)
    {
        chan(plugin.state, event.channel, "A vote is already in progress!");
        return;
    }

    if (event.content.count(' ') < 2)
    {
        chan(plugin.state, event.channel, "Need one duration and at least two choices.");
        return;
    }

    Duration dur;
    string slice = event.content;

    try
    {
        import kameloso.common : abbreviatedDuration;
        import lu.string : nom;
        dur = abbreviatedDuration(slice.nom!(Yes.decode)(' '));
    }
    catch (ConvException e)
    {
        chan(plugin.state, event.channel, "Duration must be a positive number.");
        return;
    }
    catch (Exception e)
    {
        chan(plugin.state, event.channel, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        return;
    }

    if (dur <= Duration.zero)
    {
        chan(plugin.state, event.channel, "Duration must not be negative.");
        return;
    }

    /// Available vote choices and their vote counts.
    uint[string] voteChoices;

    /// What the choices were originally named before lowercasing.
    string[string] origChoiceNames;

    foreach (immutable rawChoice; slice.splitter(' '))
    {
        import lu.string : beginsWith, strippedRight;
        import std.format : format;
        import std.uni : toLower;

        if (plugin.votesSettings.forbidPrefixedChoices && rawChoice.beginsWith(plugin.state.settings.prefix))
        {
            enum pattern = `Vote choices may not start with the command prefix ("%s").`;
            immutable message = pattern.format(plugin.state.settings.prefix);
            chan(plugin.state, event.channel, message);
            return;
        }

        // Strip any trailing commas
        immutable choice = rawChoice.strippedRight(',');
        if (!choice.length) continue;
        immutable lower = choice.toLower;

        if (lower in origChoiceNames)
        {
            enum pattern = `Duplicate choice: "%s"`;
            immutable message = pattern.format(choice);
            chan(plugin.state, event.channel, message);
            return;
        }

        origChoiceNames[lower] = choice;
        voteChoices[lower] = 0;
    }

    if (voteChoices.length < 2)
    {
        chan(plugin.state, event.channel, "Need at least two unique vote choices.");
        return;
    }

    return voteImpl(plugin, event, dur, voteChoices, origChoiceNames);
}


// voteImpl
/++
    Implementation function for generating a vote Fiber.

    Params:
        plugin = The current [VotesPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        dur = Vote/poll [core.time.Duration|Duration].
        voteChoices = Associative array of vote tally by vote choice string key.
        origChoiceNames = Original names of the keys in `voteChoices` before
            [std.uni.toLower|toLower] was called on them.
 +/
void voteImpl(
    VotesPlugin plugin,
    const /*ref*/ IRCEvent event,
    const Duration dur,
    /*const*/ uint[string] voteChoices,
    const string[string] origChoiceNames)
{
    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.plugins.common.misc : idOf;
    import kameloso.common : timeSince;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import std.random : uniform;
    import core.thread : Fiber;

    /// Which users have already voted.
    bool[string] votedUsers;

    /// Unique vote instance identifier
    immutable id = uniform(1, 10_000);

    void reportResults()
    {
        import std.algorithm.iteration : sum;
        import std.array : array;

        immutable total = cast(double)voteChoices.byValue.sum;

        if (total == 0)
        {
            chan(plugin.state, event.channel, "Voting complete, no one voted.");
            return;
        }

        chan(plugin.state, event.channel, "Voting complete, results:");

        auto sorted = voteChoices
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
                immutable message = pattern.format(origChoiceNames[result.key], result.value, noun, votePercentage);
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

    void dg()
    {
        scope(exit) cleanup();

        while (true)
        {
            const currentVoteInstance = event.channel in plugin.channelVoteInstances;

            if (!currentVoteInstance)
            {
                return;  // Aborted
            }
            else if (*currentVoteInstance == VotesPlugin.endVoteEarlyMagicNumber)
            {
                // Magic number, end early
                reportResults();
                return;
            }
            else if (*currentVoteInstance != id)
            {
                return;  // Different vote started
            }

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
            immutable thisEvent = thisFiber.payload;

            if (thisEvent == IRCEvent.init)
            {
                // Invoked by timer, not by event
                reportResults();
                return;  // End Fiber
            }

            if (plugin.votesSettings.onlyRegisteredMayVote &&
                (thisEvent.sender.class_ < IRCUser.Class.registered))
            {
                // User not authorised to vote. Yield and await a new event
                Fiber.yield();
                continue;
            }

            immutable accountOrNickname = idOf(thisEvent.sender);

            // Triggered by an event
            with (IRCEvent.Type)
            switch (event.type)
            {
            case NICK:
                if (accountOrNickname in votedUsers)
                {
                    immutable newID = idOf(thisEvent.target);
                    votedUsers[newID] = true;
                    votedUsers.remove(accountOrNickname);
                }
                break;

            case CHAN:
                import lu.string : contains, stripped;
                import std.uni : toLower;

                if (thisEvent.channel != event.channel) break;

                immutable vote = thisEvent.content.stripped;

                if (!vote.length || vote.contains!(Yes.decode)(' '))
                {
                    // Not a vote; yield and await a new event
                }
                else if (accountOrNickname in votedUsers)
                {
                    // User already voted and we don't support revotes for now
                }
                else if (auto ballot = vote.toLower in voteChoices)
                {
                    // Valid entry, increment vote count
                    ++(*ballot);
                    votedUsers[accountOrNickname] = true;
                }
                break;

            case ACCOUNT:
                if (const oldEntry = thisEvent.sender.nickname in votedUsers)
                {
                    // Move the old entry to a new one with the account as key
                    votedUsers[thisEvent.sender.account] = *oldEntry;
                    votedUsers.remove(thisEvent.sender.nickname);
                }
                break;

            case PART:
            case QUIT:
                if (plugin.votesSettings.onlyOnlineUsersCount)
                {
                    votedUsers.remove(accountOrNickname);
                }
                break;

            default:
                assert(0, "Unexpected IRCEvent type seen in vote delegate");
            }

            // Yield and await a new event
            Fiber.yield();
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        await(plugin, fiber, nonTwitchVoteEventTypes[]);
    }

    await(plugin, fiber, IRCEvent.Type.CHAN);
    delay(plugin, fiber, dur);
    plugin.channelVoteInstances[event.channel] = id;

    const sortedChoices = voteChoices
        .keys
        .sort
        .release;

    generateVoteReminders(plugin, event, id, dur, sortedChoices);

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
        plugin = The current [VotesPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        id = Unique vote identifier, used as key in [VotesPlugin.channelVoteInstances].
        dur = Vote/poll [core.time.Duration|Duration].
        sortedChoices = A sorted `string[]` list of all vote choices.
 +/
void generateVoteReminders(
    VotesPlugin plugin,
    const /*ref*/ IRCEvent event,
    const uint id,
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

        const currentVoteInstance = event.channel in plugin.channelVoteInstances;
        if (!currentVoteInstance || (*currentVoteInstance != id)) return;  // Aborted

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

    // Warn about the vote ending at certain points, depending on how long the duration is.

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
            import kameloso.plugins.common.delayawait : await, delay;
            immutable delta = (dur - reminderPoint);
            delay(plugin, (() => reminderDg(reminderPoint)), delta);
        }
    }
}


mixin MinimalAuthentication;

public:


// VotesPlugin
/++
    The Vote plugin offers the ability to hold votes/polls in a channel.
 +/
final class VotesPlugin : IRCPlugin
{
private:
    /// All Votes plugin settings.
    VotesSettings votesSettings;

    /// Magic number to use to signal that a vote is to end.
    enum endVoteEarlyMagicNumber = -1;

    /++
        An unique identifier for an ongoing channel vote, as set by
        [onCommandVote] and monitored inside its [core.thread.fiber.Fiber|Fiber]'s closures.
     +/
    int[string] channelVoteInstances;

    mixin IRCPluginImpl;
}

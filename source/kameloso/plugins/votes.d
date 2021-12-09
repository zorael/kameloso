/++
    The Votes plugin offers the ability to hold votes/polls in a channel. Any
    number of choices is supported, as long as they're more than one.

    Cheating by changing nicknames is warded against.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#votes
        [kameloso.plugins.common.core]
        [kameloso.plugins.common.base]
 +/
module kameloso.plugins.votes;

version(WithPlugins):
version(WithVotesPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


/++
    All Votes plugin runtime settings aggregated.
 +/
@Settings struct VotesSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;
}


// onCommandVote
/++
    Instigates a vote or stops an ongoing one.

    If starting one a duration and two or more voting options have to be passed.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "poll")
@BotCommand(PrefixPolicy.prefixed, "vote", Yes.hidden)
@Description(`Starts or stops a vote. Pass "abort" to abort, or "end" to end early.`,
    "$command [seconds] [choice1] [choice2] ...")
void onCommandVote(VotesPlugin plugin, const /*ref*/ IRCEvent event)
{
    import lu.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;
    import core.thread : Fiber;

    if (event.content.length)
    {
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
                *currentVoteInstance = -1;
            }
            else
            {
                chan(plugin.state, event.channel, "There is no ongoing vote.");
            }
            return;

        default:
            break;
        }
    }

    if (event.channel in plugin.channelVoteInstances)
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
        //version(PrintStacktraces) logger.trace(e.info);
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

    foreach (immutable rawChoice; slice.splitter(' '))
    {
        import lu.string : strippedRight;

        // Strip any trailing commas
        immutable choice = rawChoice.strippedRight(',');
        if (!choice.length) continue;
        immutable lower = choice.toLower;

        origChoiceNames[lower] = choice;
        voteChoices[lower] = 0;
    }

    if (voteChoices.length < 2)
    {
        chan(plugin.state, event.channel, "Need at least two unique vote choices.");
        return;
    }

    import kameloso.thread : CarryingFiber;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.format : format;
    import std.random : uniform;

    /// Unique vote instance identifier
    immutable id = uniform(1, 10_000);

    void reportResults()
    {
        import std.algorithm.iteration : sum;

        immutable total = cast(double)voteChoices.byValue.sum;

        if (total > 0)
        {
            chan(plugin.state, event.channel, "Voting complete, results:");

            auto sorted = voteChoices
                .byKeyValue
                .array
                .sort!((a, b) => a.value < b.value);

            foreach (const result; sorted)
            {
                if (result.value == 0)
                {
                    chan(plugin.state, event.channel,
                        origChoiceNames[result.key] ~ " : 0 votes");
                }
                else
                {
                    import lu.string : plurality;

                    immutable noun = result.value.plurality("vote", "votes");
                    immutable double voteRatio = cast(double)result.value / total;
                    immutable double votePercentage = 100 * voteRatio;

                    chan(plugin.state, event.channel, "%s : %d %s (%.1f%%)"
                        .format(origChoiceNames[result.key], result.value, noun, votePercentage));
                }
            }
        }
        else
        {
            chan(plugin.state, event.channel, "Voting complete, no one voted.");
        }
    }

    // Take into account people leaving or changing nicknames on non-Twitch servers
    // On Twitch NICKs and QUITs don't exist, and PARTs are unreliable.
    static immutable IRCEvent.Type[3] nonTwitchVoteEventTypes =
    [
        IRCEvent.Type.NICK,
        IRCEvent.Type.PART,
        IRCEvent.Type.QUIT,
    ];

    void cleanup()
    {
        import kameloso.plugins.common.delayawait : unawait;

        if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
        {
            unawait(plugin, nonTwitchVoteEventTypes[]);
        }

        unawait(plugin, IRCEvent.Type.CHAN);
        plugin.channelVoteInstances.remove(event.channel);
    }

    void dg()
    {
        while (true)
        {
            const currentVoteInstance = event.channel in plugin.channelVoteInstances;

            if (!currentVoteInstance)
            {
                return;  // Aborted
            }
            else if (*currentVoteInstance == -1)
            {
                // Magic number, end early
                reportResults();
                cleanup();
                return;
            }
            else if (*currentVoteInstance != id)
            {
                return;  // Different vote started
            }

            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

            if (thisFiber.payload == IRCEvent.init)
            {
                // Invoked by timer, not by event
                reportResults();
                cleanup();
                return;  // End Fiber
            }

            // Triggered by an event
            with (IRCEvent.Type)
            switch (event.type)
            {
            case NICK:
                if (thisFiber.payload.sender.nickname in votedUsers)
                {
                    immutable newNickname = thisFiber.payload.target.nickname;
                    votedUsers[newNickname] = true;
                    votedUsers.remove(thisFiber.payload.sender.nickname);
                }
                break;

            case CHAN:
                if (thisFiber.payload.channel != event.channel) break;

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
                break;

            case PART:
            case QUIT:
                immutable nickname = thisFiber.payload.sender.nickname;
                votedUsers.remove(nickname);
                break;

            default:
                throw new Exception("Unexpected IRCEvent type seen in vote delegate");
            }

            // Yield and await a new event
            Fiber.yield();
        }
    }

    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.constants : BufferSize;
    import core.time : seconds;

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        await(plugin, fiber, nonTwitchVoteEventTypes[]);
    }

    await(plugin, fiber, IRCEvent.Type.CHAN);
    delay(plugin, fiber, dur.seconds);
    plugin.channelVoteInstances[event.channel] = id;

    const sortedChoices = voteChoices
        .keys
        .sort
        .release;

    void dgReminderImpl(const long time)
    {
        const currentVoteInstance = event.channel in plugin.channelVoteInstances;
        if (!currentVoteInstance || (*currentVoteInstance != id)) return;  // Aborted

        if ((time % 60) == 0)
        {
            import lu.string : plurality;

            // An even minute
            immutable minutes = cast(int)(time / 60);

            chan(plugin.state, event.channel, "%d %s! (%-(%s, %))"
                .format(minutes, minutes.plurality("minute", "minutes"), sortedChoices));
        }
        else
        {
            chan(plugin.state, event.channel, "%d seconds! (%-(%s, %))"
                .format(time, sortedChoices));
        }
    }

    // Warn once at 600 seconds if the vote was for at least 1200 seconds
    // also 600/300, 240/60, 60/30 and 20/10.

    if (dur >= 1200)
    {
        delay(plugin, (() => dgReminderImpl(600)), (dur-600).seconds);
    }

    if (dur >= 600)
    {
        delay(plugin, (() => dgReminderImpl(300)), (dur-300).seconds);
    }

    if (dur >= 240)
    {
        delay(plugin, (() => dgReminderImpl(180)), (dur-180).seconds);
    }

    if (dur >= 60)
    {
        delay(plugin, (() => dgReminderImpl(30)), (dur-30).seconds);
    }

    if (dur >= 20)
    {
        delay(plugin, (() => dgReminderImpl(10)), (dur-10).seconds);
    }

    chan(plugin.state, event.channel,
        "Voting commenced! Please place your vote for one of: %-(%s, %) (%d seconds)"
            .format(sortedChoices, dur));
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

    /++
        An unique identifier for an ongoing channel vote, as set by
        [onCommandVote] and monitored inside its [core.thread.fiber.Fiber]'s closures.
     +/
    int[string] channelVoteInstances;

    mixin IRCPluginImpl;
}

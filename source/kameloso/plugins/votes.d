/++
 +  The Votes plugin offers the ability to hold votes/polls in a channel. Any
 +  number of choices is supported, as long as they're more than one.
 +
 +  Cheating by changing nicknames is warded against.
 +/
module kameloso.plugins.votes;

version(WithPlugins):
version(WithVotesPlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;


/++
 +  All Votes plugin runtime settings aggregated.
 +/
@Settings struct VotesSettings
{
    /// Whether or not this plugin should react to any events.
    @Enabler bool enabled = true;

    /// Maximum allowed vote duration, in seconds.
    int maxVoteDuration = 600;
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
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "vote")
@BotCommand(PrefixPolicy.prefixed, "poll")
@Description("Starts a vote.", "$command [seconds] [choice1] [choice2] ...")
void onCommandStartVote(VotesPlugin plugin, const IRCEvent event)
do
{
    import lu.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;
    import std.typecons : Flag, No, Yes;
    import std.uni : toLower;
    import core.thread : Fiber;

    if (event.content == "abort")
    {
        // "!vote abort" command instead of "!abortvote"
        return plugin.onCommandAbortVote(event);
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
    else if (dur > plugin.votesSettings.maxVoteDuration)
    {
        import std.format : format;

        immutable message = "Votes are currently limited to a maximum duration of %d seconds."
            .format(plugin.votesSettings.maxVoteDuration);
        chan(plugin.state, event.channel, message);
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
        const currentVoteInstance = event.channel in plugin.channelVoteInstances;
        if (!currentVoteInstance || (*currentVoteInstance != id)) return;  // Aborted

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        if (thisFiber.payload != IRCEvent.init)
        {
            // Triggered by an event

            with (IRCEvent.Type)
            switch (event.type)
            {
            case NICK:
                immutable oldNickname = thisFiber.payload.sender.nickname;

                if (oldNickname in votedUsers)
                {
                    immutable newNickname = thisFiber.payload.target.nickname;
                    votedUsers[newNickname] = true;
                    votedUsers.remove(oldNickname);
                }
                break;

            case CHAN:
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

            default:
                throw new Exception("Unexpected IRCEvent type seen in vote delegate");
            }

            // Yield and await a new event
            Fiber.yield();
            return dg();
        }

        // Invoked by timer, not by event
        import std.algorithm.iteration : sum;
        import std.algorithm.sorting : sort;
        import std.array : array;

        immutable total = cast(double)voteChoices.byValue.sum;

        if (total > 0)
        {
            chan(plugin.state, event.channel, "Voting complete, results:");

            auto sorted = voteChoices
                .byKeyValue
                .array
                .sort!((a,b) => a.value < b.value);

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

        // Cleanup

        if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
        {
            plugin.unlistFiberAwaitingEvent(IRCEvent.Type.NICK);
        }

        plugin.unlistFiberAwaitingEvent(IRCEvent.Type.CHAN);
        plugin.channelVoteInstances.remove(event.channel);

        // End Fiber
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32768);

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
    {
        // Can't change nicknames on Twitch
        plugin.awaitEvent(fiber, IRCEvent.Type.NICK);
    }

    plugin.awaitEvent(fiber, IRCEvent.Type.CHAN);
    plugin.delayFiber(fiber, dur);
    plugin.channelVoteInstances[event.channel] = id;

    void dgReminder()
    {
        const currentVoteInstance = event.channel in plugin.channelVoteInstances;
        if (!currentVoteInstance || (*currentVoteInstance != id)) return;  // Aborted

        auto thisFiber = cast(CarryingFiber!int)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        chan(plugin.state, event.channel, "%d seconds! (%-(%s, %))"
            .format(thisFiber.payload, voteChoices.byKey));
    }

    // Warn once at 60 seconds if the vote was for at least 240 second
    // Warn once at 30 seconds if the vote was for at least 60 seconds
    // Warn once at 10 seconds if the vote was for at least 20 seconds

    if (dur >= 240)
    {
        auto reminder60 = new CarryingFiber!int(&dgReminder, 32768);
        reminder60.payload = 60;
        plugin.delayFiber(reminder60, dur-60);
    }

    if (dur >= 60)
    {
        auto reminder30 = new CarryingFiber!int(&dgReminder, 32768);
        reminder30.payload = 30;
        plugin.delayFiber(reminder30, dur-30);
    }

    if (dur >= 20)
    {
        auto reminder10 = new CarryingFiber!int(&dgReminder, 32768);
        reminder10.payload = 10;
        plugin.delayFiber(reminder10, dur-10);
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
 +  duration comes to a close. By removing the entry for the channel in
 +  `VotesPlugin.channelVoteInstances` we invalidate all such Fibers, which rely
 +  on that ID entry being present and equal to the ID they themselves have
 +  stored in their closures.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "abortvote")
@BotCommand(PrefixPolicy.prefixed, "abortpoll")
@Description("Aborts an ongoing vote.")
void onCommandAbortVote(VotesPlugin plugin, const IRCEvent event)
do
{
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
}


mixin MinimalAuthentication;

public:


// VotesPlugin
/++
 +  The Vote plugin offers the ability to hold votes/polls in a channel.
 +/
final class VotesPlugin : IRCPlugin
{
    /// All Votes plugin settings.
    VotesSettings votesSettings;

    /++
     +  An unique identifier for an ongoing channel vote, as set by
     +  `onCommandVote` and monitored inside its `core.thread.Fiber`'s closures.
     +/
    uint[string] channelVoteInstances;

    mixin IRCPluginImpl;
}

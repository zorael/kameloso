/++
 +  This is an example Twitch bot. It is largely untested and mostly just
 +  showcases how a Twitch plugin might be written.
 +
 +  One immediately obvious venue of expansion is expression bans, such as if a
 +  message has too many capital letters, contains banned words, etc.
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(TwitchBot):

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
    bool enabled = false;
}


// onCommandUptime
/++
 +  Reports how long the streamer has been streaming.
 +
 +  Technically, how much time has passed since `!start` was issued.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "uptime")
void onCommandUptime(TwitchBotPlugin plugin, const IRCEvent event)
{
    if (plugin.broadcastStart > 0)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock, SysTime;
        import std.format : format;

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;

        immutable delta = now - SysTime.fromUnixTime(plugin.broadcastStart);

        plugin.state.chan(event.channel, "%s has been streaming for %s."
            .format(event.channel, delta));
    }
    else
    {
        plugin.state.chan(event.channel, event.channel ~ " is currently not streaming.");
    }
}


// onCommandStart
/++
 +  Marks the start of a broadcast, for later uptime queries.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.ignore, "start")
void onCommandStart(TwitchBotPlugin plugin, const IRCEvent event)
{
    import std.datetime.systime : Clock;

    plugin.broadcastStart = Clock.currTime.toUnixTime;
    plugin.state.chan(event.channel, "Broadcast start registered.");
}


// onCommandStop
/++
 +  Marks the stop of a broadcast.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.ignore, "stop")
void onCommandStop(TwitchBotPlugin plugin, const IRCEvent event)
{
    plugin.broadcastStart = 0L;
    plugin.state.chan(event.channel, "Broadcast set as ended.");
}


// onOneliner
/++
 +  Responds to oneliners.
 +
 +  Responses are stored in `TwitchBotPlugin.oneliners`.
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
    immutable oneliner = slice.contains(" ") ? slice.nom(" ") : slice;

    if (const response = oneliner in plugin.oneliners)
    {
        plugin.state.chan(event.channel, *response);
    }
}


// onCommandStartVote
/++
 +  Instigates a vote. A duration and two or more voting options have to be passed.
 +
 +  Implemented as a `core.thread.Fiber`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "startvote")
void onCommandStartVote(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;

    if (plugin.votingUnderway)
    {
        plugin.state.chan(event.channel, "A vote is already in progress!");
        return;
    }

    if (event.content.count(' ') > 2)
    {
        plugin.state.chan(event.channel, "Need one duration and at least two options.");
        return;
    }

    long dur;
    string slice = event.content;

    try
    {
        dur = slice.nom(' ').to!long;
    }
    catch (const ConvException e)
    {
        plugin.state.chan(event.channel, "Duration must be a number.");
        return;
    }

    /// Available vote options and their vote counts.
    uint[string] voteChoices;

    /// Which users have already voted.
    bool[string] votedUsers;

    foreach (immutable choice; slice.splitter(" "))
    {
        voteChoices[choice] = 0;
    }

    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;
    import std.format : format;

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        if (thisFiber.payload == IRCEvent.init)
        {
            // Invoked by timer, not by event
            import std.algorithm.iteration : sum;
            import std.algorithm.sorting : sort;
            import std.array : array;

            plugin.state.chan(event.channel, "Voting complete, results:");

            immutable total = cast(double)voteChoices.byValue.sum;
            auto sorted = voteChoices.byKeyValue.array.sort!((a,b) => a.value < b.value);

            foreach (const result; sorted)
            {
                import kameloso.string : plurality;

                immutable noun = result.value.plurality("vote", "votes");

                plugin.state.chan(event.channel, "%s : %d %s (%.1f)"
                    .format(result.key, result.value, noun,
                    cast(double)(result.value/(result.value + total))));
            }

            plugin.votingUnderway = false;

            // End Fiber
            return;
        }

        // Triggered by an event
        immutable vote = thisFiber.payload.content;

        if (!vote.length || (vote.contains(" ")))
        {
            // Not a vote; yield and await a new event
            Fiber.yield();
            return dg();
        }

        if (thisFiber.payload.sender.nickname in votedUsers)
        {
            // User already voted
            Fiber.yield();
            return dg();
        }

        if (auto ballot = vote in voteChoices)
        {
            // Valid entry, increment vote count
            ++(*ballot);
            votedUsers[thisFiber.payload.sender.nickname] = true;
        }

        // Yield and await a new event
        Fiber.yield();
        return dg();
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg);

    plugin.awaitEvent(fiber, IRCEvent.Type.CHAN);
    plugin.delayFiber(fiber, dur);
    plugin.votingUnderway = true;

    plugin.state.chan(event.channel,
        "Voting commenced! Please place your vote for one of: %(%s, %)".format(voteChoices.keys));
}


// onCommandAddOneliner
/++
 +  Adds a oneliner to the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "oneliner")
void onCommandAddOneliner(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.typecons : No, Yes;

    if (!event.content.contains!(Yes.decode)(" "))
    {
        // Delete oneliner
        plugin.oneliners.remove(event.content);
        plugin.state.chan(event.channel, "Oneliner " ~ event.content ~ " removed.");
        return;
    }

    string slice = event.content;
    immutable word = slice.nom!(Yes.decode)(" ");
    plugin.oneliners[word] = slice;
    saveOneliners(plugin.oneliners, plugin.onelinerFile);

    plugin.state.chan(event.channel, "Oneliner " ~ word ~ " added.");
}


// onEndOfMotd
/++
 +  Populate the oneliners array after we have successfully logged onto the server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(TwitchBotPlugin plugin)
{
    plugin.populateOneliners();
}


// saveOneliners
/++
 +  Saves the passed oneliner associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +
 +  Params:
 +      oneliners = The associative array of oneliners to save.
 +      filename = Filename of the file to write to.
 +/
void saveOneliners(const string[string] oneliners, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(oneliners).toPrettyString);
}


// initResources
/++
 +  Reads and writes the file of oneliners to disk, ensuring that it's there.
 +/
void initResources(TwitchBotPlugin plugin)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.onelinerFile);
    }
    catch (const JSONException e)
    {
        import std.path : baseName;
        throw new IRCPluginInitialisationException(plugin.onelinerFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    json.save(plugin.onelinerFile);
}


// populateOneliners
/++
 +  Reads oneliners from disk, populating a `string[string]` associative array;
 +  `oneliner[trigger]`.
 +
 +  It is stored in JSON form, so we read it into a `JSONValue` and then iterate
 +  it to populate a normal associative array for faster lookups.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +/
void populateOneliners(TwitchBotPlugin plugin)
{
    import kameloso.json : JSONStorage;

    JSONStorage onelinersJSON;
    onelinersJSON.load(plugin.onelinerFile);
    plugin.oneliners = typeof(plugin.oneliners).init;

    foreach (immutable trigger, const stringJSON; onelinersJSON.object)
    {
        plugin.oneliners[trigger] = stringJSON.str;
    }
}


mixin UserAwareness;
mixin ChannelAwareness;
mixin TwitchAwareness;


public:


// TwitchBotPlugin
/++
 +  The Twitch plugin is an example of how a bot for Twitch servers may be written.
 +/
final class TwitchBotPlugin : IRCPlugin
{
    /// Flag for when voting is underway.
    bool votingUnderway;

    /// UNIX timestamp of when broadcasting started.
    long broadcastStart;

    /// An associative array of oneliners.
    string[string] oneliners;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "twitchliners.json";

    /// All Twitch plugin settings.
    @Settings TwitchBotSettings twitchBotSettings;

    mixin IRCPluginImpl;

    /++
     +  Override `IRCPluginImpl.onEvent` and inject a server check, so this
     +  plugin does nothing on non-Twitch servers. The function to call is
     +  `IRCPluginImpl.onEventImpl`.
     +
     +  Non-onEvent functions will still need server checks.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to pass onto `onEventImpl`
     +          after verifying we're on a Twitch server.
     +/
    void onEvent(const IRCEvent event)
    {
        if ((state.client.server.daemon != IRCServer.Daemon.unset) &&
            (state.client.server.daemon != IRCServer.Daemon.twitch))
        {
            // Daemon known and not Twitch
            return;
        }

        return onEventImpl(event);
    }
}

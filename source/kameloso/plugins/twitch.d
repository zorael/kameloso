/++
 +  This is an example Twitch plugin. It is largely untested and mostly just
 +  showcases how a Twitch plugin might be written. It is the product of a few
 +  hours of mostly brainstorming.
 +
 +  One immediately obvious venue of expansion is expression bans, such as if a
 +  message has too many capital letters, contains banned words, etc.
 +/
module kameloso.plugins.twitch;

version(WithPlugins):
version(TwitchSupport):
version(TwitchBot):

private:

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.messaging;
import kameloso.common : logger;


/// All Twitch plugin runtime settings.
struct TwitchSettings
{
    /// Whether or not this plugin should react to any events.
    bool enabled = false;

    /// String name of the owner of the bot (channel broadcaster).
    string owner = "The streamer";

    /// Character(s) we should expect oneliners to be prefixed with.
    string onelinerPrefix = "!";
}


// onCommandUptime
/++
 +  Reports how long the streamer has been streaming.
 +
 +  Technically, how much time has passed since `!start` was issued.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "uptime")
void onCommandUptime(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    if (plugin.broadcastStart > 0)
    {
        import std.datetime.systime : Clock;
        import std.format : format;

        immutable delta = Clock.currTime.toUnixTime - plugin.broadcastStart;
        plugin.state.chan(event.channel, "%s has been streaming for %s."
            .format(plugin.twitchSettings.owner, delta));
    }
    else
    {
        plugin.state.chan(event.channel, plugin.twitchSettings.owner ~
            " is currently not streaming.");
    }
}


// onCommandStart
/++
 +  Marks the start of a broadcast, for later uptime queries.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.ignore, "start")
void onCommandStart(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    import std.datetime.systime : Clock;

    plugin.broadcastStart = Clock.currTime.toUnixTime;
    plugin.state.query(event.sender.nickname, "Broadcast start registered.");
}


// onCommandStop
/++
 +  Marks the stop of a broadcast.
 +/
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.ignore, "stop")
void onCommandStop(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    import std.datetime.systime : Clock;

    plugin.broadcastStart = 0L;
    plugin.state.query(event.sender.nickname, "Broadcast set as ended.");
}


// onOneliner
/++
 +  Responds to oneliners.
 +
 +  Responses are stored in `TwitchPlugin.oneliners`.
 +/
@(Chainable)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onOneliner(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    import kameloso.string : beginsWith, nom;

    if (!event.content.beginsWith(plugin.twitchSettings.onelinerPrefix)) return;

    string slice = event.content;
    immutable oneliner = slice.nom(plugin.twitchSettings.onelinerPrefix);

    if (const response = oneliner in plugin.oneliners)
    {
        plugin.state.chan(event.channel, *response);
    }
}


// onCommandStartVote
/++
 +  Instigates a vote. A duration and two or more voting options have to be
 +  passed.
 +
 +  Implemented as a Fiber.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "startvote")
void onCommandStartVote(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    import kameloso.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;

    if (plugin.voting)
    {
        logger.warning("A vote is already in progress!");
        return;
    }

    if (event.content.count(' ') > 2)
    {
        logger.warning("Need one duration and at least two options");
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
        logger.warning("Duration must be a number");
        return;
    }

    /// Available vote options and their vote counts.
    uint[string] votes;

    /// Which users have already voted.
    bool[string] votedUsers;

    foreach (immutable option; slice.splitter(" "))
    {
        votes[option] = 0;
    }

    import kameloso.thread : CarryingFiber, ThreadMessage;
    import core.thread : Fiber;
    import std.format : format;

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        if (thisFiber.payload == IRCEvent.init)
        {
            // Invoked by timer, not by event
            import std.algorithm.sorting : sort;
            import std.array : array;

            plugin.state.chan(event.channel, "Voting complete, results:");

            auto sorted = votes.byKeyValue.array.sort!((a,b) => a.value < b.value);
            foreach (const result; sorted)
            {
                import kameloso.string : plurality;
                plugin.state.chan(event.channel, "%s : %d %s"
                    .format(result.key, result.value, result.value.plurality("vote", "votes")));
            }

            plugin.voting = false;

            // End Fiber
            return;
        }

        // Triggered by an event
        immutable vote = thisFiber.payload.content;

        if (!vote.length || (vote.count(" ") > 0))
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

        if (auto ballot = vote in votes)
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
    plugin.voting = true;

    plugin.state.chan(event.channel, "Voting commenced! Please place your vote for one of: "
        ~ "%(%s, %)".format(votes.keys));
}


// onCommandAddOneliner
/++
 +  Adds a oneliner to the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.direct, "oneliner")
void onCommandAddOneliner(TwitchPlugin plugin, const IRCEvent event)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    import kameloso.string : contains, nom;
    import std.typecons : Flag, No, Yes;

    if (!event.content.contains!(Yes.decode)(" "))
    {
        // Delete oneliner
        plugin.oneliners.remove(event.content);
        return;
    }

    string slice = event.content;
    immutable word = slice.nom!(Yes.decode)(" ");
    plugin.oneliners[word] = slice;
    saveOneliners(plugin.oneliners, plugin.onelinerFile);

    plugin.state.chan(event.channel, "Oneliner " ~ word ~ " added");
}


// onEndOfMotd
/++
 +  Populate the oneliners array after we have successfully logged onto the
 +  server.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(TwitchPlugin plugin)
{
    if (!plugin.twitchSettings.enabled) return;
    if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

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
    import std.stdio : File, write, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(oneliners).toPrettyString);
}


// teardown
/++
 +  When closing the program or when crashing with grace, saves the oneliners
 +  array to disk for later reloading.
 +/
void teardown(TwitchPlugin plugin)
{
    if (!plugin.twitchSettings.enabled) return;

    saveOneliners(plugin.oneliners, plugin.onelinerFile);
}


// initResources
/++
 +  Reads and writes the file of oneliners to disk, ensuring that it's there.
 +/
void initResources(TwitchPlugin plugin)
{
    if (!plugin.twitchSettings.enabled) return;

    import kameloso.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.onelinerFile);
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
 +      plugin = The current `TwitchPlugin`.
 +/
void populateOneliners(TwitchPlugin plugin)
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


// TwitchPlugin
/++
 +  The Twitch plugin is an example of how a plugin for Twitch servers may be
 +  written.
 +/
final class TwitchPlugin : IRCPlugin
{
    /// Flag for when voting is underway.
    bool voting;

    /// UNIX timestamp of when broadcasting started.
    long broadcastStart;

    /// An associative array of oneliners.
    string[string] oneliners;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "twitchliners.json";

    /// All Twitch plugin settings.
    @Settings TwitchSettings twitchSettings;

    mixin IRCPluginImpl;
}

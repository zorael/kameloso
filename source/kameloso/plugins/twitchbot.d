/++
 +  This is an example Twitch bot.
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

    /// Whether or not to bell on every message.
    bool bellOnMessage = false;
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
 +  This resets all that channel's state, except for oneliners.
 +/
@(IRCEvent.Type.SELFPART)
@(ChannelPolicy.home)
void onSelfpart(TwitchBotPlugin plugin, const IRCEvent event)
{
    plugin.activeChannels.remove(event.channel);
}


// onCommandUptime
/++
 +  Reports how long the streamer has been streaming.
 +
 +  Technically, how much time has passed since `!start` was issued. The streamer's
 +  name is assumed to be the same as the channel's.
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

    if (broadcastStart > 0)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock, SysTime;
        import std.format : format;

        // Remove fractional seconds from the current timestamp
        auto now = Clock.currTime;
        now.fracSecs = 0.msecs;

        immutable delta = now - SysTime.fromUnixTime(broadcastStart);

        plugin.state.chan(event.channel, "%s has been streaming for %s."
            .format(event.channel[1..$], delta));
    }
    else
    {
        plugin.state.chan(event.channel, event.channel[1..$] ~ " is currently not streaming.");
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
@BotCommand(PrefixPolicy.prefixed, "start")
@Description("Marks the start of a broadcast.")
void onCommandStart(TwitchBotPlugin plugin, const IRCEvent event)
{
    import std.datetime.systime : Clock;

    plugin.activeChannels[event.channel].broadcastStart = Clock.currTime.toUnixTime;
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
@BotCommand(PrefixPolicy.prefixed, "stop")
@Description("Marks the stop of a brodcast.")
void onCommandStop(TwitchBotPlugin plugin, const IRCEvent event)
{
    import core.time : msecs;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    auto channel = event.channel in plugin.activeChannels;
    auto now = Clock.currTime;
    now.fracSecs = 0.msecs;
    auto delta = now - SysTime.fromUnixTime(channel.broadcastStart);
    channel.broadcastStart = 0L;

    plugin.state.chan(event.channel, "Broadcast ended. You streamed for %s.".format(delta));
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

    if (const channelOneliners = event.channel in plugin.onelinersByChannel)
    {
        if (const response = oneliner in *channelOneliners)
        {
            plugin.state.chan(event.channel, *response);
        }
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
@BotCommand(PrefixPolicy.prefixed, "vote")
@BotCommand(PrefixPolicy.prefixed, "poll")
@Description("Starts a vote.", "$command [seconds] [choice1] [choice2] ...")
void onCommandStartVote(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : count;
    import std.conv : ConvException, to;

    auto channel = event.channel in plugin.activeChannels;

    if (channel.votingUnderway)
    {
        plugin.state.chan(event.channel, "A vote is already in progress!");
        return;
    }

    if (event.content.count(' ') < 2)
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
                immutable double voteRatio = cast(double)result.value / total;
                immutable double votePercentage = 100 * voteRatio;

                plugin.state.chan(event.channel, "%s : %d %s (%.1f%%)"
                    .format(result.key, result.value, noun, votePercentage));
            }

            channel.votingUnderway = false;

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
    channel.votingUnderway = true;

    plugin.state.chan(event.channel,
        "Voting commenced! Please place your vote for one of: %-(%s, %) (%d seconds)"
        .format(voteChoices.keys, dur));
}


// onCommandAddOneliner
/++
 +  Adds a oneliner to the list of oneliners, and saves it to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "oneliner")
@Description("Adds a oneliner command.", "$command [trigger] [text, if none then deletes the trigger]")
void onCommandAddOneliner(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.format : format;
    import std.typecons : No, Yes;

    if (!event.content.length)
    {
        plugin.state.chan(event.channel, "You must specify a trigger.");
        return;
    }
    else if (!event.content.contains!(Yes.decode)(" "))
    {
        // Delete oneliner
        plugin.onelinersByChannel[event.channel].remove(event.content);
        saveOneliners(plugin.onelinersByChannel, plugin.onelinerFile);
        plugin.state.chan(event.channel, "Oneliner %s%s removed."
            .format(settings.prefix, event.content));
        return;
    }

    string slice = event.content;
    immutable word = slice.nom!(Yes.decode)(" ");
    plugin.onelinersByChannel[event.channel][word] = slice;
    saveOneliners(plugin.onelinersByChannel, plugin.onelinerFile);

    plugin.state.chan(event.channel, "Oneliner %s%s added.".format(settings.prefix, word));
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

    if (const channelOneliners = event.channel in plugin.onelinersByChannel)
    {
        plugin.state.chan(event.channel, ("Available commands: %-(" ~ settings.prefix ~ "%s, %)")
            .format(channelOneliners.keys));
    }
    else
    {
        plugin.state.chan(event.channel, "There are no commands available right now.");
    }
}


// onCommandAddAdmin
/++
 +  Adds a nickname to be an administrator for the current channel (that this
 +  message was sent in).
 +
 +  Only one nickname at a time. Only the current channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "addadmin")
@Description("Adds a Twitch administrator to the current channel.")
void onCommandAddAdmin(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains;

    if (!event.content.length || event.content.contains(" "))
    {
        plugin.state.chan(event.channel, "You must specify one (1) nickname.");
        return;
    }

    if (auto adminArray = event.channel in plugin.adminsByChannel)
    {
        import std.algorithm.searching : canFind;

        if ((*adminArray).canFind(event.content))
        {
            plugin.state.chan(event.channel, event.content ~ " is already a bot administrator.");
            return;
        }
        else
        {
            *adminArray ~= event.content;
            // Drop down for report
        }
    }
    else
    {
        plugin.adminsByChannel[event.channel] ~= event.content;
        // Drop down for report
    }

    saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
    plugin.state.chan(event.channel, event.content ~ " is now an administrator.");

}


// onCommandDelAdmin
/++
 +  Removes a nickname from being an administrator for the current channel
 +  (that this message was sent in).
 +
 +  Only one nickname at a time. Only the current channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "deladmin")
@Description("Removes a Twitch administrator from the current channel.")
void onCommandDelAdmin(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains;

    if (!event.content.length || event.content.contains(" "))
    {
        plugin.state.chan(event.channel, "You must specify one (1) nickname.");
        return;
    }

    if (auto adminArray = event.channel in plugin.adminsByChannel)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable index = (*adminArray).countUntil(event.content);

        if (index != -1)
        {
            *adminArray = (*adminArray).remove!(SwapStrategy.unstable)(index);
            saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
            plugin.state.chan(event.channel, "Administrator removed.");
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
    plugin.populateOneliners(plugin.onelinerFile);
    plugin.populateAdmins(plugin.adminsFile);
}


// saveOneliners
/++
 +  Saves the passed oneliner associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +
 +  Params:
 +      onelinersByChannel = The associative array of oneliners to save.
 +      filename = Filename of the file to write to.
 +/
void saveOneliners(const string[string][string] onelinersByChannel, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(onelinersByChannel).toPrettyString);
}


// saveAdmins
/++
 +  Saves the passed admins associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +
 +  Params:
 +      adminsByChannel = The associative array of admins to save.
 +      filename = Filename of the file to write to.
 +/
void saveAdmins(const string[][string] adminsByChannel, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(adminsByChannel).toPrettyString);
}


// initResources
/++
 +  Reads and writes the file of oneliners to disk, ensuring that it's there.
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
    catch (const JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.onelinerFile.baseName ~ " may be malformed.");
    }

    JSONStorage adminsJSON;

    try
    {
        adminsJSON.load(plugin.adminsFile);
    }
    catch (const JSONException e)
    {
        throw new IRCPluginInitialisationException(plugin.adminsFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    onelinerJSON.save(plugin.onelinerFile);
    adminsJSON.save(plugin.adminsFile);
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
 +      filename = Filename of the file to read from.
 +/
void populateOneliners(TwitchBotPlugin plugin, const string filename)
{
    import kameloso.json : JSONStorage;

    JSONStorage channelOnelinerJSON;
    channelOnelinerJSON.load(filename);
    plugin.onelinersByChannel.clear();

    foreach (immutable channelName, const onelinersJSON; channelOnelinerJSON.object)
    {
        foreach (immutable trigger, const stringJSON; onelinersJSON.object)
        {
            plugin.onelinersByChannel[channelName][trigger] = stringJSON.str;
        }
    }

    plugin.onelinersByChannel.rehash();
}


// populateAdmins
/++
 +  Reads admins from disk, populating a `string[][string]` associative array;
 +  `nickname[][channel]`.
 +
 +  It is stored in JSON form, so we read it into a `JSONValue` and then iterate
 +  it to populate a normal associative array for faster lookups.
 +
 +  Params:
 +      plugin = The current `TwitchBotPlugin`.
 +      filename = Filename of the file to read from.
 +/
void populateAdmins(TwitchBotPlugin plugin, const string filename)
{
    import kameloso.json : JSONStorage;

    JSONStorage channelAdminsJSON;
    channelAdminsJSON.load(filename);
    plugin.adminsByChannel.clear();

    foreach (immutable channelName, const adminsJSON; channelAdminsJSON.object)
    {
        foreach (const nickname; adminsJSON.array)
        {
            plugin.adminsByChannel[channelName] ~= nickname.str;
        }
    }

    plugin.adminsByChannel.rehash();
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
    /// Contained state of a bot channel, so there can be several alongside each other.
    struct Channel
    {
        /// Flag for when voting is underway.
        bool votingUnderway;

        /// UNIX timestamp of when broadcasting started.
        long broadcastStart;
    }

    /// Array of active bot channels' state.
    Channel[string] activeChannels;

    /// Associative array of oneliners, keyed by channel name keyed by trigger word.
    string[string][string] onelinersByChannel;

    /// Filename of file with oneliners.
    @Resource string onelinerFile = "twitchliners.json";

    /// Associative array of admins, nickname array keyed by channel.
    string[][string] adminsByChannel;

    /// Filename of file with oneliners.
    @Resource string adminsFile = "twitchadmins.json";

    /// All Twitch plugin settings.
    @Settings TwitchBotSettings twitchBotSettings;

    mixin IRCPluginImpl;

    /++
     +  Override `IRCPluginImpl.allow` and inject a user check, so we can support
     +  channel-specific admins.
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
        case whitelist:
            return allowImpl(event, privilegeLevel);

        case admin:
            if (const channelAdmins = event.channel in adminsByChannel)
            {
                import std.algorithm.searching : canFind;

                return ((*channelAdmins).canFind(event.sender.nickname)) ?
                    FilterResult.pass : allowImpl(event, privilegeLevel);
            }
            else
            {
                return allowImpl(event, privilegeLevel);
            }
        }
    }

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

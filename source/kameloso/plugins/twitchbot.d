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
    @Enabler bool enabled = false;

    /// Whether or not to bell on every message.
    bool bellOnMessage = false;
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
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onAnyMessage(TwitchBotPlugin plugin)
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    if (!plugin.twitchBotSettings.bellOnMessage) return;

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

        plugin.state.chan(event.channel, "%s has been streaming for %s."
            .format(nickname, delta));
    }
    else
    {
        plugin.state.chan(event.channel, nickname ~ " is currently not streaming.");
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

        plugin.state.chan(event.channel, nickname ~ " is already streaming.");
        return;
    }

    channel.broadcastStart = Clock.currTime.toUnixTime;
    plugin.state.chan(event.channel, "Broadcast start registered!");
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
    auto now = Clock.currTime;
    now.fracSecs = 0.msecs;
    const delta = now - SysTime.fromUnixTime(channel.broadcastStart);
    channel.broadcastStart = 0L;

    string nickname = event.channel[1..$];

    if (const streamer = nickname in plugin.state.users)
    {
        if (streamer.alias_.length) nickname = streamer.alias_;
    }

    plugin.state.chan(event.channel, "Broadcast ended. %s's stream lasted %s."
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

    auto channel = event.channel in plugin.activeChannels;

    if (channel.votingUnderway)
    {
        plugin.state.chan(event.channel, "A vote is already in progress!");
        return;
    }

    if (event.content.count(" ") < 2)
    {
        plugin.state.chan(event.channel, "Need one duration and at least two options.");
        return;
    }

    long dur;
    string slice = event.content;

    try
    {
        dur = slice.nom!(Yes.decode)(" ").to!long;
    }
    catch (ConvException e)
    {
        plugin.state.chan(event.channel, "Duration must be a positive number.");
        return;
    }

    if (dur <= 0)
    {
        plugin.state.chan(event.channel, "Duration must be a positive number.");
        return;
    }

    /// Available vote options and their vote counts.
    uint[string] voteChoices;

    /// Which users have already voted.
    bool[string] votedUsers;

    foreach (immutable rawChoice; slice.splitter(" "))
    {
        import kameloso.string : strippedRight;

        // Strip any trailing commas
        immutable choice = rawChoice.strippedRight(',');
        if (!choice.length) continue;

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

            immutable total = cast(double)voteChoices.byValue.sum;

            if (total > 0)
            {
                plugin.state.chan(event.channel, "Voting complete, results:");

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
            }
            else
            {
                plugin.state.chan(event.channel, "Voting complete, no one voted.");
            }

            channel.votingUnderway = false;

            // End Fiber
            return;
        }

        // Triggered by an event
        immutable vote = thisFiber.payload.content;
        immutable nickname = thisFiber.payload.sender.nickname;

        if (!vote.length || (vote.contains(" ")))
        {
            // Not a vote; yield and await a new event
        }
        else if (nickname in votedUsers)
        {
            // User already voted and we don't support revotes for now
        }
        else if (auto ballot = vote in voteChoices)
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
    channel.votingUnderway = true;

    plugin.state.chan(event.channel,
        "Voting commenced! Please place your vote for one of: %-(%s, %) (%d seconds)"
        .format(voteChoices.keys, dur));
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
        plugin.state.chan(event.channel, "Usage: %s%s [add|del] [trigger] [text]"
            .format(settings.prefix, event.aux));
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit)(" ");

    switch (verb)
    {
    case "add":
        if (slice.contains(" "))
        {
            immutable trigger = slice.nom(" ");

            plugin.onelinersByChannel[event.channel][trigger] = slice;
            saveOneliners(plugin.onelinersByChannel, plugin.onelinerFile);

            plugin.state.chan(event.channel, "Oneliner %s%s added.".format(settings.prefix, trigger));
        }
        else
        {
            plugin.state.chan(event.channel, "Usage: %s%s add [trigger] [text]"
                .format(settings.prefix, event.aux));
        }
        return;

    case "del":
        if (slice.length)
        {
            plugin.onelinersByChannel[event.channel].remove(slice);
            saveOneliners(plugin.onelinersByChannel, plugin.onelinerFile);

            plugin.state.chan(event.channel, "Oneliner %s%s removed."
                .format(settings.prefix, slice));
        }
        else
        {
            plugin.state.chan(event.channel, "Usage: %s%s del [trigger]"
                .format(settings.prefix, event.aux));
        }
        return;

    default:
        plugin.state.chan(event.channel, "Usage: %s%s [add|del] [trigger] [text]"
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
        plugin.state.chan(event.channel, ("Available commands: %-(" ~ settings.prefix ~ "%s, %)")
            .format(channelOneliners.keys));
    }
    else
    {
        plugin.state.chan(event.channel, "There are no commands available right now.");
    }
}


// onCommandAdmin
/++
 +  Adds, lists and removes administrators from a channel.
 +
 +  * `!admin add nickname` adds `nickname` as an administrator.
 +  * `!admin del nickname` removes `nickname` as an administrator.
 +  * `!admin list` lists all administrators.
 +  * `!admin clear` clears all administrators.
 +
 +  Only one nickname at a time. Only the current channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "admin")
@Description("Adds or removes a Twitch administrator to/from the current channel.",
    "$command [add|del|list|clear] [nickname]")
void onCommandAdmin(TwitchBotPlugin plugin, const IRCEvent event)
{
    import kameloso.string : contains, nom;
    import std.algorithm.searching : count;
    import std.format : format;
    import std.uni : toLower;

    if (!event.content.length || (event.content.count(" ") > 1))
    {
        plugin.state.chan(event.channel, "Usage: %s%s [add|del|list|clear] [nickname]"
            .format(settings.prefix, event.aux));
        return;
    }

    string slice = event.content;
    immutable verb = slice.nom!(Yes.inherit)(" ");

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
                    plugin.state.chan(event.channel, slice ~ " is already a bot administrator.");
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

            saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
            plugin.state.chan(event.channel, slice ~ " is now an administrator.");
        }
        else
        {
            plugin.state.chan(event.channel, "Usage: %s%s [add] [nickname]"
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
                    saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
                    plugin.state.chan(event.channel, "Administrator removed.");
                }
            }
        }
        else
        {
            plugin.state.chan(event.channel, "Usage: %s%s [del] [nickname]"
                .format(settings.prefix, event.aux));
        }
        break;

    case "list":
        if (const adminList = event.channel in plugin.adminsByChannel)
        {
            import std.format : format;
            plugin.state.chan(event.channel, "Current administrators: %-(%s, %)"
                .format(*adminList));
        }
        else
        {
            plugin.state.chan(event.channel, "There are no administrators registered for this channel.");
        }
        break;

    case "clear":
        plugin.adminsByChannel.remove(event.channel);
        saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
        plugin.state.chan(event.channel, "Administrator list cleared.");
        break;

    default:
        plugin.state.chan(event.channel, "Usage: %s%s [add|del|list|clear] [nickname]"
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
            plugin.state.chan(event.channel, *response);
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
 +  Example:
 +  ---
 +  plugin.onelinersByChannel["#channel"]["adl"] = "I thought what I'd do " ~
 +      "was, I'd pretend I was one of those deaf-mutes.";
 +
 +  saveOneliners(plugin.onelinersByChannel, plugin.onelinerFile);
 +  ---
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
 +  Example:
 +  ---
 +  plugin.adminsByChannel["#channel"] ~= "kameloso";
 +  plugin.adminsByChannel["#channel"] ~= "hirrsteff";
 +
 +  saveAdmins(plugin.adminsByChannel, plugin.adminsFile);
 +  ---
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

    // Let other Exceptions pass.

    onelinerJSON.save(plugin.onelinerFile);
    adminsJSON.save(plugin.adminsFile);
}


// populateOneliners
/++
 +  Reads oneliners from disk, populating a `string[string][string]` associative
 +  array; `oneliner[trigger][channel]`.
 +
 +  It is stored in JSON form, so we read it into a `JSONValue` and then iterate
 +  it to populate a normal associative array for faster lookups.
 +
 +  Example:
 +  ---
 +  // Early after connect...
 +  plugin.populateOneliners(plugin.onelinerFile);
 +  plugin.populateAdmins(plugin.adminsFile);
 +  ---
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
 +  Example:
 +  ---
 +  // Early after connect...
 +  plugin.populateOneliners(plugin.onelinerFile);
 +  plugin.populateAdmins(plugin.adminsFile);
 +  ---
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
            import std.uni : toLower;
            plugin.adminsByChannel[channelName] ~= nickname.str.toLower;
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
 +  The Twitch Bot plugin is an example Twitch streamer bot. It contains some
 +  basic tools for streamers, and the audience thereof.
 +/
final class TwitchBotPlugin : IRCPlugin
{
private:
    /// Contained state of a channel, so that there can be several alongside each other.
    struct Channel
    {
        /// Flag for when voting is currently ongoing.
        bool votingUnderway;

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
     +  plugin does nothing on non-Twitch servers. The function to call is
     +  `IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to pass onto `onEventImpl`
     +          after verifying we're on a Twitch server.
     +/
    public void onEvent(const IRCEvent event)
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

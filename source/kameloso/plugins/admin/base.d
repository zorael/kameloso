/++
    The Admin plugin features bot commands which help with debugging the current
    state, like printing the current list of users, the
    current channels, the raw incoming strings from the server, and some other
    things along the same line.

    It also offers some less debug-y, more administrative functions, like adding
    and removing homes on-the-fly, whitelisting or de-whitelisting account
    names, adding/removing from the operator list, joining or leaving channels, and such.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#admin
        [kameloso.plugins.common.core]
        [kameloso.plugins.common.misc]
 +/
@("admin")
module kameloso.plugins.admin.base;

version(WithPlugins):
version(WithAdminPlugin):

private:

import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;

import kameloso.plugins.common.core;
import kameloso.plugins.common.misc : applyCustomSettings;
import kameloso.plugins.common.awareness;
import kameloso.common : Tint, logger;
import kameloso.constants : BufferSize;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.concurrency : send;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;


version(OmniscientAdmin)
{
    /++
        The [kameloso.plugins.common.core.ChannelPolicy] to mix in awareness with depending
        on whether version `OmniscientAdmin` is set or not.
     +/
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    enum omniscientChannelPolicy = ChannelPolicy.home;
}


// AdminSettings
/++
    All Admin plugin settings, gathered in a struct.
 +/
@Settings struct AdminSettings
{
private:
    import lu.uda : Unserialisable;

public:
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    @Unserialisable
    {
        /++
            Toggles whether [onAnyEvent] prints the raw strings of all incoming
            events or not.
         +/
        bool printRaw;

        /++
            Toggles whether [onAnyEvent] prints the raw bytes of the *contents*
            of events or not.
         +/
        bool printBytes;
    }
}


// onAnyEvent
/++
    Prints incoming events to the local terminal, in forms depending on
    which flags have been set with bot commands.

    If [AdminPlugin.printRaw] is set by way of invoking [onCommandPrintRaw],
    prints all incoming server strings.

    If [AdminPlugin.printBytes] is set by way of invoking [onCommandPrintBytes],
    prints all incoming server strings byte by byte.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ANY)
    .channelPolicy(ChannelPolicy.any)
    .chainable(true)
)
void onAnyEvent(AdminPlugin plugin, const ref IRCEvent event)
{
    return onAnyEventImpl(plugin, event);
}


// onCommandShowUser
/++
    Prints the details of one or more specific, supplied users to the local terminal.

    It basically prints the matching [dialect.defs.IRCUser].
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("user")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Prints out information about one or more " ~
                "specific users to the local terminal.")
            .syntax("$command [nickname] [nickname] ...")
    )
)
void onCommandShowUser(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandShowUserImpl(plugin, event);
}


// onCommandSave
/++
    Saves current configuration to disk.

    This saves all plugins' settings, not just this plugin's, effectively
    regenerating the configuration file.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("save")
            .policy(PrefixPolicy.nickname)
            .description("Saves current configuration to disk.")
    )
)
void onCommandSave(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    privmsg(plugin.state, event.channel, event.sender.nickname, "Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
    Prints out the current `users` array of the [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState] to the local terminal.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("users")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Prints out the current users array to the local terminal.")
    )
)
void onCommandShowUsers(AdminPlugin plugin)
{
    return onCommandShowUsersImpl(plugin);
}


// onCommandSudo
/++
    Sends supplied text to the server, verbatim.

    You need basic knowledge of IRC server strings to use this.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(omniscientChannelPolicy)
    .addCommand(
        IRCEventHandler.Command()
            .word("sudo")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Sends supplied text to the server, verbatim.")
            .syntax("$command [raw string]")
    )
)
void onCommandSudo(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandSudoImpl(plugin, event);
}


// onCommandQuit
/++
    Sends a [dialect.defs.IRCEvent.Type.QUIT] event to the server.

    If any extra text is following the "quit" command, it uses that as the quit
    reason. Otherwise it falls back to what is specified in the configuration file.
 +/

@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("quit")
            .policy(PrefixPolicy.nickname)
            .description("Send a QUIT event to the server and exits the program.")
            .syntax("$command [optional quit reason]")
    )
)
void onCommandQuit(AdminPlugin plugin, const ref IRCEvent event)
{
    quit(plugin.state, event.content);
}


// onCommandHome
/++
    Adds or removes channels to/from the list of currently active home channels, in the
    [kameloso.kameloso.IRCBot.homeChannels] array of the current [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState].

    Merely passes on execution to [addHome] and [delHome].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("home")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes a channel to/from the list of home channels.")
            .syntax("$command [add|del|list] [channel]")
    )
)
void onCommandHome(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, strippedRight;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [add|del|list] [channel]"
                .format(plugin.state.settings.prefix, event.aux));
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content.strippedRight;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        return plugin.addHome(event, slice);

    case "del":
        return plugin.delHome(event, slice);

    case "list":
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Current home channels: %-(%s, %)"
                .format(plugin.state.bot.homeChannels));
        return;

    default:
        return sendUsage();
    }
}


// addHome
/++
    Adds a channel to the list of currently active home channels, in the
    [kameloso.kameloso.IRCBot.homeChannels] array of the current [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState].

    Follows up with a [core.thread.fiber.Fiber] to verify that the channel was actually joined.

    Params:
        plugin = The current [AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent].
        rawChannel = The channel to be added, potentially in unstripped, cased form.
 +/
void addHome(AdminPlugin plugin, const ref IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to add a home but the channel string was empty")
{
    import kameloso.plugins.common.delayawait : await, unawait;
    import dialect.common : isValidChannel;
    import lu.string : stripped;
    import std.algorithm.searching : canFind, countUntil;
    import std.uni : toLower;

    immutable channelName = rawChannel.stripped.toLower;

    if (!channelName.isValidChannel(plugin.state.server))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid channel name.");
        return;
    }

    if (plugin.state.bot.homeChannels.canFind(channelName))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "We are already in that home channel.");
        return;
    }

    // We need to add it to the homeChannels array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    plugin.state.bot.homeChannels ~= channelName;
    plugin.state.botUpdated = true;
    privmsg(plugin.state, event.channel, event.sender.nickname, "Home added.");

    immutable existingChannelIndex = plugin.state.bot.guestChannels.countUntil(channelName);

    if (existingChannelIndex != -1)
    {
        import kameloso.thread : ThreadMessage, busMessage;
        import std.algorithm.mutation : SwapStrategy, remove;

        logger.info("We're already in this channel as a guest. Cycling.");

        // Make sure there are no duplicates between homes and channels.
        plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
            .remove!(SwapStrategy.unstable)(existingChannelIndex);

        return cycle(plugin, channelName);
    }

    join(plugin.state, channelName);

    // We have to follow up and see if we actually managed to join the channel
    // There are plenty ways for it to fail.

    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    static immutable IRCEvent.Type[13] joinTypes =
    [
        IRCEvent.Type.ERR_BANNEDFROMCHAN,
        IRCEvent.Type.ERR_INVITEONLYCHAN,
        IRCEvent.Type.ERR_BADCHANNAME,
        IRCEvent.Type.ERR_LINKCHANNEL,
        IRCEvent.Type.ERR_TOOMANYCHANNELS,
        IRCEvent.Type.ERR_FORBIDDENCHANNEL,
        IRCEvent.Type.ERR_CHANNELISFULL,
        IRCEvent.Type.ERR_BADCHANNELKEY,
        IRCEvent.Type.ERR_BADCHANNAME,
        IRCEvent.Type.RPL_BADCHANPASS,
        IRCEvent.Type.ERR_SECUREONLYCHAN,
        IRCEvent.Type.ERR_SSLONLYCHAN,
        IRCEvent.Type.SELFJOIN,
    ];

    void dg()
    {
        CarryingFiber!IRCEvent thisFiber;

        while (true)
        {
            thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');
            assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

            if (thisFiber.payload.channel == channelName) break;

            // Different channel; yield fiber, wait for another event
            Fiber.yield();
        }

        const followupEvent = thisFiber.payload;

        scope(exit) unawait(plugin, joinTypes[]);

        with (IRCEvent.Type)
        switch (followupEvent.type)
        {
        case SELFJOIN:
            // Success!
            // return so as to not drop down and undo the addition below.
            return;

        case ERR_LINKCHANNEL:
            // We were redirected. Still assume we wanted to add this one?
            logger.info("Redirected!");
            plugin.state.bot.homeChannels ~= followupEvent.content.toLower;  // note: content
            // Drop down and undo original addition
            break;

        default:
            privmsg(plugin.state, event.channel, event.sender.nickname, "Failed to join home channel.");
            break;
        }

        // Undo original addition
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable homeIndex = plugin.state.bot.homeChannels.countUntil(followupEvent.channel);

        if (homeIndex != -1)
        {
            plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
                .remove!(SwapStrategy.unstable)(homeIndex);
            plugin.state.botUpdated = true;
        }
        /*else
        {
            logger.error("Tried to remove non-existent home channel.");
        }*/
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);
    await(plugin, fiber, joinTypes);
}


// delHome
/++
    Removes a channel from the list of currently active home channels, from the
    [kameloso.kameloso.IRCBot.homeChannels] array of the current [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState].
 +/
void delHome(AdminPlugin plugin, const ref IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to delete a home but the channel string was empty")
{
    import lu.string : stripped;
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;
    import std.uni : toLower;

    immutable channelName = rawChannel.stripped.toLower;
    immutable homeIndex = plugin.state.bot.homeChannels.countUntil(channelName);

    if (homeIndex == -1)
    {
        import std.format : format;

        enum pattern = "Channel %s was not listed as a home.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(channelName.ircBold) :
            pattern.format(channelName);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }

    plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
        .remove!(SwapStrategy.unstable)(homeIndex);
    plugin.state.botUpdated = true;
    part(plugin.state, channelName);

    if (channelName != event.channel)
    {
        // We didn't just leave the channel, so we can report success
        // Otherwise we get ERR_CANNOTSENDTOCHAN
        privmsg(plugin.state, event.channel, event.sender.nickname, "Home removed.");
    }
}


// onCommandWhitelist
/++
    Adds a nickname to the list of users who may trigger the bot, to the current
    [dialect.defs.IRCClient.Class.whitelist] of the current [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState].

    This is on a [kameloso.plugins.common.core.Permissions.operator] level.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("whitelist")
            .policy(PrefixPolicy.prefixed)
            .description("Add or remove an account to/from the whitelist of users who may trigger the bot.")
            .syntax("$command [add|del] [account or nickname]")
    )
)
void onCommandWhitelist(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "whitelist");
}


// onCommandOperator
/++
    Adds a nickname or account to the list of users who may trigger lower-level
    functions of the bot, without being a full admin.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.staff)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("operator")
            .policy(PrefixPolicy.prefixed)
            .description("Add or remove an account to/from the operator list of operators/moderators.")
            .syntax("$command [add|del] [account or nickname]")
    )
)
void onCommandOperator(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "operator");
}


// onCommandStaff
/++
    Adds a nickname or account to the list of users who may trigger even lower level
    functions of the bot, without being a full admin. This roughly corresponds to
    channel owners.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("staff")
            .policy(PrefixPolicy.prefixed)
            .description("Add or remove an account to/from the staff list.")
            .syntax("$command [add|del] [account or nickname]")
    )
)
void onCommandStaff(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "staff");
}


// onCommandBlacklist
/++
    Adds a nickname to the list of users who may not trigger the bot whatsoever,
    except on actions annotated [kameloso.plugins.common.core.Permissions.ignore].

    This is on a [kameloso.plugins.common.core.Permissions.operator] level.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("blacklist")
            .policy(PrefixPolicy.prefixed)
            .description("Add or remove an account to/from the blacklist of " ~
                "people who may explicitly not trigger the bot.")
            .syntax("$command [add|del] [account or nickname]")
    )
)
void onCommandBlacklist(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "blacklist");
}


// onCommandReload
/++
    Asks plugins to reload their resources and/or configuration as they see fit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("reload")
            .policy(PrefixPolicy.nickname)
            .description("Asks plugins to reload their resources and/or configuration as they see fit.")
            .syntax("$command [optional plugin name]")
    )
)
void onCommandReload(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.conv : text;

    immutable message = event.content.length ?
        text("Reloading plugin \"", event.content, "\".") :
        "Reloading plugins.";

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
    plugin.state.mainThread.send(ThreadMessage.Reload(), event.content);
}


// onCommandPrintRaw
/++
    Toggles a flag to print all incoming events *raw*.

    This is for debugging purposes.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("printraw")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Toggles a flag to print all incoming events raw.")
    )
)
void onCommandPrintRaw(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandPrintRawImpl(plugin, event);
}


// onCommandPrintBytes
/++
    Toggles a flag to print all incoming events *as individual bytes*.

    This is for debugging purposes.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("printbytes")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Toggles a flag to print all incoming events as bytes.")
    )
)
void onCommandPrintBytes(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandPrintBytesImpl(plugin, event);
}


// onCommandJoin
/++
    Joins a supplied channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("join")
            .policy(PrefixPolicy.nickname)
            .description("Joins a guest channel.")
            .syntax("$command [channel]")
    )
)
void onCommandJoin(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : splitInto;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "No channels to join supplied...");
        return;
    }

    string slice = event.content;  // mutable
    string channel;
    string key;

    cast(void)slice.splitInto(channel, key);
    join(plugin.state, channel, key);
}


// onCommandPart
/++
    Parts a supplied channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("part")
            .policy(PrefixPolicy.nickname)
            .description("Parts a channel.")
            .syntax("$command [channel]")
    )
)
void onCommandPart(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : splitInto;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "No channels to part supplied...");
        return;
    }

    string slice = event.content;  // mutable
    string channel;
    string reason;

    cast(void)slice.splitInto(channel, reason);
    part(plugin.state, channel, reason);
}


// onSetCommand
/++
    Sets a plugin option by variable string name.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("set")
            .policy(PrefixPolicy.nickname)
            .description("Changes a plugin's settings.")
            .syntax("$command [plugin.setting=value]")
    )
)
void onSetCommand(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;

    void dg(bool success)
    {
        if (success)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, "Setting changed.");
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Invalid syntax or plugin/setting name.");
        }
    }

    plugin.state.mainThread.send(ThreadMessage.ChangeSetting(), cast(shared)&dg, event.content);
}


// onCommandAuth
/++
    Asks the [kameloso.plugins.connect.ConnectService] to (re-)authenticate to services.
 +/
version(WithConnectService)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("auth")
            .policy(PrefixPolicy.nickname)
            .description("(Re-)authenticates with services. Useful if the server " ~
                "has forcefully logged the bot out.")
    )
)
void onCommandAuth(AdminPlugin plugin)
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch) return;
    }

    import kameloso.thread : ThreadMessage, busMessage;
    import std.concurrency : send;

    plugin.state.mainThread.send(ThreadMessage.BusMessage(), "connect", busMessage("auth"));
}


// onCommandStatus
/++
    Dumps information about the current state of the bot to the local terminal.

    This can be very spammy.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("status")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Dumps information about the current state of the bot to the local terminal.")
    )
)
void onCommandStatus(AdminPlugin plugin)
{
    return onCommandStatusImpl(plugin);
}


// onCommandSummary
/++
    Causes a connection summary to be printed to the terminal.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("summary")
            .policy(PrefixPolicy.nickname)
            .description("Causes a connection summary to be printed to the terminal.")
    )
)
void onCommandSummary(AdminPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    plugin.state.mainThread.send(ThreadMessage.WantLiveSummary());
}


// onCommandCycle
/++
    Cycles (parts and immediately rejoins) a channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("cycle")
            .policy(PrefixPolicy.nickname)
            .description("Cycles (parts and rejoins) a channel.")
            .syntax("$command [optional channel] [optional delay] [optional key(s)]")
    )
)
void onCommandCycle(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom;
    import std.conv : ConvException, text, to;

    string slice = event.content;  // mutable

    if (!slice.length)
    {
        return cycle(plugin, event.channel);
    }

    immutable channelName = slice.nom!(Yes.inherit)(' ');

    if (channelName !in plugin.state.channels)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "I am not in that channel.");
        return;
    }

    if (!slice.length)
    {
        return cycle(plugin, channelName);
    }

    immutable delaystring = slice.nom!(Yes.inherit)(' ');

    try
    {
        immutable delay = delaystring.to!uint;
        return cycle(plugin, channelName, delay, slice);
    }
    catch (ConvException e)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            text(`"`, slice, `" is not a valid number for seconds to delay.`));
        return;
    }
}


// cycle
/++
    Implementation of cycling, called by [onCommandCycle]

    Params:
        plugin = The current [AdminPlugin].
        channelName = The name of the channel to cycle.
        delaySecs = Number of second to delay rejoining.
        key = The key to use when rejoining the channel.
 +/
void cycle(AdminPlugin plugin,
    const string channelName,
    const uint delaySecs = 0,
    const string key = string.init)
{
    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    void dg()
    {
        while (true)
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');
            assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

            const partEvent = thisFiber.payload;

            if (partEvent.channel == channelName)
            {
                void joinDg()
                {
                    join(plugin.state, channelName, key);
                }

                if (!delaySecs)
                {
                    return joinDg();
                }
                else
                {
                    import core.time : seconds;
                    return delay(plugin, &joinDg, delaySecs.seconds);
                }
            }

            // Wrong channel, wait for the next SELFPART
            Fiber.yield();
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);
    await(plugin, fiber, IRCEvent.Type.SELFPART);
    part(plugin.state, channelName, "Cycling");
}


// onCommandMask
/++
    Adds, removes or lists hostmasks used to identify users on servers that
    don't employ services.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("hostmask")
            .policy(PrefixPolicy.prefixed)
            .description("Modifies a hostmask definition, for use on servers without services accounts.")
            .syntax("$command [add|del|list] [account] [hostmask]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("mask")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandMask(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : SplitResults, contains, nom, splitInto;
    import std.format : format;

    if (!plugin.state.settings.preferHostmasks)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "This bot is not currently configured to use hostmasks for authentication.");
        return;
    }

    void sendUsage()
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [add|del|list] [args...]"
                .format(plugin.state.settings.prefix, event.aux));
    }

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        string account;
        string mask;

        immutable results = slice.splitInto(account, mask);

        if (results != SplitResults.match)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s add [account] [hostmask]"
                    .format(plugin.state.settings.prefix, event.aux));
            return;
        }

        return plugin.modifyHostmaskDefinition(Yes.add, account, mask, event);

    case "del":
    case "remove":
        if (!slice.length || slice.contains(' '))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Usage: %s%s del [hostmask]"
                    .format(plugin.state.settings.prefix, event.aux));
            return;
        }

        return plugin.modifyHostmaskDefinition(No.add, string.init, slice, event);

    case "list":
        return plugin.listHostmaskDefinitions(event);

    default:
        return sendUsage();
    }
}


// listHostmaskDefinitions
/++
    Lists existing hostmask definitions.

    Params:
        plugin = The current [AdminPlugin].
        event = The instigating [dialect.defs.IRCEvent].
 +/
void listHostmaskDefinitions(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    // Remove any placeholder examples
    enum examplePlaceholderKey = "<nickname>!<ident>@<address>";
    aa.remove(examplePlaceholderKey);

    if (aa.length)
    {
        if (event == IRCEvent.init)
        {
            import std.json : JSONValue;
            import std.stdio : writeln;

            logger.log("Current hostmasks:");
            // json can contain the example placeholder, so make a new one out of aa
            writeln(JSONValue(aa).toPrettyString);
        }
        else
        {
            import std.conv : text;
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Current hostmasks: " ~ aa.text.ircBold);
        }
    }
    else
    {
        enum message = "There are presently no hostmasks defined.";

        if (event == IRCEvent.init)
        {
            logger.info(message);
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
}


// onCommandBus
/++
    Sends an internal bus message to other plugins, much like how such can be
    sent with the Pipeline plugin.
 +/
debug
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("bus")
            .policy(PrefixPolicy.nickname)
            .description("[DEBUG] Sends an internal bus message.")
            .syntax("$command [header] [content...]")
    )
)
void onCommandBus(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandBusImpl(plugin, event.content);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.BusMessage] with the "`admin`" header,
    and calls functions based on the payload message.

    This is used in the Pipeline plugin, to allow us to trigger admin verbs via
    the command-line pipe.

    Params:
        plugin = The current [AdminPlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    if (header != "admin") return;

    // Don't return if disabled, as it blocks us from re-enabling with verb set

    import kameloso.printing : printObject;
    import kameloso.thread : BusMessage;
    import lu.string : contains, nom, strippedRight;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload.strippedRight;
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    debug
    {
        case "status":
            return plugin.onCommandStatus();

        case "users":
            return plugin.onCommandShowUsers();

        case "user":
            if (const user = slice in plugin.state.users)
            {
                printObject(*user);
            }
            else
            {
                logger.error("No such user: ", slice);
            }
            break;

        case "state":
            printObject(plugin.state);
            break;

        case "printraw":
            plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
            return;

        case "printbytes":
            plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
            return;
    }

    case "set":
        import kameloso.thread : ThreadMessage;

        void dg(bool success)
        {
            if (success) logger.log("Setting changed.");
        }

        return plugin.state.mainThread.send(ThreadMessage.ChangeSetting(), cast(shared)&dg, slice);

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.Save());

    case "reload":
        import kameloso.thread : ThreadMessage;

        if (slice.length)
        {
            logger.logf("Reloading plugin \"%s%s%s\".", Tint.info, slice, Tint.log);
        }
        else
        {
            logger.log("Reloading plugins.");
        }

        return plugin.state.mainThread.send(ThreadMessage.Reload(), slice);

    case "whitelist":
    case "operator":
    case "staff":
    case "blacklist":
        import lu.string : SplitResults, splitInto;

        string subverb;
        string channel;

        immutable results = slice.splitInto(subverb, channel);
        if (results == SplitResults.underrun)
        {
            // verb_channel_nickname
            logger.warningf("Invalid bus message syntax; expected %s " ~
                "[verb] [channel] [nickname if add/del], got \"%s\"",
                verb, message.payload.strippedRight);
            return;
        }

        switch (subverb)
        {
        case "add":
        case "del":
            immutable user = slice;

            if (!user.length)
            {
                logger.warning("Invalid bus message syntax; no user supplied, " ~
                    "only channel ", channel);
                return;
            }

            if (subverb == "add")
            {
                return plugin.lookupEnlist(user, subverb, channel);
            }
            else /*if (subverb == "del")*/
            {
                return plugin.delist(user, subverb, channel);
            }

        case "list":
            return plugin.listList(channel, verb);

        default:
            logger.warningf("Invalid bus message %s subverb: %s", verb, subverb);
            break;
        }
        break;

    case "hostmask":
        import lu.string : nom;

        immutable subverb = slice.nom!(Yes.inherit)(' ');

        switch (subverb)
        {
        case "add":
            import lu.string : SplitResults, splitInto;

            string account;
            string mask;

            immutable results = slice.splitInto(account, mask);
            if (results != SplitResults.match)
            {
                logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask add [account] [hostmask]");
                return;
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, Yes.add, account, mask, lvalueEvent);

        case "del":
        case "remove":
            if (!slice.length)
            {
                logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask del [hostmask]");
                return;
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, No.add, string.init, slice, lvalueEvent);

        case "list":
            IRCEvent lvalueEvent;
            return listHostmaskDefinitions(plugin, lvalueEvent);

        default:
            logger.warningf("Invalid bus message %s subverb: %s", verb, subverb);
            break;
        }
        break;

    case "summary":
        return plugin.onCommandSummary();

    default:
        logger.error("[admin] Unimplemented bus message verb: ", verb);
        break;
    }
}


mixin UserAwareness!omniscientChannelPolicy;
mixin ChannelAwareness!omniscientChannelPolicy;

version(TwitchSupport)
{
    mixin TwitchAwareness!omniscientChannelPolicy;
}


public:


// AdminPlugin
/++
    The Admin plugin is a plugin aimed for adḿinistrative use and debugging.

    It was historically part of the [kameloso.plugins.chatbot.ChatbotPlugin].
 +/
final class AdminPlugin : IRCPlugin
{
package:
    import kameloso.constants : KamelosoFilenames;

    /// All Admin options gathered.
    AdminSettings adminSettings;

    /// File with user definitions. Must be the same as in persistence.d.
    @Resource string userFile = KamelosoFilenames.users;

    /// File with hostmasks definitions. Must be the same as in persistence.d
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    mixin IRCPluginImpl;
}

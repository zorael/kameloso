/++
    The Admin plugin features bot commands which help with debugging the current
    state, like printing the current list of users, the
    current channels, the raw incoming strings from the server, and some other
    things along the same line.

    It also offers some less debug-y, more administrative functions, like adding
    and removing homes on-the-fly, whitelisting or de-whitelisting account
    names, adding/removing from the operator/staff lists, joining or leaving channels, and such.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#admin
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.admin.base;

version(WithAdminPlugin):

private:

import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.concurrency : send;
import std.typecons : Flag, No, Yes;
import core.time : Duration;


version(OmniscientAdmin)
{
    /++
        The [kameloso.plugins.common.core.ChannelPolicy|ChannelPolicy] to mix in
        awareness with depending on whether version `OmniscientAdmin` is set or not.
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
    if (plugin.state.settings.headless) return;
    onAnyEventImpl(plugin, event);
}


// onCommandShowUser
/++
    Prints the details of one or more specific, supplied users to the local terminal.

    It basically prints the matching [dialect.defs.IRCUser|IRCUsers].
 +/
debug
version(IncludeHeavyStuff)
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
            .addSyntax("$command [nickname] [nickname] ...")
    )
)
void onCommandShowUser(AdminPlugin plugin, const ref IRCEvent event)
{
    if (plugin.state.settings.headless) return;
    onCommandShowUserImpl(plugin, event);
}


// onCommandWhoami
/++
    Sends what we know of the inquiring user.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("whoami")
            .policy(PrefixPolicy.prefixed)
            .description("Replies with what we know of the inquiring user.")
    )
)
void onCommandWhoami(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.conv : Enum;
    import std.format : format;

    immutable account = event.sender.account.length ? event.sender.account : "*";
    string message;  // mutable

    if (event.channel.length)
    {
        enum pattern = "You are <h>%s<h>@<b>%s<b> (%s), class:<b>%s<b> in the scope of <b>%s<b>.";
        message = pattern.format(event.sender.nickname, account, event.sender.hostmask,
            Enum!(IRCUser.Class).toString(event.sender.class_), event.channel);
    }
    else
    {
        enum pattern = "You are <h>%s<h>@<b>%s<b> (%s), class:<b>%s<b> in a global scope.";
        message = pattern.format(event.sender.nickname, account, event.sender.hostmask,
            Enum!(IRCUser.Class).toString(event.sender.class_));
    }

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
            .description("Saves current configuration.")
    )
)
void onCommandSave(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    enum message = "Saving configuration to disk.";
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
    plugin.state.mainThread.send(ThreadMessage.save());
}


// onCommandShowUsers
/++
    Prints out the current `users` array of the [AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState|IRCPluginState] to the local terminal.
 +/
debug
version(IncludeHeavyStuff)
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
    if (plugin.state.settings.headless) return;
    onCommandShowUsersImpl(plugin);
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
            .addSyntax("$command [raw string]")
    )
)
void onCommandSudo(AdminPlugin plugin, const ref IRCEvent event)
{
    onCommandSudoImpl(plugin, event);
}


// onCommandQuit
/++
    Sends a [dialect.defs.IRCEvent.Type.QUIT|IRCEvent.Type.QUIT] event to the server.

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
            .description("Disconnects from the server and exits the program.")
            .addSyntax("$command [optional quit reason]")
    )
)
void onCommandQuit(AdminPlugin plugin, const ref IRCEvent event)
{
    quit(plugin.state, event.content);
}


// onCommandHome
/++
    Adds or removes channels to/from the list of currently active home channels,
    in the [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] array of
    the current [AdminPlugin]'s [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

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
            .addSyntax("$command add [channel]")
            .addSyntax("$command del [channel]")
            .addSyntax("$command list")
    )
)
void onCommandHome(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, strippedRight;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [channel]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
        enum pattern = "Current home channels: %-(<b>%s<b>, %)<b>";
        immutable message = pattern.format(plugin.state.bot.homeChannels);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);

    default:
        return sendUsage();
    }
}


// addHome
/++
    Adds a channel to the list of currently active home channels, in the
    [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] array of the
    current [AdminPlugin]'s [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

    Follows up with a [core.thread.fiber.Fiber|Fiber] to verify that the channel
    was actually joined.

    Params:
        plugin = The current [AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        rawChannel = The channel to be added, potentially in unstripped, cased form.
 +/
void addHome(AdminPlugin plugin, const /*ref*/ IRCEvent event, const string rawChannel)
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
        enum message = "Invalid channel name.";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    if (plugin.state.bot.homeChannels.canFind(channelName))
    {
        enum message = "We are already in that home channel.";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    // We need to add it to the homeChannels array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    plugin.state.bot.homeChannels ~= channelName;
    plugin.state.updates |= typeof(plugin.state.updates).bot;

    enum addedMessage = "Home added.";
    privmsg(plugin.state, event.channel, event.sender.nickname, addedMessage);

    immutable existingChannelIndex = plugin.state.bot.guestChannels.countUntil(channelName);

    if (existingChannelIndex != -1)
    {
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
            enum message = "Failed to join home channel.";
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
            plugin.state.updates |= typeof(plugin.state.updates).bot;
        }
        /*else
        {
            logger.error("Tried to remove non-existent home channel.");
        }*/
    }

    import kameloso.constants : BufferSize;

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, BufferSize.fiberStack);
    await(plugin, fiber, joinTypes);
}


// delHome
/++
    Removes a channel from the list of currently active home channels, from the
    [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] array of the
    current [AdminPlugin]'s [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].
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

        enum pattern = "Channel <b>%s<b> was not listed as a home.";
        immutable message = pattern.format(channelName);
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
        .remove!(SwapStrategy.unstable)(homeIndex);
    plugin.state.updates |= typeof(plugin.state.updates).bot;
    part(plugin.state, channelName);

    if (channelName != event.channel)
    {
        // We didn't just leave the channel, so we can report success
        // Otherwise we get ERR_CANNOTSENDTOCHAN
        enum message = "Home removed.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// onCommandWhitelist
/++
    Adds a nickname to the list of users who may trigger the bot, to the current
    [dialect.defs.IRCClient.Class.whitelist|IRCClient.Class.whitelist] of the
    current [AdminPlugin]'s [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

    This is on a [kameloso.plugins.common.core.Permissions.operator|Permissions.operator] level.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("whitelist")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes an account to/from the whitelist of users " ~
                "(in the current channel).")
            .addSyntax("$command add [account or nickname]")
            .addSyntax("$command del [account or nickname]")
            .addSyntax("$command list")
    )
)
void onCommandWhitelist(AdminPlugin plugin, const ref IRCEvent event)
{
    plugin.manageClassLists(event, "whitelist");
}


// onCommandElevated
/++
    Adds a nickname to the list of users who may trigger the bot, to the current
    list of [dialect.defs.IRCClient.Class.elevated|IRCClient.Class.elevated] users of the
    current [AdminPlugin]'s [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

    This is on a [kameloso.plugins.common.core.Permissions.operator|Permissions.operator] level.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("elevated")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes an account to/from the list of elevated users " ~
                "(in the current channel).")
            .addSyntax("$command add [account or nickname]")
            .addSyntax("$command del [account or nickname]")
            .addSyntax("$command list")
    )
)
void onCommandElevated(AdminPlugin plugin, const ref IRCEvent event)
{
    plugin.manageClassLists(event, "elevated");
}


// onCommandOperator
/++
    Adds a nickname or account to the list of users who may trigger lower-level
    functions of the bot, without being a full admin.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.staff)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("operator")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes an account to/from the operator list of " ~
                "operators/moderators (of the current channel).")
            .addSyntax("$command add [account or nickname]")
            .addSyntax("$command del [account or nickname]")
            .addSyntax("$command list")
    )
)
void onCommandOperator(AdminPlugin plugin, const ref IRCEvent event)
{
    plugin.manageClassLists(event, "operator");
}


// onCommandStaff
/++
    Adds a nickname or account to the list of users who may trigger even lower level
    functions of the bot, without being a full admin. This roughly corresponds to
    channel owners.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("staff")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes an account to/from the staff list (of the current channel).")
            .addSyntax("$command add [account or nickname]")
            .addSyntax("$command del [account or nickname]")
            .addSyntax("$command list")
    )
)
void onCommandStaff(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "staff");
}


// onCommandBlacklist
/++
    Adds a nickname to the list of users who may not trigger the bot whatsoever,
    except on actions annotated [kameloso.plugins.common.core.Permissions.ignore|Permissions.ignore].

    This is on a [kameloso.plugins.common.core.Permissions.operator|Permissions.operator] level.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.operator)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("blacklist")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes an account to/from the blacklist of " ~
                "people who may explicitly not trigger the bot (in the current channel).")
            .addSyntax("$command add [account or nickname]")
            .addSyntax("$command del [account or nickname]")
            .addSyntax("$command list")
    )
)
void onCommandBlacklist(AdminPlugin plugin, const ref IRCEvent event)
{
    plugin.manageClassLists(event, "blacklist");
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
            .addSyntax("$command [optional plugin name]")
    )
)
void onCommandReload(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.conv : text;

    immutable message = event.content.length ?
        text("Reloading plugin \"<b>", event.content, "<b>\".") :
        "Reloading plugins.";

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
    plugin.state.mainThread.send(ThreadMessage.reload(event.content));
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
    onCommandPrintRawImpl(plugin, event);
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
            .description("[debug] Toggles a flag to print all incoming events as individual bytes.")
    )
)
void onCommandPrintBytes(AdminPlugin plugin, const ref IRCEvent event)
{
    onCommandPrintBytesImpl(plugin, event);
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
            .addSyntax("$command [channel]")
    )
)
void onCommandJoin(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : splitInto, stripped;

    if (!event.content.length)
    {
        enum message = "No channels to join supplied...";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
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
            .addSyntax("$command [channel]")
    )
)
void onCommandPart(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : splitInto, stripped;

    if (!event.content.length)
    {
        enum message = "No channels to part supplied...";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
    string channel;
    string reason;

    cast(void)slice.splitInto(channel, reason);
    part(plugin.state, channel, reason);
}


// onCommandSet
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
            .description("Changes a setting of a plugin.")
            .addSyntax("$command [plugin].[setting]=[value]")
    )
)
void onCommandSet(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.thread : CarryingFiber;
    import kameloso.constants : BufferSize;
    import std.typecons : Tuple;
    import core.thread : Fiber;

    alias Payload = Tuple!(bool);

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis;
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        immutable message = thisFiber.payload[0] ?
            "Setting changed." :
            "Invalid syntax or plugin/setting name.";
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    auto fiber = new CarryingFiber!Payload(&dg, BufferSize.fiberStack);
    plugin.state.specialRequests ~= specialRequest!Payload(event.content, fiber);
}


// onCommandGet
/++
    Fetches a setting of a given plugin, or a list of all settings of a given plugin
    if no setting name supplied.

    Filename paths to certificate files and private keys will be visible to users
    of this, so be careful with what permissions should be required.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("get")
            .policy(PrefixPolicy.nickname)
            .description("Fetches a setting of a given plugin, " ~
                "or a list of all available settings of a given plugin.")
            .addSyntax("$command [plugin].[setting]")
            .addSyntax("$command [plugin]")
    )
)
void onCommandGet(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;
    import core.thread : Fiber;

    alias Payload = Tuple!(string, string, string);

    void dg()
    {
        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis;
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        immutable pluginName = thisFiber.payload[0];
        immutable setting = thisFiber.payload[1];
        immutable value = thisFiber.payload[2];

        if (!pluginName.length)
        {
            enum message = "Invalid plugin.";
            return privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        else if (setting.length)
        {
            import lu.string : contains;
            import std.format : format;

            immutable pattern = value.contains(' ') ?
                "%s.%s=\"%s\"" :
                "%s.%s=%s";
            immutable message = pattern.format(pluginName, setting, value);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        else if (value.length)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, value);
        }
        else
        {
            enum message = "Invalid setting.";
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }

    auto fiber = new CarryingFiber!Payload(&dg, BufferSize.fiberStack);
    plugin.state.specialRequests ~= specialRequest!Payload(event.content, fiber);
}


// onCommandAuth
/++
    Asks the [kameloso.plugins.services.connect.ConnectService|ConnectService] to
    (re-)authenticate to services.
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

    import kameloso.thread : ThreadMessage, boxed;
    import std.concurrency : send;

    plugin.state.mainThread.send(ThreadMessage.busMessage("connect", boxed("auth")));
}


// onCommandStatus
/++
    Dumps information about the current state of the bot to the local terminal.

    This can be very spammy.
 +/
debug
version(IncludeHeavyStuff)
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
    if (plugin.state.settings.headless) return;
    onCommandStatusImpl(plugin);
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
            .description("Prints a connection summary to the local terminal.")
    )
)
void onCommandSummary(AdminPlugin plugin)
{
    import kameloso.thread : ThreadMessage;

    if (plugin.state.settings.headless) return;
    plugin.state.mainThread.send(ThreadMessage.wantLiveSummary());
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
            .addSyntax("$command [optional channel] [optional delay] [optional key(s)]")
    )
)
void onCommandCycle(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.time : DurationStringException, abbreviatedDuration;
    import lu.string : nom, stripped;
    import std.conv : ConvException;

    string slice = event.content.stripped;  // mutable

    if (!slice.length)
    {
        return cycle(plugin, event.channel);
    }

    immutable channelName = slice.nom!(Yes.inherit)(' ');

    if (channelName !in plugin.state.channels)
    {
        enum message = "I am not in that channel.";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    if (!slice.length)
    {
        return cycle(plugin, channelName);
    }

    immutable delaystring = slice.nom!(Yes.inherit)(' ');

    try
    {
        immutable delay = abbreviatedDuration(delaystring);
        cycle(plugin, channelName, delay, slice);
    }
    catch (ConvException _)
    {
        import std.format : format;

        enum pattern = `"<b>%s<b>" is not a valid number for seconds to delay.`;
        immutable message = pattern.format(slice);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
    catch (DurationStringException e)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, e.msg);
    }
}


// cycle
/++
    Implementation of cycling, called by [onCommandCycle]

    Params:
        plugin = The current [AdminPlugin].
        channelName = The name of the channel to cycle.
        delay_ = [core.time.Duration|Duration] to delay rejoining.
        key = The key to use when rejoining the channel.
 +/
void cycle(
    AdminPlugin plugin,
    const string channelName,
    const Duration delay_ = Duration.zero,
    const string key = string.init)
{
    import kameloso.plugins.common.delayawait : await, delay, unawait;
    import kameloso.constants : BufferSize;
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

                if (delay_ == Duration.zero)
                {
                    return joinDg();
                }
                else
                {
                    import core.time : seconds;
                    return delay(plugin, &joinDg, delay_);
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
            .addSyntax("$command add [account] [hostmask]")
            .addSyntax("$command del [hostmask]")
            .addSyntax("$command list")
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
    import lu.string : SplitResults, contains, nom, splitInto, stripped;
    import std.format : format;

    if (!plugin.state.settings.preferHostmasks)
    {
        enum message = "This bot is not currently configured to use hostmasks for authentication.";
        return privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [args...]";
        immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        string account;
        string mask;

        immutable results = slice.splitInto(account, mask);

        if (results != SplitResults.match)
        {
            enum pattern = "Usage: <b>%s%s add<b> [account] [hostmask]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
            return privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }

        return plugin.modifyHostmaskDefinition(Yes.add, account, mask, event);

    case "del":
    case "remove":
        if (!slice.length || slice.contains(' '))
        {
            enum pattern = "Usage: <b>%s%s del<b> [hostmask]";
            immutable message = pattern.format(plugin.state.settings.prefix, event.aux[$-1]);
            return privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
        event = The instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void listHostmaskDefinitions(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage json;
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
            import std.stdio : stdout, writeln;

            if (plugin.state.settings.headless) return;

            logger.log("Current hostmasks:");
            // json can contain the example placeholder, so make a new one out of aa
            writeln(JSONValue(aa).toPrettyString);
            if (plugin.state.settings.flush) stdout.flush();
        }
        else
        {
            import std.format : format;

            enum pattern = "Current hostmasks: <b>%s<b>";
            immutable message = pattern.format(aa);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
            .description("[debug] Sends an internal bus message.")
            .addSyntax("$command [header] [content]")
    )
)
void onCommandBus(AdminPlugin plugin, const ref IRCEvent event)
{
    onCommandBusImpl(plugin, event.content);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.Boxed|Boxed] instance with the "`admin`"
    header, and calls functions based on the payload message.

    This is used in the Pipeline plugin, to allow us to trigger admin verbs via
    the command-line pipe.

    Params:
        plugin = The current [AdminPlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    import kameloso.thread : Boxed;
    import lu.string : contains, nom, strippedRight;

    // Don't return if disabled, as it blocks us from re-enabling with verb set
    if (header != "admin") return;

    auto message = cast(Boxed!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload.strippedRight;
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    debug
    {
        version(IncludeHeavyStuff)
        {
            import kameloso.printing : printObject;

            case "users":
                return plugin.onCommandShowUsers();

            case "status":
                return plugin.onCommandStatus();

            case "user":
                if (const user = slice in plugin.state.users)
                {
                    printObject(*user);
                }
                else
                {
                    logger.error("No such user: <l>", slice);
                }
                break;

            case "state":
                printObject(plugin.state);
                break;
        }

        case "printraw":
            plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
            return;

        case "printbytes":
            plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
            return;
    }

    case "set":
        import kameloso.constants : BufferSize;
        import kameloso.thread : CarryingFiber;
        import std.typecons : Tuple;
        import core.thread : Fiber;

        alias Payload = Tuple!(bool);

        void dg()
        {
            auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis;
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

            immutable success = thisFiber.payload[0];

            if (success)
            {
                logger.log("Setting changed.");
            }
            else
            {
                logger.error("Invalid syntax or plugin/setting name.");
            }
        }

        auto fiber = new CarryingFiber!Payload(&dg, BufferSize.fiberStack);
        plugin.state.specialRequests ~= specialRequest!Payload(slice, fiber);
        return;

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.save());

    case "reload":
        import kameloso.thread : ThreadMessage;

        if (slice.length)
        {
            enum pattern = `Reloading plugin "<i>%s</>".`;
            logger.logf(pattern, slice);
        }
        else
        {
            logger.log("Reloading plugins.");
        }

        return plugin.state.mainThread.send(ThreadMessage.reload(slice));

    case "whitelist":
    case "elevated":
    case "operator":
    case "staff":
    case "blacklist":
        import lu.string : SplitResults, splitInto;

        string subverb;
        string channelName;

        immutable results = slice.splitInto(subverb, channelName);
        if (results == SplitResults.underrun)
        {
            // verb_channel_nickname
            enum pattern = "Invalid bus message syntax; expected <l>%s</> " ~
                "[verb] [channel] [nickname if add/del], got \"<l>%s</>\"";
            return logger.warningf(pattern, verb, message.payload.strippedRight);
        }

        switch (subverb)
        {
        case "add":
        case "del":
            immutable user = slice;

            if (!user.length)
            {
                return logger.warning("Invalid bus message syntax; no user supplied, " ~
                    "only channel <l>", channelName);
            }

            if (subverb == "add")
            {
                return plugin.lookupEnlist(user, verb, channelName);
            }
            else /*if (subverb == "del")*/
            {
                return plugin.delist(user, verb, channelName);
            }

        case "list":
            return plugin.listList(channelName, verb);

        default:
            enum pattern = "Invalid bus message <l>%s</> subverb <l>%s";
            logger.warningf(pattern, verb, subverb);
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
                return logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask add [account] [hostmask]");
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, Yes.add, account, mask, lvalueEvent);

        case "del":
        case "remove":
            if (!slice.length)
            {
                return logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask del [hostmask]");
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, No.add, string.init, slice, lvalueEvent);

        case "list":
            IRCEvent lvalueEvent;
            return listHostmaskDefinitions(plugin, lvalueEvent);

        default:
            enum pattern = "Invalid bus message <l>%s</> subverb <l>%s";
            logger.warningf(pattern, verb, subverb);
            break;
        }
        break;

    case "summary":
        return plugin.onCommandSummary();

    default:
        enum pattern = "[admin] Unimplemented bus message verb: <l>%s";
        logger.errorf(pattern, verb);
        break;
    }
}


mixin UserAwareness!omniscientChannelPolicy;
mixin ChannelAwareness!omniscientChannelPolicy;
mixin PluginRegistration!(AdminPlugin, -4.priority);

version(TwitchSupport)
{
    mixin TwitchAwareness!omniscientChannelPolicy;
}

public:


// AdminPlugin
/++
    The Admin plugin is a plugin aimed for administrative use and debugging.

    It was historically part of the [kameloso.plugins.chatbot.ChatbotPlugin|ChatbotPlugin].
 +/
final class AdminPlugin : IRCPlugin
{
package:
    import kameloso.constants : KamelosoFilenames;

    /// All Admin options gathered.
    AdminSettings adminSettings;

    /// File with user definitions. Must be the same as in `persistence.d`.
    @Resource string userFile = KamelosoFilenames.users;

    /// File with hostmasks definitions. Must be the same as in `persistence.d`.
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    mixin IRCPluginImpl;
}

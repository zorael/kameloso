/++
    The Admin plugin features bot commands which help with debugging the current
    state, like printing the current list of users, the
    current channels, the raw incoming strings from the server, and some other
    things along the same line.

    It also offers some less debug-y, more administrative functions, like adding
    and removing homes on-the-fly, whitelisting or de-whitelisting account
    names, adding/removing from the operator/staff lists, joining or leaving channels, and such.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#admin,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.admin;

version(WithAdminPlugin):
debug version = Debug;

private:

import kameloso.plugins.admin.classifiers;
version(Debug) import kameloso.plugins.admin.debugging;

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import kameloso.common : logger;
import kameloso.messaging;
import kameloso.thread : Sendable;
import dialect.defs;
import core.thread.fiber : Fiber;
import core.time : Duration;


version(OmniscientAdmin)
{
    /++
        The [kameloso.plugins.ChannelPolicy|ChannelPolicy] to mix in
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
    /++
        Toggles whether or not the plugin should react to events at all.
     +/
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

        /++
            A list of what [dialect.defs.IRCEvent.Type|IRCEvent.Type]s to
            prettyprint, using [kameloso.prettyprint.prettyprint].
         +/
        string printEvents;
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
version(Debug)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ANY)
    .channelPolicy(ChannelPolicy.any)
    .chainable(true)
)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    if (plugin.state.coreSettings.headless) return;
    onAnyEventImpl(plugin, event);
}


// onCommandShowUser
/++
    Prints the details of one or more specific, supplied users to the local terminal.

    It basically prints the matching [dialect.defs.IRCUser|IRCUsers].
 +/
version(Debug)
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
void onCommandShowUser(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (plugin.state.coreSettings.headless) return;
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
void onCommandWhoami(AdminPlugin plugin, const IRCEvent event)
{
    import lu.conv : toString;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    immutable account = event.sender.account.length ? event.sender.account : "*";
    string message;  // mutable

    if (event.channel.name.length)
    {
        enum pattern = "You are <h>%s<h>@<b>%s<b> (%s), class:<b>%s<b> in the scope of <b>%s<b>.";
        message = pattern.format(
            event.sender.nickname,
            account,
            event.sender.hostmask,
            event.sender.class_.toString,
            event.channel.name);
    }
    else
    {
        enum pattern = "You are <h>%s<h>@<b>%s<b> (%s), class:<b>%s<b> in a global scope.";
        message = pattern.format(
            event.sender.nickname,
            account,
            event.sender.hostmask,
            event.sender.class_.toString);
    }

    privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
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
void onCommandSave(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    mixin(memoryCorruptionCheck);

    enum message = "Saving configuration to disk.";
    privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    plugin.state.messages ~= ThreadMessage.save;
}


// onCommandShowUsers
/++
    Prints out the current `users` array of the [AdminPlugin]'s
    [kameloso.plugins.IRCPluginState|IRCPluginState] to the local terminal.
 +/
version(Debug)
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
void onCommandShowUsers(AdminPlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);

    if (plugin.state.coreSettings.headless) return;
    onCommandShowUsersImpl(plugin);
}


// onCommandSudo
/++
    Sends supplied text to the server, verbatim.

    You need basic knowledge of IRC server strings to use this.
 +/
version(Debug)
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
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
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
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    quit(plugin.state, event.content);
}


// onCommandHome
/++
    Adds or removes channels to/from the list of currently active home channels,
    in the [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] array of
    the current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState].

    Merely passes on execution to [addChannel] and [delChannel] with `addAsHome: true`
    (and `delFromHomes: true`) as argument.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
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
void onCommandHome(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, strippedRight;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [channel]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content.strippedRight;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "add":
        return addChannel(plugin, event, slice, addAsHome: true);

    case "del":
        return delChannel(plugin, event, slice, delFromHomes: true);

    case "list":
        enum pattern = "Current home channels: %-(<b>%s<b>, %)<b>";
        immutable message = pattern.format(plugin.state.bot.homeChannels);
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);

    default:
        return sendUsage();
    }
}


// onCommandGuest
/++
    Adds or removes channels to/from the list of currently active guest channels,
    in the [kameloso.pods.IRCBot.guestChannels|IRCBot.guestChannels] array of
    the current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState].

    Merely passes on execution to [addChannel] and [delChannel] with `addAsHome: false`
    (and `delFromHomes: false`) as argument.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("guest")
            .policy(PrefixPolicy.prefixed)
            .description("Adds or removes a channel to/from the list of guest channels.")
            .addSyntax("$command add [channel]")
            .addSyntax("$command del [channel]")
            .addSyntax("$command list")
    )
)
void onCommandGuest(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : advancePast, strippedRight;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [channel]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (!event.content.length) return sendUsage();

    string slice = event.content.strippedRight;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "add":
        return addChannel(plugin, event, slice, addAsHome: false);

    case "del":
        return delChannel(plugin, event, slice, delFromHomes: false);

    case "list":
        enum pattern = "Current guest channels: %-(<b>%s<b>, %)<b>";
        immutable message = pattern.format(plugin.state.bot.homeChannels);
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);

    default:
        return sendUsage();
    }
}


// addChannel
/++
    Adds a channel to the list of currently active home or guest channels, to the
    [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] and
    [kameloso.pods.IRCBot.guestChannels|IRCBot.guestChannels] arrays of the
    current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState],
    respectively.

    Follows up with a [core.thread.fiber.Fiber|Fiber] to verify that the channel
    was actually joined.

    Params:
        plugin = The current [AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        rawChannel = The channel to be added, potentially in unstripped, cased form.
        addAsHome = Whether to add the channel as a home or guest channel.
 +/
void addChannel(
    AdminPlugin plugin,
    const IRCEvent event,
    const string rawChannel,
    const bool addAsHome)
in (Fiber.getThis(), "Tried to call `addChannel` from outside a fiber")
in (rawChannel.length, "Tried to add a home but the channel string was empty")
{
    import kameloso.plugins.common.scheduling : await, unawait;
    import kameloso.thread : CarryingFiber;
    import dialect.common : isValidChannel;
    import lu.string : stripped;
    import std.algorithm.searching : canFind, countUntil;
    import std.uni : toLower;

    void sendWeAreAlreadyInChannel()
    {
        immutable message = addAsHome ?
            "We are already in that home channel." :
            "We are already in that guest channel.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    void sendChannelIsAlreadyAHome()
    {
        immutable message = "That channel is already a home channel.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    immutable channelName = rawChannel.stripped.toLower();
    if (!channelName.isValidChannel(plugin.state.server))
    {
        enum message = "Invalid channel name.";
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    immutable channelIsHome = plugin.state.bot.homeChannels.canFind(channelName);
    immutable channelIsGuest = plugin.state.bot.guestChannels.canFind(channelName);

    if (addAsHome && channelIsHome)
    {
        return sendWeAreAlreadyInChannel();
    }
    else if (!addAsHome && channelIsGuest)
    {
        return sendWeAreAlreadyInChannel();
    }
    else if (!addAsHome && channelIsHome)
    {
        return sendChannelIsAlreadyAHome();
    }

    // We need to add it to the homeChannels array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    if (addAsHome) plugin.state.bot.homeChannels ~= channelName;
    else plugin.state.bot.guestChannels ~= channelName;
    plugin.state.updates |= typeof(plugin.state.updates).bot;

    immutable addedMessage = addAsHome ?
        "Home channel added." :
        "Guest channel added.";
    privmsg(plugin.state, event.channel.name, event.sender.nickname, addedMessage);

    if (addAsHome)
    {
        immutable guestChannelIndex = plugin.state.bot.guestChannels.countUntil(channelName);
        if (guestChannelIndex != -1)
        {
            import std.algorithm.mutation : SwapStrategy, remove;

            logger.info("We're already in this channel as a guest. Cycling.");

            // Make sure there are no duplicates between homes and channels.
            plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
                .remove!(SwapStrategy.unstable)(guestChannelIndex);
            //plugin.state.updates |= typeof(plugin.state.updates).bot;  // done above
            return cycle(plugin, channelName);
        }
    }

    join(plugin.state, channelName);

    // We have to follow up and see if we actually managed to join the channel
    // There are plenty ways for it to fail.
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

    scope(exit) unawait(plugin, joinTypes[]);
    await(plugin, joinTypes[], yield: true);

    while (true)
    {
        CarryingFiber!IRCEvent thisFiber;

        inner:
        while (true)
        {
            thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
            assert(thisFiber, "Incorrectly cast fiber: `" ~ typeof(thisFiber).stringof ~ '`');
            assert((thisFiber.payload.type != IRCEvent.Type.UNSET), "Uninitialised payload in carrying fiber");

            if (thisFiber.payload.channel.name == channelName) break inner;

            // Different channel; yield fiber, wait for another event
            Fiber.yield();
        }

        const followupEvent = thisFiber.payload;

        void undoChannelAppend()
        {
            immutable existingIndex = addAsHome ?
                plugin.state.bot.homeChannels.countUntil(followupEvent.channel.name) :
                plugin.state.bot.guestChannels.countUntil(followupEvent.channel.name);

            if (existingIndex != -1)
            {
                import std.algorithm.mutation : SwapStrategy, remove;

                if (addAsHome)
                {
                    plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
                        .remove!(SwapStrategy.unstable)(existingIndex);
                }
                else
                {
                    plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
                        .remove!(SwapStrategy.unstable)(existingIndex);
                }

                plugin.state.updates |= typeof(plugin.state.updates).bot;
            }
        }

        with (IRCEvent.Type)
        switch (followupEvent.type)
        {
        case SELFJOIN:
            // Success!
            // scopeguard unawaits
            return;

        case ERR_LINKCHANNEL:
            // We were redirected. Still assume we wanted to add this one?
            logger.info("Redirected!");
            undoChannelAppend();
            if (addAsHome) plugin.state.bot.homeChannels ~= followupEvent.content.toLower;  // note: content
            else plugin.state.bot.guestChannels ~= followupEvent.content.toLower;  // ditto
            Fiber.yield();
            continue;

        default:
            enum message = "Failed to join channel.";
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            undoChannelAppend();
            // scopeguard unawaits
            return;
        }
    }
}


// delChannel
/++
    Removes a channel from the list of currently active home or guest channels, from the
    [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] and
    [kameloso.pods.IRCBot.guestChannels|IRCBot.guestChannels] arrays of the
    current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState],
    respectively.

    Params:
        plugin = The current [AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        rawChannel = The channel to be removed, potentially in unstripped, cased form.
        delFromHomes = Whether to remove a home or a guest channel.
 +/
void delChannel(
    AdminPlugin plugin,
    const IRCEvent event,
    const string rawChannel,
    const bool delFromHomes)
in (rawChannel.length, "Tried to delete a home but the channel string was empty")
{
    import lu.string : stripped;
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;
    import std.uni : toLower;

    immutable channelName = rawChannel.stripped.toLower;
    immutable existingIndex = delFromHomes ?
        plugin.state.bot.homeChannels.countUntil(channelName) :
        plugin.state.bot.guestChannels.countUntil(channelName);

    if (existingIndex == -1)
    {
        import std.format : format;

        enum pattern = "Channel <b>%s<b> was not listed as a %s channel.";
        immutable what = delFromHomes ? "home" : "guest";
        immutable message = pattern.format(channelName, what);
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (delFromHomes)
    {
        plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
            .remove!(SwapStrategy.unstable)(existingIndex);
    }
    else
    {
        plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
            .remove!(SwapStrategy.unstable)(existingIndex);
    }

    plugin.state.updates |= typeof(plugin.state.updates).bot;
    part(plugin.state, channelName);

    if (channelName != event.channel.name)
    {
        // We didn't just leave the channel, so we can report success
        // Otherwise we get ERR_CANNOTSENDTOCHAN
        immutable message = delFromHomes ?
            "Home channel removed." :
            "Guest channel removed.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }
}


// onCommandWhitelist
/++
    Adds a nickname to the list of users who may trigger the bot, to the current
    [dialect.defs.IRCClient.Class.whitelist|IRCClient.Class.whitelist] of the
    current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState].

    This is on a [kameloso.plugins.Permissions.operator|Permissions.operator] level.
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
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    manageClassLists(plugin, event, IRCUser.Class.whitelist);
}


// onCommandElevated
/++
    Adds a nickname to the list of users who may trigger the bot, to the current
    list of [dialect.defs.IRCClient.Class.elevated|IRCClient.Class.elevated] users of the
    current [AdminPlugin]'s [kameloso.plugins.IRCPluginState|IRCPluginState].

    This is on a [kameloso.plugins.Permissions.operator|Permissions.operator] level.
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
void onCommandElevated(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    manageClassLists(plugin, event, IRCUser.Class.elevated);
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
void onCommandOperator(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    manageClassLists(plugin, event, IRCUser.Class.operator);
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
void onCommandStaff(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    manageClassLists(plugin, event, IRCUser.Class.staff);
}


// onCommandBlacklist
/++
    Adds a nickname to the list of users who may not trigger the bot whatsoever,
    except on actions annotated [kameloso.plugins.Permissions.ignore|Permissions.ignore].

    This is on a [kameloso.plugins.Permissions.operator|Permissions.operator] level.
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
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    manageClassLists(plugin, event, IRCUser.Class.blacklist);
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
void onCommandReload(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.conv : text;

    mixin(memoryCorruptionCheck);

    immutable message = event.content.length ?
        text("Reloading plugin \"<b>", event.content, "<b>\".") :
        "Reloading plugins.";
    privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    plugin.state.messages ~= ThreadMessage.reload(event.content);
}


// onCommandPrintRaw
/++
    Toggles a flag to print all incoming events *raw*.

    This is for debugging purposes.
 +/
version(Debug)
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
void onCommandPrintRaw(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    onCommandPrintRawImpl(plugin, event);
}


// onCommandPrintBytes
/++
    Toggles a flag to print all incoming events *as individual bytes*.

    This is for debugging purposes.
 +/
version(Debug)
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
void onCommandPrintBytes(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    onCommandPrintBytesImpl(plugin, event);
}


// onCommandPrintEvents
/++
    Toggles a flag to prettyprint all incoming events, using
    [kameloso.prettyprint.prettyprint].

    This is for debugging purposes.
 +/
version(Debug)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("printevents")
            .policy(PrefixPolicy.nickname)
            .description("[debug] Toggles a flag to prettyprint all incoming events.")
    )
)
void onCommandPrintEvents(AdminPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    onCommandPrintEventsImpl(plugin, event.content, event);
}


// onCommandJoin
/++
    Joins a supplied channel temporarily, without recording as neither a home nor
    as a guest channel.
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
            .description("Joins a channel temporarily, without recording as " ~
                "neither a home nor as a guest channel.")
            .addSyntax("$command [channel] [optional key]")
    )
)
void onCommandJoin(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : splitInto, stripped;

    mixin(memoryCorruptionCheck);

    if (!event.content.length)
    {
        enum message = "No channels to join supplied...";
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
    string channel;  // ditto
    string key;  // ditto
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
void onCommandPart(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : splitInto, stripped;

    mixin(memoryCorruptionCheck);

    if (!event.content.length)
    {
        enum message = "No channels to part supplied...";
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
    string channel;  // ditto
    string reason;  // ditto
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
void onCommandSet(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;

    mixin(memoryCorruptionCheck);

    alias Payload = Tuple!(bool);

    void setSettingDg()
    {
        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        immutable message = thisFiber.payload[0] ?
            "Setting changed." :
            "Invalid syntax or plugin/setting name.";
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    defer!Payload(plugin, &setSettingDg, event.content);
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
void onCommandGet(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;

    mixin(memoryCorruptionCheck);

    alias Payload = Tuple!(string, string, string);

    void getSettingDg()
    {
        auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        immutable pluginName = thisFiber.payload[0];
        immutable setting = thisFiber.payload[1];
        immutable value = thisFiber.payload[2];

        if (!pluginName.length)
        {
            enum message = "Invalid plugin.";
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else if (setting.length)
        {
            import std.algorithm.searching : canFind;
            import std.format : format;

            immutable pattern = value.canFind(' ') ?
                "%s.%s=\"%s\"" :
                "%s.%s=%s";

            immutable message = pattern.format(pluginName, setting, value);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else if (value.length)
        {
            privmsg(plugin.state, event.channel.name, event.sender.nickname, value);
        }
        else
        {
            enum message = "Invalid setting.";
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
    }

    defer!Payload(plugin, &getSettingDg, event.content);
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
void onCommandAuth(AdminPlugin plugin, const IRCEvent _)
{
    import kameloso.thread : ThreadMessage, boxed;

    mixin(memoryCorruptionCheck);

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch) return;
    }

    plugin.state.messages ~= ThreadMessage.busMessage("connect", boxed("auth"));
}


// onCommandStatus
/++
    Dumps information about the current state of the bot to the local terminal.

    This can be very spammy.
 +/
version(Debug)
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
void onCommandStatus(AdminPlugin plugin, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);

    if (plugin.state.coreSettings.headless) return;
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
void onCommandSummary(AdminPlugin plugin, const IRCEvent _)
{
    import kameloso.thread : ThreadMessage;

    mixin(memoryCorruptionCheck);

    if (plugin.state.coreSettings.headless) return;
    plugin.state.messages ~= ThreadMessage.wantLiveSummary;
}


// onCommandFake
/++
    Fakes a string as having been sent by the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("fake")
            .policy(PrefixPolicy.nickname)
            .description("Fakes a string as having been sent by the server.")
    )
)
version(Debug)
void onCommandFake(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    mixin(memoryCorruptionCheck);
    plugin.state.messages ~= ThreadMessage.fakeEvent(event.content);
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
    .fiber(true)
    .addCommand(
        IRCEventHandler.Command()
            .word("cycle")
            .policy(PrefixPolicy.nickname)
            .description("Cycles (parts and rejoins) a channel.")
            .addSyntax("$command [optional channel] [optional delay] [optional key(s)]")
    )
)
void onCommandCycle(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.time : DurationStringException, asAbbreviatedDuration;
    import lu.string : advancePast, stripped;
    import std.conv : ConvException;

    mixin(memoryCorruptionCheck);

    string slice = event.content.stripped;  // mutable
    if (!slice.length) return cycle(plugin, event.channel.name);

    immutable channelName = slice.advancePast(' ', inherit: true);

    if (channelName !in plugin.state.channels)
    {
        enum message = "I am not in that channel.";
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (!slice.length) return cycle(plugin, channelName);

    immutable delaystring = slice
        .advancePast(' ', inherit: true)
        .stripped;

    try
    {
        immutable delay = delaystring.asAbbreviatedDuration;
        cycle(plugin, channelName, delay, slice);
    }
    catch (ConvException _)
    {
        import std.format : format;

        enum pattern = `"<b>%s<b>" is not a valid number for seconds to delay.`;
        immutable message = pattern.format(slice);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }
    catch (DurationStringException e)
    {
        privmsg(plugin.state, event.channel.name, event.sender.nickname, e.msg);
    }
}


// cycle
/++
    Implementation of cycling, called by [onCommandCycle].

    Note: Must be called from within a [core.thread.fiber.Fiber|Fiber].

    Params:
        plugin = The current [AdminPlugin].
        channelName = The name of the channel to cycle.
        delay_ = (Optional) [core.time.Duration|Duration] to delay rejoining.
        key = (Optional) The key to use when rejoining the channel.
 +/
void cycle(
    AdminPlugin plugin,
    const string channelName,
    const Duration delay_ = Duration.zero,
    const string key = string.init)
in (Fiber.getThis(), "Tried to call `cycle` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : await, delay, unawait;
    import kameloso.thread : CarryingFiber;

    part(plugin.state, channelName, "Cycling");

    scope(exit) unawait(plugin, IRCEvent.Type.SELFPART);
    await(plugin, IRCEvent.Type.SELFPART, yield: true);

    while (true)
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: `" ~ typeof(thisFiber).stringof ~ '`');
        assert((thisFiber.payload.type != IRCEvent.Type.UNSET), "Uninitialised payload in carrying fiber");

        const partEvent = thisFiber.payload;

        if (partEvent.channel.name != channelName)
        {
            // Wrong channel, wait for the next SELFPART
            Fiber.yield();
            continue;
        }

        if (delay_ > Duration.zero) delay(plugin, delay_, yield: true);
        return join(plugin.state, channelName, key);
    }
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
void onCommandMask(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : SplitResults, advancePast, splitInto, stripped;
    import std.format : format;

    mixin(memoryCorruptionCheck);

    if (!plugin.state.coreSettings.preferHostmasks)
    {
        enum message = "This bot is not currently configured to use hostmasks for authentication.";
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    void sendUsage()
    {
        enum pattern = "Usage: <b>%s%s<b> [add|del|list] [args...]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    case "add":
        string account;  // mutable
        string mask;  // ditto
        immutable results = slice.splitInto(account, mask);

        if (results != SplitResults.match)
        {
            enum pattern = "Usage: <b>%s%s add<b> [account] [hostmask]";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }

        return modifyHostmaskDefinition(plugin, add: true, account, mask, event);

    case "del":
    case "remove":
        import std.algorithm.searching : canFind;

        if (!slice.length || (slice.canFind(' ')))
        {
            enum pattern = "Usage: <b>%s%s del<b> [hostmask]";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }

        return modifyHostmaskDefinition(plugin, add: false, string.init, slice, event);

    case "list":
        return listHostmaskDefinitions(plugin, event);

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
void listHostmaskDefinitions(AdminPlugin plugin, const IRCEvent event)
{
    import asdf : deserialize;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File, stdout, writeln;

    if (plugin.state.coreSettings.headless) return;

    auto aa = plugin.hostmasksFile.readText.deserialize!(string[string]);

    // Remove any placeholder examples
    enum examplePlaceholderKey = "<nickname>!<ident>@<address>";
    aa.remove(examplePlaceholderKey);

    if (aa.length)
    {
        if (event.type == IRCEvent.Type.UNSET)
        {
            if (plugin.state.coreSettings.headless) return;

            logger.log("Current hostmasks:");
            immutable serialised = JSONValue(aa).toPrettyString;
            writeln(serialised);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
        else
        {
            import std.format : format;

            enum pattern = "Current hostmasks: <b>%s<b>";
            immutable message = pattern.format(aa);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
    }
    else
    {
        enum message = "There are presently no hostmasks defined.";

        if (event.type == IRCEvent.Type.UNSET)
        {
            logger.info(message);
        }
        else
        {
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
    }
}


// onCommandReconnect
/++
    Disconnect from and immediately reconnects to the server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("reconnect")
            .policy(PrefixPolicy.nickname)
            .description("Disconnects from and immediately reconnects to the server.")
            .addSyntax("$command [optional quit message]")
    )
)
void onCommandReconnect(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage, boxed;
    import lu.string : stripped;

    mixin(memoryCorruptionCheck);

    logger.warning("Reconnecting upon administrator request.");
    auto message = ThreadMessage.reconnect(event.content.stripped, boxed(false));
    plugin.state.priorityMessages ~= message;

}


// onCommandReexec
/++
    Re-executes the program.
 +/
version(Posix)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("reexec")
            .policy(PrefixPolicy.nickname)
            .description("Re-executes the program.")
            .addSyntax("$command [optional quit message]")
    )
)
void onCommandReexec(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage, boxed;
    import lu.string : stripped;

    mixin(memoryCorruptionCheck);

    auto message = ThreadMessage.reconnect(event.content.stripped, boxed(true));
    plugin.state.priorityMessages ~= message;
}


// onCommandBus
/++
    Sends an internal bus message to other plugins, much like how such can be
    sent with the Pipeline plugin.
 +/
version(Debug)
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
void onCommandBus(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : splitInto, stripped;

    mixin(memoryCorruptionCheck);

    string slice = event.content.stripped;  // mutable
    string header;  // ditto
    cast(void)slice.splitInto(header);

    if (!header.length)
    {
        import std.format : format;

        enum pattern = "Usage: <b>%s<b> [header] [content...]";
        immutable message = pattern.format(event.aux[$-1]);
        return privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    onCommandBusImpl(plugin, header, slice);
}


// onCommandSelftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.admin)
    .channelPolicy(ChannelPolicy.home)
    .addCommand(
        IRCEventHandler.Command()
            .word("selftest")
            .policy(PrefixPolicy.nickname)
            .description("Performs self-tests against another bot.")
            .addSyntax("$command [target nickname] [optional plugin name(s)]")
    )
)
void onCommandSelftest(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : CarryingFiber;
    import std.format : format;
    import std.typecons : Ternary, Tuple;

    mixin(memoryCorruptionCheck);

    alias Payload = Tuple!(string[], Ternary delegate()[]);

    void selftestDgOuter()
    {
        import kameloso.constants : BufferSize;
        import kameloso.thread : CarryingFiber;

        auto outerFiber = cast(CarryingFiber!Payload)Fiber.getThis();
        assert(outerFiber, "Incorrectly cast fiber: " ~ typeof(outerFiber).stringof);

        immutable pluginNames = outerFiber.payload[0].idup;
        auto testDelegates = outerFiber.payload[1].dup;

        void selftestDgInner()
        {
            import kameloso.irccolours : expandIRCTags;
            import kameloso.time : timeSince;
            import core.time : MonoTime;

            /*auto innerFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
            assert(innerFiber, "Incorrectly cast fiber: " ~ typeof(innerFiber).stringof);*/

            immutable start = MonoTime.currTime;

            enum message = "Running self-tests. This may take several minutes.";
            enum pluginListPattern = "Plugins to test: <b>%-(%s<b>, <b>%)<b> (<b>%d<b>)";
            immutable pluginListMessage = pluginListPattern
                .format(pluginNames, pluginNames.length)
                .expandIRCTags;

            chan(plugin.state, event.channel.name, message);
            chan(plugin.state, event.channel.name, pluginListMessage);

            string[] succeeded;
            string[] failed;
            string[] skipped;

            foreach (immutable i; 0..pluginNames.length)
            {
                immutable pluginName = pluginNames[i];

                try
                {
                    immutable pre = MonoTime.currTime;
                    immutable result = testDelegates[i]();
                    immutable post = MonoTime.currTime;
                    immutable delta = (post - pre);
                    immutable elapsed = delta.timeSince;

                    if (result == Ternary.yes)
                    {
                        succeeded ~= pluginName;
                        enum successPattern = "Self-test of the <l>%s</> plugin " ~
                            "finished without errors in <l>%s</>.";
                        logger.infof(successPattern, pluginName, elapsed);
                    }
                    else if (result == Ternary.no)
                    {
                        failed ~= pluginName;
                        enum failurePattern = "Self-test of the <l>%s</> plugin " ~
                            "FAILED after <l>%s</>.";
                        logger.warningf(failurePattern, pluginName, elapsed);
                    }
                    else /*if (result == Ternary.unknown)*/
                    {
                        skipped ~= pluginName;
                    }
                }
                catch (Exception e)
                {
                    version(PrintStacktraces)
                    {
                        logger.trace(e);
                    }
                    failed ~= pluginName;
                }
            }

            immutable stop = MonoTime.currTime;
            immutable delta = (stop - start);
            immutable elapsed = delta.timeSince;

            enum completePattern = "Self-tests completed in <b>%s<b>.";
            immutable completeMessage = completePattern.format(elapsed);
            chan(plugin.state, event.channel.name, completeMessage);

            if (succeeded.length)
            {
                enum successPattern = "Succeeded (<b>%d<b>): %-(<b>%s<b>, %)<b>";
                immutable successMessage = successPattern.format(
                    succeeded.length,
                    succeeded);
                chan(plugin.state, event.channel.name, successMessage);
            }

            if (failed.length)
            {
                enum failurePattern = "Failed (<b>%d<b>): %-(<b>%s<b>, %)<b>";
                immutable failureMessage = failurePattern.format(
                    failed.length,
                    failed);
                chan(plugin.state, event.channel.name, failureMessage);
            }

            if (skipped.length)
            {
                import lu.string : plurality;
                enum skippedPattern = "<b>%d<b> %s skipped due to not having any tests defined.";
                immutable skippedMessage = skippedPattern.format(
                    skipped.length,
                    skipped.length.plurality("plugin was", "plugins were"));
                chan(plugin.state, event.channel.name, skippedMessage);
            }
        }

        auto innerFiber = new CarryingFiber!IRCEvent(&selftestDgInner, BufferSize.fiberStack);
        innerFiber.call();
    }

    if (!event.content.length)
    {
        enum pattern = "Usage: %s%s [target nickname] [optional plugin name(s)]";
        immutable message = pattern.format(
            plugin.state.coreSettings.prefix,
            event.aux[$-1]);
        chan(plugin.state, event.channel.name, message);
        return;
    }

    defer!Payload(plugin, &selftestDgOuter, event.channel.name, event.content);
}


// parseTypesFromString
/++
    Modifies [AdminPlugin.eventTypesToPrint|eventTypesToPrint] based on a string
    of comma-separated event types.

    Params:
        plugin = The current [AdminPlugin].
        definitions = String of comma-separated event types to print.
 +/
version(Debug)
package auto parseTypesFromString(AdminPlugin plugin, const string definitions)
{
    import kameloso.common : logger;
    import lu.conv : Enum;
    import lu.string : stripped;
    import std.algorithm.iteration : map, splitter;
    import std.conv : ConvException;
    import std.uni : toUpper;

    if (!definitions.length) return true;

    try
    {
        auto typenumRange = definitions
            .toUpper()
            .splitter(",")
            .map!(s => Enum!(IRCEvent.Type).fromString(s.stripped));

        foreach (immutable typenum; typenumRange)
        {
            plugin.eventTypesToPrint[cast(size_t)typenum] = true;
        }

        return true;
    }
    catch (ConvException e)
    {
        enum pattern = `Invalid <l>%s</>.<l>printEvents</> setting: "<l>%s</>" <t>(%s)`;
        logger.errorf(pattern, plugin.name, definitions, e.msg);
        return false;
    }
}


// initialise
/++
    Populates the array of what incoming types to prettyprint to the local terminal.

    Gate it behind version `Debug` to be neat.
 +/
version(Debug)
void initialise(AdminPlugin plugin)
{
    plugin.eventTypesToPrint.length = __traits(allMembers, IRCEvent.Type).length;

    immutable success = parseTypesFromString(
        plugin,
        plugin.settings.printEvents);

    if (!success) *plugin.state.abort = true;
}


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
void onBusMessage(
    AdminPlugin plugin,
    const string header,
    /*shared*/ Sendable content)
{
    import kameloso.thread : Boxed, ThreadMessage, boxed;
    import lu.string : advancePast, strippedRight;

    // Don't return if disabled, as it blocks us from re-enabling with verb set
    if (header != "admin") return;

    const message = cast(Boxed!string)content;

    if (!message)
    {
        enum pattern = "The <l>%s</> plugin received an invalid bus message: expected type <l>%s";
        logger.errorf(pattern, plugin.name, typeof(message).stringof);
        return;
    }

    string slice = message.payload.strippedRight;
    immutable verb = slice.advancePast(' ', inherit: true);

    switch (verb)
    {
    version(Debug)
    {
        version(IncludeHeavyStuff)
        {
            import core.memory : GC;

            version(WantAdminStatePrinter)
            {
                case "state":
                    import kameloso.prettyprint : prettyprint;
                    // Adds 350 mb to compilation memory usage
                    if (plugin.state.coreSettings.headless) return;
                    return prettyprint(plugin.state);
            }

            case "status":
                return onCommandStatusImpl(plugin);

            case "gc.minimize":
                GC.minimize();
                if (plugin.state.coreSettings.headless) return;
                logger.info("Memory minimised.");
                break;
        }

        /+
            Provide a heavy `gc.collect` verb that logs the amount of memory
            collected and the time taken to do so, as well as a slimmer version
            that just collects the garbage.
         +/
        version(IncludeHeavyStuff)
        {
            case "gc.collect":
                import core.time : MonoTime;

                if (plugin.state.coreSettings.headless) return GC.collect();

                // Only adds some 10 mb to compilation memory usage but it's
                // very rarely needed, so keep it behind IncludeHeavyStuff
                immutable statsPre = GC.stats();
                immutable timestampPre = MonoTime.currTime;
                immutable memoryUsedPre = statsPre.usedSize;

                GC.collect();

                immutable statsPost = GC.stats();
                immutable timestampPost = MonoTime.currTime;
                immutable memoryUsedPost = statsPost.usedSize;
                immutable memoryCollected = (memoryUsedPre - memoryUsedPost);
                immutable duration = (timestampPost - timestampPre);

                enum pattern = "Collected <l>%,d</> bytes of garbage in <l>%s";
                logger.infof(pattern, memoryCollected, duration);
                break;
        }
        else
        {
            case "gc.collect":
                import core.memory : GC;

                GC.collect();
                if (plugin.state.coreSettings.headless) return
                logger.info("Garbage collected.");
                break;
        }

        case "user":
            if (plugin.state.coreSettings.headless) return;

            if (const user = slice in plugin.state.users)
            {
                import kameloso.prettyprint : prettyprint;
                prettyprint(*user);
            }
            else
            {
                logger.error("No such user: <l>", slice);
            }
            break;

        case "users":
            return onCommandShowUsersImpl(plugin);

        case "printraw":
            if (plugin.state.coreSettings.headless) return;
            plugin.settings.printRaw = !plugin.settings.printRaw;
            enum pattern = "Printing raw: <l>%s";
            logger.infof(pattern, plugin.settings.printRaw);
            break;

        case "printbytes":
            if (plugin.state.coreSettings.headless) return;
            plugin.settings.printBytes = !plugin.settings.printBytes;
            enum pattern = "Printing bytes: <l>%s";
            logger.infof(pattern, plugin.settings.printBytes);
            break;

        case "printevents":
            // headless is checked inside the function
            return onCommandPrintEventsImpl(plugin, slice, IRCEvent.init);

        case "fake":
            plugin.state.messages ~= ThreadMessage.fakeEvent(slice);
            if (plugin.state.coreSettings.headless) return;
            logger.info("Faking event.");
            break;
    }

    case "gc.stats":
        import kameloso.misc : printGCStats;
        if (plugin.state.coreSettings.headless) return;
        return printGCStats();

    case "reconnect":
        plugin.state.priorityMessages ~= ThreadMessage.reconnect;
        break;

    case "reexec":
        plugin.state.priorityMessages ~= ThreadMessage.reconnect(string.init, boxed(true));
        break;

    case "quit":
        return slice.length ?
            quit(plugin.state, slice) :
            quit(plugin.state);

    case "set":
        import kameloso.thread : CarryingFiber;
        import std.typecons : Tuple;

        alias Payload = Tuple!(bool);

        void setSettingBusDg()
        {
            if (plugin.state.coreSettings.headless) return;

            auto thisFiber = cast(CarryingFiber!Payload)Fiber.getThis();
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

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

        defer!Payload(plugin, &setSettingBusDg, slice);
        break;

    case "save":
        plugin.state.messages ~= ThreadMessage.save;
        if (plugin.state.coreSettings.headless) return;
        logger.info("Saving configuration to disk.");
        break;

    case "reload":
        plugin.state.messages ~= ThreadMessage.reload(slice);
        if (plugin.state.coreSettings.headless) return;

        if (slice.length)
        {
            enum pattern = `Reloading plugin "<l>%s</>".`;
            logger.infof(pattern, slice);
        }
        else
        {
            logger.info("Reloading plugins.");
        }
        break;

    case "whitelist":
    case "elevated":
    case "operator":
    case "staff":
    case "blacklist":
        import lu.conv : Enum;
        import lu.string : SplitResults, splitInto;

        string subverb;  // mutable
        string channelName;  // ditto
        immutable results = slice.splitInto(subverb, channelName);

        if (results == SplitResults.underrun)
        {
            // verb_channel_nickname
            enum pattern = "Invalid bus message syntax; expected <l>%s</> " ~
                "[verb] [channel] [nickname if add/del], got \"<l>%s</>\"";
            logger.warningf(pattern, verb, message.payload.strippedRight);
            return;
        }

        immutable class_ = Enum!(IRCUser.Class).fromString(verb);

        switch (subverb)
        {
        case "add":
        case "del":
            alias user = slice;

            if (!user.length)
            {
                logger.warning("Invalid bus message syntax; no user supplied, " ~
                    "only channel <l>", channelName);
                return;
            }

            return (subverb == "add") ?
                lookupEnlist(plugin, user, class_, channelName) :
                delist(plugin, user, class_, channelName);  // implicitly subverb == "del"

        case "list":
            return listList(plugin, channelName, class_);

        default:
            enum pattern = "Invalid bus message <l>%s</> subverb <l>%s";
            logger.warningf(pattern, verb, subverb);
            break;
        }
        break;

    case "hostmask":
        import lu.string : advancePast;

        immutable subverb = slice.advancePast(' ', inherit: true);

        switch (subverb)
        {
        case "add":
            import lu.string : SplitResults, splitInto;

            string account;  // mutable
            string mask;  // ditto
            immutable results = slice.splitInto(account, mask);

            if (results != SplitResults.match)
            {
                enum invalidSyntaxMessage = "Invalid bus message syntax; " ~
                    "expected <l>hostmask add [account] [hostmask]";
                logger.warning(invalidSyntaxMessage);
                return;
            }

            IRCEvent lvalueEvent;
            modifyHostmaskDefinition(
                plugin,
                add: true,
                account,
                mask,
                lvalueEvent);
            break;

        case "del":
        case "remove":
            if (!slice.length)
            {
                enum invalidSyntaxMessage = "Invalid bus message syntax; " ~
                    "expected <l>hostmask del [hostmask]";
                logger.warning(invalidSyntaxMessage);
                return;
            }

            IRCEvent lvalueEvent;
            modifyHostmaskDefinition(
                plugin,
                add: false,
                account: string.init,
                mask: slice,
                event: lvalueEvent);
            break;

        case "list":
            IRCEvent lvalueEvent;
            listHostmaskDefinitions(plugin, lvalueEvent);
            break;

        default:
            enum pattern = "Invalid bus message <l>%s</> subverb <l>%s";
            logger.warningf(pattern, verb, subverb);
            break;
        }
        break;

    case "summary":
        plugin.state.messages ~= ThreadMessage.wantLiveSummary;
        break;

    default:
        enum pattern = "[admin] Unimplemented bus message verb: <l>%s";
        logger.errorf(pattern, verb);
        break;
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(AdminPlugin _, Selftester s)
{
    import std.range : only;

    // ------------ home, guest

    s.send("home del #harpsteff");
    s.expect("Channel #harpsteff was not listed as a home channel.");

    s.send("home add #harpsteff");
    s.expect("Home channel added.");

    s.send("home add #harpsteff");
    s.expect("We are already in that home channel.");

    s.send("home del #harpsteff");
    s.expect("Home channel removed.");

    s.send("home del #harpsteff");
    s.expect("Channel #harpsteff was not listed as a home channel.");

    s.send("guest add #BLIRPBLARP");
    s.expect("Guest channel added.");

    s.send("guest del #BLIRPBLARP");
    s.expect("Guest channel removed.");

    // ------------ lists

    foreach (immutable list; only("staff"))//, "operator", "elevated", "whitelist", "blacklist"))
    {
        immutable definiteFormSingular =
            (list == "staff") ? "staff" :
            (list == "operator") ? "an operator" :
            (list == "elevated") ? "an elevated user" :
            (list == "whitelist") ? "a whitelisted user" :
            /*(list == "blacklist") ?*/ "a blacklisted user";

        immutable plural =
            (list == "staff") ? "staff" :
            (list == "operator") ? "operators" :
            (list == "elevated") ? "elevated users" :
            (list == "whitelist") ? "whitelisted users" :
            /*(list == "blacklist") ?*/ "blacklisted users";

        s.send(list ~ " del xorael");
        s.expect("xorael isn't " ~ definiteFormSingular ~ " in ${channel}.");

        s.send(list ~ " add xorael");
        s.expect("Added xorael as " ~ definiteFormSingular ~ " in ${channel}.");

        s.send(list ~ " add xorael");
        s.expect("xorael was already " ~ definiteFormSingular ~ " in ${channel}.");

        s.send(list ~ " list");
        s.expect("Current " ~ plural ~ " in ${channel}: xorael");

        s.send(list ~ " del xorael");
        s.expect("Removed xorael as " ~ definiteFormSingular ~ " in ${channel}.");

        s.send(list ~ " list");
        s.expect("There are no " ~ plural ~ " in ${channel}.");

        s.send(list ~ " add");
        s.expect("No nickname supplied.");
    }

    // ------------ misc

    s.send("cycle #flirrp");
    s.expect("I am not in that channel.");

    // ------------ hostmasks

    s.send("hostmask");
    s.awaitReply();

    enum noHostmaskMessage = "This bot is not currently configured " ~
        "to use hostmasks for authentication.";

    if (s.lastMessage != noHostmaskMessage)
    {
        s.send("hostmask add");
        s.expect("Usage: !hostmask [add|del|list] ([account] [hostmask]/[hostmask])");

        s.send("hostmask add kameloso HIRF#%%!SNIR@sdasdasd");
        s.expect("Invalid hostmask.");

        s.send("hostmask add kameloso kameloso^!*@*");
        s.expect("Hostmask list updated.");

        s.send("hostmask list");
        // `Current hostmasks: ["kameloso^!*@*":"kameloso"]`);
        s.expectInBody(`"kameloso^!*@*":"kameloso"`);

        s.send("hostmask del kameloso^!*@*");
        s.expect("Hostmask list updated.");

        s.send("hostmask del kameloso^!*@*");
        s.expect("No such hostmask on file.");
    }

    // ------------ misc

    s.send("reload");
    s.expect("Reloading plugins.");

    s.send("reload admin");
    s.expect("Reloading plugin \"admin\".");

    s.send("join #skabalooba");
    s.send("part #skabalooba");

    s.send("get admin.enabled");
    s.expect("admin.enabled=true");

    s.send("get core.prefix");
    s.expect(`core.prefix="${prefix}"`);

    s.send("sudo PRIVMSG ${channel} :hello world");
    s.expect("hello world");

    return true;
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
private:
    import kameloso.constants : KamelosoFilenames;

package:
    /++
        All Admin options gathered.
     +/
    AdminSettings settings;


    version(Debug)
    {
        /++
            Typemap of what incoming [dialect.defs.IRCEvent.Type|IRCEvent.Type]s to
            print to the terminal.
         +/
        bool[] eventTypesToPrint;
    }

    /++
        File with user definitions. Must be the same as in `persistence.d`.
     +/
    @Resource string userFile = KamelosoFilenames.users;

    /++
        File with hostmasks definitions. Must be the same as in `persistence.d`.
     +/
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    mixin IRCPluginImpl;
}

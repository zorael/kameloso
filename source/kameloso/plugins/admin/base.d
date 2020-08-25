/++
 +  The Admin plugin features bot commands which help with debugging the current
 +  state of the running bot, like printing the current list of users, the
 +  current channels, the raw incoming strings from the server, and some other
 +  things along the same line.
 +
 +  It also offers some less debug-y, more administrative functions, like adding
 +  and removing homes on-the-fly, whitelisting or de-whitelisting account
 +  names, adding/removing from the operator list, joining or leaving channels, and such.
 +
 +  See the GitHub wiki for more information about available commands:<br>
 +  - https://github.com/zorael/kameloso/wiki/Current-plugins#admin
 +/
module kameloso.plugins.admin.base;

version(WithPlugins):
version(WithAdminPlugin):

//version = OmniscientAdmin;

private:

import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;

import kameloso.plugins.core;
import kameloso.plugins.common;
import kameloso.plugins.awareness : ChannelAwareness, TwitchAwareness, UserAwareness;
import kameloso.common : Tint, logger;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.concurrency : send;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;


// AdminSettings
/++
 +  All Admin plugin settings, gathered in a struct.
 +/
@Settings struct AdminSettings
{
    import lu.uda : Unserialisable;

    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    @Unserialisable
    {
        /++
         +  Toggles whether `onAnyEvent` prints the raw strings of all incoming
         +  events or not.
         +/
        bool printRaw;

        /++
         +  Toggles whether `onAnyEvent` prints the raw bytes of the *contents*
         +  of events or not.
         +/
        bool printBytes;

        /++
         +  Toggles whether `onAnyEvent` prints assert statements for incoming
         +  events or not.
         +/
        bool printAsserts;
    }
}


// onAnyEvent
/++
 +  Prints incoming events to the local terminal, in forms depending on
 +  which flags have been set with bot commands.
 +
 +  If `AdminPlugin.printRaw` is set by way of invoking `onCommandPrintRaw`,
 +  prints all incoming server strings.
 +
 +  If `AdminPlugin.printBytes` is set by way of invoking `onCommandPrintBytes`,
 +  prints all incoming server strings byte by byte.
 +
 +  If `AdminPlugin.printAsserts` is set by way of invoking `onCommandPrintRaw`,
 +  prints all incoming events as assert statements, for use in generating source
 +  code `unittest` blocks.
 +/
debug
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    return onAnyEventImpl(plugin, event);
}


// onCommandShowUser
/++
 +  Prints the details of one or more specific, supplied users to the local terminal.
 +
 +  It basically prints the matching `dialect.defs.IRCUser`.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "user")
@Description("[debug] Prints out information about one or more specific users " ~
    "to the local terminal.", "$command [nickname] [nickname] ...")
void onCommandShowUser(AdminPlugin plugin, const IRCEvent event)
{
    return onCommandShowUserImpl(plugin, event);
}


// onCommandSave
/++
 +  Saves current configuration to disk.
 +
 +  This saves all plugins' settings, not just this plugin's, effectively
 +  regenerating the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "save")
@BotCommand(PrefixPolicy.nickname, "writeconfig", Yes.hidden)
@Description("Saves current configuration to disk.")
void onCommandSave(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    privmsg(plugin.state, event.channel, event.sender.nickname, "Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `users` array of the `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState` to the local terminal.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
    return onCommandShowUsersImpl(plugin);
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  You need basic knowledge of IRC server strings to use this.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "sudo")
@Description("[debug] Sends supplied text to the server, verbatim.",
    "$command [raw string]")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    return onCommandSudoImpl(plugin, event);
}


// onCommandQuit
/++
 +  Sends a `dialect.defs.IRCEvent.Type.QUIT` event to the server.
 +
 +  If any extra text is following the "quit" command, it uses that as the quit
 +  reason. Otherwise it falls back to what is specified in the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "quit")
@Description("Send a QUIT event to the server and exits the program.",
    "$command [optional quit reason]")
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
    quit(plugin.state, event.content);
}


// onCommandHome
/++
 +  Adds or removes channels to/from the list of currently active home channels, in the
 +  `kameloso.common.IRCBot.homeChannels` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState`.
 +
 +  Merely passes on execution to `addHome` and `delHome`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "home")
@Description("Adds or removes a channel to/from the list of home channels.",
    "$command [add|del|list] [channel]")
void onCommandHome(AdminPlugin plugin, const IRCEvent event)
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
 +  Adds a channel to the list of currently active home channels, in the
 +  `dialect.defs.IRCClient.homeChannels` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState`.
 +
 +  Follows up with a `core.thread.fiber.Fiber` to verify that the channel was actually joined.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      rawChannel = The channel to be added, potentially in unstripped, cased form.
 +/
void addHome(AdminPlugin plugin, const IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to add a home but the channel string was empty")
{
    import kameloso.plugins.common.delayawait : await, unawait;
    import dialect.common : isValidChannel;
    import lu.string : stripped;
    import std.algorithm.searching : canFind, countUntil;
    import std.uni : toLower;

    immutable channel = rawChannel.stripped.toLower;

    if (!channel.isValidChannel(plugin.state.server))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "Invalid channel name.");
        return;
    }

    if (plugin.state.bot.homeChannels.canFind(channel))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "We are already in that home channel.");
        return;
    }

    // We need to add it to the homeChannels array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    plugin.state.bot.homeChannels ~= channel;
    plugin.state.botUpdated = true;
    privmsg(plugin.state, event.channel, event.sender.nickname, "Home added.");

    immutable existingChannelIndex = plugin.state.bot.guestChannels.countUntil(channel);

    if (existingChannelIndex != -1)
    {
        import kameloso.thread : ThreadMessage, busMessage;
        import std.algorithm.mutation : SwapStrategy, remove;

        logger.info("We're already in this channel as a guest. Cycling.");

        // Make sure there are no duplicates between homes and channels.
        plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
            .remove!(SwapStrategy.unstable)(existingChannelIndex);

        return cycle(plugin, channel);
    }

    join(plugin.state, channel);

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

            if (thisFiber.payload.channel == channel) break;

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

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32_768);
    await(plugin, fiber, joinTypes);
}


// delHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `dialect.defs.IRCClient.homeChannels` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState`.
 +/
void delHome(AdminPlugin plugin, const IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to delete a home but the channel string was empty")
{
    import lu.string : stripped;
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.uni : toLower;

    immutable channel = rawChannel.stripped.toLower;
    immutable homeIndex = plugin.state.bot.homeChannels.countUntil(channel);

    if (homeIndex == -1)
    {
        import std.format : format;

        enum pattern = "Channel %s was not listed as a home.";

        immutable message = plugin.state.settings.colouredOutgoing ?
            pattern.format(channel.ircBold) :
            pattern.format(channel);

        privmsg(plugin.state, event.channel, event.sender.nickname, message);
        return;
    }

    plugin.state.bot.homeChannels = plugin.state.bot.homeChannels
        .remove!(SwapStrategy.unstable)(homeIndex);
    plugin.state.botUpdated = true;
    part(plugin.state, channel);

    if (channel != event.channel)
    {
        // We didn't just leave the channel, so we can report success
        // Otherwise we get ERR_CANNOTSENDTOCHAN
        privmsg(plugin.state, event.channel, event.sender.nickname, "Home removed.");
    }
}


// onCommandWhitelist
/++
 +  Adds a nickname to the list of users who may trigger the bot, to the current
 +  `dialect.defs.IRCClient.Class.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState`.
 +
 +  This is on a `kameloso.plugins.core.PrivilegeLevel.operator` level.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "whitelist")
@Description("Add or remove an account to/from the whitelist of users who may trigger the bot.",
    "$command [add|del] [account or nickname]")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    return plugin.manageClassLists(event, "whitelist");
}


// onCommandOperator
/++
 +  Adds a nickname or account to the list of users who may trigger lower-level
 +  functions of the bot, without being a full admin.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "operator")
@Description("Add or remove an account to/from the operator list of operators/moderators.",
    "$command [add|del] [account or nickname]")
void onCommandOperator(AdminPlugin plugin, const IRCEvent event)
{
    return plugin.manageClassLists(event, "operator");
}


// onCommandBlacklist
/++
 +  Adds a nickname to the list of users who may not trigger the bot whatsoever,
 +  except on actions annotated `kameloso.plugins.core.PrivilegeLevel.ignore`.
 +
 +  This is on a `kameloso.plugins.core.PrivilegeLevel.operator` level.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.operator)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "blacklist")
@Description("Add or remove an account to/from the blacklist of people who may " ~
    "explicitly not trigger the bot.", "$command [add|del] [account or nickname]")
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    return plugin.manageClassLists(event, "blacklist");
}


// onCommandReload
/++
 +  Asks plugins to reload their resources and/or configuration as they see fit.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "reload")
@Description("Asks plugins to reload their resources and/or configuration as they see fit.")
void onCommandReload(AdminPlugin plugin)
{
    import kameloso.thread : ThreadMessage;

    logger.info("Reloading plugins.");
    plugin.state.mainThread.send(ThreadMessage.Reload());
}


// onCommandResetTerminal
/++
 +  Outputs the ASCII control character *`15`* to the terminal.
 +
 +  This helps with restoring it if the bot has accidentally printed a different
 +  control character putting it would-be binary mode, like what happens when
 +  you try to `cat` a binary file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "resetterm")
@Description("Outputs the ASCII control character 15 to the local terminal, " ~
    "to recover from binary garbage mode.")
void onCommandResetTerminal()
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    write(cast(char)TerminalToken.reset);
    stdout.flush();
}


// onCommandPrintRaw
/++
 +  Toggles a flag to print all incoming events *raw*.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printraw")
@Description("[debug] Toggles a flag to print all incoming events raw.")
void onCommandPrintRaw(AdminPlugin plugin, const IRCEvent event)
{
    return onCommandPrintRawImpl(plugin, event);
}


// onCommandPrintBytes
/++
 +  Toggles a flag to print all incoming events *as individual bytes*.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printbytes")
@Description("[debug] Toggles a flag to print all incoming events as bytes.")
void onCommandPrintBytes(AdminPlugin plugin, const IRCEvent event)
{
    return onCommandPrintBytesImpl(plugin, event);
}


// onCommandJoin
/++
 +  Joins a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "join")
@Description("Joins a guest channel.", "$command [channel]")
void onCommandJoin(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : splitInto;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "No channels to join supplied ...");
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
 +  Parts a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "part")
@Description("Parts a guest channel.", "$command [channel]")
void onCommandPart(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : splitInto;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "No channels to part supplied ...");
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
 +  Sets a plugin option by variable string name.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "set")
@Description("Changes a plugin's settings.", "$command [plugin.setting=value]")
void onSetCommand(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : CarryingFiber, ThreadMessage;
    import std.concurrency : send;

    void dg()
    {
        import core.thread : Fiber;
        import std.conv : ConvException;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

        try
        {
            immutable success = thisFiber.payload
                .applyCustomSettings([ event.content ], plugin.state.settings);

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
        catch (ConvException e)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "There was a conversion error. Please verify the values in your setting.");
            version(PrintStacktraces) logger.trace(e.info);
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg, 32_768);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
}


// onCommandAuth
/++
 +  Asks the `kameloso.plugins.connect.ConnectService` to (re-)authenticate to services.
 +/
version(WithConnectService)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "auth")
@Description("(Re-)authenticates with services. Useful if the server has " ~
    "forcefully logged the bot out.")
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
 +  Dumps information about the current state of the bot to the local terminal.
 +
 +  This can be very spammy.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "status")
@Description("[debug] Dumps information about the current state of the bot to the local terminal.")
void onCommandStatus(AdminPlugin plugin)
{
    return onCommandStatusImpl(plugin);
}


// onCommandSummary
/++
 +  Causes a connection summary to be printed to the terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "summary")
@Description("Causes a connection summary to be printed to the terminal.")
void onCommandSummary(AdminPlugin plugin)
{
    import kameloso.thread : ThreadMessage;
    plugin.state.mainThread.send(ThreadMessage.WantLiveSummary());
}


// cycle
/++
 +  Cycles (parts and immediately rejoins) a channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "cycle")
@Description("Cycles (parts and immediately rejoins) a channel.")
void onCommandCycle(AdminPlugin plugin, const IRCEvent event)
{
    import lu.string : nom;

    string slice = event.content;  // mutable

    immutable channelName = slice.length ?
        slice.nom!(Yes.inherit)(' ') :
        event.channel;

    if (event.content.length && (channelName !in plugin.state.channels))
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "I am not in that channel.");
        return;
    }

    cycle(plugin, channelName, slice);
}


// cycle
/++
 +  Implementation of cycling, called by `onCommandCycle`
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      channelName = The name of the channel to cycle.
 +      key = The key to use when rejoining the channel.
 +/
void cycle(AdminPlugin plugin, const string channelName, const string key = string.init)
{
    import kameloso.plugins.common.delayawait : await;
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
                return join(plugin.state, channelName, key);
            }

            // Wrong channel, wait for the next SELFPART
            Fiber.yield();
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32_768);
    await(plugin, fiber, IRCEvent.Type.SELFPART);
    part(plugin.state, channelName, "Cycling");
}


// onCommandMask
/++
 +  Adds, removes or lists hostmasks used to identify users on servers that
 +  don't employ services.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "mask")
@BotCommand(PrefixPolicy.prefixed, "hostmask", Yes.hidden)
@Description("Modifies a hostmask definition, for use on servers without services accounts.",
    "$command [add|del|list] [account] [hostmask if adding]")
void onCommandMask(AdminPlugin plugin, const IRCEvent event)
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
            "Usage: %s%s [add|del|list] ([account] [hostmask]/[hostmask])"
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
        if (results != SplitResults.match) return sendUsage();

        return plugin.modifyHostmaskDefinition(Yes.add, account, mask, event);

    case "del":
    case "remove":
        if (!slice.length || slice.contains(' ')) return sendUsage();
        return plugin.modifyHostmaskDefinition(No.add, string.init, slice, event);

    case "list":
        return plugin.listHostmaskDefinitions(event);

    default:
        return sendUsage();
    }
}


// modifyHostmaskDefinition
/++
 +  Adds or removes hostmasks used to identify users on servers that don't employ services.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      add = Whether to add or to remove the hostmask.
 +      account = Account the hostmask will equate to.
 +      mask = String "nickname!ident@address.tld" hostmask.
 +      event = Instigating `dialect.defs.IRCEvent`.
 +/
void modifyHostmaskDefinition(AdminPlugin plugin, const Flag!"add" add,
    const string account, const string mask, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage, populateFromJSON;
    import lu.string : contains;
    import std.concurrency : send;
    import std.json : JSONValue;

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    bool didSomething;

    if (add)
    {
        import dialect.common : isValidHostmask;

        if (!mask.isValidHostmask(plugin.state.server))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Invalid hostmask.");
            return;
        }

        aa[mask] = account;
        didSomething = true;
        json.reset();
        json = JSONValue(aa);
    }
    else
    {
        // Allow for removing an invalid mask

        if (mask in aa)
        {
            aa.remove(mask);
            didSomething = true;
        }

        json.reset();
        json = JSONValue(aa);
    }

    json.save!(JSONStorage.KeyOrderStrategy.passthrough)(plugin.hostmasksFile);

    immutable message = didSomething ?
        "Hostmask list updated." :
        "No such hostmask on file.";

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
}


// listHostmaskDefinitions
/++
 +  Lists existing hostmask definitions.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      event = The instigating `dialect.defs.IRCEvent`.
 +/
void listHostmaskDefinitions(AdminPlugin plugin, const IRCEvent event)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    if (aa.length)
    {
        import std.conv : to;

        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Current hostmasks: " ~ aa.to!string);
    }
    else
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "There are presently no hostmasks defined.");
    }
}


// onCommandBus
/++
 +  Sends an internal bus message to other plugins, much like how such can be
 +  sent with the Pipeline plugin.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "bus")
@Description("[DEBUG] Sends an internal bus message.", "$command [header] [content...]")
void onCommandBus(AdminPlugin plugin, const IRCEvent event)
{
    return onCommandBusImpl(plugin, event);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`admin`" header,
 +  and calls functions based on the payload message.
 +
 +  This is used in the Pipeline plugin, to allow us to trigger admin verbs via
 +  the command-line pipe.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
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

    case "resetterm":
        return onCommandResetTerminal();

    case "set":
        import kameloso.thread : CarryingFiber, ThreadMessage;

        void dg()
        {
            import core.thread : Fiber;
            import std.conv : ConvException;

            auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);

            immutable success = thisFiber.payload
                .applyCustomSettings([ slice ], plugin.state.settings);
            if (success) logger.log("Setting changed.");
            // applyCustomSettings displays its own error messages
        }

        auto fiber = new CarryingFiber!(IRCPlugin[])(&dg, 32_768);
        return plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.Save());

    case "whitelist":
    case "operator":
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

    case "summary":
        return plugin.onCommandSummary();

    default:
        logger.error("[admin] Unimplemented bus message verb: ", verb);
        break;
    }
}


version(OmniscientAdmin)
{
    /++
     +  The `kameloso.plugins.core.ChannelPolicy` to mix in awareness with  depending
     +  on whether version `OmniscientAdmin` is set or not.
     +/
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    enum omniscientChannelPolicy = ChannelPolicy.home;
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
 +  The Admin plugin is a plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of the `kameloso.plugins.chatbot.ChatbotPlugin`.
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

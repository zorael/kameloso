/++
 +  The Admin plugin features bot commands which help with debugging the current
 +  state of the running bot, like printing the current list of users, the
 +  current channels, the raw incoming strings from the server, and some other
 +  things along the same line.
 +
 +  It also offers some less debug-y, more administrative functions, like adding
 +  and removing homes on-the-fly, whitelisting or un-whitelisting account
 +  names, joining or leaving channels, as well as plain quitting.
 +
 +  It has a few command, whose names should be fairly self-explanatory:
 +
 +  `addhome`<br>
 +  `delhome`<br>
 +  `join`<br>
 +  `part`<br>
 +  `channels`<br>
 +  `users`<br>
 +  `user`<br>
 +  `printall`<br>
 +  `printbytes`<br>
 +  `resetterm`<br>
 +  `sudo`<br>
 +  `asserts`<br>
 +  `forgetaccounts`<br>
 +  `whitelist`<br>
 +  `unwhitelist`<br>
 +  `writeconfig` | `save`<br>
 +  `quit`
 +
 +  It is optional if you don't intend to be controlling the bot from another
 +  client.
 +/
module kameloso.plugins.admin;

import kameloso.common : logger;
import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency : send;
import std.typecons : Flag, No, Yes;

import std.stdio;

private:


// AdminSettings
/++
 +  All Admin plugin settings, gathered in a struct.
 +/
struct AdminSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
}


// onAnyEvent
/++
 +  Prints all incoming events to the local terminal, in forms depending on
 +  which flags have been set with bot commands.
 +
 +  If `AdminPlugin.printAll` is set by way of invoking `onCommandPrintAll`,
 +  prints all incoming server strings.
 +
 +  If `AdminPlugin.printBytes` is set by way of invoking `onCommandPrintBytes`,
 +  prints all incoming server strings byte per byte.
 +
 +  If `AdminPlugin.printAsserts` is set by way of invoking `onCommandPrintAll`,
 +  prints all incoming events as assert statements, for use in soure code
 +  `unittest` blocks.
 +/
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    if (plugin.printAll) writeln(event.raw, '$');

    if (plugin.printBytes)
    {
        import std.string : representation;

        foreach (i, c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        version(Cygwin_) stdout.flush();
    }

    if (plugin.printAsserts)
    {
        import kameloso.debugging : formatEventAssertBlock;
        import std.algorithm.searching : canFind;

        if ((cast(ubyte[])event.raw).canFind(1))
        {
            logger.warning("event.raw contains CTCP 1 which might not get printed");
        }

        formatEventAssertBlock(stdout.lockingTextWriter, event);
        writeln();
        version(Cygwin_) stdout.flush();
    }
}


// onCommandShowOneUser
/++
 +  Prints the details of a specific, supplied user.
 +
 +  It basically prints the matching `kameloso.ircdefs.IRCUser`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "user")
@Description("[debug] Prints the details of a specific user.")
void onCommandShowOneUser(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : printObject;

    if (event.content in plugin.state.users)
    {
        printObject(plugin.state.users[event.sender.nickname]);
    }
    else
    {
        logger.warning("No such user ", event.content, " in storage");
    }
}


// onCommandForgetUserAccounts
/++
 +  Forgets all users' accounts, prompting new `WHOIS` calls.
 +
 +  This is only done locally to this plugin; other plugins will retain the
 +  information. It is a tool to help diagnose whether logins are being caught
 +  or not, used in tandem with `onCommandShowOneUser`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "forgetaccounts")
@Description("[debug] Forget user accounts (for this plugin).")
void onCommandForgetAccounts(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    foreach (ref user; plugin.state.users)
    {
        writeln("Clearing ", user.nickname);
        user.account = string.init;
        user.lastWhois = 0L;
    }
}


// onCommandSave
/++
 +  Saves current configuration to disk.
 +
 +  This saves all plugins' configuration, not just this plugin's.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "save")
@BotCommand(NickPolicy.required, "writeconfig")
@Description("Saves current configuration to disk.")
void onCommandSave(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : ThreadMessage;

    logger.info("Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `users` array of the `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState` to the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : deepSizeof, printObject;

    logger.trace("Printing Admin's users");

    printObject(plugin.state.bot);

    foreach (key, value; plugin.state.users)
    {
        writefln("%-12s [%s]", key, value);
    }

    writefln("%d bytes from %d users (deep size %d bytes)",
        (IRCUser.sizeof * plugin.state.users.length), plugin.state.users.length,
        plugin.state.users.deepSizeof);

    version(Cygwin_) stdout.flush();
}


// onCommandShowChannels
/++
 +  Prints out the current `channels` array of the `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState` to the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "channels")
@Description("Prints out the current channels array to the local terminal.")
void onCommandShowChannels(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : printObject;

    logger.trace("Printing Admin's channels");

    printObject(plugin.state.bot);

    foreach (key, value; plugin.state.channels)
    {
        writefln("%-12s [%s]", key, value);
    }

    version(Cygwin_) stdout.flush();
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  You need basic knowledge of IRC server strings to use this.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "sudo")
@Description("Sends supplied text to the server, verbatim.")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.raw(event.content);
}


// onCommandQuit
/++
 +  Sends a `QUIT` event to the server.
 +
 +  If any extra text is following the "`quit`" prefix, it uses that as the quit
 +  reason, otherwise it falls back to the default as specified in the
 +  configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "quit")
@Description("Send a QUIT event to the server and exits the program.")
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    with (plugin.state)
    {
        if (event.content.length)
        {
            plugin.quit(event.content);
        }
        else
        {
            plugin.quit();
        }
    }
}


// onCommandAddChan
/++
 +  Adds a channel to the list of currently active home channels, in the
 +  `kameloso.ircdefs.IRCBot.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "addhome")
@Description("Adds a channel to the list of homes.")
void onCommandAddHome(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidChannel;
    import kameloso.string : stripped;
    import std.algorithm.searching : canFind;

    immutable channel = event.content.stripped;

    if (!channel.isValidChannel(plugin.state.bot.server))
    {
        logger.error("Invalid channel");
        return;
    }

    with (plugin.state)
    {
        if (!bot.homes.canFind(channel))
        {
            plugin.join(channel);
        }

        logger.info("Adding channel: ", channel);
        bot.homes ~= channel;
        bot.updated = true;
    }
}


// onCommandDelHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `kameloso.ircdefs.IRCBot.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "delhome")
@Description("Removes a channel from the list of homes.")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidChannel;
    import kameloso.string : stripped;
    import std.algorithm : countUntil, remove;

    immutable channel = event.content.stripped;

    if (!channel.isValidChannel(plugin.state.bot.server))
    {
        logger.error("Invalid channel");
        return;
    }

    with (plugin.state)
    {
        immutable homeIndex = bot.homes.countUntil(channel);

        if (homeIndex == -1)
        {
            logger.errorf("Channel %s was not in bot.homes", channel);
            return;
        }

        bot.homes = bot.homes.remove(homeIndex);
        bot.updated = true;
        plugin.part(channel);
    }
}


// onCommandWhitelist
/++
 +  Adds a nickname to the list of users who may trigger the bot, to the current
 +  `kameloso.ircdefs.IRCBot.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `whitelist` level, as opposed to `anyone` and `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "whitelist")
@Description("Adds a nickname to the whitelist of users who may trigger the bot.")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidNickname;
    import kameloso.string : has, stripped;

    immutable nickname = event.content.stripped;

    if (!nickname.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid nickname: ", nickname);
        return;
    }

    with (plugin.state)
    {
        bot.whitelist ~= nickname;
        bot.updated = true;
        logger.infof("%s added to whitelist", nickname);
    }
}


// onCommandUnwhitelist
/++
 +  Removes a nickname from the list of users who may trigger the bot, from the
 +  `kameloso.ircdefs.IRCBot.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `whitelist` level, as opposed to `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "unwhitelist")
@Description("Removes a nickname from the whitelist of users who may trigger the bot.")
void onCommandUnwhitelist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidNickname;
    import kameloso.string : has, stripped;
    import std.algorithm : countUntil, remove;

    immutable nickname = event.content.stripped;

    if (!nickname.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid nickname: ", nickname);
        return;
    }

    immutable whitelistIndex = plugin.state.bot.whitelist.countUntil(nickname);

    if (whitelistIndex == -1)
    {
        logger.error("No such user in whitelist");
        return;
    }

    with (plugin.state)
    {
        bot.whitelist = bot.whitelist.remove(whitelistIndex);
        bot.updated = true;
        logger.infof("%s removed from whitelist", nickname);
    }
}


// onCommandResetTerminal
/++
 +  Outputs the ASCII control character *15* to the terminal.
 +
 +  This helps with restoring it if the bot has accidentally printed a different
 +  control character putting it would-be binary mode, like what happens when
 +  you try to `cat` a binary file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "resetterm")
@Description("Outputs the ASCII control character 15 to the terminal, " ~
    "to recover from binary garbage mode")
void onCommandResetTerminal(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.bash : TerminalToken;
    write(TerminalToken.reset);
    version(Cygwin_) stdout.flush();
}


// onCommandPrintAll
/++
 +  Toggles a flag to print all incoming events *raw*.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printall")
@Description("[debug] Toggles a flag to print all incoming events raw.")
void onCommandPrintAll(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.printAll = !plugin.printAll;
    logger.info("Printing all: ", plugin.printAll);
}


// onCommandPrintBytes
/++
 +  Toggles a flag to print all incoming events *as individual bytes*.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printbytes")
@Description("[debug] Toggles a flag to print all incoming events as bytes.")
void onCommandPrintBytes(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.printBytes = !plugin.printBytes;
    logger.info("Printing bytes: ", plugin.printBytes);
}


// onCommandAsserts
/++
 +  Toggles a flag to print *assert statements* of incoming events.
 +
 +  This is used to creating unittest blocks in the source code.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "asserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events")
void onCommandAsserts(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.debugging : formatBotAssignment;

    plugin.printAsserts = !plugin.printAsserts;
    logger.info("Printing asserts: ", plugin.printAsserts);
    formatBotAssignment(stdout.lockingTextWriter, plugin.state.bot);
    version(Cygwin_) stdout.flush();
}


// joinPartImpl
/++
 +  Joins or parts a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "join")
@BotCommand(NickPolicy.required, "part")
@Description("Joins/parts a channel.")
void onCommandJoinPart(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : joiner, splitter;
    import std.array : array;
    import std.conv : to;
    import std.uni : asLowerCase;

    if (!event.content.length)
    {
        logger.error("No channels supplied...");
        return;
    }

    immutable channels = event.content
        .splitter(" ")
        .joiner(",")
        .array
        .to!string;

    if (event.aux.asLowerCase.equal("join"))
    {
        plugin.join(channels);
    }
    else
    {
        plugin.part(channels);
    }
}


// onSetCommand
/++
 +  Sets a plugin option by variable string name.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(NickPolicy.required, "set")
@Description("[debug] Changes a plugin's settings")
void onSetCommand(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    plugin.setEvent = event;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin)plugin);
}


// peekPlugins
/++
 +  Takes a reference to the main `kameloso.common.Client.plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s, and applies any queued custom settings
 +  to them, as were saved in `plugin.setEvent` upon someone requesting the verb
 +  "`set`".
 +/
void peekPlugins(AdminPlugin plugin, IRCPlugin[] plugins)
{
    if (plugin.setEvent == IRCEvent.init) return;
    scope(exit) plugin.setEvent = IRCEvent.init;

    plugins.applyCustomSettings([ plugin.setEvent.content ]);
}


mixin UserAwareness;
mixin ChannelAwareness;

public:


// AdminPlugin
/++
 +  The `AdminPlugin` is a plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of the `kameloso.plugins.chatbot.ChatbotPlugin`.
 +/
final class AdminPlugin : IRCPlugin
{
    /++
     +  Toggles whether `onAnyEvent` prints the raw strings of all incoming
     +  events.
     +/
    bool printAll;

    /++
     +  Toggles whether `onAnyEvent` prints the raw bytes of the *contents* of
     +  events.
     +/
    bool printBytes;

    /++
     +  Toggles whether `onAnyEvent` prints assert statements for incoming
     +  events.
     +/
    bool printAsserts;

    /++
    +   The event that spawned a "`set`" request. As a hack it is currently
    +   stored here, so the plugin knows what to do when the results of
    +   `kameloso.common.ThreadMessage.PeekPlugins` return.
    +/
    IRCEvent setEvent;

    /// All Admin options gathered.
    @Settings AdminSettings adminSettings;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

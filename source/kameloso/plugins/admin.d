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
    import kameloso.uda : Unconfigurable;

    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;

    @Unconfigurable
    {
        /++
        +  Toggles whether `onAnyEvent` prints the raw strings of all incoming
        +  events.
        +/
        bool printAll;

        /++
        +  Toggles whether `onAnyEvent` prints the raw bytes of the *contents*
        +  of events.
        +/
        bool printBytes;

        /++
        +  Toggles whether `onAnyEvent` prints assert statements for incoming
        +  events.
        +/
        bool printAsserts;
    }
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

    if (plugin.adminSettings.printAll) writeln(event.raw, '$');

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        version(Cygwin_) stdout.flush();
    }

    if (plugin.adminSettings.printAsserts)
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

    if (const user = event.content in plugin.state.users)
    {
        printObject(*user);
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
        logger.warning("Invalid channel: ", channel);
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
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : remove;

    immutable channel = event.content.stripped;

    if (!channel.isValidChannel(plugin.state.bot.server))
    {
        logger.warning("Invalid channel: ", channel);
        return;
    }

    with (plugin.state)
    {
        immutable homeIndex = bot.homes.countUntil(channel);

        if (homeIndex == -1)
        {
            logger.warningf("Channel %s was not in bot.homes", channel);
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
@Description("Adds an account to the whitelist of users who may trigger the bot.")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidNickname;
    import kameloso.string : has, stripped;

    immutable account = event.content.stripped;

    if (!account.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid account: ", account);
        return;
    }

    plugin.alterAccountClassifier(Yes.add, "whitelist", account);
}


// onCommandDewhitelist
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
@BotCommand(NickPolicy.required, "dewhitelist")
@Description("Removes an account from the whitelist of users who may trigger the bot.")
void onCommandDewhitelist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;

    plugin.alterAccountClassifier(No.add, "whitelist", event.content.stripped);
}


// onCommandBlacklist
/++
 +  Adds a nickname to the list of users who may not trigger the bot whatsoever,
 +  even on actions annotated `PrivilegeLevel.anyone`.
 +
 +  This is on a `whitelist` level, as opposed to `anyone` and `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "blacklist")
@Description("Adds an account to the blacklist, exempting them from triggering the bot.")
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.irc : isValidNickname;
    import kameloso.string : has, stripped;

    immutable account = event.content.stripped;

    if (!account.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid account: ", account);
        return;
    }

    plugin.alterAccountClassifier(Yes.add, "blacklist", account);
}


// onCommandDeblacklist
/++
 +  Removes a nickname from the list of users who may not trigger the bot
 +  whatsoever.
 +
 +  This is on a `whitelist` level, as opposed to `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "deblacklist")
@Description("Removes an account from the blacklist, allowing them to trigger the bot again.")
void onCommandDeblacklist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;

    plugin.alterAccountClassifier(No.add, "blacklist", event.content.stripped);
}


// alterAccountClassifier
/++
 +  Adds or removes an account from the file of user classifier definitions,
 +  and reloads all plugins to make them read the updated lists.
 +/
void alterAccountClassifier(AdminPlugin plugin, const Flag!"add" add,
    const string section, const string account)
{
    import kameloso.json : JSONStorage;
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;
    import std.json : JSONValue;

    assert(((section == "whitelist") || (section == "blacklist")), section);

    JSONStorage json;
    json.reset();
    json.load(plugin.usersFile);

    /*if ("admin" !in json)
    {
        json["admin"] = null;
        json["admin"].array = null;
    }*/

    if ("whitelist" !in json)
    {
        json["whitelist"] = null;
        json["whitelist"].array = null;
    }

    if ("blacklist" !in json)
    {
        json["blacklist"] = null;
        json["blacklist"].array = null;
    }

    immutable accountAsJSON = JSONValue(account);

    if (add)
    {
        json[section].array ~= accountAsJSON;
    }
    else
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        immutable index = json[section].array.countUntil(accountAsJSON);

        if (index == -1)
        {
            logger.logf("No such account %s to de%s", account, section);
            return;
        }

        json[section] = json[section].array.remove(index);
    }

    logger.logf("%s %s%sed", account, (add ? string.init : "de"), section);
    json.save(plugin.usersFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
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

    plugin.adminSettings.printAll = !plugin.adminSettings.printAll;
    logger.info("Printing all: ", plugin.adminSettings.printAll);
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

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
    logger.info("Printing bytes: ", plugin.adminSettings.printBytes);
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

    plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;
    logger.info("Printing asserts: ", plugin.adminSettings.printAsserts);
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
        logger.warning("No channels supplied...");
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

    plugin.currentPeekType = AdminPlugin.PeekType.set;
    IRCEvent mutEvent = event;
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin)plugin, mutEvent);
}


// onAuthCommand
/++
 +  Asks the `ConnectService` to (re-)authenticate to services.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@BotCommand(NickPolicy.required, "auth")
@Description("(Re-)authenticates with services. Useful if the server has forcefully logged us out.")
void onCommandAuth(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    plugin.currentPeekType = AdminPlugin.PeekType.auth;
    IRCEvent mutEvent;  // may as well be .init, we won't use the information
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(),
        cast(shared IRCPlugin)plugin, mutEvent);
}


// onCommandStatus
/++
 +  Dumps information about the current state of the bot to the local terminal.
 +
 +  This can be very spammy.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "status")
@Description("[debug] Dumps information about the current state of the bot to the local terminal.")
void onCommandStatus(AdminPlugin plugin)
{
    import kameloso.common : printObject, printObjects;
    import std.stdio : writeln, stdout;

    logger.log("Current state:");
    printObjects!(Yes.printAll)(plugin.state.bot, plugin.state.bot.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable name, const channel; plugin.state.channels)
    {
        writeln(name);
        printObject(channel);
    }
    writeln();

    logger.log("Users:");
    foreach (immutable nickname, const user; plugin.state.users)
    {
        printObject(user);
    }

    version(Cygwin_) stdout.flush();
}


// peekPlugins
/++
 +  Takes a reference to the main `kameloso.common.Client.plugins` array of
 +  `kameloso.plugins.common.IRCPlugin`s. Either sets a plugin's settings' value
 +  by name, or tells the `kameloso.plugins.connect.ConnectService` to reauth
 +  with services, depending on how the peek was requested.
 +/
void peekPlugins(AdminPlugin plugin, IRCPlugin[] plugins, const IRCEvent event)
{
    with (plugin.PeekType)
    final switch (plugin.currentPeekType)
    {
    case set:
        plugins.applyCustomSettings([ event.content ]);
        break;

    case auth:
        foreach (basePlugin; plugins)
        {
            import kameloso.plugins.connect;

            ConnectService service = cast(ConnectService)basePlugin;
            if (!service) continue;

            service.auth(service);
            plugin.state.bot = service.state.bot;
            plugin.state.bot.updated = true;
            break;
        }
        break;

    case unset:
        logger.warning("Admin peekPlugins type of peek was unset!");
        break;
    }

    plugin.currentPeekType = AdminPlugin.PeekType.unset;
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
    /// The kind of peek that we know the incoming `peekPlugins` will be of.
    enum PeekType
    {
        unset,
        set,
        auth,
    }

    /// FIXME: File with user definitions. Must be the same as in persistence.d.
    enum usersFile = "users.json";

    /// Which sort of peek is currently in flight; see `peekPlugins`.
    PeekType currentPeekType;

    /// All Admin options gathered.
    @Settings AdminSettings adminSettings;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

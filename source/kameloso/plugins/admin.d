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
 +  `users`<br>
 +  `user`<br>
 +  `printraw`<br>
 +  `printbytes`<br>
 +  `resetterm`<br>
 +  `sudo`<br>
 +  `printasserts`<br>
 +  `forgetaccounts`<br>
 +  `whitelist`<br>
 +  `dewhitelist`<br>
 +  `blacklist`<br>
 +  `dewblacklist`<br>
 +  `writeconfig` | `save`<br>
 +  `quit`<br>
 +  `set`<br>
 +  `auth`<br>
 +  `status`
 +
 +  It is optional if you don't intend to be controlling the bot from another
 +  client.
 +/
module kameloso.plugins.admin;

version(WithPlugins):

private:

import kameloso.common : logger;
import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.messaging;

import std.concurrency : send;
import std.typecons : Flag, No, Yes;

import std.stdio;


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
        bool printRaw;

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
 +  If `AdminPlugin.printRaw` is set by way of invoking `onCommandprintRaw`,
 +  prints all incoming server strings.
 +
 +  If `AdminPlugin.printBytes` is set by way of invoking `onCommandPrintBytes`,
 +  prints all incoming server strings byte per byte.
 +
 +  If `AdminPlugin.printAsserts` is set by way of invoking `onCommandprintRaw`,
 +  prints all incoming events as assert statements, for use in soure code
 +  `unittest` blocks.
 +/
debug
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) writeln(event.tags, '$');
        writeln(event.raw, '$');
        version(Cygwin_) stdout.flush();
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        version(Cygwin_) stdout.flush();
    }

    debug if (plugin.adminSettings.printAsserts)
    {
        import kameloso.debugging : formatEventAssertBlock;
        import kameloso.string : contains;

        if (event.raw.contains(1))
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
 +  Prints the details of one or more specific, supplied users to the local
 +  terminal.
 +
 +  It basically prints the matching `kameloso.ircdefs.IRCUser`.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "user")
@Description("[debug] Prints out information about one or more specific users " ~
    "the local terminal.", "$command [nickname]")
void onCommandShowUser(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.printing : printObject;
    import std.algorithm.iteration : splitter;

    foreach (immutable username; event.content.splitter(" "))
    {
        if (const user = username in plugin.state.users)
        {
            printObject(*user);
        }
        else
        {
            logger.trace("No such user: ", username);
        }
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

    import kameloso.thread : ThreadMessage;

    logger.info("Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `users` array of the `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState` to the local terminal.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.printing : printObject;
    import kameloso.objmanip : deepSizeof;

    logger.trace("Printing Admin's users");

    foreach (key, value; plugin.state.users)
    {
        printObject(value);
    }

    writefln("%d bytes from %d users (deep size %d bytes)",
        (IRCUser.sizeof * plugin.state.users.length), plugin.state.users.length,
        plugin.state.users.deepSizeof);

    version(Cygwin_) stdout.flush();
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "sudo")
@Description("[debug] Sends supplied text to the server, verbatim.",
    "$command [raw string]")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.state.raw(event.content);
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
@Description("Send a QUIT event to the server and exits the program.",
    "$command [optional quit reason]")
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    if (event.content.length)
    {
        plugin.state.quit(event.content);
    }
    else
    {
        plugin.state.quit();
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
@Description("Adds a channel to the list of homes.", "$command [channel]")
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
            plugin.state.join(channel);
            logger.info("Adding home: ", channel);
            bot.homes ~= channel;
            bot.updated = true;
        }
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
@Description("Removes a channel from the list of homes.", "$command [channel]")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : remove;

    immutable channel = event.content.stripped;

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
        plugin.state.part(channel);
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
@Description("Adds an account to the whitelist of users who may trigger the bot.",
    "$command [account to whitelist]")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;
    return plugin.addToList(event.content.stripped, "whitelist");
}


// addToList
/++
 +  Adds an account to either the whitelist or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      specified = The nickname or account to white-/blacklist.
 +      list = Which of "whitelist" or "blacklist" to add to.
 +/
void addToList(AdminPlugin plugin, const string specified, const string list)
{
    import kameloso.irc : isValidNickname;
    import kameloso.string : contains, stripped;

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        return plugin.alterAccountClassifier(Yes.add, list, user.account);
    }
    else if (!specified.isValidNickname(plugin.state.bot.server))
    {
        logger.warning("Invalid nickname/account: ", specified);
    }
    else
    {
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        // User not on record or on record but no account; WHOIS and try based on results

        void dg()
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
            assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

            const whoisEvent = thisFiber.payload;
            writeln(whoisEvent.type);
            IRCUser whoisUser;

            with (IRCEvent.Type)
            switch (whoisEvent.type)
            {
            case RPL_WHOISACCOUNT:
            case RPL_WHOISREGNICK:
                whoisUser = whoisEvent.target;
                break;

            case ACCOUNT:
                whoisUser = whoisEvent.sender;
                break;

            case RPL_ENDOFWHOIS:
                logger.logf("% is not logged onto a service account.", specified);
                return;  // End fiber

            case ERR_NOSUCHNICK:
                whoisUser = whoisEvent.target;
                break;  // Drop down

            default:
                assert(0);
            }

            immutable m = plugin.state.bot.server.caseMapping;
            if (IRCUser.toLowercase(specified, m) != IRCUser.toLowercase(whoisUser.nickname, m))
            {
                // wrong WHOIS; reset and await a new one
                Fiber.yield();
                return dg();
            }

            immutable endAccount = whoisUser.account.length ? whoisUser.account : specified;
            plugin.alterAccountClassifier(Yes.add, list, endAccount);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&dg);
        plugin.state.awaitingFibers[IRCEvent.Type.RPL_WHOISACCOUNT] ~= fiber;
        plugin.state.awaitingFibers[IRCEvent.Type.RPL_WHOISREGNICK] ~= fiber;
        plugin.state.awaitingFibers[IRCEvent.Type.RPL_ENDOFWHOIS] ~= fiber;
        plugin.state.awaitingFibers[IRCEvent.Type.ERR_NOSUCHNICK] ~= fiber;

        import kameloso.messaging : raw;
        plugin.state.raw("WHOIS " ~ specified);
    }
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
@Description("Removes an account from the whitelist of users who may trigger the bot.",
    "$command [account to remove from whitelist]")
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
@Description("Adds an account to the blacklist, exempting them from triggering the bot.",
    "$command [account to blacklist]")
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;
    return plugin.addToList(event.content.stripped, "blacklist");
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
@Description("Removes an account from the blacklist, allowing them to trigger the bot again.",
    "$command [account to remove from whitelist]")
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
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;
    import std.json : JSONValue;

    assert(((section == "whitelist") || (section == "blacklist")), section);

    string infotint, logtint;

    version(Colours)
    {
        import kameloso.common : settings;

        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

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
        import std.algorithm.searching : canFind;

        if (json[section].array.canFind(accountAsJSON))
        {
            logger.logf("Account %s%s%s already %sed.", infotint, account, logtint, section);
            return;
        }
        else
        {
            json[section].array ~= accountAsJSON;
        }
    }
    else
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        immutable index = json[section].array.countUntil(accountAsJSON);

        if (index == -1)
        {
            logger.logf("No such account %s%s%s to de%s.", infotint, account, logtint, section);
            return;
        }

        json[section] = json[section].array.remove(index);
    }

    logger.logf("%s%sed %s%s%s.", (add ? string.init : "de"), section, infotint, account, logtint);
    json.save(plugin.userFile);

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


// onCommandprintRaw
/++
 +  Toggles a flag to print all incoming events *raw*.
 +
 +  This is for debugging purposes.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printraw")
@Description("[debug] Toggles a flag to print all incoming events raw.")
void onCommandprintRaw(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
    logger.info("Printing all: ", plugin.adminSettings.printRaw);
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
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printasserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events")
void onCommandAsserts(AdminPlugin plugin)
{
    if (!plugin.adminSettings.enabled) return;

    plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;
    logger.info("Printing asserts: ", plugin.adminSettings.printAsserts);

    if (plugin.adminSettings.printAsserts)
    {
        import kameloso.debugging : formatBotAssignment;
        // Only print the bot assignment if we're toggling it on
        formatBotAssignment(stdout.lockingTextWriter, plugin.state.bot);
    }

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
@Description("Joins/parts a channel.", "$command [channel]")
void onCommandJoinPart(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : joiner, splitter;
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
        .to!string;

    if (event.aux.asLowerCase.equal("join"))
    {
        plugin.state.join(channels);
    }
    else
    {
        plugin.state.part(channels);
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
@Description("Changes a plugin's settings", "$command [plugin.setting=value]")
void onSetCommand(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.thread : CarryingFiber, ThreadMessage;
    import std.concurrency : send;

    void dg()
    {
        import core.thread : Fiber;
        import std.conv : ConvException;

        auto thisFiber = cast(CarryingFiber!(IRCPlugin[]))(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        try
        {
            thisFiber.payload.applyCustomSettings([ event.content ]);
            logger.info("Setting changed.");
        }
        catch (const ConvException e)
        {
            logger.warning("Invalid setting.");
        }
    }

    auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
    plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);
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

    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;

    plugin.state.mainThread.send(ThreadMessage.BusMessage(), "auth");
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "status")
@Description("[debug] Dumps information about the current state of the bot to the local terminal.")
void onCommandStatus(AdminPlugin plugin)
{
    import kameloso.printing : printObjects;
    import std.stdio : writeln, stdout;

    logger.log("Current state:");
    printObjects!(Yes.printAll)(plugin.state.bot, plugin.state.bot.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable name, const channel; plugin.state.channels)
    {
        writeln(name);
        printObjects(channel);
    }
    //writeln();

    /*logger.log("Users:");
    foreach (immutable nickname, const user; plugin.state.users)
    {
        printObject(user);
    }*/
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
    /// File with user definitions. Must be the same as in persistence.d.
    @Resource string userFile = "users.json";

    /// All Admin options gathered.
    @Settings AdminSettings adminSettings;

    mixin IRCPluginImpl;
}

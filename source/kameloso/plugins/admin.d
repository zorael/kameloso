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
 +  `user`<br>
 +  `save` | `writeconfig`<br>
 +  `users`<br>
 +  `sudo`<br>
 +  `quit`<br>
 +  `addhome`<br>
 +  `delhome`<br>
 +  `whitelist`<br>
 +  `dewhitelist`<br>
 +  `blacklist`<br>
 +  `deblacklist`<br>
 +  `resetterm`<br>
 +  `printraw`<br>
 +  `printbytes`<br>
 +  `printasserts`<br>
 +  `join`<br>
 +  `part`<br>
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

import kameloso.common : logger, settings;
import kameloso.plugins.common;
import kameloso.irc : IRCClient;
import kameloso.irccolours : IRCColour, ircBold, ircColour;
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
 +  prints all incoming events as assert statements, for use in source code
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


// onCommandShowUser
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
    "to the local terminal.", "$command [nickname] [nickname] ...")
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
            string message;

            if (settings.colouredOutgoing)
            {
                message = "No such user: " ~ username.ircColour(IRCColour.red).ircBold;
            }
            else
            {
                message = "No such user: " ~ username;
            }

            plugin.state.privmsg(event.channel, event.sender.nickname, message);
        }
    }
}


// onCommandSave
/++
 +  Saves current configuration to disk.
 +
 +  This saves all plugins' settings, not just this plugin's.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "save")
@BotCommand(NickPolicy.required, "writeconfig")
@Description("Saves current configuration to disk.")
void onCommandSave(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.thread : ThreadMessage;

    plugin.state.privmsg(event.channel, event.sender.nickname, "Saving configuration to disk.");
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
    import std.stdio : stdout, writeln;

    foreach (immutable name, const user; plugin.state.users)
    {
        writeln(name);
        printObject(user);
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
 +  `kameloso.irc.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  Follows up with a Fiber to verify that the channel was actually joined.
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

    immutable channelToAdd = event.content.stripped;

    if (!channelToAdd.isValidChannel(plugin.state.client.server))
    {
        plugin.state.privmsg(event.channel, event.sender.nickname, "Invalid channel name.");
        return;
    }

    with (plugin.state)
    {
        if (client.homes.canFind(channelToAdd))
        {
            plugin.state.privmsg(event.channel, event.sender.nickname,
                "We are already in that home channel.");
            return;
        }

        // We need to add it to the homes array so as to get ChannelPolicy.home
        // ChannelAwareness to pick up the SELFJOIN.
        client.homes ~= channelToAdd;
        client.updated = true;
        plugin.state.join(channelToAdd);

        plugin.state.privmsg(event.channel, event.sender.nickname, "Home added.");

        // We have to follow up and see if we actually managed to join the channel
        // There are plenty ways for it to fail.

        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        void dg()
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
            assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

            const followupEvent = thisFiber.payload;

            if (followupEvent.channel != channelToAdd)
            {
                // Different channel; yield and reset fiber, wait for another event
                thisFiber.payload = IRCEvent.init;
                Fiber.yield();
                return dg();
            }

            with (IRCEvent.Type)
            switch (followupEvent.type)
            {
            case SELFJOIN:
                // Success!
                /*client.homes ~= followupEvent.channel;
                client.updated = true;*/
                return;

            case ERR_LINKCHANNEL:
                // We were redirected. Still assume we wanted to add this one?
                logger.log("Redirected!");
                client.homes ~= followupEvent.content;
                // Drop down and undo original addition
                break;

            default:
                plugin.state.privmsg(event.channel, event.sender.nickname,
                    "Failed to join home channel.");
                break;
            }

            // Undo original addition
            import std.algorithm.mutation : SwapStrategy, remove;
            import std.algorithm.searching : countUntil;

            immutable homeIndex = client.homes.countUntil(followupEvent.channel);
            if (homeIndex != -1)
            {
                client.homes = client.homes.remove!(SwapStrategy.unstable)(homeIndex);
                client.updated = true;
            }
            else
            {
                logger.error("Tried to remove non-existent home channel.");
            }
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&dg);

        with (IRCEvent.Type)
        {
            static immutable types =
            [
                ERR_BANNEDFROMCHAN,
                ERR_INVITEONLYCHAN,
                ERR_BADCHANNAME,
                ERR_LINKCHANNEL,
                ERR_TOOMANYCHANNELS,
                ERR_FORBIDDENCHANNEL,
                ERR_CHANNELISFULL,
                ERR_BADCHANNELKEY,
                ERR_BADCHANNAME,
                RPL_BADCHANPASS,
                ERR_SECUREONLYCHAN,
                ERR_SSLONLYCHAN,
                SELFJOIN,
            ];

            plugin.awaitEvents(fiber, types);
        }
    }
}


// onCommandDelHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `kameloso.irc.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "delhome")
@Description("Removes a channel from the list of homes and leaves it.", "$command [channel]")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import kameloso.string : stripped;
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;

    immutable channel = event.content.stripped;

    with (plugin.state)
    {
        immutable homeIndex = client.homes.countUntil(channel);

        if (homeIndex == -1)
        {
            import std.format : format;

            string message;

            if (settings.colouredOutgoing)
            {
                message = "Channel %s was not listed as a home.".format(channel.ircBold);
            }
            else
            {
                message = "Channel %s was not listed as a home.".format(channel);
            }

            plugin.state.privmsg(event.channel, event.sender.nickname, message);
            return;
        }

        client.homes = client.homes.remove!(SwapStrategy.unstable)(homeIndex);
        client.updated = true;
        plugin.state.part(channel);
    }
}


// onCommandWhitelist
/++
 +  Adds a nickname to the list of users who may trigger the bot, to the current
 +  `kameloso.irc.IRCClient.whitelist` of the current `AdminPlugin`'s
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
    plugin.addToList(event.content.stripped, "whitelist");
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
    import kameloso.common : settings;
    import kameloso.irc : isValidNickname;
    import kameloso.string : contains, stripped;

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        return plugin.alterAccountClassifier(Yes.add, list, user.account);
    }
    else if (!specified.isValidNickname(plugin.state.client.server))
    {
        string logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        logger.warning("Invalid nickname/account: ", logtint, specified);
        return;
    }

    void onSuccess(const string id)
    {
        plugin.alterAccountClassifier(Yes.add, list, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    // User not on record or on record but no account; WHOIS and try based on results

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// onCommandDewhitelist
/++
 +  Removes a nickname from the list of users who may trigger the bot, from the
 +  `kameloso.irc.IRCClient.whitelist` of the current `AdminPlugin`'s
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
    plugin.addToList(event.content.stripped, "blacklist");
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
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable index = json[section].array.countUntil(accountAsJSON);

        if (index == -1)
        {
            logger.logf("No such account %s%s%s to de%s.", infotint, account, logtint, section);
            return;
        }

        json[section] = json[section].array.remove!(SwapStrategy.unstable)(index);
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
void onCommandprintRaw(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import std.conv : text;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    string message;

    if (settings.colouredOutgoing)
    {
        message = "Printing all: " ~ plugin.adminSettings.printRaw.text.ircBold;
    }
    else
    {
        message = "Printing all: " ~ plugin.adminSettings.printRaw.text;
    }

    plugin.state.privmsg(event.channel, event.sender.nickname, message);
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
void onCommandPrintBytes(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import std.conv : text;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    string message;

    if (settings.colouredOutgoing)
    {
        message = "Printing bytes: " ~ plugin.adminSettings.printBytes.text.ircBold;
    }
    else
    {
        message = "Printing bytes: " ~ plugin.adminSettings.printBytes.text;
    }

    plugin.state.privmsg(event.channel, event.sender.nickname, message);
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
void onCommandAsserts(AdminPlugin plugin, const IRCEvent event)
{
    if (!plugin.adminSettings.enabled) return;

    import std.conv : text;

    plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

    string message;

    if (settings.colouredOutgoing)
    {
        message = "Printing asserts: " ~ plugin.adminSettings.printAsserts.text.ircBold;
    }
    else
    {
        message = "Printing asserts: " ~ plugin.adminSettings.printAsserts.text;
    }

    plugin.state.privmsg(event.channel, event.sender.nickname, message);

    if (plugin.adminSettings.printAsserts)
    {
        import kameloso.debugging : formatClientAssignment;
        // Print the bot assignment but only if we're toggling it on
        formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
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
        plugin.state.privmsg(event.channel, event.sender.nickname, "No channels supplied ...");
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
            plugin.state.privmsg(event.channel, event.sender.nickname, "Setting changed.");
        }
        catch (const ConvException e)
        {
            plugin.state.privmsg(event.channel, event.sender.nickname, "Invalid setting.");
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
    printObjects!(Yes.printAll)(plugin.state.client, plugin.state.client.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        writeln(channelName);
        printObjects(channel);
    }
    //writeln();

    /*logger.log("Users:");
    foreach (immutable nickname, const user; plugin.state.users)
    {
        writeln(nickname);
        printObject(user);
    }*/
}


// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`admin verb`"
 +  header, and calls functions based on the payload message.
 +
 +  This is used in the Pipeline plugin, to allow us to trigger admin verbs via
 +  the command-line pipe.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
import kameloso.thread : Sendable;
void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    if (header == "piped verb")
    {
        import kameloso.thread : BusMessage;

        auto message = cast(BusMessage!string)content;
        assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

        switch (message.payload)
        {
        case "status":
            return plugin.onCommandStatus();

        case "users":
            return plugin.onCommandShowUsers();

        case "printraw":
            plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
            return;

        case "printbytes":
            plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
            return;

        case "printasserts":
            plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;
            return;

        default:
            break;
        }
    }
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

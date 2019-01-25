/++
 +  The Admin plugin features bot commands which help with debugging the current
 +  state of the running bot, like printing the current list of users, the
 +  current channels, the raw incoming strings from the server, and some other
 +  things along the same line.
 +
 +  It also offers some less debug-y, more administrative functions, like adding
 +  and removing homes on-the-fly, whitelisting or de-whitelisting account
 +  names, joining or leaving channels, as well as plain quitting.
 +
 +  It has a few command, whose names should be fairly self-explanatory:
 +
 +  `user` (debug)<br>
 +  `save` | `writeconfig`<br>
 +  `users` (debug)<br>
 +  `sudo` (debug)<br>
 +  `quit`<br>
 +  `addhome`<br>
 +  `delhome`<br>
 +  `whitelist`<br>
 +  `dewhitelist`<br>
 +  `blacklist`<br>
 +  `deblacklist`<br>
 +  `resetterm`<br>
 +  `printraw` (debug)<br>
 +  `printbytes` (debug)<br>
 +  `printasserts` (debug)<br>
 +  `join`<br>
 +  `part`<br>
 +  `set`<br>
 +  `auth`<br>
 +  `status` (debug)
 +
 +  It is optional if you don't intend to be controlling the bot from another
 +  client or via the terminal.
 +/
module kameloso.plugins.admin;

version(WithPlugins):
version(WithAdminPlugin):

//version = OmniscientAdmin;

private:

import kameloso.common : logger, settings;
import kameloso.plugins.common;
import kameloso.irc.common : IRCClient;
import kameloso.irc.colours : IRCColour, ircBold, ircColour, ircColourNick;
import kameloso.irc.defs;
import kameloso.messaging;

import std.concurrency : send;
import std.typecons : Flag, No, Yes;


// AdminSettings
/++
 +  All Admin plugin settings, gathered in a struct.
 +/
struct AdminSettings
{
    import kameloso.uda : Unconfigurable;

    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    @Unconfigurable
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
 +  prints all incoming events as assert statements, for use in generating source
 +  code `unittest` blocks.
 +/
debug
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
    import std.stdio : stdout, writefln, writeln;

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) writeln(event.tags, '$');
        writeln(event.raw, '$');
        if (settings.flush) stdout.flush();
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        if (settings.flush) stdout.flush();
    }

    if (plugin.adminSettings.printAsserts)
    {
        import kameloso.debugging : formatEventAssertBlock;
        import kameloso.string : contains;

        if (event.raw.contains(1))
        {
            logger.warning("event.raw contains CTCP 1 which might not get printed");
        }

        formatEventAssertBlock(stdout.lockingTextWriter, event);
        writeln();

        if (plugin.state.client != plugin.previousClient)
        {
            import kameloso.debugging : formatDelta;

            /+writeln("/*");
            /*writeln("with (parser.client)");
            writeln("{");*/
            stdout.lockingTextWriter.formatDelta!(No.asserts)
                (plugin.previousClient, plugin.state.client, 0);
            /*writeln("}");*/
            writeln("*/");
            writeln();+/

            writeln("with (parser.client)");
            writeln("{");
            stdout.lockingTextWriter.formatDelta!(Yes.asserts)
                (plugin.previousClient, plugin.state.client, 1);
            writeln("}\n");

            plugin.previousClient = plugin.state.client;
        }

        if (settings.flush) stdout.flush();
    }
}


// onCommandShowUser
/++
 +  Prints the details of one or more specific, supplied users to the local terminal.
 +
 +  It basically prints the matching `kameloso.irc.defs.IRCUser`.
 +/
debug
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "user")
@Description("[debug] Prints out information about one or more specific users " ~
    "to the local terminal.", "$command [nickname] [nickname] ...")
void onCommandShowUser(AdminPlugin plugin, const IRCEvent event)
{
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
 +  This saves all plugins' settings, not just this plugin's, effectively
 +  regenerating the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "save")
@BotCommand(PrefixPolicy.nickname, "writeconfig")
@Description("Saves current configuration to disk.")
void onCommandSave(AdminPlugin plugin, const IRCEvent event)
{
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
@BotCommand(PrefixPolicy.nickname, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
    import kameloso.printing : printObject;
    import kameloso.objmanip : deepSizeof;
    import std.stdio : stdout, writefln, writeln;

    foreach (immutable name, const user; plugin.state.users)
    {
        writeln(name);
        printObject(user);
    }

    writefln("%d bytes from %d users (deep size %d bytes)",
        (IRCUser.sizeof * plugin.state.users.length), plugin.state.users.length,
        plugin.state.users.deepSizeof);

    if (settings.flush) stdout.flush();
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
@BotCommand(PrefixPolicy.nickname, "sudo")
@Description("[debug] Sends supplied text to the server, verbatim.",
    "$command [raw string]")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    plugin.state.raw(event.content);
}


// onCommandQuit
/++
 +  Sends a `QUIT` event to the server.
 +
 +  If any extra text is following the "`quit`" prefix, it uses that as the quit
 +  reason, otherwise it falls back to the default as specified in the configuration file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "quit")
@Description("Send a QUIT event to the server and exits the program.",
    "$command [optional quit reason]")
void onCommandQuit(AdminPlugin plugin, const IRCEvent event)
{
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
 +  `kameloso.irc.common.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  Follows up with a `core.thread.Fiber` to verify that the channel was actually joined.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "addhome")
@Description("Adds a channel to the list of homes.", "$command [channel]")
void onCommandAddHome(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.irc.common : isValidChannel;
    import kameloso.string : stripped;
    import std.algorithm.searching : canFind;
    import std.uni : toLower;

    immutable channelToAdd = event.content.stripped.toLower;

    if (!channelToAdd.isValidChannel(plugin.state.client.server))
    {
        plugin.state.privmsg(event.channel, event.sender.nickname, "Invalid channel name.");
        return;
    }

    if (plugin.state.client.homes.canFind(channelToAdd))
    {
        plugin.state.privmsg(event.channel, event.sender.nickname, "We are already in that home channel.");
        return;
    }

    // We need to add it to the homes array so as to get ChannelPolicy.home
    // ChannelAwareness to pick up the SELFJOIN.
    plugin.state.client.homes ~= channelToAdd;
    plugin.state.client.updated = true;
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
            // Different channel; yield fiber, wait for another event
            Fiber.yield();
            return dg();
        }

        with (IRCEvent.Type)
        switch (followupEvent.type)
        {
        case SELFJOIN:
            // Success!
            /*client.homes ~= followupChannel;
            client.updated = true;*/
            return;

        case ERR_LINKCHANNEL:
            // We were redirected. Still assume we wanted to add this one?
            logger.log("Redirected!");
            plugin.state.client.homes ~= followupEvent.content.toLower;
            // Drop down and undo original addition
            break;

        default:
            plugin.state.privmsg(event.channel, event.sender.nickname, "Failed to join home channel.");
            break;
        }

        // Undo original addition
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable homeIndex = plugin.state.client.homes.countUntil(followupEvent.channel);
        if (homeIndex != -1)
        {
            plugin.state.client.homes = plugin.state.client.homes
                .remove!(SwapStrategy.unstable)(homeIndex);
            plugin.state.client.updated = true;
        }
        else
        {
            logger.error("Tried to remove non-existent home channel.");
        }
    }

    Fiber fiber = new CarryingFiber!IRCEvent(&dg);

    with (IRCEvent.Type)
    {
        static immutable IRCEvent.Type[13] types =
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


// onCommandDelHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `kameloso.irc.common.IRCClient.homes` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "delhome")
@Description("Removes a channel from the list of homes and leaves it.", "$command [channel]")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripped;
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;

    immutable channel = event.content.stripped;
    immutable homeIndex = plugin.state.client.homes.countUntil(channel);

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

    plugin.state.client.homes = plugin.state.client.homes
        .remove!(SwapStrategy.unstable)(homeIndex);
    plugin.state.client.updated = true;
    plugin.state.part(channel);
    plugin.state.privmsg(event.channel, event.sender.nickname, "Home removed.");
}


// onCommandWhitelist
/++
 +  Adds a nickname to the list of users who may trigger the bot, to the current
 +  `kameloso.irc.common.IRCClient.Class.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `whitelist` level, as opposed to `anyone` and `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "whitelist")
@Description("Adds an account to the whitelist of users who may trigger the bot.",
    "$command [account to whitelist]")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripped;
    plugin.lookupEnlist(event.content.stripped, "whitelist", event);
}


// lookupEnlist
/++
 +  Adds an account to either the whitelist or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      specified = The nickname or account to white-/blacklist.
 +      list = Which of "whitelist" or "blacklist" to add to.
 +      event = Optional instigating `kameloso.irc.defs.IRCEvent`.
 +/
void lookupEnlist(AdminPlugin plugin, const string specified, const string list,
    const IRCEvent event = IRCEvent.init)
{
    import kameloso.common : settings;
    import kameloso.irc.common : isValidNickname;
    import kameloso.string : contains, stripped;

    /// Report result, either to the local terminal or to the IRC channel/sender
    void report(const AlterationResult result, const string id)
    {
        import std.format : format;

        if (event.sender.nickname.length)
        {
            // IRC report

            with (AlterationResult)
            final switch (result)
            {
            case success:
                string message;

                if (settings.colouredOutgoing)
                {
                    message = "%sed %s.".format(list, id.ircColourNick.ircBold);
                }
                else
                {
                    message = "%sed %s.".format(list, id);
                }

                plugin.state.privmsg(event.channel, event.sender.nickname, message);
                break;

            case noSuchAccount:
                assert(0, "Invalid delist-only AlterationResult passed to report()");

            case alreadyInList:
                string message;

                if (settings.colouredOutgoing)
                {
                    message = "Account %s already %sed.".format(id.ircColourNick.ircBold, list);
                }
                else
                {
                    message = "Account %s already %sed.".format(id, list);
                }

                plugin.state.privmsg(event.channel, event.sender.nickname, message);
                break;
            }
        }
        else
        {
            // Terminal report

            string infotint, logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;

                    infotint = (cast(KamelosoLogger)logger).infotint;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            with (AlterationResult)
            final switch (result)
            {
            case success:
                logger.logf("%sed %s%s%s.", list, infotint, specified, logtint);
                break;

            case noSuchAccount:
                assert(0, "Invalid enlist-only AlterationResult passed to report()");

            case alreadyInList:
                logger.logf("Account %s%s%s already %sed.", infotint, specified, logtint, list);
                break;
            }
        }
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        immutable result = plugin.alterAccountClassifier(Yes.add, list, user.account);
        return report(result, user.account);
    }
    else if (!specified.isValidNickname(plugin.state.client.server))
    {
        if (event.sender.nickname.length)
        {
            // IRC report

            string message;

            if (settings.colouredOutgoing)
            {
                message = "Invalid nickname/account: " ~ specified.ircColour(IRCColour.red).ircBold;
            }
            else
            {
                message = "Invalid nickname/account: " ~ specified;
            }

            plugin.state.privmsg(event.channel, event.sender.nickname, message);
        }
        else
        {
            // Terminal report

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
        }
        return;
    }

    void onSuccess(const string id)
    {
        immutable result = plugin.alterAccountClassifier(Yes.add, list, id);
        report(result, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    version(TwitchSupport)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            return onSuccess(specified);
        }
    }

    // User not on record or on record but no account; WHOIS and try based on results

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// delist
/++
 +  Removes a nickname from either the whitelist or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      account = The account to delist as whitelisted/blacklisted.
 +      list = Which of "whitelist" or "blacklist" to remove from.
 +      event = Optional instigating `kameloso.irc.defs.IRCEvent`.
 +/
void delist(AdminPlugin plugin, const string account, const string list,
    const IRCEvent event = IRCEvent.init)
{
    import std.format : format;

    if (!account.length)
    {
        if (event.sender.nickname.length)
        {
            // IRC report
            plugin.state.privmsg(event.channel, event.sender.nickname, "No account specified.");
        }
        else
        {
            // Terminal report
            logger.warning("No account specified.");
        }
        return;
    }

    immutable result = plugin.alterAccountClassifier(No.add, list, account);

    if (event.sender.nickname.length)
    {
        // IRC report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only AlterationResult returned to delist()");

        case noSuchAccount:
            string message;

            if (settings.colouredOutgoing)
            {
                message = "No such account %s to de%s.".format(account.ircColourNick.ircBold, list);
            }
            else
            {
                message = "No such account %s to de%s".format(account, list);
            }

            plugin.state.privmsg(event.channel, event.sender.nickname, message);
            break;

        case success:
            string message;

            if (settings.colouredOutgoing)
            {
                message = "de%sed %s.".format(list, account.ircColourNick.ircBold);
            }
            else
            {
                message = "de%sed %s".format(list, account);
            }

            plugin.state.privmsg(event.channel, event.sender.nickname, message);
            break;
        }
    }
    else
    {
        // Terminal report

        string infotint, logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only AlterationResult returned to delist()");

        case noSuchAccount:
            logger.logf("No such account %s%s%s to de%s.", infotint, account, logtint, list);
            break;

        case success:
            logger.logf("de%sed %s%s%s.", list, infotint, account, logtint);
            break;
        }
    }
}


// onCommandDewhitelist
/++
 +  Removes a nickname from the list of users who may trigger the bot, from the
 +  `kameloso.irc.common.IRCClient.Class.whitelist` of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `whitelist` level, as opposed to `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "dewhitelist")
@Description("Removes an account from the whitelist of users who may trigger the bot.",
    "$command [account to remove from whitelist]")
void onCommandDewhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripped;
    plugin.delist(event.content.stripped, "whitelist", event);
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
@BotCommand(PrefixPolicy.nickname, "blacklist")
@Description("Adds an account to the blacklist, exempting them from triggering the bot.",
    "$command [account to blacklist]")
void onCommandBlacklist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripped;
    plugin.lookupEnlist(event.content.stripped, "blacklist", event);
}


// onCommandDeblacklist
/++
 +  Removes a nickname from the list of users who may not trigger the bot whatsoever.
 +
 +  This is on a `whitelist` level, as opposed to `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "deblacklist")
@Description("Removes an account from the blacklist, allowing them to trigger the bot again.",
    "$command [account to remove from whitelist]")
void onCommandDeblacklist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : stripped;
    plugin.delist(event.content.stripped, "blacklist", event);
}


// AlterationResult
/++
 +  Enum embodying the results of an account alteration.
 +
 +  Returned by functions to report success or failure, to let them give terminal
 +  or IRC feedback appropriately.
 +/
enum AlterationResult
{
    alreadyInList,  /// When enlisting, an account already existed.
    noSuchAccount,  /// When delisting, an account could not be found.
    success,        /// Successful enlist/delist.
}


// alterAccountClassifier
/++
 +  Adds or removes an account from the file of user classifier definitions,
 +  and reloads all plugins to make them read the updated lists.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      add = Whether to add to or remove from lists.
 +      list = Which list to add to or remove from; `whitelist` or `blacklist`.
 +      account = Services account name to add or remove.
 +
 +  Returns:
 +      `AlterationResult.alreadyInList` if enlisting (`Yes.add`) and the account
 +      was already in the specified list.
 +      `AlterationResult.noSuchAccount` if delisting (`No.add`) and no such
 +      account could be found in the specified list.
 +      `AlterationResult.success` if enlisting or delisting succeeded.
 +/
AlterationResult alterAccountClassifier(AdminPlugin plugin, const Flag!"add" add,
    const string list, const string account)
{
    import kameloso.json : JSONStorage;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;
    import std.json : JSONValue;

    assert(((list == "whitelist") || (list == "blacklist")), list);

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

        if (json[list].array.canFind(accountAsJSON))
        {
            return AlterationResult.alreadyInList;
        }
        else
        {
            json[list].array ~= accountAsJSON;
        }
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable index = json[list].array.countUntil(accountAsJSON);

        if (index == -1)
        {
            return AlterationResult.noSuchAccount;
        }

        json[list] = json[list].array.remove!(SwapStrategy.unstable)(index);
    }

    json.save(plugin.userFile, JSONStorage.KeyOrderStrategy.adjusted);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
    return AlterationResult.success;
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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "resetterm")
@Description("Outputs the ASCII control character 15 to the terminal, " ~
    "to recover from binary garbage mode")
void onCommandResetTerminal()
{
    import kameloso.terminal : TerminalToken;
    import std.stdio : stdout, write;

    write(cast(char)TerminalToken.reset);
    if (settings.flush) stdout.flush();
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
@BotCommand(PrefixPolicy.nickname, "printraw")
@Description("[debug] Toggles a flag to print all incoming events raw.")
void onCommandprintRaw(AdminPlugin plugin, const IRCEvent event)
{
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
@BotCommand(PrefixPolicy.nickname, "printbytes")
@Description("[debug] Toggles a flag to print all incoming events as bytes.")
void onCommandPrintBytes(AdminPlugin plugin, const IRCEvent event)
{
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
@BotCommand(PrefixPolicy.nickname, "printasserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events")
void onCommandAsserts(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;
    import std.stdio : stdout;

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

    if (settings.flush) stdout.flush();
}


// joinPartImpl
/++
 +  Joins or parts a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "join")
@BotCommand(PrefixPolicy.nickname, "part")
@Description("Joins/parts a channel.", "$command [channel]")
void onCommandJoinPart(AdminPlugin plugin, const IRCEvent event)
{
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
@BotCommand(PrefixPolicy.nickname, "set")
@Description("Changes a plugin's settings", "$command [plugin.setting=value]")
void onSetCommand(AdminPlugin plugin, const IRCEvent event)
{
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
            immutable success = thisFiber.payload.applyCustomSettings([ event.content ]);

            if (success)
            {
                plugin.state.privmsg(event.channel, event.sender.nickname, "Setting changed.");
            }
            else
            {
                plugin.state.privmsg(event.channel, event.sender.nickname,
                    "Invalid syntax or plugin/settings name.");
            }
        }
        catch (ConvException e)
        {
            plugin.state.privmsg(event.channel, event.sender.nickname,
                "There was a conversion error. Please verify the values in your setting.");
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
@BotCommand(PrefixPolicy.nickname, "auth")
@Description("(Re-)authenticates with services. Useful if the server has forcefully logged us out.")
void onCommandAuth(AdminPlugin plugin)
{
    if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch) return;

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
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "status")
@Description("[debug] Dumps information about the current state of the bot to the local terminal.")
void onCommandStatus(AdminPlugin plugin)
{
    import kameloso.printing : printObjects;
    import std.stdio : stdout, writeln;

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
import kameloso.thread : Sendable;
version(Posix)  // No need to compile this in on pipeline-less builds
void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    if (header != "admin") return;

    // Don't return if disabled, as it blocks us from reenabling with verb set

    import kameloso.printing : printObject;
    import kameloso.string : contains, nom, strippedRight;
    import kameloso.thread : BusMessage;

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

        case "printasserts":
            plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

            if (plugin.adminSettings.printAsserts)
            {
                import kameloso.debugging : formatClientAssignment;
                import std.stdio : stdout;

                // Print the bot assignment but only if we're toggling it on
                formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
            }
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
            assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

            try
            {
                thisFiber.payload.applyCustomSettings([ slice ]);
                logger.log("Setting changed.");
            }
            catch (ConvException e)
            {
                logger.error("Invalid setting.");
            }
        }

        auto fiber = new CarryingFiber!(IRCPlugin[])(&dg);
        return plugin.state.mainThread.send(ThreadMessage.PeekPlugins(), cast(shared)fiber);

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.Save());

    case "whitelist":
    case "blacklist":
        return plugin.lookupEnlist(slice, verb);

    case "dewhitelist":
    case "deblacklist":
        return plugin.delist(slice, verb[2..$]);

    default:
        logger.error("Unimplemented piped verb: ", verb);
        break;
    }
}


// start
/++
 +  Print the initial assignment of client member fields, if we're printing asserts.
 +
 +  This lets us copy and paste the environment of later generated asserts.
 +
 +  `printAsserts` is debug-only, so gate this behind debug too.
 +/
debug
void start(AdminPlugin plugin)
{
    if (!plugin.adminSettings.printAsserts) return;

    import kameloso.debugging : formatClientAssignment;
    import std.stdio : stdout, writeln;

    writeln();
    formatClientAssignment(stdout.lockingTextWriter, plugin.state.client);
    writeln();

    plugin.previousClient = plugin.state.client;
}


version(OmniscientAdmin)
{
    mixin UserAwareness!(ChannelPolicy.any);
    mixin ChannelAwareness!(ChannelPolicy.any);
    mixin TwitchAwareness!(ChannelPolicy.any);
}
else
{
    mixin UserAwareness;
    mixin ChannelAwareness;
}

public:


// AdminPlugin
/++
 +  The `AdminPlugin` is a plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of the `kameloso.plugins.chatbot.ChatbotPlugin`.
 +/
final class AdminPlugin : IRCPlugin
{
private:
    /// Snapshot of previous `IRCClient`.
    debug IRCClient previousClient;

    /// File with user definitions. Must be the same as in persistence.d.
    @Resource string userFile = "users.json";

    /// All Admin options gathered.
    @Settings AdminSettings adminSettings;

    mixin IRCPluginImpl;
}

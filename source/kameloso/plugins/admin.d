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
module kameloso.plugins.admin;

version(WithPlugins):
version(WithAdminPlugin):

//version = OmniscientAdmin;

private:

import kameloso.plugins.ircplugin;
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
    import std.stdio : stdout, write, writefln, writeln;

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) write('@', event.tags, ' ');
        writeln(event.raw, '$');
        if (plugin.state.settings.flush) stdout.flush();
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }

        if (plugin.state.settings.flush) stdout.flush();
    }

    version(AdminAssertGeneration)
    {
        if (plugin.adminSettings.printAsserts)
        {
            import lu.string : contains;

            if (event.raw.contains(1))
            {
                logger.warning("event.raw contains CTCP 1 which might not get printed");
            }

            formatEventAssertBlock(stdout.lockingTextWriter, event);
            writeln();

            if (plugin.state.client != plugin.previousClient)
            {
                import lu.deltastrings : formatDeltaInto;

                writeln("with (parser.client)");
                writeln("{");
                stdout.lockingTextWriter.formatDeltaInto!(Yes.asserts)
                    (plugin.previousClient, plugin.state.client, 1);
                writeln("}\n");

                plugin.previousClient = plugin.state.client;
            }

            if (plugin.state.settings.flush) stdout.flush();
        }
    }
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
            immutable message = plugin.state.settings.colouredOutgoing ?
                "No such user: " ~ username.ircColour(IRCColour.red).ircBold :
                "No such user: " ~ username;

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
 +  `kameloso.plugins.common.IRCPluginState` to the local terminal.
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
    import kameloso.printing : printObject;
    import std.stdio : stdout, writeln;

    foreach (immutable name, const user; plugin.state.users)
    {
        writeln(name);
        printObject(user);
    }

    writeln(plugin.state.users.length, " users.");
    if (plugin.state.settings.flush) stdout.flush();
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
    raw(plugin.state, event.content);
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
    if (event.content.length)
    {
        quit(plugin.state, event.content);
    }
    else
    {
        quit(plugin.state);
    }
}


// onCommandHome
/++
 +  Adds or removes channels to/from the list of currently active home channels, in the
 +  `kameloso.common.IRCBot.homeChannels` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
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
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  Follows up with a `core.thread.Fiber` to verify that the channel was actually joined.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      rawChannel = The channel to be added, potentially in unstripped, cased form.
 +/
void addHome(AdminPlugin plugin, const IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to add a home but the channel string was empty")
{
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
        privmsg(plugin.state, event.channel, event.sender.nickname, "We are already in that home channel.");
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

        // We're converting a normal channel into a home. Let other plugins know
        // (as there is no SELFJOIN trigger).
        logger.info("We're already in this channel as a guest. Converting it to a home.");
        plugin.state.mainThread.send(ThreadMessage.BusMessage(), "home add", busMessage(channel));

        // Make sure there are no duplicates between homes and channels.
        plugin.state.bot.guestChannels = plugin.state.bot.guestChannels
            .remove!(SwapStrategy.unstable)(existingChannelIndex);
        return;
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
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');
        assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

        const followupEvent = thisFiber.payload;

        if (followupEvent.channel != channel)
        {
            // Different channel; yield fiber, wait for another event
            Fiber.yield();
            return dg();
        }

        scope(exit) plugin.unlistFiberAwaitingEvents(thisFiber, joinTypes[]);

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
    plugin.awaitEvents(fiber, joinTypes);
}


// delHome
/++
 +  Removes a channel from the list of currently active home channels, from the
 +  `dialect.defs.IRCClient.homeChannels` array of the current `AdminPlugin`'s
 +  `kameloso.plugins.common.IRCPluginState`.
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
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.operator` level.
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
 +  except on actions annotated `kameloso.plugins.common.PrivilegeLevel.ignore`.
 +
 +  This is on a `kameloso.plugins.common.PrivilegeLevel.operator` level.
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


// manageClassLists
/++
 +  Common code for whitelisting and blacklisting nicknames/accounts.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +      list = Which list to add/remove from, "whitelist", "operator" or "blacklist".
 +/
void manageClassLists(AdminPlugin plugin, const IRCEvent event, const string list)
in (((list == "whitelist") || (list == "blacklist") || (list == "operator")),
    list ~ " is not whitelist, operator nor blacklist")
do
{
    import lu.string : nom;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        import std.format : format;
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [add|del|list]".format(plugin.state.settings.prefix, list));
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        return plugin.lookupEnlist(slice, list, event.channel, event);

    case "del":
        return plugin.delist(slice, list, event.channel, event);

    case "list":
        immutable channel = slice.length ? slice : event.channel;
        if (!channel.length) return sendUsage();
        return plugin.listList(channel, list, event);

    default:
        return sendUsage();
    }
}


// listList
/++
 +  Sends a list of the current users in the whitelist, operator list or the
 +  blacklist to the querying user or channel.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      channel = The channel the list relates to.
 +      list = Which list to list; "whitelist", "operator" or "blacklist".
 +      event = Optional `dialect.defs.IRCEvent` that instigated the listing.
 +/
void listList(AdminPlugin plugin, const string channel, const string list,
    const IRCEvent event = IRCEvent.init)
in (((list == "whitelist") || (list == "blacklist") || (list == "operator")),
    list ~ " is not whitelist, operator nor blacklist")
{
    import lu.json : JSONStorage;
    import std.format : format;

    immutable asWhat =
        (list == "operator") ? "operators" :
        (list == "whitelist") ? "whitelisted users" :
        /*(list == "blacklist") ?*/ "blacklisted users";

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

    if (channel in json[list].object)
    {
        import std.algorithm.iteration : map;

        auto userlist = json[list][channel].array
            .map!(jsonEntry => jsonEntry.str);

        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Current %s in %s: %-(%s, %)"
            .format(asWhat, channel, userlist));
    }
    else
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "There are no %s in %s.".format(asWhat, channel));
    }
}


// lookupEnlist
/++
 +  Adds an account to either the whitelist, operator list or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      specified = The nickname or account to white-/blacklist.
 +      list = Which of "whitelist", "operator" or "blacklist" to add to.
 +      event = Optional instigating `dialect.defs.IRCEvent`.
 +/
void lookupEnlist(AdminPlugin plugin, const string rawSpecified, const string list,
    const string channel, const IRCEvent event = IRCEvent.init)
in (((list == "whitelist") || (list == "blacklist") || (list == "operator")),
    list ~ " is not whitelist, operator nor blacklist")
{
    import dialect.common : isValidNickname;
    import lu.string : contains, stripped;
    import std.range : only;

    immutable specified = rawSpecified.stripped;

    immutable asWhat =
        (list == "operator") ? "an operator" :
        (list == "whitelist") ? "a whitelisted user" :
        /*(list == "blacklist") ?*/ "a blacklisted user";

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
                enum pattern = "Added %s as %s in %s.";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash.ircBold, asWhat, channel) :
                    pattern.format(id, asWhat, channel);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid delist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "%s was already %s in %s.";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash.ircBold, asWhat, channel) :
                    pattern.format(id, asWhat, channel);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;
            }
        }
        else
        {
            // Terminal report

            with (AlterationResult)
            final switch (result)
            {
            case success:
                logger.logf("Added %s%s%s as %s in %s.",
                    Tint.info, specified, Tint.log, asWhat, channel);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid enlist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                logger.logf("%s%s%s is already %s in %s.",
                    Tint.info, specified, Tint.log, asWhat, channel);
                break;
            }
        }
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        foreach (immutable thisList; only("operator", "whitelist", "blacklist"))
        {
            if (thisList == list) continue;
            plugin.alterAccountClassifier(No.add, thisList, user.account, channel);
        }

        immutable result = plugin.alterAccountClassifier(Yes.add, list, user.account, channel);
        return report(result, nameOf(*user));
    }
    else if (!specified.isValidNickname(plugin.state.server))
    {
        if (event.sender.nickname.length)
        {
            // IRC report

            immutable message = plugin.state.settings.colouredOutgoing ?
                "Invalid nickname/account: " ~ specified.ircColour(IRCColour.red).ircBold :
                "Invalid nickname/account: " ~ specified;

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        else
        {
            // Terminal report
            logger.warning("Invalid nickname/account: ", Tint.log, specified);
        }
        return;
    }

    void onSuccess(const string id)
    {
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                import std.algorithm.iteration : filter;

                if (const userInList = id in plugin.state.users)
                {
                    foreach (immutable thisList; only("operator", "whitelist", "blacklist"))
                    {
                        if (thisList == list) continue;
                        plugin.alterAccountClassifier(No.add, thisList, id, channel);
                    }

                    immutable result = plugin.alterAccountClassifier(Yes.add, list, id, channel);
                    return report(result, nameOf(*userInList));
                }

                // If we're here, assume a display name was specified and look up the account
                auto usersWithThisDisplayName = plugin.state.users
                    .byValue
                    .filter!(u => u.displayName == id);

                if (!usersWithThisDisplayName.empty)
                {
                    foreach (immutable thisList; only("operator", "whitelist", "blacklist"))
                    {
                        if (thisList == list) continue;

                        plugin.alterAccountClassifier(No.add, thisList,
                            usersWithThisDisplayName.front.account, channel);
                    }

                    immutable result = plugin.alterAccountClassifier(Yes.add,
                        list, usersWithThisDisplayName.front.account, channel);
                    return report(result, id);
                }

                // Assume a valid account was specified even if we can't see it, and drop down
            }
        }

        foreach (immutable thisList; only("operator", "whitelist", "blacklist"))
        {
            if (thisList == list) continue;
            plugin.alterAccountClassifier(No.add, thisList, id, channel);
        }

        immutable result = plugin.alterAccountClassifier(Yes.add, list, id, channel);
        report(result, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
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
 +  Removes a nickname from either the whitelist, operator list or the blacklist.
 +
 +  Passes the `list` parameter to `alterAccountClassifier`, for list selection.
 +
 +  Params:
 +      plugin = The current `AdminPlugin`.
 +      account = The account to delist as whitelisted/blacklisted or as operator.
 +      list = Which of "whitelist", "operator" or "blacklist" to remove from.
 +      event = Optional instigating `dialect.defs.IRCEvent`.
 +/
void delist(AdminPlugin plugin, const string account, const string list,
    const string channel, const IRCEvent event = IRCEvent.init)
in (((list == "whitelist") || (list == "blacklist") || (list == "operator")),
    list ~ " is not whitelist, operator nor blacklist")
{
    import std.format : format;

    if (!account.length)
    {
        if (event.sender.nickname.length)
        {
            // IRC report
            privmsg(plugin.state, event.channel, event.sender.nickname, "No account specified.");
        }
        else
        {
            // Terminal report
            logger.warning("No account specified.");
        }
        return;
    }

    immutable asWhat =
        (list == "operator") ? "an operator" :
        (list == "whitelist") ? "a whitelisted user" :
        /*(list == "blacklist") ?*/ "a blacklisted user";

    immutable result = plugin.alterAccountClassifier(No.add, list, account, channel);

    if (event.sender.nickname.length)
    {
        // IRC report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only `AlterationResult` returned to `delist`");

        case noSuchAccount:
            enum pattern = "No such account %s to remove as %s in %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, asWhat, channel) :
                pattern.format(account, asWhat, channel);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;

        case noSuchChannel:
            enum pattern = "Account %s isn't %s in %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, asWhat, channel) :
                pattern.format(account, asWhat, channel);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;

        case success:
            enum pattern = "Removed %s as %s in %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, asWhat, channel) :
                pattern.format(account, asWhat, channel);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;
        }
    }
    else
    {
        // Terminal report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only `AlterationResult` returned to `delist`");

        case noSuchAccount:
            logger.logf("No such account %s%s%s was found as %s in %s.",
                Tint.info, account, Tint.log, asWhat, channel);
            break;

        case noSuchChannel:
            logger.logf("Account %s%s%s isn't %s in %s.",
                Tint.info, account, Tint.log, asWhat, channel);
            break;

        case success:
            logger.logf("Removed %s%s%s as %s in %s",
                Tint.info, account, Tint.log, asWhat, channel);
            break;
        }
    }
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
    noSuchChannel,  /// When delisting, a channel count not be found.
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
 +      list = Which list to add to or remove from; `whitelist`, `operator` or `blacklist`.
 +      account = Services account name to add or remove.
 +      channel = Channel the account-class applies to.
 +
 +  Returns:
 +      `AlterationResult.alreadyInList` if enlisting (`Yes.add`) and the account
 +      was already in the specified list.
 +      `AlterationResult.noSuchAccount` if delisting (`No.add`) and no such
 +      account could be found in the specified list.
 +      `AlterationResult.noSuchChannel` if delisting (`No.add`) and no such
 +      channel could be found in the specified list.
 +      `AlterationResult.success` if enlisting or delisting succeeded.
 +/
AlterationResult alterAccountClassifier(AdminPlugin plugin, const Flag!"add" add,
    const string list, const string account, const string channel)
in (((list == "whitelist") || (list == "blacklist") || (list == "operator")),
    list ~ " is not whitelist, operator nor blacklist")
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage;
    import std.concurrency : send;
    import std.json : JSONValue;

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

    if (add)
    {
        import std.algorithm.searching : canFind;

        const accountAsJSON = JSONValue(account);

        if (channel in json[list].object)
        {
            if (json[list][channel].array.canFind(accountAsJSON))
            {
                return AlterationResult.alreadyInList;
            }
            else
            {
                json[list][channel].array ~= accountAsJSON;
            }
        }
        else
        {
            json[list][channel] = null;
            json[list][channel].array = null;
            json[list][channel].array ~= accountAsJSON;
        }
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        if (channel in json[list].object)
        {
            immutable index = json[list][channel].array.countUntil(JSONValue(account));

            if (index == -1)
            {
                return AlterationResult.noSuchAccount;
            }

            json[list][channel] = json[list][channel].array.remove!(SwapStrategy.unstable)(index);
        }
        else
        {
            return AlterationResult.noSuchChannel;
        }
    }

    json.save!(JSONStorage.KeyOrderStrategy.adjusted)(plugin.userFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
    return AlterationResult.success;
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
    import std.conv : text;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    immutable message = plugin.state.settings.colouredOutgoing ?
        "Printing all: " ~ plugin.adminSettings.printRaw.text.ircBold :
        "Printing all: " ~ plugin.adminSettings.printRaw.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
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
    import std.conv : text;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    immutable message = plugin.state.settings.colouredOutgoing ?
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text.ircBold :
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandAsserts
/++
 +  Toggles a flag to print *assert statements* of incoming events.
 +
 +  This is used to creating unittest blocks in the source code.
 +/
debug
version(AdminAssertGeneration)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "printasserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events.")
void onCommandAsserts(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;
    import std.stdio : stdout;

    plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

    immutable message = plugin.state.settings.colouredOutgoing ?
        "Printing asserts: " ~ plugin.adminSettings.printAsserts.text.ircBold :
        "Printing asserts: " ~ plugin.adminSettings.printAsserts.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    if (plugin.adminSettings.printAsserts)
    {
        import lu.deltastrings : formatDeltaInto;

        // Print the bot assignment but only if we're toggling it on
        formatClientAssignment(stdout.lockingTextWriter,
            plugin.state.client, plugin.state.server);
    }

    if (plugin.state.settings.flush) stdout.flush();
}


// formatClientAssignment
/++
 +  Constructs statement lines for each changed field of an
 +  `dialect.defs.IRCClient`, including instantiating a fresh one.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.formatClientAssignment(client, server);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      client = `dialect.defs.IRCClient` to simulate the assignment of.
 +      server = `dialect.defs.IRCServer` to simulate the assignment of.
 +/
debug
version(AdminAssertGeneration)
void formatClientAssignment(Sink)(auto ref Sink sink, const IRCClient client, const IRCServer server)
if (isOutputRange!(Sink, char[]))
{
    import lu.deltastrings : formatDeltaInto;

    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    sink.put("IRCParser parser;\n\n");
    sink.put("with (parser)\n");
    sink.put("{\n");
    sink.formatDeltaInto(IRCClient.init, client, 1, "client");
    sink.formatDeltaInto(IRCServer.init, server, 1, "server");
    sink.put('}');

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

///
debug
version(AdminAssertGeneration)
unittest
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCClient client;
    IRCServer server;

    with (client)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 6667;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = "eIbq";
    }

    sink.formatClientAssignment(client, server);

    assert(sink.data ==
`IRCParser parser;

with (parser)
{
    client.nickname = "NICKNAME";
    client.user = "UUUUUSER";
    server.address = "something.freenode.net";
    server.port = 6667;
    server.daemon = IRCServer.Daemon.unreal;
    server.aModes = "eIbq";
}`, '\n' ~ sink.data);
}


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an
 +  `dialect.defs.IRCEvent`.
 +
 +  Example:
 +  ---
 +  IRCEvent event;
 +  Appender!string sink;
 +  sink.formatEventAssertBlock(event);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      event = `dialect.defs.IRCEvent` to construct assert statements for.
 +/
debug
version(AdminAssertGeneration)
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
if (isOutputRange!(Sink, char[]))
{
    import lu.deltastrings : formatDeltaInto;
    import lu.string : tabs;
    import std.array : replace;
    import std.format : format, formattedWrite;

    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    immutable raw = event.tags.length ?
        "@%s %s".format(event.tags, event.raw) : event.raw;

    immutable escaped = raw
        .replace('\\', `\\`)
        .replace('"', `\"`);

    sink.put("{\n");
    if (escaped != raw) sink.formattedWrite("%s// %s\n", 1.tabs, raw);
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, escaped);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDeltaInto!(Yes.asserts)(IRCEvent.init, event, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

///
debug
version(AdminAssertGeneration)
unittest
{
    import dialect.parsing : IRCParser;
    import lu.deltastrings : formatDeltaInto;
    import lu.string : tabs;
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(1024);

    IRCClient client;
    IRCServer server;
    auto parser = IRCParser(client, server);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");

    // copy/paste the above
    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, event.raw);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDeltaInto!(Yes.asserts)(IRCEvent.init, event, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    assert(sink.data ==
`{
    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    with (event)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
    }
}`, '\n' ~ sink.data);
}


// onCommandJoinPart
/++
 +  Joins or parts a supplied channel.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "join")
@BotCommand(PrefixPolicy.nickname, "part")
@Description("Joins/parts a guest channel.", "$command [channel]")
void onCommandJoinPart(AdminPlugin plugin, const IRCEvent event)
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : joiner, splitter;
    import std.conv : to;
    import std.uni : asLowerCase;

    if (!event.content.length)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname, "No channels supplied ...");
        return;
    }

    immutable channels = event.content
        .splitter(" ")
        .joiner(",")
        .to!string;

    if (event.aux.asLowerCase.equal("join"))
    {
        join(plugin.state, channels);
    }
    else
    {
        part(plugin.state, channels);
    }
}


// onSetCommand
/++
 +  Sets a plugin option by variable string name.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
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
 +  Asks the `kamloso.plugins.connect.ConnectService` to (re-)authenticate to services.
 +/
version(WithConnectService)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PrivilegeLevel.admin)
@BotCommand(PrefixPolicy.nickname, "auth")
@Description("(Re-)authenticates with services. Useful if the server has forcefully logged the bot out.")
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
    import kameloso.printing : printObjects;
    import std.stdio : stdout, writeln;

    logger.log("Current state:");
    printObjects!(Yes.printAll)(plugin.state.client, plugin.state.server);
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
            "Usage: %s%s [add|del|list] [account] [hostmask if adding]"
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
        if (!mask.contains('!') || !mask.contains('@'))
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
    import kameloso.thread : ThreadMessage, busMessage;
    import lu.string : contains, nom;
    import std.stdio : stdout, writeln;

    if (!event.content.length) return;

    if (!event.content.contains!(Yes.decode)(" "))
    {
        logger.info("Sending bus message.");
        writeln("Header: ", event.content);
        writeln("Content: (empty)");
        if (plugin.state.settings.flush) stdout.flush();

        plugin.state.mainThread.send(ThreadMessage.BusMessage(), event.content);
    }
    else
    {
        string slice = event.content;  // mutable
        immutable header = slice.nom(" ");

        logger.info("Sending bus message.");
        writeln("Header: ", header);
        writeln("Content: ", slice);
        if (plugin.state.settings.flush) stdout.flush();

        plugin.state.mainThread.send(ThreadMessage.BusMessage(),
            header, busMessage(slice));
    }
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

        debug
        version(AdminAssertGeneration)
        {
            case "printasserts":
                plugin.adminSettings.printAsserts = !plugin.adminSettings.printAsserts;

                if (plugin.adminSettings.printAsserts)
                {
                    import std.stdio : stdout;

                    // Print the bot assignment but only if we're toggling it on
                    formatClientAssignment(stdout.lockingTextWriter,
                        plugin.state.client, plugin.state.server);
                }
                return;
        }
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


// start
/++
 +  Print the initial assignment of client member fields, if we're printing asserts.
 +
 +  This lets us copy and paste the environment of later generated asserts.
 +
 +  `printAsserts` is debug-only, so gate this behind debug too.
 +/
debug
version(AdminAssertGeneration)
void start(AdminPlugin plugin)
{
    if (!plugin.adminSettings.printAsserts) return;

    import std.stdio : stdout, writeln;

    writeln();
    formatClientAssignment(stdout.lockingTextWriter, plugin.state.client, plugin.state.server);
    writeln();

    plugin.previousClient = plugin.state.client;
}


version(OmniscientAdmin)
{
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
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
private:
    import kameloso.constants : KamelosoFilenames;

    /// All Admin options gathered.
    AdminSettings adminSettings;

    debug
    version(AdminAssertGeneration)
    {
        /// Snapshot of the previous `dialect.defs.IRCClient`.
        IRCClient previousClient;
    }

    /// File with user definitions. Must be the same as in persistence.d.
    @Resource string userFile = KamelosoFilenames.users;

    /// File with hostmasks definitions. Must be the same as in persistence.d
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    mixin IRCPluginImpl;
}

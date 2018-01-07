module kameloso.plugins.admin;

import kameloso.common : logger;
import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency : send;
import std.typecons : Flag, No, Yes;

import std.stdio;

private:


// onAnyEvent
/++
 +  Prints all incoming events raw if the flag to do so has been set with
 +  `onCommandPrintAll`, by way of the `printall` verb. Also prints the content
 +  of any incomings events, cast to bytes.
 +
 +  Params:
 +      event = the event whose raw IRC string to print.
 +/
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(AdminPlugin plugin, const IRCEvent event)
{
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
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "user")
@Description("[debug] Prints the details of a specific user.")
void onCommandShowOneUser(AdminPlugin plugin, const IRCEvent event)
{
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
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "forgetaccounts")
@Description("[debug] Forget user accounts.")
void onCommandForgetAccounts(AdminPlugin plugin)
{
    import kameloso.common : printObject;

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
    import kameloso.common : ThreadMessage;

    logger.info("Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `state.users` array to the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "users")
@Description("[debug] Prints out the current users array to the local terminal.")
void onCommandShowUsers(AdminPlugin plugin)
{
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
 +  Prints out the current `state.channels` array to the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "channels")
@Description("Prints out the current channels array to the local terminal.")
void onCommandShowChannels(AdminPlugin plugin)
{
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
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "sudo")
@Description("Sends supplied text to the server, verbatim.")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    plugin.raw(event.content);
}


// onCommandQuit
/++
 +  Sends a `QUIT` event to the server.
 +
 +  If any extra text is following the 'quit' prefix, it uses that as the quit
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
 +  Add a channel to the list of currently active home channels.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "addhome")
@Description("Adds a channel to the list of homes.")
void onCommandAddHome(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.irc : isValidChannel;
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

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
 +  Removes a channel from the list of currently active home channels.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "delhome")
@Description("Removes a channel from the list of homes.")
void onCommandDelHome(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.irc : isValidChannel;
    import std.algorithm : countUntil, remove;
    import std.string : strip;

    immutable channel = event.content.strip();

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
 +  Add a nickname to the list of users who may trigger the bot.
 +
 +  This is at a `whitelist` level, as opposed to `anyone` and `admin`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "whitelist")
@Description("Adds a nickname to the whitelist of users who may trigger the bot.")
void onCommandWhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : has;
    import std.string : strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        logger.error("No nickname supplied...");
        return;
    }
    else if (nickname.has!(Yes.decode)(' ') != -1)
    {
        logger.error("Nickname must not contain spaces");
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
 +  Remove a nickname from the list of users who may trigger the bot.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "unwhitelist")
@Description("Removes a nickname from the whitelist of users who may trigger the bot.")
void onCommandUnwhitelist(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.string : has;
    import std.algorithm : countUntil, remove;
    import std.string : strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        logger.error("No nickname supplied...");
        return;
    }
    else if (nickname.has!(Yes.decode)(' ') != -1)
    {
        logger.error("Only one nick at a time. Nickname must not contain spaces");
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
 +  you try to cat a binary file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "resetterm")
@Description("Outputs the ASCII control character 15 to the terminal, " ~
    "to recover from binary garbage mode")
void onCommandResetTerminal()
{
    import kameloso.bash : TerminalToken;
    write(TerminalToken.reset);
    version(Cygwin_) stdout.flush();
}


// onCommandPrintAll
/++
 +  Toggles a flag to print all incoming events raw.
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
    plugin.printAll = !plugin.printAll;
    logger.info("Printing all: ", plugin.printAll);
}


// onCommandPrintBytes
/++
 +  Toggles a flag to print all incoming events as bytes.
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
    plugin.printBytes = !plugin.printBytes;
    logger.info("Printing bytes: ", plugin.printBytes);
}


// onCommandAsserts
/++
 +  Toggles a flag to print assert statements for incoming events.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "asserts")
@Description("[debug] Toggles a flag to generate assert statements for incoming events")
void onCommandAsserts(AdminPlugin plugin)
{
    import kameloso.debugging : formatBot;

    plugin.printAsserts = !plugin.printAsserts;
    logger.info("Printing asserts: ", plugin.printAsserts);
    formatBot(stdout.lockingTextWriter, plugin.state.bot);
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


mixin UserAwareness;
mixin ChannelAwareness;

public:


// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of `Chatbot`.
 +/
final class AdminPlugin : IRCPlugin
{
    /// Toggles whether onAnyEvent prints the raw strings of all incoming events
    bool printAll;

    /// Toggles whether onAnyEvent prints the raw bytes of the *contents* of events
    bool printBytes;

    /// Toggles whether onAnyEvent prints assert statements for incoming events
    bool printAsserts;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

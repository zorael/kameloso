module kameloso.plugins.admin;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : logger;

import std.concurrency : send;

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


// onCommandSave
/++
 +  Saves current configuration to disk.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "save")
@Prefix(NickPolicy.required, "writeconfig")
void onCommandSave(AdminPlugin plugin)
{
    import kameloso.common : ThreadMessage;

    logger.info("Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}


// onCommandShowUsers
/++
 +  Prints out the current `state.users` array in the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "users")
void onCommandShowUsers(AdminPlugin plugin)
{
    import kameloso.common : printObject;

    logger.trace("Printing Admin's users");

    printObject(plugin.state.bot);

    foreach (entry; plugin.state.users.byKeyValue)
    {
        writefln("%-12s [%s]", entry.key, entry.value);
    }

    version(Cygwin_) stdout.flush();
}

// onCommandShowChannels
/++
 +  Prints out the current `state.users` array in the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "channels")
void onCommandShowChannels(AdminPlugin plugin)
{
    import kameloso.common : printObject;

    logger.trace("Printing Admin's channels");

    printObject(plugin.state.bot);

    foreach (entry; plugin.state.channels.byKeyValue)
    {
        writefln("%-12s [%s]", entry.key, entry.value);
    }

    version(Cygwin_) stdout.flush();
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "sudo")
void onCommandSudo(AdminPlugin plugin, const IRCEvent event)
{
    // FIXME
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "quit")
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
 +  Add a channel to the list of currently active channels.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "addhome")
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "delhome")
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


// onCommandAddFriend
/++
 +  Add a nickname to the list of users who may trigger the bot.
 +
 +  This is at a `friends` level, as opposed to `anyone` and `master`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "addfriend")
void onCommandAddFriend(AdminPlugin plugin, const IRCEvent event)
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
        bot.friends ~= nickname;
        bot.updated = true;
        logger.infof("%s added to friends", nickname);
    }
}


// onCommandDelFriend
/++
 +  Remove a nickname from the list of users who may trigger the bot.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "delfriend")
void onCommandDelFriend(AdminPlugin plugin, const IRCEvent event)
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

    immutable friendIndex = plugin.state.bot.friends.countUntil(nickname);

    if (friendIndex == -1)
    {
        logger.error("No such friend");
        return;
    }

    with (plugin.state)
    {
        bot.friends = bot.friends.remove(friendIndex);
        bot.updated = true;
        logger.infof("%s removed from friends", nickname);
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "resetterm")
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printall")
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printbytes")
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
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "asserts")
void onCommandAsserts(AdminPlugin plugin)
{
    import kameloso.debugging : formatBot;

    plugin.printAsserts = !plugin.printAsserts;
    logger.info("Printing asserts: ", plugin.printAsserts);
    formatBot(stdout.lockingTextWriter, plugin.state.bot);
    version(Cygwin_) stdout.flush();
}


// onCommandJoin
/++
 +  Joins a supplied channel.
 +
 +  Simply defers to `joinPartImpl` with the prefix `JOIN`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "join")
void onCommandJoin(AdminPlugin plugin, const IRCEvent event)
{
    plugin.joinPartImpl("JOIN", event);
}


// onCommandPart
/++
 +  Parts from a supplied channel.
 +
 +  Simply defers to `joinPartImpl` with the prefix `PART`.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "part")
void onCommandPart(AdminPlugin plugin, const IRCEvent event)
{
    plugin.joinPartImpl("PART", event);
}


// joinPartImpl
/++
 +  Joins or parts a supplied channel.
 +
 +  Technically sends the action passed in the prefix variable with the list of
 +  channels as its list of arguments.
 +
 +  Params:
 +      prefix = the action string to send (`JOIN` or `PART`).
 +      event = the triggering `IRCEvent`.
 +/
void joinPartImpl(AdminPlugin plugin, const string prefix, const IRCEvent event)
{
    import std.algorithm.iteration : joiner, splitter;
    import std.array : array;
    import std.conv : to;
    import std.format : format;

    // The prefix could be in lowercase. Do we care?
    assert(((prefix == "JOIN") || (prefix == "PART")),
           "Invalid prefix passed to joinPartlImpl: " ~ prefix);

    if (!event.content.length)
    {
        logger.error("No channels supplied...");
        return;
    }

    immutable string channels = event.content
        .splitter(' ')
        .joiner(",")
        .array
        .to!string;

    if (prefix == "JOIN")
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

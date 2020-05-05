/++
 +  Implementation of Admin plugin functionality that borders on debugging.
 +  For internal use.
 +
 +  The `dialect.defs.IRCEvent`-annotated handlers must be in the same module
 +  as the `kameloso.plugins.admin.AdminPlugin`, but these implementation
 +  functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.admin.debugging;

version(WithPlugins):
version(WithAdminPlugin):
debug:

private:

import kameloso.plugins.admin : AdminPlugin;

import kameloso.common : logger;
import kameloso.irccolours : IRCColour, ircBold, ircColour;//, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;

package:


// onAnyEventImpl
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
void onAnyEventImpl(AdminPlugin plugin, const IRCEvent event)
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
}


// onCommandShowUserImpl
/++
 +  Prints the details of one or more specific, supplied users to the local terminal.
 +
 +  It basically prints the matching `dialect.defs.IRCUser`.
 +/
void onCommandShowUserImpl(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.printing : printObject;
    import std.algorithm.iteration : splitter;

    foreach (immutable username; event.content.splitter(' '))
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


// onCommandShowUsersImpl
/++
 +  Prints out the current `users` array of the `AdminPlugin`'s
 +  `kameloso.plugins.core.IRCPluginState` to the local terminal.
 +/
void onCommandShowUsersImpl(AdminPlugin plugin)
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


// onCommandSudoImpl
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  You need basic knowledge of IRC server strings to use this.
 +/
void onCommandSudoImpl(AdminPlugin plugin, const IRCEvent event)
{
    raw(plugin.state, event.content);
}


// onCommandPrintRawImpl
/++
 +  Toggles a flag to print all incoming events *raw*.
 +
 +  This is for debugging purposes.
 +/
void onCommandPrintRawImpl(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    immutable message = plugin.state.settings.colouredOutgoing ?
        "Printing all: " ~ plugin.adminSettings.printRaw.text.ircBold :
        "Printing all: " ~ plugin.adminSettings.printRaw.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandPrintBytesImpl
/++
 +  Toggles a flag to print all incoming events *as individual bytes*.
 +
 +  This is for debugging purposes.
 +/
void onCommandPrintBytesImpl(AdminPlugin plugin, const IRCEvent event)
{
    import std.conv : text;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    immutable message = plugin.state.settings.colouredOutgoing ?
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text.ircBold :
        "Printing bytes: " ~ plugin.adminSettings.printBytes.text;

    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandStatusImpl
/++
 +  Dumps information about the current state of the bot to the local terminal.
 +
 +  This can be very spammy.
 +/
void onCommandStatusImpl(AdminPlugin plugin)
{
    import kameloso.printing : printObjects;
    import std.stdio : stdout, writeln;

    logger.log("Current state:");
    printObjects!(Yes.all)(plugin.state.client, plugin.state.server);
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


// onCommandBusImpl
/++
 +  Sends an internal bus message to other plugins, much like how such can be
 +  sent with the Pipeline plugin.
 +/
void onCommandBusImpl(AdminPlugin plugin, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage, busMessage;
    import lu.string : contains, nom;
    import std.concurrency : send;
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

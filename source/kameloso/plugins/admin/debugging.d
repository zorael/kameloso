/++
    Implementation of Admin plugin functionality that borders on debugging.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.admin.base|admin.base]
 +/
module kameloso.plugins.admin.debugging;

version(WithAdminPlugin):
debug:

private:

import kameloso.plugins.admin.base : AdminPlugin;

import kameloso.messaging;
import dialect.defs;
import std.stdio : stdout;
import std.typecons : Flag, No, Yes;

package:


// onAnyEventImpl
/++
    Prints incoming events to the local terminal, in forms depending on
    which flags have been set with bot commands.

    If [kameloso.plugins.admin.base.AdminPlugin.printRaw|AdminPlugin.printRaw] is set by way of
    invoking [kameloso.plugins.admin.base.onCommandPrintRaw|onCommandPrintRaw], prints all incoming server strings.

    If [kameloso.plugins.admin.base.AdminPlugin.printBytes|AdminPlugin.printBytes] is set by way of
    invoking [kameloso.plugins.admin.base.onCommandPrintBytes|onCommandPrintBytes], prints all incoming server strings byte by byte.
 +/
void onAnyEventImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    import std.stdio : write, writefln, writeln;

    if (plugin.state.settings.headless) return;

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) write('@', event.tags, ' ');
        writeln(event.raw, '$');
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }
    }

    if (plugin.state.settings.flush) stdout.flush();
}


// onCommandShowUserImpl
/++
    Prints the details of one or more specific, supplied users to the local terminal.

    It basically prints the matching [dialect.defs.IRCUser|IRCUser].
 +/
version(IncludeHeavyStuff)
void onCommandShowUserImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.printing : printObject;
    import std.algorithm.iteration : splitter;

    if (plugin.state.settings.headless) return;

    foreach (immutable username; event.content.splitter(' '))
    {
        if (const user = username in plugin.state.users)
        {
            printObject(*user);
        }
        else
        {
            import std.format : format;

            enum pattern = "No such user: <4>%s<c>";
            immutable message = pattern.format(username);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
}


// onCommandShowUsersImpl
/++
    Prints out the current `users` array of the [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState|IRCPluginState] to the local terminal.
 +/
version(IncludeHeavyStuff)
void onCommandShowUsersImpl(AdminPlugin plugin)
{
    import kameloso.printing : printObject;
    import std.stdio : writeln;

    if (plugin.state.settings.headless) return;

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
    Sends supplied text to the server, verbatim.

    You need basic knowledge of IRC server strings to use this.
 +/
void onCommandSudoImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    raw(plugin.state, event.content);
}


// onCommandPrintRawImpl
/++
    Toggles a flag to print all incoming events *raw*.

    This is for debugging purposes.
 +/
void onCommandPrintRawImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    import std.conv : text;
    import std.format : format;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    enum pattern = "Printing all: <b>%s<b>";
    immutable message = pattern.format(plugin.adminSettings.printRaw);
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandPrintBytesImpl
/++
    Toggles a flag to print all incoming events *as individual bytes*.

    This is for debugging purposes.
 +/
void onCommandPrintBytesImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    import std.conv : text;
    import std.format : format;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    enum pattern = "Printing bytes: <b>%s<b>";
    immutable message = pattern.format(plugin.adminSettings.printBytes);
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandStatusImpl
/++
    Dumps information about the current state of the bot to the local terminal.

    This can be very spammy.
 +/
version(IncludeHeavyStuff)
void onCommandStatusImpl(AdminPlugin plugin)
{
    import kameloso.common : logger;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    if (plugin.state.settings.headless) return;

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

    if (plugin.state.settings.flush) stdout.flush();
}


// onCommandBusImpl
/++
    Sends an internal bus message to other plugins, much like how such can be
    sent with the Pipeline plugin.
 +/
void onCommandBusImpl(AdminPlugin plugin, const string input)
{
    import kameloso.common : logger;
    import kameloso.thread : ThreadMessage, boxed;
    import lu.string : contains, nom;
    import std.concurrency : send;
    import std.stdio : writeln;

    if (!input.length) return;

    if (!input.contains!(Yes.decode)(' '))
    {
        if (!plugin.state.settings.headless)
        {
            logger.info("Sending bus message.");
            writeln("Header: ", input);
            writeln("Content: (empty)");
        }

        plugin.state.mainThread.send(ThreadMessage.busMessage(input));
    }
    else
    {
        string slice = input;  // mutable
        immutable header = slice.nom(' ');

        if (!plugin.state.settings.headless)
        {
            logger.info("Sending bus message.");
            writeln("Header: ", header);
            writeln("Content: ", slice);
        }

        plugin.state.mainThread.send(ThreadMessage.busMessage(header, boxed(slice)));
    }

    if (plugin.state.settings.flush) stdout.flush();
}

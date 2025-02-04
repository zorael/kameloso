/++
    Implementation of Admin plugin functionality that borders on debugging.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.AdminPlugin|AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.admin]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.admin.debugging;

version(WithAdminPlugin):
debug version = Debug;
version(Debug):

private:

import kameloso.plugins.admin : AdminPlugin;

import kameloso.messaging;
import dialect.defs;

package:


// onAnyEventImpl
/++
    Prints incoming events to the local terminal, in forms depending on
    which flags have been set with bot commands.

    If [kameloso.plugins.admin.AdminPlugin.printRaw|AdminPlugin.printRaw] is set by way of
    invoking [kameloso.plugins.admin.onCommandPrintRaw|onCommandPrintRaw], prints all incoming server strings.

    If [kameloso.plugins.admin.AdminPlugin.printBytes|AdminPlugin.printBytes] is set by way of
    invoking [kameloso.plugins.admin.onCommandPrintBytes|onCommandPrintBytes], prints all incoming server strings byte by byte.
 +/
void onAnyEventImpl(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.stdio : stdout, write, writefln, writeln;

    if (plugin.state.settings.headless) return;

    bool wroteSomething;  // mutable

    if (plugin.adminSettings.printRaw)
    {
        if (event.tags.length) write('@', event.tags, ' ');
        writeln(event.raw, '$');
        wroteSomething = true;
    }

    if (plugin.adminSettings.printEvents.length)
    {
        if (plugin.eventTypesToPrint[event.type] ||
            plugin.eventTypesToPrint[IRCEvent.Type.ANY])
        {
            import kameloso.prettyprint : prettyprint;

            prettyprint(event);
            if (event.sender != IRCUser.init) prettyprint(event.sender);
            if (event.target != IRCUser.init) prettyprint(event.target);
            wroteSomething = true;
        }
    }

    if (plugin.adminSettings.printBytes)
    {
        import std.string : representation;

        foreach (immutable i, immutable c; event.content.representation)
        {
            import std.encoding : isValidCodeUnit;
            import std.utf : replacementDchar;

            immutable dc = isValidCodeUnit(c) ? dchar(c) : replacementDchar;
            enum pattern = "[%3d] %s : %03d";
            writefln(pattern, i, dc, c);
        }
        wroteSomething = true;
    }

    if (plugin.state.settings.flush && wroteSomething) stdout.flush();
}


// onCommandShowUserImpl
/++
    Prints the details of one or more specific, supplied users to the local terminal.

    It basically prints the matching [dialect.defs.IRCUser|IRCUser].
 +/
void onCommandShowUserImpl(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.prettyprint : prettyprint;
    import std.algorithm.iteration : splitter;

    if (plugin.state.settings.headless) return;

    foreach (immutable username; event.content.splitter(' '))
    {
        if (const user = username in plugin.state.users)
        {
            prettyprint(*user);
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
    Prints out the current `users` array of the [kameloso.plugins.admin.AdminPlugin|AdminPlugin]'s
    [kameloso.plugins.common.IRCPluginState|IRCPluginState] to the local terminal.
 +/
void onCommandShowUsersImpl(AdminPlugin plugin)
{
    import kameloso.prettyprint : prettyprint;
    import std.stdio : stdout, writeln;

    if (plugin.state.settings.headless) return;

    foreach (immutable name, const user; plugin.state.users.aaOf)
    {
        writeln(name);
        prettyprint(user);
    }

    writeln(plugin.state.users.length, " users.");
    if (plugin.state.settings.flush) stdout.flush();
}


// onCommandSudoImpl
/++
    Sends supplied text to the server, verbatim.

    You need basic knowledge of IRC server strings to use this.
 +/
void onCommandSudoImpl(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    raw(plugin.state, event.content);
}


// onCommandPrintRawImpl
/++
    Toggles a flag to print all incoming events *raw*.

    This is for debugging purposes.
 +/
void onCommandPrintRawImpl(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.conv : text;
    import std.format : format;

    if (plugin.state.settings.headless) return;

    plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;

    enum pattern = "Printing raw: <b>%s<b>";
    immutable message = pattern.format(plugin.adminSettings.printRaw);
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandPrintBytesImpl
/++
    Toggles a flag to print all incoming events *as individual bytes*.

    This is for debugging purposes.
 +/
void onCommandPrintBytesImpl(AdminPlugin plugin, const /*ref*/ IRCEvent event)
{
    import std.conv : text;
    import std.format : format;

    if (plugin.state.settings.headless) return;

    plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;

    enum pattern = "Printing bytes: <b>%s<b>";
    immutable message = pattern.format(plugin.adminSettings.printBytes);
    privmsg(plugin.state, event.channel, event.sender.nickname, message);
}


// onCommandPrintEventsImpl
/++
    Changes the contents of the
    [kameloso.plugins.admin.AdminPlugin.eventTypesToPrint|AdminPlugin.eventTypesToPrint]
    array, to prettyprint all incoming events of the types with a value of `true`
    therein, using [kameloso.prettyprint.prettyprint|prettyprint].

    This is for debugging purposes.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        input = A string of event types to print, separated by commas.
        event = The event that triggered this command, if any. If it was not
            triggered by an event, it should be [dialect.defs.IRCEvent|IRCEvent.init].
 +/
void onCommandPrintEventsImpl(
    AdminPlugin plugin,
    const string input,
    const /*ref*/ IRCEvent event)
{
    import kameloso.plugins.admin : parseTypesFromString;
    import kameloso.common : logger;
    import std.algorithm.iteration : map;
    import std.format : format;

    if (plugin.state.settings.headless) return;  // shouldn't output events to terminal

    if (!input.length)
    {
        if (event == IRCEvent.init)
        {
            enum message = "Printing event types: <l>(disabled)";
            logger.info(message);
        }
        else
        {
            enum message = "Printing event types: <b>(disabled)<b>";
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }

        plugin.eventTypesToPrint[] = false;
        plugin.adminSettings.printEvents = string.init;  // for easy detection if something is set
        return;
    }

    immutable success = parseTypesFromString(plugin, input);

    if (success)
    {
        plugin.adminSettings.printEvents = input;  // as above

        if (event == IRCEvent.init)
        {
            enum pattern = "Printing event types: <l>%s";
            logger.infof(pattern, input);
        }
        else
        {
            enum pattern = "Printing event types: <b>%s<b>";
            immutable message = pattern.format(input);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
    else
    {
        if (event == IRCEvent.init)
        {
            enum pattern = "Invalid event types: <l>%s";
            logger.infof(pattern, input);
        }
        else
        {
            enum pattern = "Invalid event types: <b>%s<b>";
            immutable message = pattern.format(input);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
}


// onCommandStatusImpl
/++
    Dumps information about the current state of the bot to the local terminal.

    This can be very spammy.

    Adds ~85 Mb to compilation memory usage.
 +/
version(IncludeHeavyStuff)
void onCommandStatusImpl(AdminPlugin plugin)
{
    import kameloso.common : logger;
    import kameloso.prettyprint : prettyprint;
    import std.stdio : stdout, writeln;
    import std.typecons : Flag, No, Yes;

    if (plugin.state.settings.headless) return;

    logger.log("Current state:");
    prettyprint!(Yes.all)(plugin.state.client, plugin.state.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        writeln(channelName);
        prettyprint(channel);
    }
    //writeln();

    /*logger.log("Users:");
    foreach (immutable nickname, const user; plugin.state.users)
    {
        writeln(nickname);
        prettyprint(user);
    }*/

    if (plugin.state.settings.flush) stdout.flush();
}


// onCommandBusImpl
/++
    Sends an internal bus message to other plugins, much like how such can be
    sent with the Pipeline plugin.
 +/
void onCommandBusImpl(
    AdminPlugin plugin,
    const string header,
    const string content)
{
    import kameloso.common : logger;
    import kameloso.thread : ThreadMessage, boxed;
    import std.stdio : stdout, writeln;

    if (!plugin.state.settings.headless)
    {
        logger.info("Sending bus message.");
        writeln("Header: ", header);
        writeln("Content: ", content);

        if (plugin.state.settings.flush) stdout.flush();
    }

    plugin.state.messages ~= ThreadMessage.busMessage(header, boxed(content));
}

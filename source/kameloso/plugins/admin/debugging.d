
module kameloso.plugins.admin.debugging;

version(WithPlugins):
version(WithAdminPlugin):
debug:

private:

import kameloso.plugins.admin.base : AdminPlugin;

import dialect.defs;
import std.typecons : Flag, No, Yes;

package:




void onAnyEventImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    import std.stdio : write, writefln, writeln;

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
}




void onCommandShowUserImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    
}




void onCommandShowUsersImpl(AdminPlugin plugin)
{
    
}




void onCommandSudoImpl(AdminPlugin plugin, const ref IRCEvent event)
{
    
}




void onCommandStatusImpl(AdminPlugin plugin)
{
    import kameloso.common : logger;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    logger.log("Current state:");
    printObjects!(Yes.all)(plugin.state.client, plugin.state.server);
    writeln();

    logger.log("Channels:");
    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        writeln(channelName);
        printObjects(channel);
    }
    

    
}




void onCommandBusImpl(AdminPlugin plugin, const string input)
{
    import kameloso.common : logger;
    import kameloso.thread : ThreadMessage, busMessage;
    import lu.string : contains, nom;
    import std.concurrency : send;
    import std.stdio : writeln;

    if (!input.length) return;

    if (!input.contains!(Yes.decode)(' '))
    {
        logger.info("Sending bus message.");
        writeln("Header: ", input);
        writeln("Content: (empty)");

        plugin.state.mainThread.send(ThreadMessage.BusMessage(), input);
    }
    else
    {
        string slice = input;  
        immutable header = slice.nom(' ');

        logger.info("Sending bus message.");
        writeln("Header: ", header);
        writeln("Content: ", slice);

        plugin.state.mainThread.send(ThreadMessage.BusMessage(),
            header, busMessage(slice));
    }
}

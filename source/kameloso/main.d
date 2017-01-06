module kameloso.main;

import kameloso.irc;
import kameloso.connection;
import kameloso.plugins;
import kameloso.constants;
import kameloso.config;
import kameloso.common;

import std.stdio    : writeln, writefln;
import std.datetime : SysTime;
import std.concurrency;

version(Windows)
shared static this()
{
    import core.sys.windows.windows;
    SetConsoleCP(65001);
    SetConsoleOutputCP(65001);
}

private:

IrcBot bot;
IrcServer server;
IrcPlugin[] plugins;
IrcEvent[string] replayQueue;
Connection conn;
SysTime[string] whoisCalls;


public:


/// A simple struct to house the IRC server information. Helps with the configuration files.
struct IrcServer
{
    string address = "irc.freenode.net";
    ushort port = 6667;
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was received.
 +  The return value tells the caller whether the received action means the bot should exit.
 +
 +  Returns:
 +      ShouldQuit.yes or ShouldQuit.no, depending.
 +/
ShouldQuit checkMessages()
{
    import core.time  : seconds;

    mixin(scopeguard(failure));

    ShouldQuit shouldQuit;
    bool receivedSomething;

    do
    {
        // Use the bool of whether anything was received at all to decide if the loop should
        // continue. That way we neatly exhaust the mailbox before returning.
        receivedSomething = receiveTimeout(0.seconds,
            (ThreadMessage.Sendline, string line)
            {
                writeln("--> ", line);
                conn.sendline(line);
            },
            (ThreadMessage.Quietline, string line)
            {
                conn.sendline(line);
            },
            (ThreadMessage.Ping)
            {
                // writefln("--> PING :%s".format(bot.server));
                conn.sendline("PING :", bot.server);
            },
            (ThreadMessage.Whois, shared IrcEvent event)
            {
                import std.datetime : Clock;
                import std.conv : to;

                writeln("WHOIS REQUESTED ON ", event.sender);

                // Several plugins may (will) ask to WHOIS someone at the same time,
                // so keep track on when we WHOISed whom, to limit it
                auto now = Clock.currTime;
                auto then = (event.sender in whoisCalls);

                if (then && (now - *then) < Timeout.whois.seconds) return;

                 writeln("--> WHOIS :", event.sender);
                 conn.sendline("WHOIS :" ~ event.sender);
                 whoisCalls[event.sender] = Clock.currTime;
                 replayQueue[event.sender] = event;
            },
            (shared IrcBot bot)
            {
                .bot = cast(IrcBot)bot;

                foreach (plugin; plugins) plugin.newBot(.bot);
            },
            (ThreadMessage.Status)
            {
                foreach (plugin; plugins) plugin.status();
            },
            (ThreadMessage.Pong)
            {
                // writefln("--> PONG %s".format(bot.server));
                conn.sendline("PONG :", bot.server);
            },
            (ThreadMessage.Quit, string reason)
            {
                // This should automatically close the connection
                // Set shouldQuit to yes to propagate the decision down the stack
                const line = reason.length ? reason : bot.quitReason;
                conn.sendline("QUIT :", line);
                shouldQuit = ShouldQuit.yes;
            },
            (LinkTerminated e)
            {
                writeln("Some linked thread died!");
                shouldQuit = ShouldQuit.yes;
            },
            (Variant v)
            {
                writeln("Main thread received unknown Variant");
                writeln(v);
            }
        );
    }
    while (receivedSomething && !shouldQuit);

    return shouldQuit;
}


// handleArguments
/++
 +  A simple getopt application, allowing for options to be overridden via the command line.
 +  The priority of options then becomes getopt over config file over hardcoded defaults.
 +
 +  Params:
 +      The string[] args the program was called with.
 +
 +  Returns:
 +      ShouldQuit.yes or no depending on whether the arguments chosen mean the program should not proceed.
 +/
ShouldQuit handleArguments(string[] args)
{
    import std.getopt;
    import std.format : format;

    bool shouldWriteConfig;
    string configFileFromArgs;

    auto helpInfo = args.getopt(
        std.getopt.config.caseSensitive,
        "n|nickname",    "Bot nickname", &bot.nickname,
        "u|user",        "Username when logging onto server (not nickname)", &bot.user,
        "i|ident",       "IDENT string", &bot.ident,
        "p|password",    "NickServ password", &bot.password,
        "m|master",      "NickServ login of bot master, who gets access to administrative functions", &bot.master,
        "s|server",      "Server address", &server.address,
        "P|port",        "Server port", &server.port,
        "c|config",      "Read configuration from file (default %s)".format(Files.config), &configFileFromArgs,
        "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
        //"v|verbose+", "Increase verbosity", &bot.verbosity,
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("kameloso IRC bot, built %s\n"
                             .format(__TIMESTAMP__), helpInfo.options);
        writeln();
        return ShouldQuit.yes;
    }

    configFileFromArgs = (configFileFromArgs.length) ? configFileFromArgs : Files.config;
    configFileFromArgs.readConfig(bot, server);

    if (shouldWriteConfig)
    {
        writeln("Writing configuration to ", configFileFromArgs);
        configFileFromArgs.writeConfig(bot, server);
        writeln();
        printObject(bot);
        writeln();
        printObject(server);
        writeln();
        return ShouldQuit.yes;
    }

    return ShouldQuit.no;
}


/// Simply resets and initialises all plugins.
void initPlugins(IrcBot bot, Tid tid)
{
    foreach (plugin; plugins) plugin.teardown();

    plugins.length = 0;

    plugins ~= new ConnectPlugin(bot, tid);
    plugins ~= new AdminPlugin(bot, tid);
    plugins ~= new Pinger(bot, tid);
    plugins ~= new Chatbot(bot, tid);
    plugins ~= new Webtitles(bot, tid);
    plugins ~= new NotesPlugin(bot, tid);
}


/// Main!
void main(string[] args)
{
    if (handleArguments(args) == ShouldQuit.yes) return;

    // Print the current settings to show what's going on.
    printObject(bot);
    writeln();
    printObject(server);
    writeln();

    if (!bot.channels.length && !bot.master.length && !bot.friends.length)
    {
        import std.path : baseName;

        writeln("No master nor channels configured!");
        writefln("Use %s --writeconfig to generate a configuration file.",
            args[0].baseName);

        return;
    }

    auto shouldQuit = ShouldQuit.no;
    do
    {
        conn.reset();
        conn.resolve(server.address, server.port);
        conn.connect();

        if (!conn.connected)
        {
            writeln("Failed to connect.");
            return;
        }

        // Reset fields in the bot that should not survive a reconnect
        bot.finishedLogin = false;
        bot.server = string.init;

        initPlugins(bot, thisTid);

        auto generator = new Generator!string(() => listenFiber(conn));
        shouldQuit = loopGenerator(generator);
    }
    while (shouldQuit == ShouldQuit.no);
}


// loopGenerator
/++
 +  This loops over the Generator fiber that's reading from the socket. Full lines are
 +  yielded in the Generator to be caught here, consequently parsed into IrcEvents, and then
 +  dispatched to all the plugins.
 +
 +  Params:
 +      generator = a string-returning Generator that's reading from the socket.
 +
 +  Returns:
 +      ShouldQuit.yes if circumstances mean the bot should exit, otherwise ShouldQuit.no.
 +/
ShouldQuit loopGenerator(Generator!string generator)
{
    import core.thread : Fiber;

    auto shouldQuit = ShouldQuit.no;
    do
    {
        if (generator.state == Fiber.State.TERM)
        {
            // listening Generator disconnected; reconnect
            generator.reset();
            return ShouldQuit.no;
        }

        generator.call();

        foreach (line; generator)
        {
            /// Empty line yielded means nothing received
            if (!line.length) break;

            /// Hopefully making the event immutable means less gets copied?
            immutable event = stringToIrcEvent(line);

            with (IrcEvent.Type)
            switch (event.type)
            {
            case RPL_NAMREPLY:
            case RPL_MOTD:
            case PING:
            case PONG:
                // These event types are too spammy; ignore
                break;

            default:
                // TODO: add timestamps
                writeln(event);
            }

            foreach (plugin; plugins)
            {
                mixin(scopeguard(failure, "onEvent loop"));
                plugin.onEvent(event);

                if (event.type == IrcEvent.Type.WHOISLOGIN)
                {
                    const savedEvent = event.target in replayQueue;
                    if (!savedEvent) continue;
                    writeln("Replaying event:");
                    writeln(*savedEvent);
                    plugin.onEvent(*savedEvent);
                }
            }

            if (event.type == IrcEvent.Type.WHOISLOGIN)
            {
                replayQueue.remove(event.target);
            }
        }

        shouldQuit = checkMessages();
    }
    while (shouldQuit == ShouldQuit.no);

    return ShouldQuit.yes;
}

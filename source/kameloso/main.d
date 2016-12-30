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


IrcBot bot;
IrcServer server;
IrcPlugin[] plugins;
Connection conn;
SysTime[string] whoisCalls;


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
    import std.format : format;
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
                writefln("--> %s", line);
                conn.sendline(line);
            },
            (ThreadMessage.Quietline, string line)
            {
                conn.sendline(line);
            },
            (ThreadMessage.Ping)
            {
                // writefln("--> PING :%s".format(bot.server));
                conn.sendline("PING :%s".format(bot.server));
            },
            (ThreadMessage.Pong)
            {
                // writefln("--> PONG %s".format(bot.server));                
                conn.sendline("PONG :%s".format(bot.server));
            },
            (ThreadMessage.Quit)
            {
                // This should automatically close the connection
                // Set shouldQuit to yes to propagate the decision down the stack
                conn.sendline("QUIT :kameloso");
                shouldQuit = ShouldQuit.yes;
            },
            (ThreadMessage.Whois, string nickname)
            {
                import std.datetime : Clock;

                // Several plugins may (will) ask to WHOIS someone at the same time,
                // so keep track on when we WHOISed whom, to limit it
                auto now = Clock.currTime;
                auto then = (nickname in whoisCalls);
                
                if (then && (now - *then) < 10.seconds) return;

                 writefln("--> WHOIS :%s".format(nickname));
                 conn.sendline("WHOIS :%s".format(nickname));
                 whoisCalls[nickname] = Clock.currTime;
            },
            (shared IrcBot bot)
            {
                writeln("Bot updated");
                .bot = cast(IrcBot)bot;

                foreach (plugin; plugins) plugin.newBot(.bot);
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
        writefln("Writing configuration to %s", configFileFromArgs);
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
    foreach (plugin; plugins)
    {
        mixin(scopeguard(failure, "tearing down plugins"));
        plugin.teardown();
    }

    plugins.length = 0;

    plugins ~= new ConnectPlugin(bot, tid);
    plugins ~= new AdminPlugin(bot, tid);
    plugins ~= new Pinger(bot, tid);
    plugins ~= new Chatbot(bot, tid);
}


/// Main!
void main(string[] args)
{
    //mixin(scopeguard(entry|exit));

    if (handleArguments(args) == ShouldQuit.yes) return;

    // Print the current settings to show what's going on.
    printObject(bot);
    writeln();
    printObject(server);
    writeln();

    auto shouldQuit = ShouldQuit.no;
    top:
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
        bot.registered = false;
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
            }
        }

        shouldQuit = checkMessages();
    }
    while (shouldQuit == ShouldQuit.no);

    return ShouldQuit.yes;
}
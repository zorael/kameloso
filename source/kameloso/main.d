module kameloso.main;

import kameloso.constants;
import kameloso.common;
import kameloso.connection;
import kameloso.config;
import kameloso.irc;
import kameloso.plugins;

import std.stdio    : writeln, writefln;
import std.datetime : SysTime;
import std.concurrency;

version(Windows)
shared static this()
{
    import core.sys.windows.windows;
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
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
 +      Quit.yes or Quit.no, depending.
 +/
Quit checkMessages()
{
    import core.time  : seconds;

    mixin(scopeguard(failure));

    Quit quit;
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

                // Several plugins may (will) ask to WHOIS someone at the same time,
                // so keep track on when we WHOISed whom, to limit it
                const now = Clock.currTime;
                const then = (event.sender in whoisCalls);

                if (then && ((now - *then) < Timeout.whois.seconds)) return;

                writeln("--> WHOIS :", event.sender);
                conn.sendline("WHOIS :", event.sender);
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
                // Set quit to yes to propagate the decision down the stack
                const line = reason.length ? reason : bot.quitReason;
                conn.sendline("QUIT :", line);
                quit = Quit.yes;
            },
            (LinkTerminated e)
            {
                writeln("Some linked thread died!");
                quit = Quit.yes;
            },
            (Variant v)
            {
                writeln("Main thread received unknown Variant");
                writeln(v);
            }
        );
    }
    while (receivedSomething && !quit);

    return quit;
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
 +      Quit.yes or no depending on whether the arguments chosen mean the program should not proceed.
 +/
Quit handleArguments(string[] args)
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
        return Quit.yes;
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
        return Quit.yes;
    }

    return Quit.no;
}


/// Simply resets and initialises all plugins.
void initPlugins(IrcBot bot, Tid tid)
{
    foreach (plugin; plugins) plugin.teardown();

    plugins.length = 0;

    version (Multithreaded)
    {
        pragma(msg, "Building multithreaded plugins");
        enum multithreaded = Multithreaded.yes;
    }
    else
    {
        pragma(msg, "Building singlethreaded plugins");
        enum multithreaded = Multithreaded.no;
    }

    IrcPluginState state;
    state.bot = bot;
    state.mainThread = tid;

    plugins ~= new ConnectPlugin!(multithreaded)(state);
    plugins ~= new Pinger(state);
    plugins ~= new AdminPlugin!(multithreaded)(state);
    plugins ~= new Chatbot!(multithreaded)(state);
    plugins ~= new Webtitles(state);
    plugins ~= new NotesPlugin!(multithreaded)(state);
    plugins ~= new SedReplacePlugin!(multithreaded)(state);
}


/// Main!
int main(string[] args)
{
    if (handleArguments(args) == Quit.yes) return 0;

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

        return 1;
    }

    auto quit = Quit.no;
    do
    {
        conn.reset();
        conn.resolve(server.address, server.port);
        conn.connect();

        if (!conn.connected)
        {
            writeln("Failed to connect.");
            return 1;
        }

        // Reset fields in the bot that should not survive a reconnect
        bot.finishedLogin = false;
        bot.server = string.init;

        initPlugins(bot, thisTid);

        auto generator = new Generator!string(() => listenFiber(conn));
        quit = loopGenerator(generator);
    }
    while (!quit);

    return 0;
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
 +      Quit.yes if circumstances mean the bot should exit, otherwise Quit.no.
 +/
Quit loopGenerator(Generator!string generator)
{
    import core.thread : Fiber;

    auto quit = Quit.no;
    do
    {
        if (generator.state == Fiber.State.TERM)
        {
            // listening Generator disconnected; reconnect
            generator.reset();
            return Quit.no;
        }

        generator.call();

        foreach (const line; generator)
        {
            /// Empty line yielded means nothing received
            if (!line.length) break;

            /// Hopefully making the event immutable means less gets copied?
            immutable event = line.toIrcEvent();

            with (IrcEvent.Type)
            switch (event.type)
            {
            case RPL_NAMREPLY:
            case RPL_MOTD:
            case PING:
            case PONG:
            case SERVERINFO:
            case SERVERINFO_2:
            case RPL_LUSERCLIENT:
            case RPL_LUSEROP:
            case RPL_LUSERCHANNELS:
            case RPL_LUSERME:
            case RPL_LUSERUNKNOWN:
            case RPL_MOTDSTART:
            case RPL_ENDOFMOTD:
            case RPL_ENDOFNAMES:
            case USERCOUNTGLOBAL:
            case USERCOUNTLOCAL:
            case CONNECTIONRECORD:
                // These event types are too spammy; ignore
                break;

            default:
                import std.datetime;
                import std.array  : Appender;
                import std.format : formattedWrite;

                Appender!string app;
                app.reserve(768);

                //const datetime = cast(DateTime)Clock.currTime;
                const datetime = cast(DateTime)SysTime.fromUnixTime(event.time);
                const timestamp = datetime.timeOfDay;

                app.formattedWrite("[%s] ", timestamp);
                event.put(app);

                writeln(app.data);
            }

            bool spammedAboutReplaying;

            foreach (plugin; plugins)
            {
                mixin(scopeguard(failure, "onEvent loop"));
                plugin.onEvent(event);

                if (event.type == IrcEvent.Type.WHOISLOGIN)
                {
                    const savedEvent = event.target in replayQueue;
                    if (!savedEvent) continue;

                    if (!spammedAboutReplaying)
                    {
                        writeln("Replaying event:");
                        writeln(*savedEvent);
                        spammedAboutReplaying = true;
                    }

                    plugin.onEvent(*savedEvent);
                }
            }

            if (event.type == IrcEvent.Type.WHOISLOGIN)
            {
                replayQueue.remove(event.target);
            }
        }

        quit = checkMessages();
    }
    while (!quit);

    return Quit.yes;
}

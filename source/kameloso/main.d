module kameloso.main;

import kameloso.constants;
import kameloso.common;
import kameloso.connection;
import kameloso.config;
import kameloso.irc;
import kameloso.plugins;

import std.datetime : SysTime;
import std.concurrency;

version (Windows)
shared static this()
{
    import core.sys.windows.windows;

    // If we don't set the right codepage, the normal Windows cmd terminal won't display
    // international characters like åäö.
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
}

private:

/// State variables and configuration for the IRC bot.
IrcBot bot;

Settings settings;

/// A runtime array of all plugins. We iterate this when we have an IrcEvent to react to.
IrcPlugin[] plugins;

/// A 1-buffer of IrcEvents to replay when a WHOIS call returns.
IrcEvent[string] replayQueue;

/// The socket we use to connect to the server.
Connection conn;

/// When a nickname was called WHOIS on, for hysteresis.
SysTime[string] whoisCalls;


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was received.
 +
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
                // Catch a line, echo it to the terminal and send it to the server
                writeln(Foreground.white, "--> ", line);
                conn.sendline(line);
            },
            (ThreadMessage.Quietline, string line)
            {
                // Catch a line and send a line to the server without echoing it
                conn.sendline(line);
            },
            (ThreadMessage.Ping)
            {
                // Send a ping "to"" the server address saved in the bot.server struct
                writeln(Foreground.white, "--> PING :", bot.server.resolvedAddress);
                conn.sendline("PING :", bot.server.resolvedAddress);
            },
            (ThreadMessage.Whois, shared IrcEvent event)
            {
                import std.datetime : Clock;

                // Send a WHOIS call to the server, and buffer the requests so only one
                // goes out for a particular nickname at any one given time.
                // Identical requests are likely to go out several at a time, and we
                // only need one reply. So limit the calls.

                const now = Clock.currTime;
                const then = (event.sender in whoisCalls);

                if (then && ((now - *then) < Timeout.whois.seconds)) return;

                writeln(Foreground.white, "--> WHOIS :", event.sender);
                conn.sendline("WHOIS :", event.sender);
                whoisCalls[event.sender] = Clock.currTime;
                replayQueue[event.sender] = event;
            },
            (shared IrcBot bot)
            {
                // Catch an IrcBot, inherit it into .bot and and propagate it to
                // all plugins.

                .bot = cast(IrcBot)bot;

                foreach (plugin; plugins) plugin.newBot(.bot);
            },
            (Settings settings)
            {
                // Catch new settings, inherit them into .settings and propagate
                // them to all plugins.
                .settings = settings;

                foreach (plugin; plugins) plugin.newSettings(.settings);
            },
            (ThreadMessage.Status)
            {
                // Ask all plugins to print their plugin state.
                foreach (plugin; plugins) plugin.status();
            },
            (ThreadMessage.Pong, string target)
            {
                // Respond to PING with the supplied text as target.
                // writeln(Foreground.white, "--> PONG :", target);
                conn.sendline("PONG :", target);
            },
            (ThreadMessage.Quit, string reason)
            {
                // Quit the server with the supplied reason.
                // This should automatically close the connection.
                // Set quit to yes to propagate the decision down the stack.
                const line = reason.length ? reason : bot.quitReason;

                writeln(Foreground.white, "--> QUIT :", line);
                conn.sendline("QUIT :", line);

                foreach (plugin; plugins) plugin.teardown();

                quit = Quit.yes;
            },
            (Variant v)
            {
                // Caught an unhandled message
                writeln(Foreground.lightred, "Main thread received unknown Variant");
                writeln(Foreground.lightred, v);
            }
        );
    }
    while (receivedSomething && !quit);

    return quit;
}


// handleArguments
/++
 +  Read command-line options.
 +
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
    string homes, channels;
    GetoptResult helpInfo;

    try
    {
        helpInfo = args.getopt(
            config.caseSensitive,
            "n|nickname",    "Bot nickname", &bot.nickname,
            "u|user",        "Username when logging onto server (not nickname)", &bot.user,
            "i|ident",       "IDENT string", &bot.ident,
            "q|quitReason",  "Quit reason string", &bot.quitReason,
            "l|login",       "Auth service login name, if applicable", &bot.login,
            "p|password",    "Auth service password", &bot.password,
            "m|master",      "Auth login of the bot's master, who gets " ~
                            "access to administrative functions", &bot.master,
            "h|home",        "Home channels to operate in, comma-separated" ~
                            " (remember to escape or enquote the #s!)", &homes,
            "C|channel",     "Non-home channels to idle in, comma-separated" ~
                            " (ditto)", &channels,
            "s|server",      "Server address", &bot.server.address,
            "P|port",        "Server port", &bot.server.port,
            "c|config",      "Read configuration from file (default %s)".format(Files.config), &configFileFromArgs,
            "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
        );
    }
    catch (Exception e)
    {
        writeln(Foreground.lightred, e.msg);
        return Quit.yes;
    }

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Command-line arguments available:\n", helpInfo.options);
        writeln();
        return Quit.yes;
    }

    configFileFromArgs = (configFileFromArgs.length) ? configFileFromArgs : Files.config;
    configFileFromArgs.readConfig(bot, bot.server, settings);

    import kameloso.stringutils : arrayify;

    if (homes.length) bot.homes = homes.arrayify;
    if (channels.length) bot.channels = channels.arrayify;

    if (shouldWriteConfig)
    {
        configFileFromArgs.writeConfigToDisk();
        return Quit.yes;
    }

    return Quit.no;
}


/// Resets and initialises all plugins.
void initPlugins()
{
    foreach (plugin; plugins) plugin.teardown();

    IrcPluginState state;
    state.bot = bot;
    state.settings = settings;
    state.mainThread = thisTid;

    plugins = cast(IrcPlugin[])
    [
        new Printer(state),
        new SedReplacePlugin(state),
        new AdminPlugin(state),
        new NotesPlugin(state),
        new Chatbot(state),
        new ConnectPlugin(state),
    ];

    version (Webtitles)
    {
        plugins ~= new Webtitles(state);
    }

    version (Posix)
    {
        plugins ~= new Pipeline(state);
    }
}


void writeConfigToDisk(const string configFile)
{
    writeln(Foreground.lightcyan, "Writing configuration to ", configFile);
    configFile.writeConfig(bot, bot.server, settings);
    writeln();
    printObjects(bot, bot.server, settings);
}


public:


version (unittest)
void main() {
    writeln("Tests passed!");
}
else
int main(string[] args)
{
    writefln(Foreground.white, "kameloso IRC bot, built %s\n", __TIMESTAMP__);

    if (handleArguments(args) == Quit.yes) return 0;

    // Print the current settings to show what's going on.
    printObjects(bot, bot.server, settings);

    if (!bot.homes.length && !bot.master.length && !bot.friends.length)
    {
        import std.path : baseName;

        writeln("No master nor channels configured!");
        writefln("Use %s --writeconfig to generate a configuration file.",
            args[0].baseName);

        return 1;
    }

    // save the original nickname *once*, outside the connection loop
    bot.origNickname = bot.nickname;

    Quit quit;
    do
    {
        conn.reset();
        conn.resolve(bot.server.address, bot.server.port);
        conn.connect();

        if (!conn.connected)
        {
            writeln("Failed to connect.");
            return 1;
        }

        // Reset fields in the bot that should not survive a reconnect
        bot.finishedLogin = false;
        bot.attemptedLogin = false;
        bot.server.resolvedAddress = string.init;

        initPlugins();

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

    Quit quit;

    while (!quit)
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
            // Empty line yielded means nothing received
            if (!line.length) break;

            // Hopefully making the event immutable means less gets copied?
            immutable event = line.toIrcEvent();

            bool spammedAboutReplaying;

            foreach (plugin; plugins)
            {
                plugin.onEvent(event);

                if ((event.type == IrcEvent.Type.WHOISLOGIN) ||
                    (event.type == IrcEvent.Type.HASTHISNICK))
                {
                    const savedEvent = event.target in replayQueue;
                    if (!savedEvent) continue;

                    if (!spammedAboutReplaying)
                    {
                        writeln(Foreground.white, "Replaying event:");
                        printObjects(*savedEvent);
                        spammedAboutReplaying = true;
                    }

                    plugin.onEvent(*savedEvent);
                }
            }

            if ((event.type == IrcEvent.Type.WHOISLOGIN) ||
                (event.type == IrcEvent.Type.HASTHISNICK))
            {
                replayQueue.remove(event.target);
            }
        }

        quit = checkMessages();
    }

    return Quit.yes;
}

module kameloso.main;

import kameloso.common;
import kameloso.connection;
import kameloso.constants;
import kameloso.irc;

import std.concurrency;
import std.datetime : SysTime;
import std.stdio;
import std.typecons : Flag, No, Yes;

version(Windows)
shared static this()
{
    import core.sys.windows.windows;

    // If we don't set the right codepage, the normal Windows cmd terminal won't
    // display international characters like åäö.
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
}

private:

/// When this is set by signal handlers, the program should exit.
bool abort;

/// State variables and configuration for the IRC bot.
IRCBot bot;

/// Runtime settings for bot behaviour.
Settings settings;


/// A 1-buffer of IRCEvents to replay when a WHOIS call returns.
IRCEvent[string] replayQueue;

/// The socket we use to connect to the server.
Connection conn;

/// When a nickname was called WHOIS on, for hysteresis.
SysTime[string] whoisCalls;


extern (C)
void signalHandler(int signal) nothrow @nogc @system
{
    printf("...caught signal %d!\n", signal);
    abort = true;
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was received.
 +
 +  The return value tells the caller whether the received action means the bot
 +  should exit or not.
 +
 +  Returns:
 +      Yes.quit or No.quit, depending.
 +/
Flag!"quit" checkMessages()
{
    import core.time : seconds;

    scope (failure) teardownPlugins();

    Flag!"quit" quit;

    /// Echo a line to the terminal and send it to the server
    static void sendline(ThreadMessage.Sendline, string line)
    {
        logger.trace("--> ", line);
        conn.sendline(line);
    }

    /// Send a line to the server without echoing it
    static void quietline(ThreadMessage.Quietline, string line)
    {
        conn.sendline(line);
    }

    /// Receive new settings, inherit them into .settings and propagate
    /// them to all plugins.
    static void updateSettings(Settings settings)
    {
        .settings = settings;
    }

    /// Respond to PING with PONG to the supplied text as target.
    static void pong(ThreadMessage.Pong, string target)
    {
        conn.sendline("PONG :", target);
    }

    /// Quit the server with the supplied reason.
    void quitServer(ThreadMessage.Quit, string reason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision down the stack.
        const line = reason.length ? reason : bot.quitReason;

        logger.trace("--> QUIT :", line);
        conn.sendline("QUIT :", line);

        teardownPlugins();

        quit = Yes.quit;
    }

    /// Fake that a string was received from the server
    static void stringToEvent(string line)
    {
    }

    bool receivedSomething;

    do
    {
        // Use the bool of whether anything was received at all to decide if
        // the loop should continue. That way we neatly exhaust the mailbox
        // before returning.

        // BUG: except if quit is true, then it returns without exhausting
        receivedSomething = receiveTimeout(0.seconds,
            &sendline,
            &quietline,
            &pong,
            &quitServer,
            &stringToEvent,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );
    }
    while (receivedSomething && !quit);

    return quit;
}


// handleArguments
/++
 +  Read command-line options and merge them with those in the configuration file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded
 +  defaults.
 +
 +  Params:
 +      The string[] args the program was called with.
 +
 +  Returns:
 +      Yes.quit or no depending on whether the arguments chosen mean the program
 +      should not proceed.
 +/
Flag!"quit" handleArguments(string[] args)
{
    import std.format : format;
    import std.getopt;

    bool shouldWriteConfig;
    bool shouldShowVersion;
    GetoptResult results;

    try
    {
        arraySep = ",";

        results = args.getopt(
            config.caseSensitive,
            "n|nickname",    "Bot nickname", &bot.nickname,
            "u|user",        "Username when registering onto server (not nickname)",
                &bot.user,
            "i|ident",       "IDENT string", &bot.ident,
            "pass",          "Registration password (not auth or nick services)",
                &bot.pass,
            "a|auth",        "Auth service login name, if applicable",
                &bot.authLogin,
            "p|authpassword","Auth service password", &bot.authPassword,
            "m|master",      "Auth login of the bot's master, who gets " ~
                            "access to administrative functions", &bot.master,
            "H|home",        "Home channels to operate in, comma-separated" ~
                            " (remember to escape or enquote the #s!)", &bot.homes,
            "C|channel",     "Non-home channels to idle in, comma-separated" ~
                            " (ditto)", &bot.channels,
            "s|server",      "Server address", &bot.server.address,
            "P|port",        "Server port", &bot.server.port,
            "c|config",      "Read configuration from file (default %s)"
                             .format(Settings.init.configFile), &settings.configFile,
            "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
            "writeconf",     &shouldWriteConfig,
            "version",       "Show version info", &shouldShowVersion,
        );
    }
    catch (const Exception e)
    {
        // User misspelled or supplied an invalid argument; error out and quit
        logger.error(e.msg);
        return Yes.quit;
    }

    // Read settings into a temporary Bot and Settings struct, then meld them
    // into the real ones into which the command-line arguments will have been
    // applied.

    return No.quit;
}

void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        colourCode.colour,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        BashForeground.default_.colour);
}


void teardownPlugins()
{
}

void startPlugins()
{
}

void propagateBot(IRCBot bot)
{
}


void initLogger()
{
    import std.experimental.logger;

    kameloso.common.logger = new KamelosoLogger(LogLevel.all,
        settings.monochrome);
}


// loopGenerator
/++
 +  This loops over the Generator fiber that's reading from the socket.
 +
 +  Full lines are yielded in the Generator to be caught here, consequently
 +  parsed into IRCEvents, and then dispatched to all the plugins.
 +
 +  Params:
 +      generator = a string-returning Generator that's reading from the socket.
 +
 +  Returns:
 +      Yes.quit if circumstances mean the bot should exit, otherwise No.quit.
 +/
Flag!"quit" loopGenerator(Generator!string generator)
{
    import core.thread : Fiber;

    Flag!"quit" quit;

    while (!quit)
    {
        if (generator.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            generator.reset();
            return No.quit;
        }

        generator.call();

        foreach (immutable line; generator)
        {
            // Empty line yielded means nothing received
            if (!line.length) break;
        }

        // Check concurrency messages to see if we should exit
        quit = checkMessages();
    }

    return Yes.quit;
}

void handleQueue(W)(const IRCEvent event, ref W[string] reqs, const string nickname)
{
    if (nickname.length &&
        ((event.type == IRCEvent.Type.RPL_WHOISACCOUNT) ||
        (event.type == IRCEvent.Type.RPL_WHOISREGNICK)))
    {
        auto req = nickname in reqs;
        if (!req) return;
        req.trigger();
        reqs.remove(nickname);
    }
    else
    {
        foreach (entry; reqs.byKeyValue)
        {
            if (!entry.key.length) continue;

            with (entry)
            {
                import std.datetime : Clock;
                import core.time : seconds;

                const then = key in whoisCalls;
                const now = Clock.currTime;

                if (!then || ((now - *then) > Timeout.whois.seconds))
                {
                    logger.trace("--> WHOIS :", key);
                    conn.sendline("WHOIS :", key);
                    whoisCalls[key] = Clock.currTime;
                }
                else
                {
                    // logger.log("Too soon... ", (now - *then));
                }
            }
        }
    }
}


public:


version(unittest)
void main() {
    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't reinit here.
    logger.info("All tests passed successfully!");
}
else
int main(string[] args)
{
    import core.stdc.signal;

    // Initialise the logger immediately so it's always available, reinit later
    initLogger();

    scope(failure)
    {
        logger.error("We just crashed!");
        signal(SIGINT, SIG_DFL);

        version(Posix)
        {
            import core.sys.posix.signal : SIGHUP;
            signal(SIGHUP, SIG_DFL);
        }
    }

    // Set up signal handlers
    signal(SIGINT, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, &signalHandler);
    }

    if (handleArguments(args) == Yes.quit) return 0;

    printVersionInfo(BashForeground.white);
    writeln();

    // Print the current settings to show what's going on.
    printObjects(bot, bot.server, settings);

    if (!bot.homes.length && !bot.master.length && !bot.friends.length)
    {
        import std.path : baseName;

        logger.warning("No master nor channels configured!");
        logger.logf("Use %s --writeconfig to generate a configuration file.",
                     args[0].baseName);
        return 1;
    }

    // Save the original nickname *once*, outside the connection loop
    bot.origNickname = bot.nickname;

    Flag!"quit" quit;

    with (bot)
    do
    {
        conn.reset();

        immutable resolved = conn.resolve(server.address, server.port, abort);
        if (!resolved) return Yes.quit;

        conn.connect(abort);

        if (!conn.connected) return 1;

        // Reset fields in the bot that should not survive a reconnect
        startedRegistering = false;
        finishedRegistering = false;
        startedAuth = false;
        finishedAuth = false;
        server.resolvedAddress = string.init;

        auto generator = new Generator!string(() => listenFiber(conn, abort));
        quit = loopGenerator(generator);
    }
    while (!quit && !abort && settings.reconnectOnFailure);

    if (quit)
    {
        teardownPlugins();
    }
    else if (abort)
    {
        logger.warning("Aborting...");
        teardownPlugins();
        return 1;
    }

    logger.info("Exiting...");

    return 0;
}

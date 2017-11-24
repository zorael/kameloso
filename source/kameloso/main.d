module kameloso.main;

import kameloso.common;
import kameloso.connection;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins;

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

/// State variables and configuration for the IRC bot.
IRCBot bot;

/// Runtime settings for bot behaviour.
Settings settings;

/// A runtime array of all plugins. We iterate this when we have an IRCEvent to react to.
IRCPlugin[] plugins;

/// A 1-buffer of IRCEvents to replay when a WHOIS call returns.
IRCEvent[string] replayQueue;

/// The socket we use to connect to the server.
Connection conn;

/// When a nickname was called WHOIS on, for hysteresis.
SysTime[string] whoisCalls;

/// Parser instance.
IRCParser parser;


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

        foreach (plugin; plugins) plugin.newSettings(.settings);
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
        immutable event = parser.toIRCEvent(line);

        logger.info("Forging an event!");

        if (parser.bot.updated)
        {
            // Parsing changed the bot
            parser.bot.updated = false;
            bot = parser.bot;
            propagateBot(bot);
        }

        foreach (plugin; plugins) plugin.onEvent(event);
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
    import kameloso.config : readConfigInto;
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

    IRCBot botFromConfig;
    Settings settingsFromConfig;

    // These arguments are by reference.
    settings.configFile.readConfigInto(botFromConfig,
        botFromConfig.server, settingsFromConfig);

    botFromConfig.meldInto(bot);
    settingsFromConfig.meldInto(settings);

    // We know Settings now so reinitialise the logger
    initLogger();

    // Give common.d a copy of Settings. FIXME
    kameloso.common.settings = settings;

    if (results.helpWanted)
    {
        printVersionInfo(BashForeground.white);
        writeln();

        defaultGetoptPrinter(BashForeground.lightgreen.colour ~
                            "Command-line arguments available:\n" ~
                            BashForeground.default_.colour,
                            results.options);
        writeln();
        return Yes.quit;
    }

    // If --version was supplied we should just show info and quit
    if (shouldShowVersion)
    {
        printVersionInfo();
        return Yes.quit;
    }

    // Likewise if --writeconfig was supplied we should just write and quit
    if (shouldWriteConfig)
    {
        printVersionInfo(BashForeground.white);
        logger.info("Writing configuration to ", settings.configFile);
        writeln();

        // If we don't initialise the plugins there'll be no plugins array
        initPlugins();

        writeConfigurationFile(settings.configFile);
        return Yes.quit;
    }

    return No.quit;
}


void writeConfigurationFile(const string filename)
{
    import kameloso.config;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(512);
    sink.serialise(bot, bot.server, settings);

    printObjects(bot, bot.server, settings);

    foreach (plugin; plugins)
    {
        plugin.addToConfig(sink);
        // Not all plugins with configuration is important enough to list
        plugin.present();
    }

    immutable justified = sink.data.justifiedConfigurationText;
    writeToDisk!(Yes.addBanner)(settings.configFile, justified);
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


/// Resets and initialises all plugins.
void initPlugins()
{
    teardownPlugins();

    IRCPluginState state;
    state.bot = bot;
    state.settings = settings;
    state.mainThread = thisTid;

    // Zero out old plugins array and allocate room for new ones
    plugins.length = 0;
    plugins.reserve(EnabledPlugins.length + 2);

    foreach (Plugin; EnabledPlugins)
    {
        plugins ~= new Plugin(state);
    }

    // Add Webtitles if possible
    static if (__traits(compiles, new WebtitlesPlugin(IRCPluginState.init)))
    {
        plugins ~= new WebtitlesPlugin(state);
    }

    // Add Pipeline if possible
    static if (__traits(compiles, new PipelinePlugin(IRCPluginState.init)))
    {
        plugins ~= new PipelinePlugin(state);
    }

    foreach (plugin; plugins)
    {
        plugin.loadConfig(state.settings.configFile);
    }
}

void teardownPlugins()
{
    if (!plugins.length) return;

    logger.info("Deinitialising plugins");
    foreach (plugin; plugins) plugin.teardown();
}

void startPlugins()
{
    if (!plugins.length) return;

    logger.info("Starting plugins");
    foreach (plugin; plugins) plugin.start();
}

/// Writes the current configuration to the config file specified in the Settings.
/*void writeConfigAndPrint(const string configFile)
{
    logger.info("Writing configuration to ", configFile);
    configFile.writeToDisk!(Yes.addBanner)(bot, bot.server, settings);
    writeln();
    printObjects(bot, bot.server, settings);
}*/

void propagateBot(IRCBot bot)
{
    parser.bot = bot;

    foreach (plugin; plugins)
    {
        plugin.newBot(bot);
    }
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

            IRCEvent event;

            try event = parser.toIRCEvent(line);
            catch (const IRCParseException e)
            {
                logger.warningf("IRCParseException at %s:%d: %s",
                    e.file, e.line, e.msg);
                printObject(event);
                continue;
            }
            catch (Exception e)
            {
                logger.warningf("Unhandled exception at %s:%d: %s",
                    e.file, e.line, e.msg);
                continue;
            }

            if (parser.bot.updated)
            {
                // Parsing changed the bot; propagate
                parser.bot.updated = false;
                bot = parser.bot;
                propagateBot(bot);
            }

            foreach (plugin; plugins)
            {
                plugin.postprocess(event);

                if (parser.bot.updated)
                {
                    // Postprocessing changed the bot; propagate
                    parser.bot.updated = false;
                    bot = parser.bot;
                    propagateBot(bot);
                }
            }

            foreach (plugin; plugins)
            {
                try
                {
                    plugin.onEvent(event);

                    auto reqs = plugin.yieldWHOISRequests();
                    reqs.handleQueue(event, event.target.nickname);

                    auto yieldedBot = plugin.yieldBot();
                    if (yieldedBot.updated)
                    {
                        /*  Plugin onEvent or WHOIS reaction updated the bot.
                            There's no need to check for both since this is just
                            a single plugin processing; it keeps its update
                            through both passes.
                         */
                        bot = yieldedBot;
                        bot.updated = false;
                        propagateBot(bot);
                    }
                }
                catch (const Exception e)
                {
                    logger.error(e.msg);
                }
            }
        }

        // Check concurrency messages to see if we should exit
        quit = checkMessages();
    }

    return Yes.quit;
}

void handleQueue(W)(ref W[string] reqs, const IRCEvent event, const string nickname)
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

/// When this is set by signal handlers, the program should exit.
__gshared bool abort;


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
        teardownPlugins();
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
        parser = IRCParser(bot);

        initPlugins();
        startPlugins();

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

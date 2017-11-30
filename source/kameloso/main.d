module kameloso.main;

import kameloso.common;
import kameloso.connection;
import kameloso.irc;
import kameloso.plugins;
import kameloso.constants;

import std.concurrency : Generator, thisTid;
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
CoreSettings settings;

/// A runtime array of all plugins. We iterate this when we have an IRCEvent to react to.
IRCPlugin[] plugins;

/// The socket we use to connect to the server.
Connection conn;

/// When a nickname was called WHOIS on, for hysteresis.
SysTime[string] whoisCalls;

/// Parser instance.
IRCParser parser;


// signalHandler
/++
 +  Called when a signal is raised, usually SIGINT.
 +
 +  Sets the `abort` variable to `true` so other parts of the program knows to
 +  gracefully shut down.
 +/
extern (C)
void signalHandler(int signal) nothrow @nogc @system
{
    printf("...caught signal %d!\n", signal);
    abort = true;
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was
 +  received.
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
    import std.concurrency : receiveTimeout, Variant;

    scope (failure) teardownPlugins();

    Flag!"quit" quit;

    /// Echo a line to the terminal and send it to the server.
    static void sendline(ThreadMessage.Sendline, string line)
    {
        logger.trace("--> ", line);
        conn.sendline(line);
    }

    /// Send a line to the server without echoing it.
    static void quietline(ThreadMessage.Quietline, string line)
    {
        conn.sendline(line);
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
        // Set quit to yes to propagate the decision up the stack.
        logger.trace("--> QUIT :", reason);
        conn.sendline("QUIT :", reason);

        quit = Yes.quit;
    }

    /// Quit the server with the default reason
    void quitEmpty(ThreadMessage.Quit)
    {
        return quitServer(ThreadMessage.Quit(), bot.quitReason);
    }

    /// Did the concurrency receive catch something?
    bool receivedSomething;

    do
    {
        receivedSomething = receiveTimeout(0.seconds,
            &sendline,
            &quietline,
            &pong,
            &quitServer,
            &quitEmpty,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );
    }
    while (receivedSomething && !quit);

    if (receivedSomething && quit)
    {
        // We received something that made us quit. Exhaust the concurrency
        // mailbox before quitting.
        do
        {
            receivedSomething = receiveTimeout(0.seconds,
                (Variant v) {},
            );
        }
        while (receivedSomething);
    }

    return quit;
}


// handleGetopt
/++
 +  Read command-line options and merge them with those in the configuration
 +  file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded
 +  defaults.
 +
 +  Params:
 +      The string[] args the program was called with.
 +
 +  Returns:
 +      Yes.quit or no depending on whether the arguments chosen mean the
 +      program should proceed or not.
 +/
Flag!"quit" handleGetopt(string[] args)
{
    import std.format : format;
    import std.getopt;

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;

    arraySep = ",";

    auto results = args.getopt(
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
        "settings",      "Show all plugins' settings", &shouldShowSettings,
        "c|config",      "Read configuration from file (default %s)"
                            .format(CoreSettings.init.configFile), &settings.configFile,
        "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
        "writeconf",     &shouldWriteConfig,
        "version",       "Show version info", &shouldShowVersion,
        "generateAsserts","(DEBUG) Parse an IRC event string and generate an assert block",
            &shouldGenerateAsserts,
        "gen",           &shouldGenerateAsserts,
    );

    meldSettingsFromFile(bot, settings);

    // Give common.d a copy of CoreSettings for printObject. FIXME
    kameloso.common.settings = settings;

    // We know CoreSettings now so reinitialise the logger
    initLogger();

    if (results.helpWanted)
    {
        // --help|-h was passed; show the help table and quit
        printVersionInfo(BashForeground.white);
        writeln();

        defaultGetoptPrinter("Command-line arguments available:\n"
            .colour(BashForeground.lightgreen), results.options);
        writeln();
        return Yes.quit;
    }

    if (shouldShowVersion)
    {
        // --version was passed; show info and quit
        printVersionInfo();
        return Yes.quit;
    }

    if (shouldWriteConfig)
    {
        // --writeconfig was passed; write configuration to file and quit
        printVersionInfo(BashForeground.white);

        logger.info("Writing configuration to ", settings.configFile);
        writeln();

        // If we don't initialise the plugins there'll be no plugins array
        initPlugins();

        writeConfigurationFile(settings.configFile);
        return Yes.quit;
    }

    if (shouldShowSettings)
    {
        // --settings was passed, show all options and quit
        printVersionInfo(BashForeground.white);
        writeln();

        // FIXME: Hardcoded width
        printObjects!17(bot, bot.server, settings);

        initPlugins();
        foreach (plugin; plugins) plugin.printSettings();

        return Yes.quit;
    }

    if (shouldGenerateAsserts)
    {
        generateAsserts();
        return Yes.quit;
    }

    return No.quit;
}


// generateAsserts
/++
 +  Reads raw server strings from `stdin`, parses them to `IRCEvent`s and
 +  constructs assert blocks of their contents.
 +
 +  This is a debugging tool.
 +/
void generateAsserts()
{
    import kameloso.plugins.admin : formatEventAssertBlock;
    import std.array : Appender;

    parser.bot = bot;

    Appender!(char[]) sink;
    sink.reserve(768);

    printObject(parser.bot);

    string input;

    while ((input = readln()) !is null)
    {
        import std.regex : matchFirst, regex;
        if (abort) return;

        auto hits = input[0..$-1].matchFirst("^[ /]*(.+)".regex);
        immutable event = parser.toIRCEvent(hits[1]);
        sink.formatEventAssertBlock(event);
        writeln();
        writeln(sink.data);
        sink.clear();
    }
}


// meldSettingsFromFile
/++
 +  Read core settings, and IRCBot from file into temporaries, then meld them
 +  into the real ones into which the command-line arguments wil have been
 +  applied.
 +
 +  Params:
 +      ref bot = the IRCBot bot apply all changes to.
 +      ref setttings = the core settings to apply changes to.
 +/
void meldSettingsFromFile(ref IRCBot bot, ref CoreSettings settings)
{
    import kameloso.config : readConfigInto;

    IRCBot botFromConfig;
    CoreSettings settingsFromConfig;

    // These arguments are by reference.
    settings.configFile.readConfigInto(botFromConfig,
        botFromConfig.server, settingsFromConfig);

    botFromConfig.meldInto(bot);
    settingsFromConfig.meldInto(settings);
}


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Params:
 +      filename = the string filename of the file to write to.
 +/
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

        // Not all plugins with configuration is important enough to list, so
        // not all will have something to present()
        plugin.present();
    }

    immutable justified = sink.data.justifiedConfigurationText;
    writeToDisk!(Yes.addBanner)(filename, justified);
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and github URL, with the
 +  passed colouring.
 +
 +  Params:
 +      colourCode = the Bash foreground colour to display the text in.
 +/
void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        colourCode.colour,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        BashForeground.default_.colour);
}


// initPlugins
/++
 +  Resets and *minimally* initialises all plugins.
 +
 +  It only initialises them to the point where they're aware of their settings,
 +  and not far enough to have loaded any resources.
 +/
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

    // Instantiate all plugin types in the `EnabledPlugins` `AliasSeq` in
    // `kameloso.plugins.package`
    foreach (Plugin; EnabledPlugins)
    {
        plugins ~= new Plugin(state);
    }

    // Add `webtitles` if possible. If it's not being publically imported in
    // `kameloso.plugins.package`, it's not there to instantiate, which is the
    // case when we're not compiling the version `Webtitles`.
    static if (__traits(compiles, new WebtitlesPlugin(IRCPluginState.init)))
    {
        plugins ~= new WebtitlesPlugin(state);
    }

    // Likewise with `pipeline`, except it depends on whether we're on a Posix
    // system or not.
    static if (__traits(compiles, new PipelinePlugin(IRCPluginState.init)))
    {
        plugins ~= new PipelinePlugin(state);
    }

    foreach (plugin; plugins)
    {
        plugin.loadConfig(state.settings.configFile);
    }
}


// teardownPlugins
/++
 +  Tears down all plugins, deinitialising them and having them save their
 +  settings for a clean shutdown.
 +
 +  Think of it as a plugin destructor.
 +/
void teardownPlugins()
{
    if (!plugins.length) return;

    logger.info("Deinitialising plugins");

    foreach (plugin; plugins)
    {
        try plugin.teardown();
        catch (const Exception e)
        {
            logger.error(e.msg);
        }
    }
}


// startPlugins
/++
 +  *start* all plugins, loading any resources they may want.
 +
 +  This has to happen after `initPlugins` or there will not be any plugins in
 +  the `plugin` array to start.
 +/
void startPlugins()
{
    if (!plugins.length) return;

    logger.info("Starting plugins");
    foreach (plugin; plugins)
    {
        plugin.start();
        auto yieldedBot = plugin.yieldBot();

        if (yieldedBot.updated)
        {
            // start changed the bot; propagate
            bot = yieldedBot;
            bot.updated = false;
            parser.bot = bot;
            propagateBot(bot);
        }
    }
}


// propagateBot
/++
 +  Takes a bot and passes it out to all plugins.
 +
 +  This is called when a change to the bot has occured and we want to update
 +  all plugins to have an updated copy of it.
 +
 +  Params:
 +      bot = IRCBot to propagate.
 +/
void propagateBot(IRCBot bot)
{
    foreach (plugin; plugins)
    {
        plugin.newBot(bot);
    }
}


// initLogger
/++
 +  Initialises the `KamelosoLogger` logger for use in the whole program.
 +
 +  We pass the `monochrome` setting bool here to control if the logger should
 +  be coloured or not.
 +/
void initLogger()
{
    import std.experimental.logger : LogLevel;

    kameloso.common.logger = new KamelosoLogger(LogLevel.all,
        settings.monochrome);
}


// mainLoop
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
Flag!"quit" mainLoop(Generator!string generator)
{
    import core.thread : Fiber;

    /// Flag denoting whether we should quit or not.
    Flag!"quit" quit;

    while (!quit)
    {
        if (generator.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            generator.reset();
            return No.quit;
        }

        // Call the generator, query it for event lines
        generator.call();

        foreach (immutable line; generator)
        {
            // Empty line yielded means nothing received
            if (!line.length) break;

            IRCEvent event;

            try
            {
                event = parser.toIRCEvent(line);

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
                    auto yieldedBot = plugin.yieldBot();

                    if (yieldedBot.updated)
                    {
                        // Postprocessing changed the bot; propagate
                        bot = yieldedBot;
                        bot.updated = false;
                        parser.bot = bot;
                        propagateBot(bot);
                    }
                }

                // Let each plugin process the event
                foreach (plugin; plugins)
                {
                    plugin.onEvent(event);

                    // Fetch any queued WHOIS requests and handle
                    auto reqs = plugin.yieldWHOISRequests();
                    reqs.handleWHOISQueue(event, event.target.nickname);

                    auto yieldedBot = plugin.yieldBot();
                    if (yieldedBot.updated)
                    {
                        /*  Plugin onEvent or WHOIS reaction updated the bot.
                            There's no need to check for both separately since
                            this is just a single plugin processing; it keeps
                            its update internally between both passes.
                        */
                        bot = yieldedBot;
                        bot.updated = false;
                        parser.bot = bot;
                        propagateBot(bot);
                    }
                }
            }
            catch (const IRCParseException e)
            {
                logger.warningf("IRCParseException at %s:%d: %s",
                    e.file, e.line, e.msg);
                printObject(event);
                continue;
            }
            catch (const Exception e)
            {
                logger.warningf("Unhandled exception at %s:%d: %s",
                    e.file, e.line, e.msg);
                continue;
            }
        }

        // Check concurrency messages to see if we should exit, else repeat
        quit = checkMessages();
    }

    return Yes.quit;
}


// handleWHOISQueue
/++
 +  Take a queue of `WHOISRequest` objects and process them one by one,
 +  replaying function pointers on attached `IRCEvent`s.
 +
 +  This is more or less a Command pattern.
 +/
void handleWHOISQueue(W)(ref W[string] reqs, const IRCEvent event,
    const string nickname)
{
    if (nickname.length &&
        ((event.type == IRCEvent.Type.RPL_WHOISACCOUNT) ||
        (event.type == IRCEvent.Type.RPL_WHOISREGNICK)))
    {
        // If the event was one with login information, see if there is an event
        // to replay, and trigger it if so
        auto req = nickname in reqs;
        if (!req) return;
        req.trigger();
        reqs.remove(nickname);
    }
    else
    {
        // Walk through requests and call `WHOIS` on those that haven't been
        // `WHOIS`ed in the last `Timeout.whois` seconds

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
                    //logger.log(key, " too soon...");
                }
            }
        }
    }
}


// setupSignals
/++
 +  Registers `SIGINT` (and optionally `SIGHUP` on Posix systems) to redirect to
 +  our own `signalHandler`. so we can catch Ctrl+C and gracefully shut down.
 +/
void setupSignals()
{
    import core.stdc.signal : signal, SIGINT;

    signal(SIGINT, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, &signalHandler);
    }
}


public:

/// When this is set by signal handlers, the program should exit. Other parts of
/// the program will be monitoring it.
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
    import std.getopt : GetOptException;

    // Initialise the logger immediately so it's always available, reinit later
    // when we know the settings for monochrome
    initLogger();

    scope(failure)
    {
        import core.stdc.signal : signal, SIGINT, SIG_DFL;

        logger.error("We just crashed!");
        teardownPlugins();

        // Restore signal handlers to the default
        signal(SIGINT, SIG_DFL);

        version(Posix)
        {
            import core.sys.posix.signal : SIGHUP;
            signal(SIGHUP, SIG_DFL);
        }
    }

    setupSignals();

    try
    {
        // Act on arguments getopt, quit if whatever was passed demands it
        if (handleGetopt(args) == Yes.quit) return 0;
    }
    catch (const GetOptException e)
    {
        logger.error(e.msg);
        return 1;
    }

    printVersionInfo(BashForeground.white);
    writeln();

    // Print the current settings to show what's going on.
    printObjects(bot, bot.server);

    if (!bot.homes.length && !bot.master.length && !bot.friends.length)
    {
        import std.path : baseName;

        logger.warning("No master nor channels configured!");
        logger.logf("Use %s --writeconfig to generate a configuration file.",
            args[0].baseName);
        return 1;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    bot.origNickname = bot.nickname;

    /// Flag denoting that we should quit the program.
    Flag!"quit" quit;

    /// Bool whether this is the first connection attempt or if we have
    /// connected at least once already.
    bool connectedAlready;

    do
    {
        if (connectedAlready)
        {
            import core.time : seconds;
            logger.log("Please wait a few seconds...");
            interruptibleSleep(Timeout.retry.seconds, abort);
        }

        conn.reset();

        immutable resolved = conn.resolve(bot.server.address,
            bot.server.port, abort);
        if (!resolved) return 1;

        conn.connect(abort);
        if (!conn.connected) return 1;

        // Reset fields in the bot that should not survive a reconnect
        bot.startedRegistering = false;
        bot.finishedRegistering = false;
        bot.startedAuth = false;
        bot.finishedAuth = false;
        bot.server.resolvedAddress = string.init;
        parser = IRCParser(bot);

        initPlugins();
        startPlugins();

        // Initialise the Generator and start the main loop
        auto generator = new Generator!string(() => listenFiber(conn, abort));
        quit = mainLoop(generator);
        connectedAlready = true;
    }
    while (!quit && !abort && settings.reconnectOnFailure);

    if (quit)
    {
        teardownPlugins();
    }
    else if (abort)
    {
        // Ctrl+C
        logger.warning("Aborting...");
        teardownPlugins();
        return 1;
    }

    logger.info("Exiting...");
    return 0;
}

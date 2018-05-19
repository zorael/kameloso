/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.main;

import kameloso.common;
import kameloso.irc;
import kameloso.ircdefs;

import core.thread : Fiber;
import std.typecons : Flag, No, Yes;

version(Windows)
shared static this()
{
    import core.sys.windows.windows : SetConsoleCP, SetConsoleOutputCP, CP_UTF8;

    // If we don't set the right codepage, the normal Windows cmd terminal won't
    // display international characters like åäö.
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
}

private:

/++
 +  Abort flag.
 +
 +  This is set when the program is interrupted (such as via Ctrl+C). Other
 +  parts of the program will be monitoring it, to take the cue and abort when
 +  it is set.
 +/
__gshared bool abort;


// signalHandler
/++
 +  Called when a signal is raised, usually `SIGINT`.
 +
 +  Sets the `abort` variable to `true` so other parts of the program knows to
 +  gracefully shut down.
 +
 +  Params:
 +      sig = Integer of the signal raised.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.stdio : printf;

    printf("...caught signal %d!\n", sig);
    abort = true;

    // Restore signal handlers to the default
    resetSignals();
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was
 +  received.
 +
 +  The return value tells the caller whether the received action means the bot
 +  should exit or not.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +
 +  Returns:
 +      `Yes.quit` or `No.quit`, depending.
 +/
Flag!"quit" checkMessages(ref Client client)
{
    import kameloso.plugins.common : IRCPlugin;
    import kameloso.common : initLogger, settings;
    import core.time : seconds;
    import std.concurrency : receiveTimeout;
    import std.variant : Variant;

    scope (failure) client.teardownPlugins();

    Flag!"quit" quit;

    /// Echo a line to the terminal and send it to the server.
    void throttleline(ThreadMessage.Throttleline, string line)
    {
        import core.thread : Thread;
        import core.time : seconds, msecs;
        import std.datetime.systime : Clock, SysTime;

        if (*(client.abort)) return;

        with (client.throttling)
        {
            const now = Clock.currTime;
            if (t0 == SysTime.init) t0 = now;

            double x = (now - t0).total!"msecs"/1000.0;
            auto y = k * x + m;

            if (y < 0)
            {
                t0 = now;
                m = 0;
                x = 0;
                y = 0;
            }

            while (y >= burst)
            {
                x = (Clock.currTime - t0).total!"msecs"/1000.0;
                y = k*x + m;
                interruptibleSleep(100.msecs, *(client.abort));
                if (*(client.abort)) return;
            }

            logger.trace("--> ", line);
            client.conn.sendline(line);

            m = y + increment;
            t0 = Clock.currTime;
        }
    }

    /// Echo a line to the terminal and send it to the server.
    void sendline(ThreadMessage.Sendline, string line)
    {
        logger.trace("--> ", line);
        client.conn.sendline(line);
    }

    /// Send a line to the server without echoing it.
    void quietline(ThreadMessage.Quietline, string line)
    {
        client.conn.sendline(line);
    }

    /// Respond to `PING` with `PONG` to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        client.conn.sendline("PONG :", target);
    }

    /// Ask plugins to reload.
    void reload(ThreadMessage.Reload)
    {
        foreach (plugin; client.plugins)
        {
            plugin.reload();
        }
    }

    /// Quit the server with the supplied reason, or the default.
    void quitServer(ThreadMessage.Quit, string givenReason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision up the stack.
        immutable reason = givenReason.length ? givenReason : client.bot.quitReason;
        logger.tracef(`--> QUIT :"%s"`, reason);
        client.conn.sendline("QUIT :\"", reason, "\"");
        quit = Yes.quit;
    }

    /// Saves current configuration to disk.
    void save(ThreadMessage.Save)
    {
        client.writeConfigurationFile(settings.configFile);
    }

    /++
     +  Passes a reference to the main array of
     +  `kameloso.plugins.common.IRCPlugin`s array (housing all plugins) to the
     +  supplied `kameloso.plugins.common.IRCPlugin`.
     +/
    void peekPlugins(ThreadMessage.PeekPlugins, shared IRCPlugin sPlugin)
    {
        auto plugin = cast(IRCPlugin)sPlugin;
        plugin.peekPlugins(client.plugins);
    }

    /// Reloads all plugins.
    void reloadPlugins(ThreadMessage.Reload)
    {
        foreach (plugin; client.plugins)
        {
            plugin.reload();
        }
    }

    /// Reverse-formats an event and sends it to the server.
    void eventToServer(IRCEvent event)
    {
        import std.format : format;

        string line;

        with (IRCEvent.Type)
        with (event)
        with (client)
        switch (event.type)
        {
        case CHAN:
            line = "PRIVMSG %s :%s".format(channel, content);
            break;

        case QUERY:
            line = "PRIVMSG %s :%s".format(target.nickname, content);
            break;

        case EMOTE:
            alias I = IRCControlCharacter;

            immutable emoteTarget = target.nickname.length ?
                target.nickname : channel;

            line = "PRIVMSG %s :%s%s%s".format(emoteTarget,
                cast(int)I.ctcp, content, cast(int)I.ctcp);
            break;

        case MODE:
            line = "MODE %s %s :%s".format(channel, aux, content);
            break;

        case TOPIC:
            line = "TOPIC %s :%s".format(channel, content);
            break;

        case INVITE:
            line = "INVITE %s :%s".format(channel, target.nickname);
            break;

        case JOIN:
            line = "JOIN %s".format(channel);
            break;

        case KICK:
            immutable reason = content.length ? " :" ~ content : string.init;
            line = "KICK %s%s".format(channel, reason);
            break;

        case PART:
            immutable reason = content.length ? " :" ~ content : string.init;
            line = "PART %s%s".format(channel, reason);
            break;

        case QUIT:
            return quitServer(ThreadMessage.Quit(), content);

        case NICK:
            line = "NICK %s".format(target.nickname);
            break;

        case PRIVMSG:
            if (channel.length) goto case CHAN;
            else goto case QUERY;

        case UNSET:
            line = content;
            break;

        default:
            logger.warning("No outgoing event case for type ", type);
            line = content;
            break;
        }

        if (event.target.special)
        {
            quietline(ThreadMessage.Quietline(), line);
        }
        else
        {
            sendline(ThreadMessage.Sendline(), line);
        }
    }

    /// Did the concurrency receive catch something?
    bool receivedSomething;
    uint receivedInARow;

    do
    {
        static immutable instant = 0.seconds;

        receivedSomething = receiveTimeout(instant,
            &sendline,
            &quietline,
            &throttleline,
            &pong,
            &eventToServer,
            &quitServer,
            &save,
            &reloadPlugins,
            &peekPlugins,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );

        if (receivedSomething) ++receivedInARow;
    }
    while (receivedSomething && !quit && (receivedInARow < 5));

    return quit;
}


// removeMeWhenPossible
/++
 +  Removing this breaks `-c vanilla -b plain` compilation, dmd error -11.
 +/
void removeMeWhenPossible()
{
    import kameloso.debugging : formatEventAssertBlock;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.formatEventAssertBlock(IRCEvent.init);
    assert(0);
}


// mainLoop
/++
 +  This loops creates a `std.concurrency.Generator` `core.thread.Fiber` to loop
 +  over the over `std.socket.Socket`, reading and yielding lines as it goes.
 +
 +  Full lines are yielded in the `std.concurrency.Generator` to be caught here,
 +  consequently parsed into `kameloso.ircdefs.IRCEvent`s, and then dispatched
 +  to all the plugins.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +
 +  Returns:
 +      `Yes.quit` if circumstances mean the bot should exit, otherwise
 +      `No.quit.`
 +/
Flag!"quit" mainLoop(ref Client client)
{
    import kameloso.common : printObjects;
    import kameloso.connection : listenFiber;
    import core.exception : UnicodeException;
    import core.thread : Fiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock;
    import std.utf : UTFException;

    /// Flag denoting whether we should quit or not.
    Flag!"quit" quit;

    /// Keep track of daemon and network so we know when to report detection.
    IRCServer.Daemon detectedDaemon;
    string detectedNetwork;

    // Instantiate a Generator to read from the socket and yield lines
    auto generator = new Generator!string(() =>
        listenFiber(client.conn, *(client.abort)));

    /// How often to check for timed `Fiber`s, multiples of `Timeout.receive`.
    enum checkTimedFibersEveryN = 3;

    /++
     +  How many more receive passes until it should next check for timed
     +  `Fiber`s.
     +/
    int timedFiberCheckCounter = checkTimedFibersEveryN;

    while (!quit)
    {
        if (generator.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            generator.reset();
            return No.quit;
        }

        // See if day broke
        const now = Clock.currTime;

        if (now.day != client.today)
        {
            logger.infof("[%d-%02d-%02d]", now.year, cast(int)now.month, now.day);
            client.today = now.day;
        }

        // Call the generator, query it for event lines
        generator.call();

        with (client)
        foreach (immutable line; generator)
        {
            // Go through Fibers awaiting a point in time, regardless of whether
            // something was read or not.

            immutable nowInUnix = now.toUnixTime;

            /++
             +  At a cadence of once every `checkFiberFibersEveryN`, walk the
             +  array of plugins and see if they have timed `core.thread.Fiber`s
             +  to call.
             +/
            if (--timedFiberCheckCounter <= 0)
            {
                // Reset counter
                timedFiberCheckCounter = checkTimedFibersEveryN;

                foreach (plugin; plugins)
                {
                    if (!plugin.timedFibers.length) continue;

                    size_t[] toRemove;

                    foreach (immutable i, ref fiber; plugin.timedFibers)
                    {
                        if (fiber.id > nowInUnix)
                        {
                            import kameloso.constants : Timeout;
                            import std.algorithm.comparison : min;

                            // This Fiber shouldn't yet be triggered.
                            // Lower timedFiberCheckCounter to fire earlier, in
                            // case the time-to-fire is lower than the current
                            // counter value. This gives it more precision.

                            immutable next = cast(int)(fiber.id - nowInUnix) /
                                Timeout.receive;
                            timedFiberCheckCounter = min(timedFiberCheckCounter,
                                next);
                            continue;
                        }

                        try
                        {
                            if (fiber.state == Fiber.State.HOLD)
                            {
                                fiber.call();
                            }

                            // Always removed a timed Fiber after processing
                            toRemove ~= i;
                        }
                        catch (const IRCParseException e)
                        {
                            logger.warningf("IRCParseException %s.timedFibers[%d]: %s",
                                plugin.name, i, e.msg);
                            printObject(e.event);
                            toRemove ~= i;
                        }
                        catch (const Exception e)
                        {
                            logger.warningf("Exception %s.timedFibers[%d]: %s",
                                plugin.name, i, e.msg);
                            toRemove ~= i;
                        }
                    }

                    // Clean up processed Fibers
                    foreach_reverse (i; toRemove)
                    {
                        import std.algorithm.mutation : remove;
                        plugin.timedFibers = plugin.timedFibers.remove(i);
                    }
                }
            }

            // Empty line yielded means nothing received; break and try again
            if (!line.length) break;

            IRCEvent mutEvent;

            try
            {
                import std.encoding : sanitize;
                // Sanitise and try again once on UTF/Unicode exceptions

                try
                {
                    mutEvent = parser.toIRCEvent(line);
                }
                catch (const UTFException e)
                {
                    mutEvent = parser.toIRCEvent(sanitize(line));
                }
                catch (const UnicodeException e)
                {
                    mutEvent = parser.toIRCEvent(sanitize(line));
                }

                if (parser.bot.updated)
                {
                    // Parsing changed the bot; propagate
                    parser.bot.updated = false;
                    bot = parser.bot;
                    propagateBot(bot);

                    if ((detectedDaemon == IRCServer.Daemon.init) &&
                        (bot.server.daemon != detectedDaemon))
                    {
                        import kameloso.string : enumToString;

                        // We know the Daemon

                        detectedDaemon = bot.server.daemon;
                        string daemonName = bot.server.daemon.enumToString;

                        version (Colours)
                        {
                            if (!settings.monochrome)
                            {
                                import kameloso.bash : BashForeground, colour;

                                immutable tint = settings.brightTerminal ?
                                    BashForeground.black : BashForeground.white;
                                daemonName = daemonName.colour(tint);
                            }
                        }

                        logger.infof("Detected daemon: %s (%s)",
                            daemonName, bot.server.daemonstring);
                    }

                    if (!detectedNetwork.length && bot.server.network != detectedNetwork)
                    {
                        import std.string : capitalize;
                        import std.uni : isLower;

                        // We know the network string

                        detectedNetwork = bot.server.network;
                        string networkName = bot.server.network[0].isLower ?
                            bot.server.network.capitalize() : bot.server.network;

                        version (Colours)
                        {
                            if (!settings.monochrome)
                            {
                                import kameloso.bash : BashForeground, colour;

                                immutable tint = settings.brightTerminal ?
                                    BashForeground.black : BashForeground.white;
                                networkName = networkName.colour(tint);
                            }
                        }

                        logger.info("Detected network: ", networkName);
                    }
                }

                foreach (plugin; plugins)
                {
                    plugin.postprocess(mutEvent);

                    if (plugin.bot.updated)
                    {
                        // Postprocessing changed the bot; propagate
                        bot = plugin.bot;
                        bot.updated = false;
                        parser.bot = bot;
                        propagateBot(bot);
                    }
                }

                immutable IRCEvent event = mutEvent;

                // Let each plugin process the event
                foreach (plugin; plugins)
                {
                    try
                    {
                        plugin.onEvent(event);

                        // Go through Fibers awaiting IRCEvent.Types
                        if (auto fibers = event.type in plugin.awaitingFibers)
                        {
                            size_t[] toRemove;

                            foreach (immutable i, ref fiber; *fibers)
                            {
                                try
                                {
                                    if (fiber.state == Fiber.State.HOLD)
                                    {
                                        fiber.call();
                                    }

                                    if (fiber.state == Fiber.State.TERM)
                                    {
                                        toRemove ~= i;
                                    }
                                }
                                catch (const IRCParseException e)
                                {
                                    logger.warningf("IRCParseException %s." ~
                                        "awaitingFibers[%d]: %s",
                                        plugin.name, i, e.msg);
                                    printObject(e.event);
                                    toRemove ~= i;
                                }
                                catch (const Exception e)
                                {
                                    logger.warningf("Exception %s.awaitingFibers[%d]: %s",
                                        plugin.name, i, e.msg);
                                    printObject(event);
                                    toRemove ~= i;
                                }
                            }

                            // Clean up processed Fibers
                            foreach_reverse (i; toRemove)
                            {
                                import std.algorithm.mutation : remove;
                                *fibers = (*fibers).remove(i);
                            }

                            // If no more Fibers left, remove the Type entry in the AA
                            if (!(*fibers).length)
                            {
                                plugin.awaitingFibers.remove(event.type);
                            }
                        }

                        // Fetch any queued `WHOIS` requests and handle
                        client.handleWHOISQueue(plugin.whoisQueue);

                        if (plugin.bot.updated)
                        {
                            /*  Plugin `onEvent` or `WHOIS` reaction updated the
                                bot. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps its update internally
                                between both passes.
                            */
                            bot = plugin.bot;
                            bot.updated = false;
                            parser.bot = bot;
                            propagateBot(bot);
                        }
                    }
                    catch (const UTFException e)
                    {
                        logger.warningf("UTFException %s.onEvent: %s",
                            plugin.name, e.msg);
                    }
                    catch (const Exception e)
                    {
                        logger.warningf("Exception %s.onEvent: %s",
                            plugin.name, e.msg);
                        printObject(event);
                    }
                }
            }
            catch (const IRCParseException e)
            {
                logger.warningf("IRCParseException at %s:%d: %s",
                    e.file, e.line, e.msg);
                printObject(e.event);
            }
            catch (const UTFException e)
            {
                logger.warning("UTFException: ", e.msg);
            }
            catch (const UnicodeException e)
            {
                logger.warning("UnicodeException: ", e.msg);
            }
            catch (const Exception e)
            {
                logger.warningf("Unhandled exception at %s:%d: %s",
                    e.file, e.line, e.msg);

                if (mutEvent != IRCEvent.init)
                {
                    printObject(mutEvent);
                }
                else
                {
                    logger.warningf(`Offending line: "%s"`, line);
                }
            }
        }

        // Check concurrency messages to see if we should exit, else repeat
        quit = checkMessages(client);
    }

    return Yes.quit;
}


// handleFibers
/++
 +  Takes an array of `core.thread.Fiber`s and processes them.
 +
 +  If passed `Yes.exhaustive` they are removed from the arrays after they are
 +  called, so they won't be triggered again next pass. Otherwise only the
 +  finished ones are removed.
 +
 +  Params:
 +      exhaustive = Whether to always remove `core.thread.Fiber`s after
 +          processing.
 +      fibers = Reference to an array of `core.thread.Fiber`s to process.
 +/
void handleFibers(Flag!"exhaustive" exhaustive = No.exhaustive)(ref Fiber[] fibers)
{
    size_t[] emptyIndices;

    foreach (immutable i, ref fiber; fibers)
    {
        if (fiber.state == Fiber.State.TERM)
        {
            emptyIndices ~= i;
        }
        else if (fiber.state == Fiber.State.HOLD)
        {
            fiber.call();
        }
        else
        {
            assert(0, "Invalid Fiber state");
        }
    }

    static if (exhaustive)
    {
        // Remove all called Fibers
        fibers.length = 0;
    }
    else
    {
        // Remove completed Fibers
        foreach_reverse (i; emptyIndices)
        {
            import std.algorithm.mutation : remove;
            fibers = fibers.remove(i);
        }
    }
}


// handleWHOISQueue
/++
 +  Takes a queue of `WHOISRequest` objects and emits `WHOIS` requests for each
 +  one.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      reqs = Refernce to an associative array of `WHOISRequest`s.
 +/
void handleWHOISQueue(W)(ref Client client, ref W[string] reqs)
{
    // Walk through requests and call `WHOIS` on those that haven't been
    // `WHOIS`ed in the last `Timeout.whois` seconds

    foreach (key, value; reqs)
    {
        if (!key.length) continue;

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;
        import core.time : seconds;

        const then = key in client.whoisCalls;
        const now = Clock.currTime.toUnixTime;

        if (!then || ((now - *then) > Timeout.whois))
        {
            logger.trace("--> WHOIS :", key);
            client.conn.sendline("WHOIS :", key);
            client.whoisCalls[key] = Clock.currTime.toUnixTime;
        }
        else
        {
            //logger.log(key, " too soon...");
        }
    }
}


// setupSignals
/++
 +  Registers `SIGINT` (and optionally `SIGHUP` on Posix systems) to redirect to
 +  our own `signalHandler`. so we can catch Ctrl+C and gracefully shut down.
 +/
void setupSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIGINT;

    signal(SIGINT, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, &signalHandler);
    }
}


// resetSignals
/++
 +  Resets `SIGINT` (and `SIGHUP` handlers) to the system default.
 +/
void resetSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIG_DFL, SIGINT;

    signal(SIGINT, SIG_DFL);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, SIG_DFL);
    }
}


public:

version(unittest)
/++
 +  Unittesting main; does nothing.
 +/
void main()
{
    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't reinit here.
    logger.info("All tests passed successfully!");
    // No need to Cygwin-flush; the logger did that already
}
else
/++
 +  Entry point of the program.
 +/
int main(string[] args)
{
    import kameloso.common : printObjects;
    import std.conv : ConvException;
    import std.getopt : GetOptException;
    import std.stdio : writeln;

    // Initialise the main Client. Set its abort pointer to the global abort.
    Client client;
    client.abort = &abort;

    string[] customSettings;

    // Initialise the logger immediately so it's always available, reinit later
    // when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal);

    scope(failure)
    {
        logger.error("We just crashed!");
        client.teardownPlugins();
        resetSignals();
    }

    setupSignals();

    try
    {
        import kameloso.getopt : handleGetopt;
        // Act on arguments getopt, quit if whatever was passed demands it
        if (client.handleGetopt(args, customSettings) == Yes.quit) return 0;
    }
    catch (const GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", e.msg);
        return 1;
    }
    catch (const ConvException e)
    {
        logger.error("Error converting command-line arguments: ", e.msg);
        return 1;
    }
    catch (const Exception e)
    {
        logger.error("Unhandled exception handling command-line arguments: ", e.msg);
        return 1;
    }

    with (client)
    {
        import kameloso.bash : BashForeground;

        BashForeground tint = BashForeground.default_;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                if (settings.brightTerminal)
                {
                    tint = BashForeground.black;
                }
                else
                {
                    tint = BashForeground.white;
                }
            }
        }

        printVersionInfo(tint);
        writeln();

        // Print the current settings to show what's going on.
        printObjects(bot, bot.server);

        if (!bot.homes.length && !bot.admins.length)
        {
            import std.path : baseName;

            logger.error("No administrators nor channels configured!");
            logger.logf("Use %s --writeconfig to generate a configuration file.",
                args[0].baseName);

            return 1;
        }

        // Save the original nickname *once*, outside the connection loop.
        // It will change later and knowing this is useful when authenticating
        bot.origNickname = bot.nickname;

        /// Flag denoting that we should quit the program.
        Flag!"quit" quit;

        /++
         +  Bool whether this is the first connection attempt or if we have
         +  connected at least once already.
         +/
        bool firstConnect = true;

        do
        {
            // Reset fields in the bot that should not survive a reconnect
            import kameloso.ircdefs : IRCBot;  // fix visibility warning
            import kameloso.irc : IRCParser;

            bot.registration = IRCBot.Status.notStarted;
            bot.authentication = IRCBot.Status.notStarted;

            /+
             +  If we're reconnecting we're connecting to the same server, so we
             +  can likely assume the daemon, daemonstring and network stay the
             +  unchanged. Not so for the resolvedAddress, as we're likely
             +  connecting to a server that redirects by round-robin to other
             +  servers.
             +/
            /*bot.server.daemon = IRCServer.Daemon.init;
            bot.server.daemontring = string.init;
            bot.server.network = string.init;*/
            bot.server.resolvedAddress = string.init;

            parser = IRCParser(bot);

            string[][string] invalidEntries = initPlugins(customSettings);

            if (invalidEntries.length)
            {
                import kameloso.bash : BashReset, colour;
                import kameloso.logger : KamelosoLogger;
                import std.array : Appender;
                import std.experimental.logger : LogLevel;

                logger.log("Found invalid configuration entries:");

                Appender!(char[]) sink;
                sink.reserve(64);

                immutable infotint = settings.brightTerminal ?
                    KamelosoLogger.logcoloursBright[LogLevel.info] :
                    KamelosoLogger.logcoloursDark[LogLevel.info];

                immutable logtint = settings.brightTerminal ?
                    KamelosoLogger.logcoloursBright[LogLevel.all] :
                    KamelosoLogger.logcoloursDark[LogLevel.all];

                foreach (const section, const sectionEntries; invalidEntries)
                {
                    import std.format : format;

                    sink.colour(logtint);
                    sink.put('[');
                    sink.colour(infotint);
                    sink.put(section);
                    sink.colour(logtint);
                    sink.put("]: ");
                    sink.colour(infotint);
                    sink.put(`%-("%s"%|, %)`.format(sectionEntries));
                    sink.colour(BashReset.all);
                    logger.trace(sink.data);
                    sink.clear();
                }

                sink.colour(logtint);
                sink.put("They are either malformed or no longer in use. Use ");
                sink.colour(infotint);
                sink.put("--writeconfig");
                sink.colour(logtint);
                sink.put(" to update your configuration file.");
                sink.colour(BashReset.all);
                logger.trace(sink.data);
            }

            if (!firstConnect)
            {
                import kameloso.constants : Timeout;
                import core.time : seconds;

                logger.log("Please wait a few seconds...");
                interruptibleSleep(Timeout.retry.seconds, *abort);
            }

            conn.reset();

            immutable resolved = conn.resolve(bot.server.address,
                bot.server.port, *abort);

            if (!resolved)
            {
                teardownPlugins();
                logger.error("Exiting...");
                return 1;
            }

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.bash : BashForeground;

                    with (settings)
                    with (BashForeground)
                    {
                        import kameloso.bash : BashReset, colour;
                        import kameloso.logger : KamelosoLogger;
                        import std.array : Appender;
                        import std.conv : to;
                        import std.experimental.logger : LogLevel;

                        Appender!string sink;
                        sink.reserve(64);

                        immutable infotint = brightTerminal ?
                            KamelosoLogger.logcoloursBright[LogLevel.info] :
                            KamelosoLogger.logcoloursDark[LogLevel.info];

                        immutable logtint = brightTerminal ?
                            KamelosoLogger.logcoloursBright[LogLevel.all] :
                            KamelosoLogger.logcoloursDark[LogLevel.all];

                        sink.colour(infotint);
                        sink.put(bot.server.address);
                        sink.colour(logtint);
                        sink.put(" resolved into ");
                        sink.colour(infotint);
                        sink.put(conn.ips.length.to!string);
                        sink.colour(logtint);
                        sink.put(" IPs.");
                        sink.colour(BashReset.all);

                        logger.trace(sink.data);
                    }
                }
                else
                {
                    logger.infof("%s resolved into %d IPs.", bot.server.address,
                    conn.ips.length);
                }
            }
            else
            {
                logger.infof("%s resolved into %d IPs.", bot.server.address,
                    conn.ips.length);
            }

            conn.connect(*abort);

            if (!conn.connected)
            {
                // Save if configuration says we should
                if (settings.saveOnExit)
                {
                    client.writeConfigurationFile(settings.configFile);
                }

                teardownPlugins();
                logger.error("Exiting...");
                return 1;
            }

            startPlugins();

            // Start the main loop
            quit = client.mainLoop();
            firstConnect = false;

            // Save if we're exiting and configuration says we should.
            if ((quit || *abort) && settings.saveOnExit)
            {
                client.writeConfigurationFile(settings.configFile);
            }

            // Always teardown after connection ends
            teardownPlugins();
        }
        while (!quit && !(*abort) && settings.reconnectOnFailure);

        if (*abort)
        {
            // Ctrl+C
            logger.error("Aborting...");
            return 1;
        }
        else
        {
            logger.info("Exiting...");
            return 0;
        }
    }
}

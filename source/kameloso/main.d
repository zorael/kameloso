module kameloso.main;

import kameloso.common;
import kameloso.connection;
import kameloso.irc;
import kameloso.ircdefs;
import kameloso.plugins;

import std.concurrency : Generator, thisTid;
import std.datetime.systime : SysTime;
import std.typecons : Flag, No, Yes;

import std.stdio;

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

Client client;


// signalHandler
/++
 +  Called when a signal is raised, usually `SIGINT`.
 +
 +  Sets the `abort` variable to `true` so other parts of the program knows to
 +  gracefully shut down.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.signal : signal, SIGINT, SIG_DFL;
    printf("...caught signal %d!\n", sig);
    client.abort = true;

    // Restore signal handlers to the default
    signal(SIGINT, SIG_DFL);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP;
        signal(SIGHUP, SIG_DFL);
    }
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
Flag!"quit" checkMessages(ref Client client)
{
    import core.time : seconds;
    import std.concurrency : receiveTimeout, Variant;

    scope (failure) client.teardownPlugins();

    Flag!"quit" quit;

    /// Echo a line to the terminal and send it to the server.
    void throttleline(ThreadMessage.Throttleline, string line)
    {
        import core.thread : Thread;
        import core.time : seconds, msecs;
        import std.datetime.systime : Clock, SysTime;

        if (client.abort) return;

        with (client.throttling)
        {
            if (t0 == SysTime.init) t0 = Clock.currTime;

            double x = (Clock.currTime - t0).total!"msecs"/1000.0;
            auto y = k * x + m;

            if (y < 0)
            {
                t0 = Clock.currTime;
                m = 0;
                x = 0;
                y = 0;
            }

            while (y >= burst)
            {
                x = (Clock.currTime - t0).total!"msecs"/1000.0;
                y = k*x + m;
                interruptibleSleep(100.msecs, client.abort);
                if (client.abort) return;
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

    /// Quit the server with the supplied reason.
    void quitServer(ThreadMessage.Quit, string reason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision up the stack.
        logger.trace("--> QUIT :", reason);
        client.conn.sendline("QUIT :", reason);

        quit = Yes.quit;
    }

    /// Quit the server with the default reason
    void quitEmpty(ThreadMessage.Quit)
    {
        return quitServer(ThreadMessage.Quit(), client.bot.quitReason);
    }

    /// Did the concurrency receive catch something?
    bool receivedSomething;
    uint receivedInARow;

    do
    {
        receivedSomething = receiveTimeout(0.seconds,
            &sendline,
            &quietline,
            &throttleline,
            &pong,
            &quitServer,
            &quitEmpty,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );

        if (receivedSomething) ++receivedInARow;
    }
    while (receivedSomething && !quit && (receivedInARow < 5));

    if (receivedSomething && quit)
    {
        // We received something that made us quit. Exhaust the concurrency
        // mailbox before quitting.
        do
        {
            receivedSomething = receiveTimeout(0.seconds,
                (Variant v)
                {
                    logger.warning("Main thread received unknown Variant: ", v);
                }
            );
        }
        while (receivedSomething);
    }

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
Flag!"quit" mainLoop(ref Client client, Generator!string generator)
{
    import core.thread : Fiber;
    import std.datetime.systime : Clock;

    /// Flag denoting whether we should quit or not.
    Flag!"quit" quit;

    /// Keep track of daemon and network so we know when to report detection
    IRCServer.Daemon detectedDaemon;
    string detectedNetwork;

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
            // Empty line yielded means nothing received
            if (!line.length) break;

            IRCEvent event;

            try
            {
                event = parser.toIRCEvent(line);

                if (parser.bot != bot)
                {
                    // Parsing changed the bot; propagate
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
                        import kameloso.bash : BashForeground, colour;

                        // We know the network string

                        detectedNetwork = bot.server.network;
                        string networkName = bot.server.network;

                        version (Colours)
                        {
                            if (!settings.monochrome)
                            {
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
                    plugin.postprocess(event);
                    auto yieldedBot = plugin.yieldBot();

                    if (yieldedBot != bot)
                    {
                        // Postprocessing changed the bot; propagate
                        bot = yieldedBot;
                        parser.bot = bot;
                        propagateBot(bot);
                    }
                }

                // Let each plugin process the event
                foreach (plugin; plugins)
                {
                    try
                    {
                        plugin.onEvent(event);

                        // Fetch any queued WHOIS requests and handle
                        auto reqs = plugin.yieldWHOISRequests();
                        client.handleWHOISQueue(reqs, event, event.target.nickname);

                        auto yieldedBot = plugin.yieldBot();
                        if (yieldedBot != bot)
                        {
                            /*  Plugin onEvent or WHOIS reaction updated the
                                bot. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps iits update internally
                                between both passes.
                            */
                            bot = yieldedBot;
                            parser.bot = bot;
                            propagateBot(bot);
                        }
                    }
                    catch (const Exception e)
                    {
                        logger.warning("Exception onEvent: ", e.msg);
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
        quit = checkMessages(client);
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
void handleWHOISQueue(W)(ref Client client, ref W[string] reqs,
    const IRCEvent event, const string nickname)
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
                import kameloso.constants : Timeout;

                import std.datetime : Clock;
                import core.time : seconds;

                const then = key in client.whoisCalls;
                const now = Clock.currTime;

                if (!then || ((now - *then) > Timeout.whois.seconds))
                {
                    logger.trace("--> WHOIS :", key);
                    client.conn.sendline("WHOIS :", key);
                    client.whoisCalls[key] = Clock.currTime;
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

version(unittest)
void main() {
    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't reinit here.
    logger.info("All tests passed successfully!");
}
else
int main(string[] args)
{
    import kameloso.bash : BashForeground;
    import std.conv : ConvException;
    import std.getopt : GetOptException;

    // Initialise the logger immediately so it's always available, reinit later
    // when we know the settings for monochrome
    initLogger(client.settings.monochrome, client.settings.brightTerminal);

    scope(failure)
    {
        import core.stdc.signal : signal, SIGINT, SIG_DFL;

        logger.error("We just crashed!");
        client.teardownPlugins();

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
        import kameloso.getopt : handleGetopt;

        // Act on arguments getopt, quit if whatever was passed demands it
        if (client.handleGetopt(args) == Yes.quit) return 0;
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
        BashForeground tint;

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

        printVersionInfo(tint);
        writeln();

        // Print the current settings to show what's going on.
        printObjects(bot, bot.server);

        if (!bot.homes.length && !bot.master.length && !bot.friends.length)
        {
            import std.path : baseName;

            logger.error("No master nor channels configured!");
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
        bool firstConnect = true;

        do
        {
            import std.datetime.systime : Clock;

            if (!firstConnect)
            {
                import kameloso.constants : Timeout;
                import core.time : seconds;

                logger.log("Please wait a few seconds...");
                interruptibleSleep(Timeout.retry.seconds, abort);
            }

            conn.reset();

            immutable resolved = conn.resolve(bot.server.address,
                bot.server.port, abort);

            if (!resolved)
            {
                // plugins not initialised so no need to teardown
                return 1;
            }

            // Reset fields in the bot that should not survive a reconnect
            import kameloso.ircdefs : IRCBot;  // fix visibility warning
            import kameloso.irc : IRCParser;

            bot.registerStatus = IRCBot.Status.notStarted;
            bot.authStatus = IRCBot.Status.notStarted;

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

            initPlugins();
            conn.connect(abort);

            if (!conn.connected)
            {
                teardownPlugins();
                logger.error("Exiting...");
                return 1;
            }

            startPlugins();

            // Initialise the Generator and start the main loop
            auto generator = new Generator!string(() => listenFiber(conn, abort));
            quit = client.mainLoop(generator);
            firstConnect = false;

            // Always teardown after connection ends
            teardownPlugins();
        }
        while (!quit && !abort && settings.reconnectOnFailure);

        if (abort)
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

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

Kameloso botState;


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
    abort = true;
    botState.abort = true;

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
Flag!"quit" checkMessages(ref Kameloso state)
{
    import core.time : seconds;
    import std.concurrency : receiveTimeout, Variant;

    scope (failure) state.teardownPlugins();

    Flag!"quit" quit;

    /// Echo a line to the terminal and send it to the server.
    void throttleline(ThreadMessage.Throttleline, string line)
    {
        import core.thread : Thread;
        import core.time : seconds, msecs;
        import std.datetime.systime : Clock, SysTime;

        if (abort) return;

        with (botState.throttling)
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
                interruptibleSleep(100.msecs, abort);
                if (abort) return;
            }

            logger.trace("--> ", line);
            state.conn.sendline(line);

            m = y + increment;
            t0 = Clock.currTime;
        }
    }

    /// Echo a line to the terminal and send it to the server.
    void sendline(ThreadMessage.Sendline, string line)
    {
        logger.trace("--> ", line);
        state.conn.sendline(line);
    }

    /// Send a line to the server without echoing it.
    void quietline(ThreadMessage.Quietline, string line)
    {
        state.conn.sendline(line);
    }

    /// Respond to `PING` with `PONG` to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        state.conn.sendline("PONG :", target);
    }

    /// Quit the server with the supplied reason.
    void quitServer(ThreadMessage.Quit, string reason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision up the stack.
        logger.trace("--> QUIT :", reason);
        state.conn.sendline("QUIT :", reason);

        quit = Yes.quit;
    }

    /// Quit the server with the default reason
    void quitEmpty(ThreadMessage.Quit)
    {
        return quitServer(ThreadMessage.Quit(), state.bot.quitReason);
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


// generateAsserts
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
Flag!"quit" mainLoop(ref Kameloso state, Generator!string generator)
{
    import core.thread : Fiber;
    import std.datetime.systime : Clock;

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

        // See if day broke
        const now = Clock.currTime;

        if (now.day != state.today)
        {
            logger.infof("[%d-%02d-%02d]", now.year, cast(int)now.month, now.day);
            state.today = now.day;
        }

        // Call the generator, query it for event lines
        generator.call();

        with (state)
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
                    plugin.onEvent(event);

                    // Fetch any queued WHOIS requests and handle
                    auto reqs = plugin.yieldWHOISRequests();
                    state.handleWHOISQueue(reqs, event, event.target.nickname);

                    auto yieldedBot = plugin.yieldBot();
                    if (yieldedBot != bot)
                    {
                        /*  Plugin onEvent or WHOIS reaction updated the bot.
                            There's no need to check for both separately since
                            this is just a single plugin processing; it keeps
                            its update internally between both passes.
                        */
                        bot = yieldedBot;
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
        quit = checkMessages(state);
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
void handleWHOISQueue(W)(ref Kameloso state, ref W[string] reqs,
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

                const then = key in state.whoisCalls;
                const now = Clock.currTime;

                if (!then || ((now - *then) > Timeout.whois.seconds))
                {
                    logger.trace("--> WHOIS :", key);
                    state.conn.sendline("WHOIS :", key);
                    state.whoisCalls[key] = Clock.currTime;
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
    import kameloso.bash : BashForeground;
    import std.getopt : GetOptException;

    // Initialise the logger immediately so it's always available, reinit later
    // when we know the settings for monochrome
    initLogger(botState.settings.monochrome);

    scope(failure)
    {
        import core.stdc.signal : signal, SIGINT, SIG_DFL;

        logger.error("We just crashed!");
        botState.teardownPlugins();

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
        if (botState.handleGetopt(args) == Yes.quit) return 0;
    }
    catch (const GetOptException e)
    {
        logger.error(e.msg);
        return 1;
    }

    immutable tint = botState.settings.monochrome ?
        BashForeground.default_ : BashForeground.white;

    printVersionInfo(tint);
    writeln();

    with (botState)
    {
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
            bot.registerStatus = IRCBot.Status.notStarted;
            bot.authStatus = IRCBot.Status.notStarted;
            bot.server.resolvedAddress = string.init;
            parser = IRCParser(bot);

            botState.initPlugins();
            conn.connect(abort);

            if (!conn.connected)
            {
                teardownPlugins();
                logger.warning("Exiting...");
                return 1;
            }

            botState.startPlugins();

            // Initialise the Generator and start the main loop
            auto generator = new Generator!string(() => listenFiber(conn, abort));
            quit = botState.mainLoop(generator);
            firstConnect = false;

            // Always teardown after connection ends
            teardownPlugins();
        }
        while (!quit && !abort && settings.reconnectOnFailure);

        if (abort)
        {
            // Ctrl+C
            logger.warning("Aborting...");
            return 1;
        }
        else
        {
            logger.info("Exiting...");
            return 0;
        }
    }
}

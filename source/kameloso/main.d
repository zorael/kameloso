/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.main;

import kameloso.common;
import kameloso.irc;
import kameloso.ircdefs;

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


/+
 +  Warn about bug #18026; Stack overflow in ddmd/dtemplate.d:6241, TemplateInstance::needsCodegen()
 +
 +  It may have been fixed in versions in the future at time of writing, so
 +  limit it to 2.082 and earlier. Update this condition as compilers are
 +  released.
 +
 +  Exempt DDoc generation, as it doesn't seem to trigger the segfaults.
 +/
static if (__VERSION__ <= 2082L)
{
    debug
    {
        // Everything is fine in debug mode
    }
    else version(D_Ddoc)
    {
        // Also fine
    }
    else
    {
        pragma(msg, "NOTE: Compilation may not succeed outside of debug mode.");
        pragma(msg, "See bug #18026 at https://issues.dlang.org/show_bug.cgi?id=18026");
    }
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


// throttleline
/++
 +  Send a string to the server in a throttled fashion, based on a simple
 +  `y = k*x + m` line.
 +
 +  This is so we don't get kicked by the server for spamming, if a lot of lines
 +  are to be sent at once.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      strings = Variadic list of strings to send.
 +/
void throttleline(Strings...)(ref Client client, const Strings strings)
{
    import core.thread : Thread;
    import core.time : seconds, msecs;
    import std.datetime.systime : Clock, SysTime;

    if (*(client.abort)) return;

    with (client.throttling)
    {
        immutable now = Clock.currTime;
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

        client.conn.sendline(strings);

        m = y + increment;
        t0 = Clock.currTime;
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
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +
 +  Returns:
 +      `Next.*` depending on what course of action to take next.
 +/
Next checkMessages(ref Client client)
{
    import kameloso.plugins.common : IRCPlugin;
    import core.time : seconds;
    import std.concurrency : receiveTimeout;
    import std.variant : Variant;

    scope (failure) client.teardownPlugins();

    Next next;

    /// Send a message to the server bypassing throttling.
    void immediateline(ThreadMessage.Immediateline, string line)
    {
        // FIXME: quiet?
        if (!settings.hideOutgoing) logger.trace("--> ", line);
        client.conn.sendline(line);
    }

    /// Echo a line to the terminal and send it to the server.
    void sendline(ThreadMessage.Sendline, string line)
    {
        if (!settings.hideOutgoing) logger.trace("--> ", line);
        client.throttleline(line);
    }

    /// Send a line to the server without echoing it.
    void quietline(ThreadMessage.Quietline, string line)
    {
        client.throttleline(line);
    }

    /// Respond to `PING` with `PONG` to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        client.throttleline("PONG :", target);
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
        immutable reason = givenReason.length ? givenReason : client.parser.bot.quitReason;
        if (!settings.hideOutgoing) logger.tracef(`--> QUIT :"%s"`, reason);
        client.conn.sendline("QUIT :\"", reason, "\"");
        next = Next.returnSuccess;
    }

    /// Disconnects from and reconnects to the server.
    void reconnect(ThreadMessage.Reconnect)
    {
        client.conn.sendline("QUIT :Reconnecting.");
        next = Next.retry;
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
    void peekPlugins(ThreadMessage.PeekPlugins, shared IRCPlugin sPlugin, IRCEvent event)
    {
        auto plugin = cast(IRCPlugin)sPlugin;
        plugin.peekPlugins(client.plugins, event);
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
            immutable emoteTarget = target.nickname.length ? target.nickname : channel;
            line = "PRIVMSG %s :%s%s%s".format(emoteTarget, cast(int)I.ctcp, content, cast(int)I.ctcp);
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

        if (event.target.class_ == IRCUser.Class.special)
        {
            quietline(ThreadMessage.Quietline(), line);
        }
        else
        {
            sendline(ThreadMessage.Sendline(), line);
        }
    }

    /// Proxies the passed message to the `logger`.
    void proxyLoggerMessages(ThreadMessage.TerminalOutput logLevel, string message)
    {
        with (ThreadMessage.TerminalOutput)
        final switch (logLevel)
        {
        case writeln:
            import std.stdio : writeln;
            writeln(message);
            break;

        case trace:
            logger.trace(message);
            break;

        case log:
            logger.log(message);
            break;

        case info:
            logger.info(message);
            break;

        case warning:
            logger.warning(message);
            break;

        case error:
            logger.error(message);
            break;
        }
    }

    /// Did the concurrency receive catch something?
    bool receivedSomething;

    /// Number of received concurrency messages this run.
    uint receivedInARow;

    /// After how many consecutive concurrency messages we should break.
    enum maxReceiveBeforeBreak = 5;

    do
    {
        static immutable instant = 0.seconds;

        receivedSomething = receiveTimeout(instant,
            &sendline,
            &quietline,
            &immediateline,
            &pong,
            &eventToServer,
            &proxyLoggerMessages,
            &quitServer,
            &save,
            &reloadPlugins,
            &peekPlugins,
            &reconnect,
            (Variant v)
            {
                // Caught an unhandled message
                logger.warning("Main thread received unknown Variant: ", v);
            }
        );

        if (receivedSomething) ++receivedInARow;
    }
    while (receivedSomething && (next == Next.continue_) &&
        (receivedInARow < maxReceiveBeforeBreak));

    return next;
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
Next mainLoop(ref Client client)
{
    import kameloso.common : printObjects;
    import kameloso.connection : listenFiber;
    import core.exception : UnicodeException;
    import core.thread : Fiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock;
    import std.utf : UTFException;

    /// Enum denoting what we should do next loop.
    Next next;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!string(() => listenFiber(client.conn, *(client.abort)));

    /// How often to check for timed `Fiber`s, multiples of `Timeout.receive`.
    enum checkTimedFibersEveryN = 3;

    /++
     +  How many more receive passes until it should next check for timed
     +  `Fiber`s.
     +/
    int timedFiberCheckCounter = checkTimedFibersEveryN;

    while (next == Next.continue_)
    {
        if (listener.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            listener.reset();
            return Next.continue_;
        }

        immutable nowInUnix = Clock.currTime.toUnixTime;

        foreach (ref plugin; client.plugins)
        {
            plugin.periodically(nowInUnix);
        }

        // Call the generator, query it for event lines
        listener.call();

        with (client)
        with (client.parser)
        foreach (immutable line; listener)
        {
            // Go through Fibers awaiting a point in time, regardless of whether
            // something was read or not.

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
                    if (!plugin.state.timedFibers.length) continue;

                    size_t[] toRemove;

                    foreach (immutable i, ref fiber; plugin.state.timedFibers)
                    {
                        if (fiber.id > nowInUnix)
                        {
                            import kameloso.constants : Timeout;
                            import std.algorithm.comparison : min;

                            // This Fiber shouldn't yet be triggered.
                            // Lower timedFiberCheckCounter to fire earlier, in
                            // case the time-to-fire is lower than the current
                            // counter value. This gives it more precision.

                            immutable nextTime = cast(int)(fiber.id - nowInUnix) / Timeout.receive;
                            timedFiberCheckCounter = min(timedFiberCheckCounter, nextTime);
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
                            logger.warningf("IRC Parse Exception %s.timedFibers[%d]: %s", plugin.name, i, e.msg);
                            printObject(e.event);
                            toRemove ~= i;
                        }
                        catch (const Exception e)
                        {
                            logger.warningf("Exception %s.timedFibers[%d]: %s", plugin.name, i, e.msg);
                            toRemove ~= i;
                        }
                    }

                    // Clean up processed Fibers
                    foreach_reverse (immutable i; toRemove)
                    {
                        import std.algorithm.mutation : remove;
                        plugin.state.timedFibers = plugin.state.timedFibers.remove(i);
                    }
                }
            }

            // Empty line yielded means nothing received; break and try again
            if (!line.length) break;

            IRCEvent mutEvent;

            scope(failure)
            {
                logger.error("scopeguard tripped.");
                printObject(mutEvent);
            }

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

                if (bot.updated)
                {
                    // Parsing changed the bot; propagate
                    bot.updated = false;
                    propagateBot(bot);
                }

                foreach (plugin; plugins)
                {
                    plugin.postprocess(mutEvent);

                    if (plugin.state.bot.updated)
                    {
                        // Postprocessing changed the bot; propagate
                        bot = plugin.state.bot;
                        bot.updated = false;
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
                        if (auto fibers = event.type in plugin.state.awaitingFibers)
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
                                    logger.warningf("IRC Parse Exception %s.awaitingFibers[%d]: %s",
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
                            foreach_reverse (immutable i; toRemove)
                            {
                                import std.algorithm.mutation : remove;
                                *fibers = (*fibers).remove(i);
                            }

                            // If no more Fibers left, remove the Type entry in the AA
                            if (!(*fibers).length)
                            {
                                plugin.state.awaitingFibers.remove(event.type);
                            }
                        }

                        // Fetch any queued `WHOIS` requests and handle
                        client.handleWHOISQueue(plugin.state.whoisQueue);

                        if (plugin.state.bot.updated)
                        {
                            /*  Plugin `onEvent` or `WHOIS` reaction updated the
                                bot. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps its update internally
                                between both passes.
                            */
                            bot = plugin.state.bot;
                            bot.updated = false;
                            parser.bot = bot;
                            propagateBot(bot);
                        }
                    }
                    catch (const UTFException e)
                    {
                        logger.warningf("UTFException %s.onEvent: %s", plugin.name, e.msg);
                    }
                    catch (const Exception e)
                    {
                        logger.warningf("Exception %s.onEvent: %s", plugin.name, e.msg);
                        printObject(event);
                    }
                }
            }
            catch (const IRCParseException e)
            {
                logger.warningf("IRC Parse Exception at %s:%d: %s", e.file, e.line, e.msg);
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
                logger.warningf("Unhandled exception at %s:%d: %s", e.file, e.line, e.msg);

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
        next = checkMessages(client);
    }

    return next;
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
 +      reqs = Reference to an associative array of `WHOISRequest`s.
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

        const then = key in client.whoisCalls;
        immutable now = Clock.currTime.toUnixTime;

        if (!then || ((now - *then) > Timeout.whois))
        {
            if (!settings.hideOutgoing) logger.trace("--> WHOIS ", key);
            client.throttleline("WHOIS ", key);
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
 +  our own `signalHandler`, so we can catch Ctrl+C and gracefully shut down.
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


// tryGetopt
/++
 +  Attempt handling `getopt`, wrapped in try-catch blocks.
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      args = The arguments passed to the program.
 +      customSettings = Reference to the dynamic array of custom settings as
 +          defined with `--set plugin.setting=value` on the command lnie.
 +
 +  Returns:
 +      `Next.*` depending on what action the calling site should take.
 +/
Next tryGetopt(ref Client client, string[] args, ref string[] customSettings)
{
    import kameloso.config : FileIsNotAFileException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;

    try
    {
        import kameloso.getopt : handleGetopt;
        // Act on arguments getopt, pass return value to main
        return client.handleGetopt(args, customSettings);
    }
    catch (const GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", e.msg);
    }
    catch (const ConvException e)
    {
        logger.error("Error converting command-line arguments: ", e.msg);
    }
    catch (const FileIsNotAFileException e)
    {
        string infotint, errortint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.bash : colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                errortint = KamelosoLogger.tint(LogLevel.error, settings.brightTerminal).colour;
            }
        }

        logger.errorf("Specified configuration file %s%s%s is not a file!",
            infotint, e.filename, errortint);
    }
    catch (const Exception e)
    {
        logger.error("Unhandled exception handling command-line arguments: ", e.msg);
    }

    return Next.returnFailure;
}


// tryConnect
/++
 +  Tries to connect to the IPs in `Client.conn.ips` by leveraging
 +  `kameloso.connection.connectFiber`, reacting on the
 +  `kameloso.connection.ConnectAttempt`s it yields to provide feedback to the
 +  user.
 +
 +  Params:
 +      client = Reference to the current `Client`.
 +
 +  Returns:
 +      `Next.continue_` if connection succeeded, `Next.returnFaillure` if
 +      connection failed and the program should exit.
 +/
Next tryConnect(ref Client client)
{
    import kameloso.connection : ConnectionAttempt, connectFiber;
    import kameloso.constants : Timeout;
    import std.concurrency : Generator;

    alias State = ConnectionAttempt.State;
    auto connector = new Generator!ConnectionAttempt(() => connectFiber(client.conn, *(client.abort)));
    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.5;

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    connector.call();

    with (client)
    foreach (attempt; connector)
    {
        import core.time : seconds;

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case preconnect:
            // Alternative: attempt.ip.toHostNameString
            logger.logf("Connecting to %s%s%s:%1$s%4$s%3$s ...",
                infotint, attempt.ip.toAddrString, logtint, attempt.ip.toPortString);
            continue;

        case connected:
            logger.log("Connected!");
            conn.connected = true;
            connector.reset();
            return Next.continue_;

        case delayThenReconnect:
            import core.time : seconds;

            if (attempt.numRetry == 0)
            {
                //logger.logf("Retrying in %d seconds...", incrementedRetryDelay);
                logger.logf("Retrying in %s%d%s seconds...",
                    infotint, incrementedRetryDelay, logtint);
            }
            else
            {
                /*logger.logf("Retrying in %d seconds (attempt %d)...",
                    incrementedRetryDelay, attempt.numRetry+1);*/
                logger.logf("Retrying in %s%d%s seconds (attempt %1$s%4$d%3$s)...",
                    infotint, incrementedRetryDelay, logtint, attempt.numRetry+1);
            }

            interruptibleSleep(incrementedRetryDelay.seconds, *abort);
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
            continue;

        case delayThenNextIP:
            //logger.logf("Trying next IP in %d seconds.", Timeout.retry);
            logger.logf("Trying next IP in %s%d%s seconds.",
                infotint, Timeout.retry, logtint);
            interruptibleSleep(Timeout.retry.seconds, *abort);
            continue;

        case noMoreIPs:
            logger.warning("Could not connect to server!");
            // Drop down to if (!conn.connected) below.
            return Next.returnFailure;

        case error:
            logger.error("Failed to connect: ", attempt.error);
            // Drop down to if (!conn.connected) below.
            return Next.returnFailure;
        }
    }

    return Next.returnFailure;
}


// tryResolve
/++
 +  Tries to resolve the address in `client.parser.bot.server` to IPs, by
 +  leveraging `kameloso.connection.resolveFiber`, reacting on the
 +  `kameloso.connection.ResolveAttempt`s it yields to provide feedback to the
 +  user.
 +
 +  Params:
 +      client = Reference to the current `Client`.
 +
 +  Returns:
 +      `Next.continue_` if resolution succeeded, `Next.returnFaillure` if
 +      it failed and the program should exit.
 +/
Next tryResolve(ref Client client)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import kameloso.constants : Timeout;
    import std.concurrency : Generator;

    alias State = ResolveAttempt.State;
    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(client.conn, client.parser.bot.server.address,
        client.parser.bot.server.port, settings.ipv6, *(client.abort)));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.5;

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    resolver.call();

    with (client)
    foreach (attempt; resolver)
    {
        with (State)
        final switch (attempt.state)
        {
            case preresolve:
                // No message for this
                continue;

            case success:
                logger.infof("%s%s resolved into %s%s%2$s IPs.",
                    parser.bot.server.address, logtint, infotint, conn.ips.length);
                return Next.continue_;

            case exception:
                logger.warning("Socket exception caught when resolving server adddress: ", attempt.error);

                enum resolveAttempts = 15;  // FIXME
                if (attempt.numRetry+1 < resolveAttempts)
                {
                    import core.time : seconds;

                    logger.logf("Network down? Retrying in %s%d%s seconds.",
                        infotint, incrementedRetryDelay, logtint);
                    interruptibleSleep(incrementedRetryDelay.seconds, *abort);
                    incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
                }
                continue;

            case error:
                logger.error("Socket exception caught when resolving server adddress: ", attempt.error);
                logger.log("Could not resolve address to IPs. Verify your server address.");
                return Next.returnFailure;

            case failure:
                logger.error("Failed to resolve host.");
                return Next.returnFailure;
        }
    }

    return Next.returnFailure;
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
    import std.stdio : writeln;

    // Initialise the main Client. Set its abort pointer to the global abort.
    Client client;
    client.abort = &abort;

    import std.path : buildNormalizedPath;
    settings.configFile = buildNormalizedPath(defaultConfigurationPrefix, "kameloso.conf");
    settings.resourceDirectory = defaultResourcePrefix;

    // Prepare an array for `handleGetopt` to fill by ref with custom settings
    // set on the command-line using `--set plugin.setting=value`
    string[] customSettings;

    // Initialise the logger immediately so it's always available.
    // handleGetopt reinits later when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal);

    scope(failure)
    {
        import kameloso.bash : TerminalToken;
        logger.error("We just crashed!", cast(char)TerminalToken.bell);
        client.teardownPlugins();
        resetSignals();
    }

    setupSignals();

    immutable actionAfterGetopt = client.tryGetopt(args, customSettings);

    with (Next)
    final switch (actionAfterGetopt)
    {
        case continue_:
        case retry:  // should never happen
            break;

        case returnSuccess:
            return 0;

        case returnFailure:
            return 1;
    }

    with (client)
    with (client.parser)
    {
        import kameloso.bash : BashForeground;

        BashForeground tint = BashForeground.default_;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                tint = settings.brightTerminal ? BashForeground.black : BashForeground.white;
            }
        }

        printVersionInfo(tint);
        writeln();

        // Print the current settings to show what's going on.
        printObjects(bot, bot.server);

        if (!bot.homes.length && !bot.admins.length)
        {
            complainAboutMissingConfiguration(bot, args);
            return 1;
        }

        // Resolve the resource directory
        import std.path : dirName;
        settings.resourceDirectory = buildNormalizedPath(settings.resourceDirectory,
            "server", bot.server.address);
        settings.configDirectory = settings.configFile.dirName;

        // Initialise plugins outside the loop once, for the error messages
        const invalidEntries = initPlugins(customSettings);
        complainAboutInvalidConfigurationEntries(invalidEntries);

        // Save the original nickname *once*, outside the connection loop.
        // It will change later and knowing this is useful when authenticating
        bot.origNickname = bot.nickname;

        // Save a backup snapshot of the bot, for restoring upon reconnections
        IRCBot backupBot = bot;

        /// Enum denoting what we should do next loop.
        Next next;

        /++
         +  Bool whether this is the first connection attempt or if we have
         +  connected at least once already.
         +/
        bool firstConnect = true;

        do
        {
            import kameloso.ircdefs : IRCBot;  // fix visibility warning
            import kameloso.irc : IRCParser;

            if (!firstConnect)
            {
                import kameloso.constants : Timeout;
                import core.time : seconds;

                // Carry some values but otherwise restore the pristine bot backup
                backupBot.nickname = bot.nickname;
                backupBot.homes = bot.homes;
                backupBot.channels = bot.channels;
                bot = backupBot;

                logger.log("Please wait a few seconds...");
                interruptibleSleep(Timeout.retry.seconds, *abort);

                // Reinit plugins here so it isn't done on the first connect attempt
                initPlugins(customSettings);
            }

            conn.reset();

            immutable actionAfterResolve = tryResolve(client);

            with (Next)
            final switch (actionAfterResolve)
            {
            case continue_:
                break;

            case returnSuccess:  // should never happen
            case retry:  // should never happen
                assert(0);

            case returnFailure:
                // No need to teardown; if it's the first connect there's
                // nothing to tear down, and if it's after the first, later code
                // will have already torn it down.
                logger.info("Exiting...");
                return 1;
            }

            string infotint; //, logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.bash : colour;
                    import kameloso.logger : KamelosoLogger;
                    import std.experimental.logger : LogLevel;

                    infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                    //logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
                }
            }

            import std.file : exists;

            if (!settings.resourceDirectory.exists)
            {
                import std.file : mkdirRecurse;
                mkdirRecurse(settings.resourceDirectory);
                logger.logf("Created resource directory %s%s", infotint, settings.resourceDirectory);
            }

            // Ensure initialised resources after resolve so we know we have a
            // valid server to create a directory for.
            initPluginResources();

            immutable actionAfterConnect = tryConnect(client);

            with (Next)
            final switch (actionAfterConnect)
            {
                case continue_:
                    break;

                case returnSuccess:
                case retry:     // should never happen
                    assert(0);  // should never happen

                case returnFailure:
                    // Save if it's not the first connection andconfiguration says we should
                    if (!firstConnect && settings.saveOnExit)
                    {
                        client.writeConfigurationFile(settings.configFile);
                    }

                    teardownPlugins();
                    logger.info("Exiting...");
                    return 1;
            }

            parser = IRCParser(bot);
            startPlugins();

            // Start the main loop
            next = client.mainLoop();
            firstConnect = false;

            // Save if we're exiting and configuration says we should.
            if (((next == Next.returnSuccess) || *abort) && settings.saveOnExit)
            {
                client.writeConfigurationFile(settings.configFile);
            }

            // Always teardown after connection ends
            teardownPlugins();
        }
        while (!(*abort) && ((next == Next.retry) ||
            ((next == Next.continue_) && settings.reconnectOnFailure)));

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

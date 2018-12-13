/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.main;

import kameloso.common;
import kameloso.irc;
import kameloso.irc.defs;
import kameloso.printing;
import kameloso.thread : ThreadMessage;

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
 +  limit it to 2.083 and earlier. Update this condition as compilers are released.
 +
 +  Exempt DDoc generation, as it doesn't seem to trigger the segfaults.
 +/
static if (__VERSION__ <= 2083L)
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
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      strings = Variadic list of strings to send.
 +/
void throttleline(Strings...)(ref IRCBot bot, const Strings strings)
{
    import kameloso.thread : interruptibleSleep;
    import core.thread : Thread;
    import core.time : seconds, msecs;
    import std.datetime.systime : Clock, SysTime;

    if (*bot.abort) return;

    with (bot.throttling)
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
            interruptibleSleep(100.msecs, *bot.abort);
            if (*bot.abort) return;
        }

        bot.conn.sendline(strings);

        m = y + increment;
        t0 = Clock.currTime;
    }
}


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was received.
 +
 +  The return value tells the caller whether the received action means the bot
 +  should exit or not.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +
 +  Returns:
 +      `kameloso.common.Next`.* depending on what course of action to take next.
 +/
Next checkMessages(ref IRCBot bot)
{
    Next next;

    /// Send a message to the server bypassing throttling.
    void immediateline(ThreadMessage.Immediateline, string line)
    {
        if (!settings.hideOutgoing)
        {
            version(Colours)
            {
                import kameloso.irc.colours : mapEffects;
                import kameloso.terminal : TerminalForeground, TerminalBackground;

                logger.trace("--> ", line.mapEffects);
                bot.conn.sendline(line);
            }
            else
            {
                import kameloso.irc.colours : stripEffects;

                immutable noEffects = line.stripEffects;
                logger.trace("--> ", noEffects);
                bot.conn.sendline(noEffects);
            }
        }
        else
        {
            bot.conn.sendline(line);
        }
    }

    /// Echo a line to the terminal and send it to the server.
    void sendline(ThreadMessage.Sendline, string line)
    {
        if (!settings.hideOutgoing)
        {
            version(Colours)
            {
                import kameloso.irc.colours : mapEffects;
                import kameloso.terminal : TerminalForeground, TerminalBackground;

                logger.trace("--> ", line.mapEffects);
                bot.throttleline(line);
            }
            else
            {
                import kameloso.irc.colours : stripEffects;

                immutable noEffects = line.stripEffects;
                logger.trace("--> ", noEffects);
                bot.throttleline(noEffects);
            }
        }
        else
        {
            bot.throttleline(line);
        }
    }

    /// Send a line to the server without echoing it.
    void quietline(ThreadMessage.Quietline, string line)
    {
        bot.throttleline(line);
    }

    /// Respond to `PING` with `PONG` to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        bot.throttleline("PONG :", target);
    }

    /// Ask plugins to reload.
    void reload(ThreadMessage.Reload)
    {
        foreach (plugin; bot.plugins)
        {
            plugin.reload();
        }
    }

    /// Quit the server with the supplied reason, or the default.
    void quitServer(ThreadMessage.Quit, string givenReason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision up the stack.
        immutable reason = givenReason.length ? givenReason : bot.parser.client.quitReason;
        if (!settings.hideOutgoing) logger.tracef(`--> QUIT :%s`, reason);
        bot.conn.sendline("QUIT :", reason);
        next = Next.returnSuccess;
    }

    /// Disconnects from and reconnects to the server.
    void reconnect(ThreadMessage.Reconnect)
    {
        bot.conn.sendline("QUIT :Reconnecting.");
        next = Next.retry;
    }

    /// Saves current configuration to disk.
    void save(ThreadMessage.Save)
    {
        bot.writeConfigurationFile(settings.configFile);
    }

    /++
     +  Attaches a reference to the main array of
     +  `kameloso.plugins.common.IRCPlugin`s (housing all plugins) to the
     +  payload member of the supplied `kameloso.common.CarryingFiber`, then
     +  invokes it.
     +/
    import kameloso.thread : CarryingFiber;
    import kameloso.plugins.common : IRCPlugin;
    void peekPlugins(ThreadMessage.PeekPlugins, shared CarryingFiber!(IRCPlugin[]) sFiber)
    {
        auto fiber = cast(CarryingFiber!(IRCPlugin[]))sFiber;
        assert(fiber, "Peeking Fiber was null!");
        fiber.payload = bot.plugins;  // Make it visible from within the Fiber
        fiber.call();
    }

    /// Reloads all plugins.
    void reloadPlugins(ThreadMessage.Reload)
    {
        foreach (plugin; bot.plugins)
        {
            plugin.reload();
        }
    }

    /// Passes a bus message to each plugin.
    import kameloso.thread : Sendable;
    void dispatchBusMessage(ThreadMessage.BusMessage, string header, shared Sendable content)
    {
        foreach (plugin; bot.plugins)
        {
            plugin.onBusMessage(header, content);
        }
    }

    /// Passes an empty header-only bus message to each plugin.
    void dispatchEmptyBusMessage(ThreadMessage.BusMessage, string header)
    {
        foreach (plugin; bot.plugins)
        {
            shared Sendable content;
            plugin.onBusMessage(header, content);
        }
    }

    /// Reverse-formats an event and sends it to the server.
    void eventToServer(IRCEvent event)
    {
        import kameloso.string : splitWords;
        import std.format : format;

        enum maxIRCLineLength = 512;

        string line;
        string prelude;
        string[] lines;

        with (IRCEvent.Type)
        with (event)
        with (bot)
        switch (event.type)
        {
        case CHAN:
            prelude = "PRIVMSG %s :".format(channel);
            lines = content.splitWords(' ', maxIRCLineLength-prelude.length);
            break;

        case QUERY:
            prelude = "PRIVMSG %s :".format(target.nickname);
            lines = content.splitWords(' ', maxIRCLineLength-prelude.length);
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
            prelude = "JOIN ";
            lines = channel.splitWords(',', maxIRCLineLength-prelude.length);
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
            import kameloso.conv : Enum;

            // Changing this to use Enum lowered compilation memory use from 4168 to 3775...
            logger.warning("No outgoing event case for type ",
                Enum!(IRCEvent.Type).toString(type));
            line = content;
            break;
        }

        void appropriateline(const string finalLine)
        {
            if (event.target.class_ == IRCUser.Class.special)
            {
                quietline(ThreadMessage.Quietline(), finalLine);
            }
            else
            {
                sendline(ThreadMessage.Sendline(), finalLine);
            }
        }

        if (lines.length)
        {
            foreach (immutable i, immutable splitLine; lines)
            {
                appropriateline(prelude ~ splitLine);
            }
        }
        else
        {
            appropriateline(line);
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
        import core.time : seconds;
        import std.concurrency : receiveTimeout;
        import std.variant : Variant;

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
            &dispatchBusMessage,
            &dispatchEmptyBusMessage,
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


// exhaustMessages
/++
 +  Exhausts the concurrency message mailbox.
 +/
void exhaustMessages()
{
    import core.time : msecs;
    import std.concurrency : receiveTimeout;
    import std.variant : Variant;

    bool notEmpty;
    static immutable instant = 10.msecs;

    do
    {
        notEmpty = receiveTimeout(instant,
            (Variant v) {}
        );
    }
    while (notEmpty);
}


// mainLoop
/++
 +  This loops creates a `std.concurrency.Generator` `core.thread.Fiber` to loop
 +  over the over `std.socket.Socket`, reading lines and yielding
 +  `kameloso.connection.ListenAttempt`s as it goes.
 +
 +  Full lines are stored in `kameloso.connection.ListenAttempt`s which are
 +  yielded in the `std.concurrency.Generator` to be caught here, consequently
 +  parsed into `kameloso.irc.defs.IRCEvent`s, and then dispatched to all plugins.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +
 +  Returns:
 +      `kameloso.common.Next.returnFailure` if circumstances mean the bot
 +      should exit with a non-zero exit code,
 +      `kameloso.common.Next.returnSuccess` if it should exit by returning `0`,
 +      `kameloso.common.Next.retry` if the bot should reconnect to the server.
 +      `kameloso.common.Next.continue_` is never returned.
 +/
Next mainLoop(ref IRCBot bot)
{
    import kameloso.connection : ListenAttempt, listenFiber;
    import std.concurrency : Generator;

    /// Enum denoting what we should do next loop.
    Next next;

    alias State = ListenAttempt.State;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(bot.conn, *bot.abort));

    /// How often to check for timed `core.thread.Fiber`s, multiples of `Timeout.receive`.
    enum checkTimedFibersEveryN = 3;

    /++
     +  How many more receive passes until it should next check for timed
     +  `core.thread.Fiber`s.
     +/
    int timedFiberCheckCounter = checkTimedFibersEveryN;

    string logtint, errortint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    while (next == Next.continue_)
    {
        import core.thread : Fiber;

        if (*bot.abort) return Next.returnFailure;

        if (listener.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected by itself; reconnect
            listener.reset();
            return Next.retry;
        }

        import std.datetime.systime : Clock;
        immutable nowInUnix = Clock.currTime.toUnixTime;

        foreach (ref plugin; bot.plugins)
        {
            plugin.periodically(nowInUnix);
        }

        // Once every 24h (24*3600s), clear the `previousWhoisTimestamps` AA.
        // That should be enough to stop it from being a memory leak.
        if ((nowInUnix % 86_400) == 0)
        {
            bot.previousWhoisTimestamps = typeof(bot.previousWhoisTimestamps).init;
        }

        // Call the generator, query it for event lines
        listener.call();

        with (bot.parser)
        listenerloop:
        foreach (const attempt; listener)
        {
            if (*bot.abort) return Next.returnFailure;

            // Go through Fibers awaiting a point in time, regardless of whether
            // something was read or not.

            /++
             +  At a cadence of once every `checkTimedFibersEveryN`, walk the
             +  array of plugins and see if they have timed `core.thread.Fiber`s
             +  to call.
             +/
            if (--timedFiberCheckCounter <= 0)
            {
                // Reset counter
                timedFiberCheckCounter = checkTimedFibersEveryN;

                foreach (plugin; bot.plugins)
                {
                    if (!plugin.state.timedFibers.length) continue;
                    plugin.handleTimedFibers(timedFiberCheckCounter, nowInUnix);
                }
            }

            // Handle the attempt; switch on its state
            with (State)
            final switch (attempt.state)
            {
            case prelisten:  // Should never happen
                assert(0, "listener attempt yielded state prelisten");

            case isEmpty:
                // Empty line yielded means nothing received; break foreach and try again
                break listenerloop;

            case hasString:
                // hasString means we should drop down and continue processing
                break;

            case warning:
                // Benign socket error; break foreach and try again
                import core.thread : Thread;
                import core.time : seconds;

                logger.warningf("Connection error! (%s%s%s)", logtint,
                    attempt.lastSocketError_, warningtint);
                Thread.sleep(1.seconds);
                break listenerloop;

            case timeout:
                logger.error("Connection lost.");
                return Next.returnFailure;

            case error:
                import kameloso.constants : Timeout;

                if (attempt.bytesReceived == 0)
                {
                    logger.errorf("Connection error: empty server response! (%s%s%s)",
                        logtint, attempt.lastSocketError_, errortint);
                }
                else
                {
                    logger.errorf("Connection error: invalid server response! (%s%s%s)",
                        logtint, attempt.lastSocketError_, errortint);
                }

                return Next.returnFailure;
            }

            IRCEvent event;

            scope(failure)
            {
                logger.error("scopeguard tripped.");
                printObject(event);
            }

            import core.exception : UnicodeException;
            import std.utf : UTFException;

            try
            {
                // Sanitise and try again once on UTF/Unicode exceptions
                import std.encoding : sanitize;

                try
                {
                    event = bot.parser.toIRCEvent(attempt.line);
                }
                catch (const UTFException e)
                {
                    event = bot.parser.toIRCEvent(sanitize(attempt.line));
                }
                catch (const UnicodeException e)
                {
                    event = bot.parser.toIRCEvent(sanitize(attempt.line));
                }

                if (client.updated)
                {
                    // Parsing changed the client; propagate
                    client.updated = false;
                    bot.propagateClient(client);
                }

                foreach (plugin; bot.plugins)
                {
                    plugin.postprocess(event);

                    if (plugin.state.client.updated)
                    {
                        // Postprocessing changed the client; propagate
                        client = plugin.state.client;
                        client.updated = false;
                        bot.propagateClient(client);
                    }
                }

                // Let each plugin process the event
                foreach (plugin; bot.plugins)
                {
                    try
                    {
                        plugin.onEvent(event);

                        // Go through Fibers awaiting IRCEvent.Types
                        plugin.handleFibers(event);

                        // Fetch any queued `WHOIS` requests and handle
                        bot.handleWHOISQueue(plugin.state.whoisQueue);

                        if (plugin.state.client.updated)
                        {
                            /*  Plugin `onEvent` or `WHOIS` reaction updated the
                                client. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps its update internally
                                between both passes.
                            */
                            client = plugin.state.client;
                            client.updated = false;
                            bot.parser.client = client;
                            bot.propagateClient(client);
                        }
                    }
                    catch (const UTFException e)
                    {
                        logger.warningf("UTFException %s.onEvent: %s%s",
                            plugin.name, logtint, e.msg);
                    }
                    catch (const Exception e)
                    {
                        logger.warningf("Exception %s.onEvent: %s%s",
                            plugin.name, logtint, e.msg);
                        printObject(event);
                    }
                }
            }
            catch (const IRCParseException e)
            {
                logger.warningf("IRC Parse Exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)",
                    logtint, e.msg, warningtint, e.file, e.line);
                printObject(e.event);
            }
            catch (const UTFException e)
            {
                logger.warning("UTFException: ", logtint, e.msg);
            }
            catch (const UnicodeException e)
            {
                logger.warning("UnicodeException: ", logtint, e.msg);
            }
            catch (const Exception e)
            {
                logger.warningf("Unhandled exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)",
                    logtint, e.msg, warningtint, e.file, e.line);

                if (event != IRCEvent.init)
                {
                    printObject(event);
                }
                else
                {
                    logger.warningf(`Offending line: "%s%s%s"`, logtint, attempt.line, warningtint);
                }
            }
        }

        // Check concurrency messages to see if we should exit, else repeat
        next = checkMessages(bot);
    }

    return next;
}


// handleFibers
/++
 +  Processes the awaiting `core.thread.Fiber`s of an
 +  `kameloso.plugins.common.IRCPlugin`.
 +
 +  Params:
 +      plugin = The `kameloso.plugins.common.IRCPlugin` whose
 +          `kameloso.irc.defs.IRCEvent.Type`-awaiting `core.thread.Fiber`s to
 +          iterate and process.
 +      event = The triggering `kameloso.irc.defs.IRCEvent`.
 +/
import kameloso.plugins.common : IRCPlugin;
void handleFibers(IRCPlugin plugin, const IRCEvent event)
{
    import core.thread : Fiber;

    if (auto fibers = event.type in plugin.state.awaitingFibers)
    {
        size_t[] toRemove;

        foreach (immutable i, ref fiber; *fibers)
        {
            try
            {
                if (fiber.state == Fiber.State.HOLD)
                {
                    import kameloso.thread : CarryingFiber;

                    // Specialcase CarryingFiber!IRCEvent to update it to carry
                    // the current IRCEvent.

                    if (auto carryingFiber = cast(CarryingFiber!IRCEvent)fiber)
                    {
                        if (carryingFiber.payload == IRCEvent.init)
                        {
                            carryingFiber.payload = event;
                        }
                        carryingFiber.call();

                        // Reset the payload so a new one will be attached next trigger
                        carryingFiber.payload = IRCEvent.init;
                    }
                    else
                    {
                        fiber.call();
                    }
                }

                if (fiber.state == Fiber.State.TERM)
                {
                    toRemove ~= i;
                }
            }
            catch (const IRCParseException e)
            {
                string logtint;

                version(Colours)
                {
                    if (!settings.monochrome)
                    {
                        import kameloso.terminal : TerminalForeground, colour;
                        import kameloso.logger : KamelosoLogger;

                        logtint = (cast(KamelosoLogger)logger).logtint;
                    }
                }

                logger.warningf("IRC Parse Exception %s.awaitingFibers[%d]: %s%s",
                    plugin.name, i, logtint, e.msg);
                printObject(e.event);
                toRemove ~= i;
            }
            catch (const Exception e)
            {
                string logtint;

                version(Colours)
                {
                    if (!settings.monochrome)
                    {
                        import kameloso.terminal : TerminalForeground, colour;
                        import kameloso.logger : KamelosoLogger;

                        logtint = (cast(KamelosoLogger)logger).logtint;
                    }
                }

                logger.warningf("Exception %s.awaitingFibers[%d]: %s%s",
                    plugin.name, i, logtint, e.msg);
                printObject(event);
                toRemove ~= i;
            }
        }

        // Clean up processed Fibers
        foreach_reverse (immutable i; toRemove)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            *fibers = (*fibers).remove!(SwapStrategy.unstable)(i);
        }

        // If no more Fibers left, remove the Type entry in the AA
        if (!(*fibers).length)
        {
            plugin.state.awaitingFibers.remove(event.type);
        }
    }
}


// handleTimedFibers
/++
 +  Processes the timed `core.thread.Fiber`s of an
 +  `kameloso.plugins.common.IRCPlugin`.
 +
 +  Params:
 +      plugin = The `kameloso.plugins.common.IRCPlugin` whose timed
 +          `core.thread.Fiber`s to iterate and process.
 +      timedFiberCheckCounter = The ref timestamp at which to next check for
 +          timed fibers to process.
 +      nowInUnix = Current UNIX timestamp to compare the timed
 +          `core.thread.Fiber`'s timestamp with.
 +/
void handleTimedFibers(IRCPlugin plugin, ref int timedFiberCheckCounter, const long nowInUnix)
{
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
            import core.thread : Fiber;

            if (fiber.state == Fiber.State.HOLD)
            {
                fiber.call();
            }

            // Always removed a timed Fiber after processing
            toRemove ~= i;
        }
        catch (const IRCParseException e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.terminal : TerminalForeground, colour;
                    import kameloso.logger : KamelosoLogger;

                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("IRC Parse Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            printObject(e.event);
            toRemove ~= i;
        }
        catch (const Exception e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.terminal : TerminalForeground, colour;
                    import kameloso.logger : KamelosoLogger;

                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            toRemove ~= i;
        }
    }

    // Clean up processed Fibers
    foreach_reverse (immutable i; toRemove)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        plugin.state.timedFibers = plugin.state.timedFibers.remove!(SwapStrategy.unstable)(i);
    }
}


// handleWHOISQueue
/++
 +  Takes a queue of `WHOISRequest` objects and emits `WHOIS` requests for each one.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      reqs = Reference to an associative array of `WHOISRequest`s.
 +/
import kameloso.plugins.common : WHOISRequest;
void handleWHOISQueue(ref IRCBot bot, ref WHOISRequest[][string] reqs)
{
    // Walk through requests and call `WHOIS` on those that haven't been
    // `WHOIS`ed in the last `Timeout.whois` seconds

    foreach (immutable nickname, const requestsForNickname; reqs)
    {
        assert(nickname.length, "Empty nickname in WHOIS queue");

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;

        const then = nickname in bot.previousWhoisTimestamps;
        immutable now = Clock.currTime.toUnixTime;

        if (!then || ((now - *then) > Timeout.whoisRetry))
        {
            if (!settings.hideOutgoing) logger.trace("--> WHOIS ", nickname);
            bot.throttleline("WHOIS ", nickname);
            bot.previousWhoisTimestamps[nickname] = now;
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
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      args = The arguments passed to the program.
 +      customSettings = Reference to the dynamic array of custom settings as
 +          defined with `--set plugin.setting=value` on the command line.
 +
 +  Returns:
 +      `kameloso.common.Next`.* depending on what action the calling site should take.
 +/
Next tryGetopt(ref IRCBot bot, string[] args, ref string[] customSettings)
{
    import kameloso.config : ConfigurationFileReadFailureException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;

    string logtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
        }
    }

    try
    {
        import kameloso.getopt : handleGetopt;
        // Act on arguments getopt, pass return value to main
        return bot.handleGetopt(args, customSettings);
    }
    catch (const GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", logtint, e.msg);
    }
    catch (const ConvException e)
    {
        logger.error("Error converting command-line arguments: ", logtint, e.msg);
    }
    catch (const FileTypeMismatchException e)
    {
        logger.errorf("Specified configuration file %s%s%s is not a file!",
            logtint, e.filename, errortint);
    }
    catch (const ConfigurationFileReadFailureException e)
    {
        logger.errorf("Error reading and decoding configuration file [%s%s%s]: %1$s%4$s",
            logtint, e.filename, errortint, e.msg);
    }
    catch (const Exception e)
    {
        logger.error("Unhandled exception handling command-line arguments: ", logtint, e.msg);
    }

    return Next.returnFailure;
}


// tryConnect
/++
 +  Tries to connect to the IPs in `kameloso.common.IRCBot.conn.ips` by
 +  leveraging `kameloso.connection.connectFiber`, reacting on the
 +  `kameloso.connection.ConnectAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if connection succeeded,
 +      `kameloso.common.Next.returnFaillure` if connection failed and the
 +      program should exit.
 +/
Next tryConnect(ref IRCBot bot)
{
    import kameloso.connection : ConnectionAttempt, connectFiber;
    import kameloso.constants : Timeout;
    import kameloso.thread : interruptibleSleep;
    import std.concurrency : Generator;

    alias State = ConnectionAttempt.State;
    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(bot.conn,  settings.endlesslyConnect, *bot.abort));
    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.5;

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    connector.call();

    with (bot)
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

            if (attempt.retryNum == 0)
            {
                logger.logf("Retrying in %s%d%s seconds...",
                    infotint, incrementedRetryDelay, logtint);
            }
            else
            {
                logger.logf("Retrying in %s%d%s seconds (attempt %1$s%4$d%3$s)...",
                    infotint, incrementedRetryDelay, logtint, attempt.retryNum+1);
            }

            interruptibleSleep(incrementedRetryDelay.seconds, *abort);
            if (*abort) return Next.returnFailure;
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
            continue;

        case delayThenNextIP:
            logger.logf("Trying next IP in %s%d%s seconds.",
                infotint, Timeout.retry, logtint);
            interruptibleSleep(Timeout.retry.seconds, *abort);
            if (*abort) return Next.returnFailure;
            continue;

        case noMoreIPs:
            logger.warning("Could not connect to server!");
            return Next.returnFailure;

        case ipv6Failure:
            logger.warning("IPv6 connection failed. Disabling IPv6.");
            continue;

        case error:
            logger.error("Failed to connect: ", attempt.error);
            return Next.returnFailure;
        }
    }

    return Next.returnFailure;
}


// tryResolve
/++
 +  Tries to resolve the address in `bot.parser.client.server` to IPs, by
 +  leveraging `kameloso.connection.resolveFiber`, reacting on the
 +  `kameloso.connection.ResolveAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.bot`.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if resolution succeeded,
 +      `kameloso.common.Next.returnFailure` if it failed and the program should exit.
 +/
Next tryResolve(ref IRCBot bot)
{
    import kameloso.connection : ResolveAttempt, resolveFiber;
    import kameloso.constants : Timeout;
    import std.concurrency : Generator;

    string infotint, logtint, warningtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
        }
    }

    import kameloso.string : contains;
    if (!settings.force && !bot.parser.client.server.address.contains('.'))
    {
        // Workaround for Issue 19247:
        // Segmentation fault when resolving address with std.socket.getAddress inside a Fiber
        logger.errorf("Invalid address! [%s%s%s]", logtint,
            bot.parser.client.server.address, errortint);
        return Next.returnFailure;
    }

    enum defaultResolveAttempts = 15;
    immutable resolveAttempts = settings.endlesslyConnect ? int.max : defaultResolveAttempts;

    alias State = ResolveAttempt.State;
    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(bot.conn, bot.parser.client.server.address,
        bot.parser.client.server.port, settings.ipv6, resolveAttempts, *bot.abort));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.2;

    resolver.call();

    with (bot)
    foreach (attempt; resolver)
    {
        with (State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            import kameloso.string : plurality;
            logger.infof("%s%s resolved into %s%s%2$s %5$s.",
                parser.client.server.address, logtint, infotint, conn.ips.length,
                conn.ips.length.plurality("IP", "IPs"));
            return Next.continue_;

        case exception:
            logger.warningf("Could not resolve server address. (%s%s%s)",
                logtint, attempt.error, warningtint);

            if (attempt.retryNum+1 < resolveAttempts)
            {
                import kameloso.thread : interruptibleSleep;
                import core.time : seconds;

                logger.logf("Network down? Retrying in %s%d%s seconds.",
                    infotint, incrementedRetryDelay, logtint);
                interruptibleSleep(incrementedRetryDelay.seconds, *abort);
                if (*abort) return Next.returnFailure;
                incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
            }
            continue;

        case error:
            logger.errorf("Could not resolve server address. (%s%s%s)", logtint, attempt.error, errortint);
            logger.log("Failed to resolve address to IPs. Verify your server address.");
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
 +  Unit-testing main; does nothing.
 +/
void main()
{
    // Compiled with -b unittest, so run the tests and exit.
    // Logger is initialised in a module constructor, don't re-init here.
    logger.info("All tests passed successfully!");
    // No need to Cygwin-flush; the logger did that already
}
else
/++
 +  Entry point of the program.
 +
 +  Params:
 +      args = Command-line arguments passed to the program.
 +
 +  Returns:
 +      `0` on success, `1` on failure.
 +/
int main(string[] args)
{
    // Initialise the main IRCBot. Set its abort pointer to the global abort.
    IRCBot bot;
    bot.abort = &abort;

    import std.path : buildNormalizedPath;
    settings.configFile = buildNormalizedPath(defaultConfigurationPrefix, "kameloso.conf");
    settings.resourceDirectory = defaultResourcePrefix;

    // Prepare an array for `handleGetopt` to fill by ref with custom settings
    // set on the command-line using `--set plugin.setting=value`
    string[] customSettings;

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal);

    scope(failure)
    {
        import kameloso.terminal : TerminalToken;
        logger.error("We just crashed!", cast(char)TerminalToken.bell);
        resetSignals();
    }

    setupSignals();

    immutable actionAfterGetopt = bot.tryGetopt(args, customSettings);

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

    string pre, post, infotint, logtint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.terminal : TerminalForeground, colour;
            import kameloso.logger : KamelosoLogger;

            immutable headertint = settings.brightTerminal ? TerminalForeground.black : TerminalForeground.white;
            immutable defaulttint = TerminalForeground.default_;
            pre = headertint.colour;
            post = defaulttint.colour;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    import std.stdio : writeln;
    printVersionInfo(pre, post);
    writeln();

    // Print the current settings to show what's going on.
    import kameloso.printing : printObjects;
    printObjects(bot.parser.client, bot.parser.client.server);

    if (!bot.parser.client.homes.length && !bot.parser.client.admins.length)
    {
        complainAboutMissingConfiguration(args);
        if (!settings.force) return 1;
    }

    // Resolve and create the resource directory
    import std.file : exists;
    import std.path : dirName;

    settings.resourceDirectory = buildNormalizedPath(settings.resourceDirectory,
        "server", bot.parser.client.server.address);
    settings.configDirectory = settings.configFile.dirName;

    if (!settings.resourceDirectory.exists)
    {
        import std.file : mkdirRecurse;
        mkdirRecurse(settings.resourceDirectory);
        logger.logf("Created resource directory %s%s", infotint, settings.resourceDirectory);
    }

    // Initialise plugins outside the loop once, for the error messages
    import std.conv : ConvException;

    try
    {
        const invalidEntries = bot.initPlugins(customSettings);
        complainAboutInvalidConfigurationEntries(invalidEntries);
    }
    catch (const ConvException e)
    {
        // Configuration file/--set argument syntax error
        logger.error(e.msg);
        return 1;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    bot.parser.client.origNickname = bot.parser.client.nickname;

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = bot.parser.client;

    /// Enum denoting what we should do next loop.
    Next next;

    /++
     +  Bool whether this is the first connection attempt or if we have
     +  connected at least once already.
     +/
    bool firstConnect = true;

    scope(exit)
    {
        // Save if we're exiting and configuration says we should.
        if (settings.saveOnExit)
        {
            bot.writeConfigurationFile(settings.configFile);
        }
    }

    do
    {
        // *bot.abort is guaranteed to be false here.

        if (!firstConnect)
        {
            import kameloso.constants : Timeout;
            import kameloso.thread : interruptibleSleep;
            import core.time : seconds;

            // Carry some values but otherwise restore the pristine client backup
            backupClient.nickname = bot.parser.client.nickname;
            backupClient.homes = bot.parser.client.homes;
            backupClient.channels = bot.parser.client.channels;
            //bot.parser.client = backupClient;  // Initialised below

            // Exhaust leftover queued messages
            exhaustMessages();

            logger.log("Please wait a few seconds ...");
            interruptibleSleep(Timeout.retry.seconds, *bot.abort);
            if (*bot.abort) break;

            // Re-init plugins here so it isn't done on the first connect attempt
            bot.initPlugins(customSettings);

            // Reset throttling, in case there were queued messages.
            bot.throttling = typeof(bot.throttling).init;
        }

        scope(exit)
        {
            // Always teardown when exiting this loop (for whatever reason)
            bot.teardownPlugins();
        }

        // May as well check once here, in case something in initPlugins aborted or so.
        if (*bot.abort) break;

        bot.conn.reset();

        immutable actionAfterResolve = tryResolve(bot);
        if (*bot.abort) break;  // tryResolve interruptibleSleep can abort

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case returnSuccess:  // should never happen
        case retry:  // should never happen
            assert(0, "tryResolve returned Next returnSuccess or retry");

        case returnFailure:
            // No need to teardown; the scopeguard does it for us.
            logger.info("Exiting...");
            return 1;
        }

        import kameloso.plugins.common : IRCPluginInitialisationException;

        // Ensure initialised resources after resolve so we know we have a
        // valid server to create a directory for.
        try
        {
            bot.initPluginResources();
        }
        catch (const IRCPluginInitialisationException e)
        {
            logger.warningf("A plugin failed to load resources: %s%s", logtint, e.msg);
            return 1;
        }

        immutable actionAfterConnect = tryConnect(bot);
        if (*bot.abort) break;  // tryConnect interruptibleSleep can abort

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnSuccess:  // should never happen
        case retry:  // should never happen
            assert(0, "tryConnect returned Next returnSuccess or retry");

        case returnFailure:
            // No need to saveOnExit, the scopeguard takes care of that
            logger.info("Exiting...");
            return 1;
        }

        import kameloso.irc.parsing : IRCParser;

        bot.parser = IRCParser(backupClient);

        try
        {
            bot.startPlugins();
        }
        catch (const IRCPluginInitialisationException e)
        {
            logger.warningf("A plugin failed to start: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)",
                logtint, e.msg, warningtint, e.file, e.line);
            return 1;
        }

        // Start the main loop
        next = bot.mainLoop();
        firstConnect = false;
    }
    while (!*bot.abort && ((next == Next.continue_) || (next == Next.retry) ||
        ((next == Next.returnFailure) && settings.reconnectOnFailure)));

    if (!*bot.abort && (next == Next.returnFailure) && !settings.reconnectOnFailure)
    {
        // Didn't Ctrl+C, did return failure and shouldn't reconnect
        logger.logf("(Not reconnecting due to %sreconnectOnFailure%s not being enabled)", infotint, logtint);
    }

    if (*bot.abort)
    {
        // Ctrl+C
        logger.error("Aborting...");
    }
    else
    {
        logger.info("Exiting...");
    }

    return *bot.abort ? 1 : 0;
}


// complainAboutInvalidConfigurationEntries
/++
 +  Prints some information about invalid configuration entries to the local terminal.
 +
 +  Params:
 +      invalidEntries = A `string[][string]` associative array of dynamic
 +          `string[]` arrays, keyed by strings. These contain invalid settings.
 +/
void complainAboutInvalidConfigurationEntries(const string[][string] invalidEntries)
{
    if (!invalidEntries.length) return;

    logger.log("Found invalid configuration entries:");

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    foreach (immutable section, const sectionEntries; invalidEntries)
    {
        logger.logf(`...under [%s%s%s]: %s%-("%s"%|, %)`,
            infotint, section, logtint, infotint, sectionEntries);
    }

    logger.logf("They are either malformed or no longer in use. " ~
        "Use %s--writeconfig%s to update your configuration file. [%1$s%3$s%2$s]",
        infotint, logtint, settings.configFile);
}


// complainAboutMissingConfiguration
/++
 +  Displays an error if the configuration is *incomplete*, e.g. missing crucial information.
 +
 +  It assumes such information is missing, and that the check has been done at
 +  the calling site.
 +
 +  Params:
 +      args = The command-line arguments passed to the program at start.
 +/
void complainAboutMissingConfiguration(const string[] args)
{
    import std.file : exists;
    import std.path : baseName;

    logger.error("No administrators nor channels configured!");

    immutable configFileExists = settings.configFile.exists;
    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    if (configFileExists)
    {
        logger.logf("Edit %s%s%s and make sure it has at least one of the following:",
            infotint, settings.configFile, logtint);
        complainAboutIncompleteConfiguration();
    }
    else
    {
        logger.logf("Use %s%s --writeconfig%s to generate a configuration file.",
            infotint, args[0].baseName, logtint);
    }
}

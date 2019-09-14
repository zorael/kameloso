/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.kameloso;

import kameloso.common;
import kameloso.printing;
import kameloso.thread : ThreadMessage;
import lu.common : Next;
import dialect;

version(ProfileGC)
{
    /++
     +  Set some flags to tune the garbage collector and have it print profiling
     +  information at program exit, iff version `ProfileGC`.
     +/
    extern(C)
    __gshared string[] rt_options =
    [
        "gcopt=profile:1 gc:precise",
        "scanDataSeg=precise",
    ];
}


// abort
/++
 +  Abort flag.
 +
 +  This is set when the program is interrupted (such as via Ctrl+C). Other
 +  parts of the program will be monitoring it, to take the cue and abort when
 +  it is set.
 +/
__gshared bool abort;


private:

/+
    Warn about bug #18026; Stack overflow in ddmd/dtemplate.d:6241, TemplateInstance::needsCodegen()

    It may have been fixed in versions in the future at time of writing, so
    limit it to 2.086 and earlier. Update this condition as compilers are released.

    Exempt DDoc generation, as it doesn't seem to trigger the segfaults.
 +/
static if (__VERSION__ <= 2088L)
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


// messageFiber
/++
 +  A Generator Fiber function that checks for concurrency messages and performs
 +  action based on what was received.
 +
 +  The return value yielded to the caller tells it whether the received action
 +  means the bot should exit or not.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +/
void messageFiber(ref Kameloso instance)
{
    import std.concurrency : yield;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. We're not ready for that yet, so catch the next
    // yield (which is upon messenger.call()).
    yield(Next.init);

    // Loop forever; we'll just terminate the Generator when we want to quit.
    while (true)
    {
        Next next;

        /// Send a message to the server bypassing throttling.
        void immediateline(ThreadMessage.Immediateline, string line) scope
        {
            if (!settings.hideOutgoing)
            {
                version(Colours)
                {
                    import kameloso.irccolours : mapEffects;
                    logger.trace("--> ", line.mapEffects);
                }
                else
                {
                    import kameloso.irccolours : stripEffects;
                    logger.trace("--> ", line.stripEffects);
                }
            }

            instance.conn.sendline(line);
        }

        /// Echo a line to the terminal and send it to the server.
        void sendline(ThreadMessage.Sendline, string line) scope
        {
            instance.outbuffer.put(OutgoingLine(line, settings.hideOutgoing));
        }

        /// Send a line to the server without echoing it.
        void quietline(ThreadMessage.Quietline, string line) scope
        {
            instance.outbuffer.put(OutgoingLine(line, true));
        }

        /// Respond to `PING` with `PONG` to the supplied text as target.
        void pong(ThreadMessage.Pong, string target) scope
        {
            instance.outbuffer.put(OutgoingLine("PONG :" ~ target, true));
        }

        /// Quit the server with the supplied reason, or the default.
        void quitServer(ThreadMessage.Quit, string givenReason, bool hideOutgoing) scope
        {
            // This will automatically close the connection.
            // Set quit to yes to propagate the decision up the stack.
            immutable reason = givenReason.length ? givenReason : settings.quitReason;
            instance.priorityBuffer.put(OutgoingLine("QUIT :" ~ reason, hideOutgoing));
            next = Next.returnSuccess;
        }

        /// Disconnects from and reconnects to the server.
        void reconnect(ThreadMessage.Reconnect) scope
        {
            instance.priorityBuffer.put(OutgoingLine("QUIT :Reconnecting.", false));
            next = Next.retry;
        }

        /// Saves current configuration to disk.
        void save(ThreadMessage.Save) scope
        {
            instance.writeConfigurationFile(settings.configFile);
        }

        import kameloso.thread : CarryingFiber;
        import kameloso.plugins.common : IRCPlugin;

        /++
        +  Attaches a reference to the main array of
        +  `kameloso.plugins.common.IRCPlugin`s (housing all plugins) to the
        +  payload member of the supplied `kameloso.common.CarryingFiber`, then
        +  invokes it.
        +/
        void peekPlugins(ThreadMessage.PeekPlugins, shared CarryingFiber!(IRCPlugin[]) sFiber) scope
        {
            auto fiber = cast(CarryingFiber!(IRCPlugin[]))sFiber;
            assert(fiber, "Peeking Fiber was null!");
            fiber.payload = instance.plugins;  // Make it visible from within the Fiber
            fiber.call();
        }

        /// Reloads all plugins.
        void reloadPlugins(ThreadMessage.Reload) scope
        {
            foreach (plugin; instance.plugins)
            {
                plugin.reload();
            }
        }

        /// Passes a bus message to each plugin.
        import kameloso.thread : Sendable;
        void dispatchBusMessage(ThreadMessage.BusMessage, string header, shared Sendable content) scope
        {
            foreach (plugin; instance.plugins)
            {
                plugin.onBusMessage(header, content);
            }
        }

        /// Passes an empty header-only bus message to each plugin.
        void dispatchEmptyBusMessage(ThreadMessage.BusMessage, string header) scope
        {
            foreach (plugin; instance.plugins)
            {
                shared Sendable content;
                plugin.onBusMessage(header, content);
            }
        }

        /// Reverse-formats an event and sends it to the server.
        void eventToServer(IRCEvent event) scope
        {
            import lu.string : splitOnWord;
            import std.format : format;

            enum maxIRCLineLength = 512;

            version(TwitchSupport)
            {
                bool fast;
            }

            string line;
            string prelude;
            string[] lines;

            with (IRCEvent.Type)
            with (event)
            with (instance)
            switch (event.type)
            {
            case CHAN:
                version(TwitchSupport)
                {
                    fast = (instance.parser.client.server.daemon == IRCServer.Daemon.twitch) &&
                        (event.aux.length > 0);
                }

                prelude = "PRIVMSG %s :".format(channel);
                lines = content.splitOnWord(' ', maxIRCLineLength-prelude.length);
                break;

            case QUERY:
                version(TwitchSupport)
                {
                    if (instance.parser.client.server.daemon == IRCServer.Daemon.twitch)
                    {
                        if (target.nickname == instance.parser.client.nickname)
                        {
                            // "You cannot whisper to yourself." (whisper_invalid_self)
                            return;
                        }

                        prelude = "PRIVMSG #%s :/w %s ".format(instance.parser.client.nickname, target.nickname);
                    }
                }

                if (!prelude.length) prelude = "PRIVMSG %s :".format(target.nickname);
                lines = content.splitOnWord(' ', maxIRCLineLength-prelude.length);
                break;

            case EMOTE:
                immutable emoteTarget = target.nickname.length ? target.nickname : channel;

                version(TwitchSupport)
                {
                    if (instance.parser.client.server.daemon == IRCServer.Daemon.twitch)
                    {
                        line = "PRIVMSG %s :/me %s".format(emoteTarget, content);
                    }
                }

                if (!line.length)
                {
                    line = "PRIVMSG %s :%cACTION %s%2c".format(emoteTarget,
                        cast(char)IRCControlCharacter.ctcp, content);
                }
                break;

            case MODE:
                line = "MODE %s %s %s".format(channel, aux, content);
                break;

            case TOPIC:
                line = "TOPIC %s :%s".format(channel, content);
                break;

            case INVITE:
                line = "INVITE %s %s".format(channel, target.nickname);
                break;

            case JOIN:
                if (aux.length)
                {
                    line = channel ~ " " ~ aux;
                }
                else
                {
                    prelude = "JOIN ";
                    lines = channel.splitOnWord(',', maxIRCLineLength-prelude.length);
                }
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
                return quitServer(ThreadMessage.Quit(), content, (target.class_ == IRCUser.Class.special));

            case NICK:
                line = "NICK %s".format(target.nickname);
                break;

            case PRIVMSG:
                if (channel.length) goto case CHAN;
                else goto case QUERY;

            case RPL_WHOISACCOUNT:
                import kameloso.constants : Timeout;
                import std.datetime.systime : Clock;

                immutable now = Clock.currTime.toUnixTime;

                if (num > 0)
                {
                    // Force
                    line = "WHOIS " ~ target.nickname;
                    instance.previousWhoisTimestamps[target.nickname] = now;
                }
                else
                {
                    // Copy/paste from whoisForTriggerRequestQueue
                    immutable then = instance.previousWhoisTimestamps.get(target.nickname, 0);

                    if ((now - then) > Timeout.whoisRetry)
                    {
                        line = "WHOIS " ~ target.nickname;
                        instance.previousWhoisTimestamps[target.nickname] = now;
                    }
                }
                break;

            case UNSET:
                line = content;
                break;

            default:
                import lu.conv : Enum;

                // Changing this to use Enum lowered compilation memory use from 4168 to 3775...
                logger.warning("No outgoing event case for type ",
                    Enum!(IRCEvent.Type).toString(type));
                line = content;
                break;
            }

            void appropriateline(const string finalLine)
            {
                version(TwitchSupport)
                {
                    if ((instance.parser.client.server.daemon == IRCServer.Daemon.twitch) && fast)
                    {
                        // Send a line via the fastbuffer, faster than normal sends.
                        immutable quiet = settings.hideOutgoing ||
                            (event.target.class_ == IRCUser.Class.special);
                        instance.fastbuffer.put(OutgoingLine(finalLine, quiet));
                        return;
                    }
                }

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
            else if (line.length)
            {
                appropriateline(line);
            }
        }

        /// Proxies the passed message to the `logger`.
        void proxyLoggerMessages(ThreadMessage.TerminalOutput logLevel, string message) scope
        {
            with (ThreadMessage.TerminalOutput)
            final switch (logLevel)
            {
            case writeln:
                import std.stdio : writeln, stdout;

                writeln(message);
                if (settings.flush) stdout.flush();
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

        import core.time : seconds;
        import std.datetime.systime : Clock;

        /// Did the concurrency receive catch something?
        bool receivedSomething;

        /// Timestamp of when the loop started.
        immutable loopStartTime = Clock.currTime;

        static immutable instant = (-1).seconds;
        static immutable oneSecond = 1.seconds;

        do
        {
            import std.concurrency : receiveTimeout;
            import std.variant : Variant;

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
                (Variant v) scope
                {
                    // Caught an unhandled message
                    logger.warning("Main thread message fiber received unknown Variant: ", v);
                }
            );
        }
        while (receivedSomething && (next == Next.continue_) &&
            ((Clock.currTime - loopStartTime) <= oneSecond));

        yield(next);
    }

    assert(0, "while (true) loop break in messageFiber");
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
    static immutable almostInstant = 10.msecs;

    do
    {
        notEmpty = receiveTimeout(almostInstant,
            (Variant v) {}
        );
    }
    while (notEmpty);
}


// mainLoop
/++
 +  This loops creates a `std.concurrency.Generator` `core.thread.Fiber` to loop
 +  over the over `std.socket.Socket`, reading lines and yielding
 +  `lu.net.ListenAttempt`s as it goes.
 +
 +  Full lines are stored in `lu.net.ListenAttempt`s which are
 +  yielded in the `std.concurrency.Generator` to be caught here, consequently
 +  parsed into `dialect.defs.IRCEvent`s, and then dispatched to all plugins.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +
 +  Returns:
 +      `kameloso.common.Next.returnFailure` if circumstances mean the bot
 +      should exit with a non-zero exit code,
 +      `kameloso.common.Next.returnSuccess` if it should exit by returning `0`,
 +      `kameloso.common.Next.retry` if the bot should reconnect to the server.
 +      `kameloso.common.Next.continue_` is never returned.
 +/
Next mainLoop(ref Kameloso instance)
{
    import lu.net : ListenAttempt, listenFiber;
    import std.concurrency : Generator;

    /// Enum denoting what we should do next loop.
    Next next;

    alias State = ListenAttempt.State;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(instance.conn, *instance.abort));

    auto messenger = new Generator!Next(() =>
        messageFiber(instance));

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

    bool readWasShortened;

    while (next == Next.continue_)
    {
        import core.thread : Fiber;

        if (*instance.abort) return Next.returnFailure;

        if (listener.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected by itself; reconnect
            return Next.retry;
        }

        import std.datetime.systime : Clock;
        immutable nowInUnix = Clock.currTime.toUnixTime;

        foreach (ref plugin; instance.plugins)
        {
            plugin.periodically(nowInUnix);
        }

        foreach (plugin; instance.plugins)
        {
            if (!plugin.state.timedFibers.length) continue;

            if (plugin.nextFiberTimestamp <= nowInUnix)
            {
                plugin.handleTimedFibers(nowInUnix);
                plugin.updateNextFiberTimestamp();
            }
        }

        // Once every 24h (24*3600s), clear the `previousWhoisTimestamps` AA.
        // That should be enough to stop it from being a memory leak.
        if ((nowInUnix % 86_400) == 0)
        {
            instance.previousWhoisTimestamps = typeof(instance.previousWhoisTimestamps).init;
        }

        // Call the generator, query it for event lines
        listener.call();

        listenerloop:
        foreach (const attempt; listener)
        {
            if (*instance.abort) return Next.returnFailure;

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

                // Sleep briefly so it won't flood the screen on chains of errors
                Thread.sleep(1.seconds);
                break listenerloop;

            case timeout:
                logger.error("Connection lost.");
                instance.conn.connected = false;
                return Next.returnFailure;

            case error:
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

                instance.conn.connected = false;
                return Next.returnFailure;
            }

            IRCEvent event;

            scope(failure)
            {
                // Something asserted
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
                    event = instance.parser.toIRCEvent(attempt.line);
                }
                catch (UTFException e)
                {
                    event = instance.parser.toIRCEvent(sanitize(attempt.line));
                }
                catch (UnicodeException e)
                {
                    event = instance.parser.toIRCEvent(sanitize(attempt.line));
                }
                catch (Exception e)
                {
                    // Print, then rethrow down.
                    logger.errorf("Exception toIRCEvent: %s%s", logtint, e.msg);
                    version(PrintStacktraces) logger.trace(e.toString);
                    throw e;
                }

                if (instance.parser.client.updated)
                {
                    // Parsing changed the client; propagate
                    instance.parser.client.updated = false;
                    instance.propagateClient(instance.parser.client);
                }

                foreach (plugin; instance.plugins)
                {
                    try
                    {
                        plugin.postprocess(event);
                    }
                    catch (Exception e)
                    {
                        logger.warningf("Exception %s.postprocess: %s%s",
                            plugin.name, logtint, e.msg);
                        printObject(event);
                        version(PrintStacktraces) logger.trace(e.toString);
                    }

                    if (plugin.state.client.updated)
                    {
                        // Postprocessing changed the client; propagate
                        instance.parser.client = plugin.state.client;
                        instance.parser.client.updated = false;
                        instance.propagateClient(instance.parser.client);
                    }
                }

                // Let each plugin process the event
                foreach (plugin; instance.plugins)
                {
                    try
                    {
                        plugin.onEvent(event);

                        // Go through Fibers awaiting IRCEvent.Types
                        plugin.handleAwaitingFibers(event);

                        // Fetch any queued `WHOIS` requests and handle
                        instance.whoisForTriggerRequestQueue(plugin.state.triggerRequestQueue);

                        if (plugin.state.client.updated)
                        {
                            /*  Plugin `onEvent` or `WHOIS` reaction updated the
                                client. There's no need to check for both
                                separately since this is just a single plugin
                                processing; it keeps its update internally
                                between both passes.
                            */
                            instance.parser.client = plugin.state.client;
                            instance.parser.client.updated = false;
                            instance.propagateClient(instance.parser.client);
                        }
                    }
                    catch (UTFException e)
                    {
                        logger.warningf("UTFException %s.onEvent: %s%s",
                            plugin.name, logtint, e.msg);
                        version(PrintStacktraces) logger.trace(e.info);
                    }
                    catch (Exception e)
                    {
                        logger.warningf("Exception %s.onEvent: %s%s",
                            plugin.name, logtint, e.msg);
                        printObject(event);
                        version(PrintStacktraces) logger.trace(e.toString);
                    }
                }

                with (IRCEvent.Type)
                switch (event.type)
                {
                case SELFCHAN:
                case SELFEMOTE:
                case SELFQUERY:
                    // Treat self-events as if we sent them ourselves, to properly
                    // rate-limit the account itself. This stops Twitch from
                    // giving spam warnings. We can easily tell whether it's a channel
                    // we're the broadcaster in, but no such luck with whether
                    // we're a moderator.
                    // FIXME: Revisit with a better solution that's broken out of throttleline.
                    import std.typecons : Flag, No, Yes;

                    version(TwitchSupport)
                    {
                        if (event.channel.length && (event.channel[1..$] == instance.parser.client.nickname))
                        {
                            instance.throttleline(instance.fastbuffer, Yes.onlyIncrement, Yes.sendFaster);
                        }
                        else
                        {
                            instance.throttleline(instance.outbuffer, Yes.onlyIncrement);
                        }
                    }
                    else
                    {
                        instance.throttleline(instance.outbuffer, Yes.onlyIncrement);
                    }
                    break;

                default:
                    break;
                }
            }
            catch (IRCParseException e)
            {
                logger.warningf("IRC Parse Exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)",
                    logtint, e.msg, warningtint, e.file, e.line);
                printObject(e.event);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UTFException e)
            {
                logger.warning("UTFException: ", logtint, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UnicodeException e)
            {
                logger.warning("UnicodeException: ", logtint, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
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

                version(PrintStacktraces) logger.trace(e.toString);
            }
        }

        // Check concurrency messages to see if we should exit, else repeat
        messenger.call();

        if (messenger.state == Fiber.State.HOLD)
        {
            next = messenger.front;
        }
        else
        {
            logger.errorf("Internal error, thread messenger Fiber ended abruptly.");
            version(PrintStacktraces) printStacktrace();
            next = Next.returnFailure;
        }

        bool bufferHasMessages = (!instance.outbuffer.empty || !instance.priorityBuffer.empty);

        version(TwitchSupport)
        {
            bufferHasMessages |= !instance.fastbuffer.empty;
        }

        if (bufferHasMessages)
        {
            // There are messages to send.

            import kameloso.constants : Timeout;
            import core.time : msecs, seconds;
            import std.socket : SocketOption, SocketOptionLevel;
            import std.typecons : Flag, No, Yes;

            double untilNext;

            version(TwitchSupport)
            {
                if (!instance.priorityBuffer.empty) untilNext = instance.throttleline(instance.priorityBuffer);
                else if (!instance.fastbuffer.empty) untilNext =
                    instance.throttleline(instance.fastbuffer, No.onlyIncrement, Yes.sendFaster);
                else
                {
                    untilNext = instance.throttleline(instance.outbuffer);
                }
            }
            else
            {
                if (!instance.priorityBuffer.empty) untilNext = instance.throttleline(instance.priorityBuffer);
                else
                {
                    untilNext = instance.throttleline(instance.outbuffer);
                }
            }

            with (instance.conn.socket)
            with (SocketOption)
            with (SocketOptionLevel)
            {
                if (untilNext > 0)
                {
                    if ((untilNext < instance.throttle.burst) &&
                        (untilNext < Timeout.receive))
                    {
                        setOption(SOCKET, RCVTIMEO, (cast(long)(1000*untilNext + 1)).msecs);
                        readWasShortened = true;
                    }
                }
                else if (readWasShortened)
                {
                    setOption(SOCKET, RCVTIMEO, Timeout.receive.seconds);
                    readWasShortened = false;
                }
            }
        }
    }

    return next;
}


import kameloso.plugins.common : IRCPlugin;

// handleAwaitingFibers
/++
 +  Processes the awaiting `core.thread.Fiber`s of an
 +  `kameloso.plugins.common.IRCPlugin`.
 +
 +  Params:
 +      plugin = The `kameloso.plugins.common.IRCPlugin` whose
 +          `dialect.defs.IRCEvent.Type`-awaiting `core.thread.Fiber`s to
 +          iterate and process.
 +      event = The triggering `dialect.defs.IRCEvent`.
 +/
void handleAwaitingFibers(IRCPlugin plugin, const IRCEvent event)
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
                        carryingFiber.resetPayload();
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
            catch (IRCParseException e)
            {
                string logtint;

                version(Colours)
                {
                    if (!settings.monochrome)
                    {
                        import kameloso.logger : KamelosoLogger;
                        logtint = (cast(KamelosoLogger)logger).logtint;
                    }
                }

                logger.warningf("IRC Parse Exception %s.awaitingFibers[%d]: %s%s",
                    plugin.name, i, logtint, e.msg);
                printObject(e.event);
                version(PrintStacktraces) logger.trace(e.info);
                toRemove ~= i;
            }
            catch (Exception e)
            {
                string logtint;

                version(Colours)
                {
                    if (!settings.monochrome)
                    {
                        import kameloso.logger : KamelosoLogger;
                        logtint = (cast(KamelosoLogger)logger).logtint;
                    }
                }

                logger.warningf("Exception %s.awaitingFibers[%d]: %s%s",
                    plugin.name, i, logtint, e.msg);
                printObject(event);
                version(PrintStacktraces) logger.trace(e.toString);
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
 +      nowInUnix = Current UNIX timestamp to compare the timed
 +          `core.thread.Fiber`'s timestamp with.
 +/
void handleTimedFibers(IRCPlugin plugin, const long nowInUnix)
in ((nowInUnix > 0), "Tried to handle timed fibers with an unset timestamp")
do
{
    size_t[] toRemove;

    foreach (immutable i, ref fiber; plugin.state.timedFibers)
    {
        if (fiber.id > nowInUnix) continue;

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
        catch (IRCParseException e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("IRC Parse Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            printObject(e.event);
            version(PrintStacktraces) logger.trace(e.info);
            toRemove ~= i;
        }
        catch (Exception e)
        {
            string logtint;

            version(Colours)
            {
                if (!settings.monochrome)
                {
                    import kameloso.logger : KamelosoLogger;
                    logtint = (cast(KamelosoLogger)logger).logtint;
                }
            }

            logger.warningf("Exception %s.timedFibers[%d]: %s%s",
                plugin.name, i, logtint, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
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


import kameloso.plugins.common : TriggerRequest;

// whoisForTriggerRequestQueue
/++
 +  Takes a queue of `TriggerRequest` objects and emits `WHOIS` requests for each one.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      reqs = Reference to an associative array of `TriggerRequest`s.
 +/
void whoisForTriggerRequestQueue(ref Kameloso instance, const TriggerRequest[][string] reqs)
{
    // Walk through requests and call `WHOIS` on those that haven't been
    // `WHOIS`ed in the last `Timeout.whois` seconds

    foreach (immutable nickname, const requestsForNickname; reqs)
    {
        assert(nickname.length, "Empty nickname in trigger queue");

        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime.toUnixTime;
        immutable then = instance.previousWhoisTimestamps.get(nickname, 0);

        if ((now - then) > Timeout.whoisRetry)
        {
            instance.outbuffer.put(OutgoingLine("WHOIS " ~ nickname, settings.hideOutgoing));
            instance.previousWhoisTimestamps[nickname] = now;
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
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      args = The arguments passed to the program.
 +      customSettings = Reference to the dynamic array of custom settings as
 +          defined with `--set plugin.setting=value` on the command line.
 +
 +  Returns:
 +      `kameloso.common.Next`.* depending on what action the calling site should take.
 +/
Next tryGetopt(ref Kameloso instance, string[] args, ref string[] customSettings)
{
    import lu.common : FileTypeMismatchException;
    import lu.serialisation : ConfigurationFileReadFailureException,
        ConfigurationFileParsingException;
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
        return instance.handleGetopt(args, customSettings);
    }
    catch (GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", logtint, e.msg);
    }
    catch (ConvException e)
    {
        logger.error("Error converting command-line arguments: ", logtint, e.msg);
    }
    catch (FileTypeMismatchException e)
    {
        logger.errorf("Specified configuration file %s%s%s is not a file!",
            logtint, e.filename, errortint);
    }
    catch (ConfigurationFileReadFailureException e)
    {
        logger.errorf("Error reading and decoding configuration file [%s%s%s]: %1$s%4$s",
            logtint, e.filename, errortint, e.msg);
    }
    catch (ConfigurationFileParsingException e)
    {
        logger.errorf("Error parsing configuration file: %s%s", logtint, e.msg);
    }
    catch (Exception e)
    {
        logger.error("Unhandled exception handling command-line arguments: ", logtint, e.msg);
    }

    return Next.returnFailure;
}


// tryConnect
/++
 +  Tries to connect to the IPs in `kameloso.common.Kameloso.conn.ips` by
 +  leveraging `lu.net.connectFiber`, reacting on the
 +  `lu.net.ConnectAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if connection succeeded,
 +      `kameloso.common.Next.returnFailure` if connection failed and the
 +      program should exit.
 +/
Next tryConnect(ref Kameloso instance)
{
    import kameloso.constants : ConnectionDefaultIntegers, ConnectionDefaultFloats, Timeout;
    import kameloso.thread : interruptibleSleep;
    import lu.net : ConnectionAttempt, connectFiber;
    import std.concurrency : Generator;

    alias State = ConnectionAttempt.State;
    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(instance.conn,  settings.endlesslyConnect,
            ConnectionDefaultIntegers.retries, *instance.abort));
    uint incrementedRetryDelay = Timeout.retry;

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

    with (instance)
    foreach (const attempt; connector)
    {
        import core.time : seconds;

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case preconnect:
            import lu.string : sharedDomains;
            import std.socket : AddressFamily;

            immutable resolvedHost = attempt.ip.toHostNameString;
            immutable pattern = !resolvedHost.length &&
                (attempt.ip.addressFamily == AddressFamily.INET6) ?
                "Connecting to [%s%s%s]:%1$s%4$s%3$s ..." :
                "Connecting to %s%s%s:%1$s%4$s%3$s ...";

            immutable address = (!resolvedHost.length ||
                (parser.client.server.address == resolvedHost) ||
                (sharedDomains(parser.client.server.address, resolvedHost) < 2)) ?
                attempt.ip.toAddrString : resolvedHost;

            logger.logf(pattern, infotint, address, logtint, attempt.ip.toPortString);
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

            import std.algorithm.comparison : min;
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay *
                ConnectionDefaultFloats.delayIncrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay,
                ConnectionDefaultIntegers.delayCap);
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
 +  Tries to resolve the address in `instance.parser.client.server` to IPs, by
 +  leveraging `lu.net.resolveFiber`, reacting on the
 +  `lu.net.ResolveAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if resolution succeeded,
 +      `kameloso.common.Next.returnFailure` if it failed and the program should exit.
 +/
Next tryResolve(ref Kameloso instance)
{
    import kameloso.constants : Timeout;
    import lu.net : ResolveAttempt, resolveFiber;
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

    enum defaultResolveAttempts = 15;
    immutable resolveAttempts = settings.endlesslyConnect ? int.max : defaultResolveAttempts;

    alias State = ResolveAttempt.State;
    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(instance.conn, instance.parser.client.server.address,
        instance.parser.client.server.port, settings.ipv6, resolveAttempts, *instance.abort));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.2;

    resolver.call();

    with (instance)
    foreach (const attempt; resolver)
    {
        with (State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            import lu.string : plurality;
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

                enum delayCap = 10*60;  // seconds
                incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
                incrementedRetryDelay = (incrementedRetryDelay < delayCap) ? incrementedRetryDelay : delayCap;
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

    logger.log("They are either malformed, no longer in use or belong to " ~
        "plugins not currently compiled in.");
    logger.logf("Use %s--writeconfig%s to update your configuration file. [%1$s%3$s%2$s]",
        infotint, logtint, settings.configFile);
    logger.warning("Mind that any settings belonging to unbuilt plugins will be LOST.");
    logger.trace("---");
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

    logger.warning("Warning: No administrators nor home channels configured!");

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

    if (settings.configFile.exists)
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


public:


// initBot
/++
 +  Entry point of the program.
 +
 +  Params:
 +      args = Command-line arguments passed to the program.
 +
 +  Returns:
 +      `0` on success, `1` on failure.
 +/
int initBot(string[] args)
{
    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("kameloso");
    }

    version(Windows)
    {
        import kameloso.terminal : setConsoleModeAndCodepage;

        // Set up the console to display text and colours properly.
        setConsoleModeAndCodepage();
    }

    import kameloso.constants : KamelosoInfo;
    import kameloso.terminal : setTitle;

    enum terminalTitle = "kameloso v" ~ cast(string)KamelosoInfo.version_;
    setTitle(terminalTitle);

    // Initialise the main Kameloso. Set its abort pointer to the global abort.
    Kameloso instance;
    instance.abort = &abort;

    import std.path : buildNormalizedPath;

    // Default values
    settings.configFile = buildNormalizedPath(defaultConfigurationPrefix, "kameloso.conf");
    settings.resourceDirectory = defaultResourcePrefix;

    // Some environments require us to flush standard out after writing to it,
    // or else nothing will appear on screen (until it gets automatically flushed
    // at an indeterminate point in the future).
    immutable platform = getPlatform();
    if ((platform == "Cygwin") || (platform == "vscode"))
    {
        // Whitelist more as we find them.
        settings.flush = true;
    }

    // Prepare an array for `handleGetopt` to fill by ref with custom settings
    // set on the command-line using `--set plugin.setting=value`
    string[] customSettings;

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for monochrome
    initLogger(settings.monochrome, settings.brightTerminal, settings.flush);

    // Set up signal handling so that we can gracefully catch Ctrl+C.
    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken;

        logger.error("We just crashed!", cast(char)TerminalToken.bell);
        *instance.abort = true;
        resetSignals();
    }

    immutable actionAfterGetopt = instance.tryGetopt(args, customSettings);

    with (Next)
    final switch (actionAfterGetopt)
    {
    case continue_:
        break;

    case retry:  // should never happen
        assert(0, "tryGetopt returned Next.retry");

    case returnSuccess:
        return 0;

    case returnFailure:
        return 1;
    }

    // Apply some defaults, as stored in `kameloso.constants`.
    with (instance.parser.client)
    {
        import kameloso.constants : KamelosoDefaultIntegers, KamelosoDefaultStrings;

        if (!realName.length) realName = KamelosoDefaultStrings.realName;
        if (!settings.quitReason.length) settings.quitReason = KamelosoDefaultStrings.quitReason;
        if (!server.address.length) server.address = KamelosoDefaultStrings.serverAddress;
        if (server.port == 0) server.port = KamelosoDefaultIntegers.port;
    }

    string pre, post, infotint, logtint, warningtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.terminal : TerminalForeground, colour;
            import kameloso.logger : KamelosoLogger;

            enum headertintColourBright = TerminalForeground.black.colour;
            enum headertintColourDark = TerminalForeground.white.colour;
            enum defaulttintColour = TerminalForeground.default_.colour;
            pre = settings.brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
            errortint = (cast(KamelosoLogger)logger).errortint;
        }
    }

    import std.stdio : writeln;
    printVersionInfo(pre, post);
    writeln();

    import kameloso.printing : printObjects;
    import lu.string : contains;

    // Print the current settings to show what's going on.
    printObjects(instance.parser.client, instance.parser.client.server);

    if (!instance.parser.client.homes.length && !instance.parser.client.admins.length)
    {
        complainAboutMissingConfiguration(args);
    }

    if (!settings.force)
    {
        IRCServer conservativeServer;
        conservativeServer.maxNickLength = 25;  // Twitch max, should be enough

        if (!instance.parser.client.nickname.isValidNickname(conservativeServer))
        {
            // No need to print the nickname, visible from printObjects preivously
            logger.error("Invalid nickname!");
            return 1;
        }

        if (!settings.prefix.length)
        {
            logger.error("No prefix configured!");
            return 1;
        }
    }

    version(Posix)
    {
        // Workaround for Issue 19247:
        // Segmentation fault when resolving address with std.socket.getAddress inside a Fiber
        // the workaround being never resolve addresses that don't contain at least one dot
        immutable addressIsResolvable = instance.parser.client.server.address.contains('.');
    }
    else
    {
        // On Windows this doesn't happen, so allow all addresses.
        enum addressIsResolvable = true;
    }

    if (!settings.force && !addressIsResolvable)
    {
        logger.errorf("Invalid address! [%s%s%s]", logtint,
            instance.parser.client.server.address, errortint);
        return 1;
    }

    import std.file : exists;
    import std.path : dirName;

    // Resolve and create the resource directory
    settings.resourceDirectory = buildNormalizedPath(settings.resourceDirectory,
        "server", instance.parser.client.server.address);
    settings.configDirectory = settings.configFile.dirName;

    if (!settings.resourceDirectory.exists)
    {
        import std.file : mkdirRecurse;
        mkdirRecurse(settings.resourceDirectory);
        logger.logf("Created resource directory %s%s", infotint, settings.resourceDirectory);
    }

    // Initialise plugins outside the loop once, for the error messages
    import kameloso.plugins.common : IRCPluginSettingsException;
    import std.conv : ConvException;

    try
    {
        const invalidEntries = instance.initPlugins(customSettings);
        complainAboutInvalidConfigurationEntries(invalidEntries);
    }
    catch (ConvException e)
    {
        // Configuration file/--set argument syntax error
        logger.error(e.msg);
        if (!settings.force) return 1;
    }
    catch (IRCPluginSettingsException e)
    {
        // --set plugin/setting name error
        logger.error(e.msg);
        if (!settings.force) return 1;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    instance.parser.client.origNickname = instance.parser.client.nickname;

    /// Return value so that the exit scopeguard knows what to return.
    int retval;

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    /// Enum denoting what we should do next loop.
    Next next;

    /++
     +  Bool whether this is the first connection attempt or if we have
     +  connected at least once already.
     +/
    bool firstConnect = true;

    /// Whether or not "Exiting..." should be printed at program exit.
    bool silentExit;

    outerloop:
    do
    {
        // *instance.abort is guaranteed to be false here.

        silentExit = true;

        if (!firstConnect)
        {
            import kameloso.constants : Timeout;
            import kameloso.thread : interruptibleSleep;
            import core.time : seconds;

            // Carry some values but otherwise restore the pristine client backup
            backupClient.nickname = instance.parser.client.nickname;
            backupClient.homes = instance.parser.client.homes;
            backupClient.channels = instance.parser.client.channels;
            //instance.parser.client = backupClient;  // Initialised below

            // Exhaust leftover queued messages
            exhaustMessages();

            // Clear outgoing messages
            instance.outbuffer.clear();
            instance.priorityBuffer.clear();

            version(TwitchSupport)
            {
                instance.fastbuffer.clear();
            }

            logger.log("Please wait a few seconds ...");
            interruptibleSleep(Timeout.retry.seconds, *instance.abort);
            if (*instance.abort) break outerloop;

            // Re-init plugins here so it isn't done on the first connect attempt
            instance.initPlugins(customSettings);

            // Reset throttling, in case there were queued messages.
            instance.throttle = typeof(instance.throttle).init;
        }

        scope(exit)
        {
            // Always teardown when exiting this loop (for whatever reason)
            instance.teardownPlugins();
        }

        // May as well check once here, in case something in initPlugins aborted or so.
        if (*instance.abort) break outerloop;

        instance.conn.connected = false;
        instance.conn.reset();

        immutable actionAfterResolve = tryResolve(instance);
        if (*instance.abort) break outerloop;  // tryResolve interruptibleSleep can abort

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case retry:  // should never happen
            assert(0, "tryResolve returned Next.retry");

        case returnFailure:
            // No need to teardown; the scopeguard does it for us.
            retval = 1;
            break outerloop;

        case returnSuccess:
            // Ditto
            retval = 0;
            break outerloop;
        }

        immutable actionAfterConnect = tryConnect(instance);
        if (*instance.abort) break outerloop;  // tryConnect interruptibleSleep can abort

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnSuccess:  // should never happen
            assert(0, "tryConnect returned Next.returnSuccess");

        case retry:  // should never happen
            assert(0, "tryConnect returned Next.retry");

        case returnFailure:
            // No need to saveOnExit, the scopeguard takes care of that
            retval = 1;
            break outerloop;
        }

        import kameloso.plugins.common : IRCPluginInitialisationException;
        import std.path : baseName;

        // Ensure initialised resources after resolve so we know we have a
        // valid server to create a directory for.
        try
        {
            instance.initPluginResources();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            import kameloso.terminal : TerminalToken;
            logger.warningf("The %s%s%s plugin failed to load its resources: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$c",
                logtint, e.file.baseName[0..$-2], warningtint, e.msg, e.file.baseName, e.line, TerminalToken.bell);
            version(PrintStacktraces) logger.trace(e.info);
            retval = 1;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;
            logger.warningf("An error occured while initialising the %s%s%s " ~
                "plugin's resources: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$c",
                logtint, e.file.baseName[0..$-2], warningtint, e.msg, e.file, e.line, TerminalToken.bell);
            version(PrintStacktraces) logger.trace(e.toString);
            retval = 1;
            break outerloop;
        }

        import dialect.parsing : IRCParser;

        instance.parser = IRCParser(backupClient);

        try
        {
            instance.startPlugins();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            import kameloso.terminal : TerminalToken;
            logger.warningf("The %s%s%s plugin failed to start up: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$c",
                logtint, e.file.baseName[0..$-2], warningtint, e.msg, e.file.baseName, e.line, TerminalToken.bell);
            version(PrintStacktraces) logger.trace(e.info);
            retval = 1;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;
            logger.warningf("An error occured while starting up the %s%s%s plugin: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$c",
                logtint, e.file.baseName[0..$-2], warningtint, e.msg, e.file.baseName, e.line, TerminalToken.bell);
            version(PrintStacktraces) logger.trace(e.toString);
            retval = 1;
            break outerloop;
        }

        // Do verbose exits if mainLoop causes a return
        silentExit = false;

        // Start the main loop
        next = instance.mainLoop();
        firstConnect = false;
    }
    while (!*instance.abort && ((next == Next.continue_) || (next == Next.retry) ||
        ((next == Next.returnFailure) && settings.reconnectOnFailure)));

    if (*instance.abort && instance.conn.connected)
    {
        if (!settings.hideOutgoing)
        {
            version(Colours)
            {
                import kameloso.irccolours : mapEffects;
                logger.trace("--> QUIT :", settings.quitReason.mapEffects);
            }
            else
            {
                import kameloso.irccolours : stripEffects;
                logger.trace("--> QUIT :", settings.quitReason.stripEffects);
            }
        }

        instance.conn.sendline("QUIT :" ~ settings.quitReason);
    }
    else if (!*instance.abort && (next == Next.returnFailure) && !settings.reconnectOnFailure)
    {
        // Didn't Ctrl+C, did return failure and shouldn't reconnect
        logger.logf("(Not reconnecting due to %sreconnectOnFailure%s not being enabled)", infotint, logtint);
    }

    // Save if we're exiting and configuration says we should.
    if (settings.saveOnExit)
    {
        instance.writeConfigurationFile(settings.configFile);
    }

    if (*instance.abort)
    {
        // Ctrl+C
        logger.error("Aborting...");
        return 1;
    }
    else if (!silentExit)
    {
        logger.info("Exiting...");
    }

    return retval;
}

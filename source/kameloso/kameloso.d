/++
 +  The main module, housing startup logic and the main event loop.
 +/
module kameloso.kameloso;

import kameloso.common;
import kameloso.printing;
import kameloso.thread : ThreadMessage;
import dialect;
import lu.common : Next;

version(ProfileGC)
{
    static if (__VERSION__ >= 2085L)
    {
        /++
         +  Set some flags to tune the garbage collector and have it print
         +  profiling information at program exit, iff version `ProfileGC`.
         +  Enables the precise garbage collector.
         +/
        extern(C)
        __gshared string[] rt_options =
        [
            "gcopt=profile:1 gc:precise",
            "scanDataSeg=precise",
        ];
    }
    else
    {
        /++
         +  Set some flags to tune the garbage collector and have it print
         +  profiling information at program exit, iff version `ProfileGC`.
         +/
        extern(C)
        __gshared string[] rt_options =
        [
            "gcopt=profile:1",
        ];
    }
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


version(Posix)
{
    // wantLiveSummary
    /++
     +  Summary request flag.
     +
     +  This is set when the process is sent a `SIGUSR1` signal (10), and tells the
     +  main loop to print the connection summary on the start of the next iteration.
     +
     +  `SIGUSR1` is not available on Windows so this is version Posix.
     +/
    __gshared bool wantLiveSummary;
}


private:


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
            immutable reason = givenReason.length ? givenReason : instance.bot.quitReason;
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

        import kameloso.plugins.common : IRCPlugin;
        import kameloso.thread : CarryingFiber;

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
                    fast = (instance.parser.server.daemon == IRCServer.Daemon.twitch) &&
                        (event.aux.length > 0);
                }

                prelude = "PRIVMSG %s :".format(channel);
                lines = content.splitOnWord(' ', maxIRCLineLength-prelude.length);
                break;

            case QUERY:
                version(TwitchSupport)
                {
                    if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
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
                    if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
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
                    // Copy/paste from processTriggerRequestQueue
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
                    if ((instance.parser.server.daemon == IRCServer.Daemon.twitch) && fast)
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

        /// Wrapper around `eventToServer` for shared heap `dialect.defs.IRCEvent`s.
        void eventPointerToServer(shared(IRCEvent)* event)
        {
            return eventToServer(cast()*event);
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
                &eventPointerToServer,
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
                    logger.warning("Main thread message fiber received unknown Variant: ", v.type);
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
    import std.datetime.systime : Clock;

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

    /++
     +  A snapshot of `settings.exitSummary` to use instead of it, so that
     +  toggling it mid-execution does nothing. It would not know the connection
     +  established timestamp and so would give an invalid connection duration.
     +/
    immutable exitSummary = settings.exitSummary;

    /// The index of the current `ConnectionHistoryIndex` in `instance.connectionHistory`.
    size_t historyEntryIndex;

    if (exitSummary)
    {
        historyEntryIndex = instance.connectionHistory.length;  // snapshot index, 0 at first
        instance.connectionHistory ~= Kameloso.ConnectionHistoryEntry.init;
        instance.connectionHistory[historyEntryIndex].startTime = Clock.currTime.toUnixTime;
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

            immutable actionAfterListen = listenAttemptToNext(instance, attempt);

            with (Next)
            final switch (actionAfterListen)
            {
            case continue_:
                // Drop down and continue
                break;

            case retry:
                // Break and try again
                break listenerloop;

            case returnSuccess:
                assert(0, "listenAttemptToNext returned Next.returnSuccess");

            case returnFailure:
                return Next.returnFailure;
            }

            if (exitSummary)
            {
                // Successful read; record as such
                instance.connectionHistory[historyEntryIndex].stopTime = nowInUnix;
            }

            IRCEvent event;

            scope(failure)
            {
                // Something asserted
                logger.error("scopeguard tripped.");

                if (event == IRCEvent.init)
                {
                    logger.warningf(`Offending line: "%s%s%s"`, logtint, attempt.line, warningtint);
                }
                else
                {
                    // Offending line included in event, in raw
                    printObject(event);
                }
            }

            import lu.string : NomException;
            import core.exception : UnicodeException;
            import std.utf : UTFException;

            try
            {
                // Sanitise and try again once on UTF/Unicode exceptions
                import std.datetime.systime : Clock;
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

                if (instance.parser.clientUpdated)
                {
                    // Parsing changed the client; propagate
                    instance.parser.clientUpdated = false;
                    instance.propagateClient(instance.parser.client);
                }

                if (instance.parser.serverUpdated)
                {
                    // Parsing changed the server; propagate
                    instance.parser.serverUpdated = false;
                    instance.propagateServer(instance.parser.server);
                }

                static void checkUpdatesAndPropagate(ref Kameloso instance, IRCPlugin plugin)
                {
                    if (plugin.state.botUpdated)
                    {
                        // Something changed the bot; propagate
                        plugin.state.botUpdated = false;
                        instance.propagateBot(plugin.state.bot);
                    }

                    if (plugin.state.clientUpdated)
                    {
                        // Something changed the client; propagate
                        plugin.state.clientUpdated = false;
                        instance.propagateClient(plugin.state.client);
                    }

                    if (plugin.state.serverUpdated)
                    {
                        // Something changed the server; propagate
                        plugin.state.serverUpdated = false;
                        instance.propagateServer(plugin.state.server);
                    }
                }

                event.time = Clock.currTime.toUnixTime;

                if (exitSummary)
                {
                    // Successful parse
                    ++instance.connectionHistory[historyEntryIndex].numEvents;
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

                    checkUpdatesAndPropagate(instance, plugin);
                }

                // Let each plugin process the event
                foreach (plugin; instance.plugins)
                {
                    try
                    {
                        plugin.onEvent(event);
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

                    checkUpdatesAndPropagate(instance, plugin);

                    try
                    {
                        plugin.handleAwaitingFibers(event);
                    }
                    catch (UTFException e)
                    {
                        logger.warningf("UTFException %s.handleAwaitingFibers: %s%s",
                            plugin.name, logtint, e.msg);
                        version(PrintStacktraces) logger.trace(e.info);
                    }
                    catch (Exception e)
                    {
                        logger.warningf("Exception %s.handleAwaitingFibers: %s%s",
                            plugin.name, logtint, e.msg);
                        printObject(event);
                        version(PrintStacktraces) logger.trace(e.toString);
                    }

                    checkUpdatesAndPropagate(instance, plugin);

                    // Fetch any queued `WHOIS` requests and handle
                    instance.processTriggerRequestQueue(plugin.state.triggerRequestQueue);
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
            catch (NomException e)
            {
                logger.warningf(`Nom Exception: tried to nom "%s%s%s" with "%1$s%4$s%3$s"`,
                    logtint, e.haystack, warningtint, e.needle);

                if (event != IRCEvent.init)
                {
                    printObject(event);
                }
                else
                {
                    logger.warningf(`Offending line: "%s%s%s"`, logtint, attempt.line, warningtint);
                }
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
            logger.error("Internal error, thread messenger Fiber ended abruptly.");
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
            sendMessages(instance, readWasShortened);
        }
    }

    return next;
}


// sendMessages
/++
 +  Sends strings to the server from the message buffers.
 +
 +  Broken out of `mainLoop` to make it more legible.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +      readWasShortened = Flag bool of whether or not the read timeout was
 +          lowered to allow us to send a message earlier.
 +/
void sendMessages(ref Kameloso instance, ref bool readWasShortened)
{
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


import lu.net : ListenAttempt;

// listenAttemptToNext
/++
 +  Translates the `lu.net.ListenAttempt.state` received from a
 +  `std.concurrency.Generator` into a `kameloso.common.Next`, while also providing
 +  warnings and error messages.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +      attempt = The `lu.net.ListenAttempt` to map the `.state` value of.
 +
 +  Returns:
 +      A `kameloso.common.Next` describing what action `mainLoop` should take next.
 +/
Next listenAttemptToNext(ref Kameloso instance, const ListenAttempt attempt)
{
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

    // Handle the attempt; switch on its state
    with (ListenAttempt.State)
    final switch (attempt.state)
    {
    case prelisten:  // Should never happen
        assert(0, "listener attempt yielded state prelisten");

    case isEmpty:
        // Empty line yielded means nothing received; break foreach and try again
        return Next.retry;

    case hasString:
        // hasString means we should drop down and continue processing
        return Next.continue_;

    case warning:
        // Benign socket error; break foreach and try again
        import core.thread : Thread;
        import core.time : seconds;

        logger.warningf("Connection error! (%s%s%s)", logtint,
            attempt.lastSocketError_, warningtint);

        // Sleep briefly so it won't flood the screen on chains of errors
        Thread.sleep(1.seconds);
        return Next.retry;

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

    if (!plugin.state.awaitingFibers[event.type].length) return;

    Fiber[] expiredFibers;

    foreach (immutable i, fiber; plugin.state.awaitingFibers[event.type])
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
                expiredFibers ~= fiber;
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
            expiredFibers ~= fiber;
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
            expiredFibers ~= fiber;
        }
    }

    // Clean up processed Fibers
    foreach (expiredFiber; expiredFibers)
    {
        foreach (ref fibersByType; plugin.state.awaitingFibers)
        {
            foreach_reverse (immutable i, /*ref*/ fiber; fibersByType)
            {
                import std.algorithm.mutation : SwapStrategy, remove;

                if (fiber == expiredFiber)
                {
                    fibersByType = fibersByType.remove!(SwapStrategy.unstable)(i);
                }
            }
        }

        destroy(expiredFiber);  // Overkill?
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

// processTriggerRequestQueue
/++
 +  Takes a queue of `TriggerRequest` objects and emits `WHOIS` requests for each one.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      reqs = Reference to an associative array of `TriggerRequest`s.
 +/
void processTriggerRequestQueue(ref Kameloso instance, const TriggerRequest[][string] reqs)
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
 +      customSettings = Out reference to the dynamic array of custom settings as
 +          defined with `--set plugin.setting=value` on the command line.
 +
 +  Returns:
 +      `kameloso.common.Next`.* depending on what action the calling site should take.
 +/
Next tryGetopt(ref Kameloso instance, string[] args, out string[] customSettings)
{
    import kameloso.getopt : handleGetopt;
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

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(instance.conn, settings.endlesslyConnect,
            ConnectionDefaultIntegers.retries, *instance.abort));
    uint incrementedRetryDelay = Timeout.retry;

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
                (parser.server.address == resolvedHost) ||
                (sharedDomains(parser.server.address, resolvedHost) < 2)) ?
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
            logger.logf("Failed to connect to IP. Trying next IP in %s%d%s seconds.",
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
 +  Tries to resolve the address in `instance.parser.server` to IPs, by
 +  leveraging `lu.net.resolveFiber`, reacting on the
 +  `lu.net.ResolveAttempt`s it yields to provide feedback to the user.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      firstConnect = Whether or not this is the first time we're attempting a connection.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` if resolution succeeded,
 +      `kameloso.common.Next.returnFailure` if it failed and the program should exit.
 +/
Next tryResolve(ref Kameloso instance, const bool firstConnect)
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

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(instance.conn, instance.parser.server.address,
        instance.parser.server.port, settings.ipv6, resolveAttempts, *instance.abort));

    uint incrementedRetryDelay = Timeout.retry;
    enum incrementMultiplier = 1.2;

    void delayOnNetworkDown(const ResolveAttempt attempt)
    {
        if (attempt.retryNum+1 < resolveAttempts)
        {
            import kameloso.thread : interruptibleSleep;
            import core.time : seconds;

            logger.logf("Network down? Retrying in %s%d%s seconds.",
                infotint, incrementedRetryDelay, logtint);
            interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);
            if (*instance.abort) return;

            import std.algorithm.comparison : min;

            enum delayCap = 10*60;  // seconds
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay, delayCap);
        }
    }

    with (instance)
    foreach (const attempt; resolver)
    {
        with (ResolveAttempt.State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            import lu.string : plurality;
            logger.infof("%s%s resolved into %s%s%2$s %5$s.",
                parser.server.address, logtint, infotint, conn.ips.length,
                conn.ips.length.plurality("IP", "IPs"));
            return Next.continue_;

        case exception:
            logger.warningf("Could not resolve server address. (%s%s%s)",
                logtint, attempt.error, warningtint);
            delayOnNetworkDown(attempt);
            if (*instance.abort) return Next.returnFailure;
            continue;

        case error:
            logger.errorf("Could not resolve server address. (%s%s%s)",
                logtint, attempt.error, errortint);

            if (firstConnect)
            {
                // First attempt and a failure; something's wrong, abort
                logger.logf("Failed to resolve host. Verify that you are connected to " ~
                    "the Internet and that the server address (%s%s%s) is correct.",
                    infotint, parser.server.address, logtint);
                return Next.returnFailure;
            }
            else
            {
                // Not the first attempt yet failure; transient error? retry
                delayOnNetworkDown(attempt);
                if (*instance.abort) return Next.returnFailure;
                continue;
            }

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
 +      binaryPath = Full path to the current binary.
 +/
void complainAboutMissingConfiguration(const string binaryPath)
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
            infotint, binaryPath.baseName, logtint);
    }
}


// preInstanceSetup
/++
 +  Sets up the program (terminal) environment.
 +
 +  Depending on your platform it may set any of thread name, terminal title and
 +  console codepages.
 +
 +  This is called very early during execution.
 +/
void preInstanceSetup()
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
}


// setupSettings
/++
 +  Sets up `kameloso.common.settings`, expanding paths and more.
 +
 +  This is called during early execution.
 +/
void setupSettings()
{
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
}


// verifySettings
/++
 +  Verifies some settings and returns whether the program should continue
 +  executing (or whether there were errors such that we should exit).
 +
 +  This is called after command-line arguments have been parsed.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +
 +  Returns:
 +      `Next.returnFailure` if the program should exit, `Next.continue_` otherwise.
 +/
Next verifySettings(ref Kameloso instance)
{
    if (!settings.force)
    {
        IRCServer conservativeServer;
        conservativeServer.maxNickLength = 25;  // Twitch max, should be enough

        if (!instance.parser.client.nickname.isValidNickname(conservativeServer))
        {
            // No need to print the nickname, visible from printObjects preivously
            logger.error("Invalid nickname!");
            return Next.returnFailure;
        }

        if (!settings.prefix.length)
        {
            logger.error("No prefix configured!");
            return Next.returnFailure;
        }
    }

    version(Posix)
    {
        import lu.string : contains;

        // Workaround for Issue 19247:
        // Segmentation fault when resolving address with std.socket.getAddress inside a Fiber
        // the workaround being never resolve addresses that don't contain at least one dot
        immutable addressIsResolvable = instance.parser.server.address.contains('.');
    }
    else
    {
        // On Windows this doesn't happen, so allow all addresses.
        enum addressIsResolvable = true;
    }

    if (!settings.force && !addressIsResolvable)
    {
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

        logger.errorf("Invalid address! [%s%s%s]", logtint,
            instance.parser.server.address, errortint);
        return Next.returnFailure;
    }

    return Next.continue_;
}


// resolveResourceDirectory
/++
 +  Resolves resource directories verbosely.
 +
 +  This is called after settings have been verified, before plugins are initialised.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +/
void resolveResourceDirectory(ref Kameloso instance)
{
    import std.file : exists;
    import std.path : buildNormalizedPath, dirName;

    // Resolve and create the resource directory
    settings.resourceDirectory = buildNormalizedPath(settings.resourceDirectory,
        "server", instance.parser.server.address);
    settings.configDirectory = settings.configFile.dirName;

    if (!settings.resourceDirectory.exists)
    {
        import std.file : mkdirRecurse;

        string infotint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;
                infotint = (cast(KamelosoLogger)logger).infotint;
            }
        }

        mkdirRecurse(settings.resourceDirectory);
        logger.logf("Created resource directory %s%s", infotint, settings.resourceDirectory);
    }
}


// startBot
/++
 +  Main connection logic.
 +
 +  This function *starts* the bot, after it has been sufficiently initialised.
 +  It resolves and connects to servers, then hands off execution to `mainLoop`.
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`.
 +      attempt = Voldemort aggregate of state variables used when connecting.
 +/
void startBot(Attempt)(ref Kameloso instance, ref Attempt attempt)
{
    string logtint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    with (attempt)
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

        immutable actionAfterResolve = tryResolve(instance, firstConnect);
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

        // Reinit with its own server.
        instance.parser = IRCParser(backupClient, instance.parser.server);

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
    /// Voldemort aggregate of state variables.
    struct Attempt
    {
        /// Enum denoting what we should do next loop.
        Next next;

        /++
         +  An array for `handleGetopt` to fill by ref with custom settings
         +  set on the command-line using `--set plugin.setting=value`.
         +/
        string[] customSettings;

        /++
         +  Bool whether this is the first connection attempt or if we have
         +  connected at least once already.
         +/
        bool firstConnect = true;

        /// Whether or not "Exiting..." should be printed at program exit.
        bool silentExit;

        /// Shell return value to exit with.
        int retval;
    }

    // Set up the terminal environment.
    preInstanceSetup();

    // Initialise the main Kameloso. Set its abort pointer to the global abort.
    Kameloso instance;
    instance.abort = &abort;
    Attempt attempt;

    // Set up `kameloso.common.settings`, expanding paths.
    setupSettings();

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

    immutable actionAfterGetopt = instance.tryGetopt(args, attempt.customSettings);

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

    import kameloso.common : applyDefaults;

    // Apply some defaults to empty members, as stored in `kameloso.constants`.
    // It's done before in tryGetopt but do it again to ensure we don't have an empty nick etc
    // Skip if --force was passed.
    if (!settings.force) applyDefaults(instance.parser.client, instance.parser.server);

    string pre, post, infotint, logtint, warningtint, errortint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            import kameloso.terminal : TerminalForeground, colour;

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

    // Print the current settings to show what's going on.
    printObjects(instance.parser.client, instance.bot, instance.parser.server);

    if (!instance.bot.homes.length && !instance.bot.admins.length)
    {
        complainAboutMissingConfiguration(args[0]);
    }

    // Verify that settings are as they should be (nickname exists and not too long, etc)
    immutable actionAfterVerification = instance.verifySettings();

    with (Next)
    final switch (actionAfterVerification)
    {
    case continue_:
        break;

    case retry:  // should never happen
        assert(0, "verifySettings returned Next.retry");

    case returnSuccess:
        return 0;

    case returnFailure:
        return 1;
    }

    // Resolve resource directory paths.
    instance.resolveResourceDirectory();

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Initialise plugins outside the loop once, for the error messages
    import kameloso.plugins.common : IRCPluginSettingsException;
    import std.conv : ConvException;

    try
    {
        const invalidEntries = instance.initPlugins(attempt.customSettings);
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

    // Go!
    instance.startBot(attempt);

    // If we're here, we should exit. The only question is in what way.

    if (*instance.abort && instance.conn.connected)
    {
        // Connected and aborting

        if (!settings.hideOutgoing)
        {
            version(Colours)
            {
                import kameloso.irccolours : mapEffects;
                logger.trace("--> QUIT :", instance.bot.quitReason.mapEffects);
            }
            else
            {
                import kameloso.irccolours : stripEffects;
                logger.trace("--> QUIT :", instance.bot.quitReason.stripEffects);
            }
        }

        instance.conn.sendline("QUIT :" ~ instance.bot.quitReason);
    }
    else if (!*instance.abort && (attempt.next == Next.returnFailure) &&
        !settings.reconnectOnFailure)
    {
        // Didn't Ctrl+C, did return failure and shouldn't reconnect
        logger.logf("(Not reconnecting due to %sreconnectOnFailure%s not being enabled)", infotint, logtint);
    }

    // Save if we're exiting and configuration says we should.
    if (settings.saveOnExit)
    {
        instance.writeConfigurationFile(settings.configFile);
    }

    // The connection history may be empty if exitSummary was set mid-execution.
    if (settings.exitSummary && instance.connectionHistory.length)
    {
        instance.printSummary();
    }

    if (*instance.abort)
    {
        // Ctrl+C
        logger.error("Aborting...");
        return 1;
    }
    else if (!attempt.silentExit)
    {
        logger.info("Exiting...");
    }

    return attempt.retval;
}


// printSummary
/++
 +  Prints a summary of the connection(s) made and events parsed this execution.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +/
void printSummary(const ref Kameloso instance)
{
    import std.stdio : writefln;
    import core.time : Duration;

    Duration totalTime;

    logger.trace("---");
    logger.info("Connection summary:");

    string logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            import kameloso.terminal : TerminalForeground, colour;

            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    foreach (immutable i, const entry; instance.connectionHistory)
    {
        import std.datetime.systime : SysTime;
        import core.time : msecs;

        auto start = SysTime.fromUnixTime(entry.startTime);
        start.fracSecs = 0.msecs;
        auto stop = SysTime.fromUnixTime(entry.stopTime);
        stop.fracSecs = 0.msecs;
        immutable duration = (stop - start);
        totalTime += duration;

        writefln("%2d: %s, %d events parsed (%s to %s)",
            i+1, duration, entry.numEvents, start, stop);
    }

    logger.info("Total time connected: ", logtint, totalTime);
    logger.trace("---");
}

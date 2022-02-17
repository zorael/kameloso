/++
    The main module, housing startup logic and the main event loop.

    No module (save [kameloso.entrypoint]) should be importing this.

    See_Also:
        [kameloso.kameloso]
        [kameloso.common]
        [kameloso.config]
 +/
module kameloso.main;

private:

import kameloso.kameloso : Kameloso, CoreSettings;
import kameloso.common : Tint, logger;
import kameloso.plugins.common.core : IRCPlugin, Replay;
import dialect.defs;
import lu.common : Next;
import std.typecons : Flag, No, Yes;


version(ProfileGC)
{
    static if (__VERSION__ >= 2085L)
    {
        /++
            Set some flags to tune the garbage collector and have it print
            profiling information at program exit, iff version `ProfileGC`.
            Enables the precise garbage collector.
         +/
        extern(C)
        public __gshared string[] rt_options =
        [
            "gcopt=profile:1 gc:precise",
            "scanDataSeg=precise",
        ];
    }
    else
    {
        /++
            Set some flags to tune the garbage collector and have it print
            profiling information at program exit, iff version `ProfileGC`.
         +/
        extern(C)
        public __gshared string[] rt_options =
        [
            "gcopt=profile:1",
        ];
    }
}


// globalAbort
/++
    Abort flag.

    This is set when the program is interrupted (such as via Ctrl+C). Other
    parts of the program will be monitoring it, to take the cue and abort when
    it is set.

    Must be `__gshared` or it doesn't seem to work on Windows.
 +/
public __gshared bool globalAbort;


// globalHeadless
/++
    Headless flag.

    If this is true the program should not output anything to the terminal.
 +/
public __gshared bool globalHeadless;


version(Posix)
{
    // signalRaised
    /++
        The value of the signal, when the process was sent one that meant it
        should abort. This determines the shell exit code to return.
     +/
    private int signalRaised;
}


// signalHandler
/++
    Called when a signal is raised, usually `SIGINT`.

    Sets the [globalAbort] variable to true so other parts of the program knows to
    gracefully shut down.

    Params:
        sig = Integer value of the signal raised.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.stdio : printf;

    // $ kill -l
    // https://man7.org/linux/man-pages/man7/signal.7.html
    static immutable string[32] signalNames =
    [
         0 : "<err>", /// Should never happen.
         1 : "HUP",   /// Hangup detected on controlling terminal or death of controlling process.
         2 : "INT",   /// Interrupt from keyboard.
         3 : "QUIT",  /// Quit from keyboard.
         4 : "ILL",   /// Illegal instruction.
         5 : "TRAP",  /// Trace/breakpoint trap.
         6 : "ABRT",  /// Abort signal from `abort(3)`.
         7 : "BUS",   /// Bus error: access to an undefined portion of a memory object.
         8 : "FPE",   /// Floating-point exception.
         9 : "KILL",  /// Kill signal.
        10 : "USR1",  /// User-defined signal 1.
        11 : "SEGV",  /// Invalid memory reference.
        12 : "USR2",  /// User-defined signal 2.
        13 : "PIPE",  /// Broken pipe: write to pipe with no readers.
        14 : "ALRM",  /// Timer signal from `alarm(2)`.
        15 : "TERM",  /// Termination signal.
        16 : "STKFLT",/// Stack fault on coprocessor. (unused?)
        17 : "CHLD",  /// Child stopped or terminated.
        18 : "CONT",  /// Continue if stopped.
        19 : "STOP",  /// Stop process.
        20 : "TSTP",  /// Stop typed at terminal.
        21 : "TTIN",  /// Terminal input for background process.
        22 : "TTOU",  /// Terminal output for background process.
        23 : "URG",   /// Urgent condition on socket. (4.2 BSD)
        24 : "XCPU",  /// CPU time limit exceeded. (4.2 BSD)
        25 : "XFSZ",  /// File size limit exceeded. (4.2 BSD)
        26 : "VTALRM",/// Virtual alarm clock. (4.2 BSD)
        27 : "PROF",  /// Profile alarm clock.
        28 : "WINCH", /// Window resize signal. (4.3 BSD, Sun)
        29 : "POLL",  /// Pollable event; a synonym for `SIGIO`: I/O now possible. (System V)
        30 : "PWR",   /// Power failure. (System V)
        31 : "SYS",   /// Bad system call. (SVr4)
    ];

    if (!globalHeadless) printf("...caught signal SIG%s!\n", signalNames[sig].ptr);
    globalAbort = true;

    version(Posix)
    {
        signalRaised = sig;
    }

    // Restore signal handlers to the default
    resetSignals();
}


// messageFiber
/++
    A Generator Fiber function that checks for concurrency messages and performs
    action based on what was received.

    The return value yielded to the caller tells it whether the received action
    means the bot should exit or not.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
 +/
void messageFiber(ref Kameloso instance)
{
    import kameloso.common : OutgoingLine, replaceTokens;
    import kameloso.messaging : Message;
    import kameloso.thread : Sendable, ThreadMessage;
    import std.concurrency : yield;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. We're not ready for that yet, so catch the next
    // yield (which is upon messenger.call()).
    yield(Next.init);

    // Loop forever; we'll just terminate the Generator when we want to quit.
    while (true)
    {
        Next next;

        alias Quiet = Flag!"quiet";

        /// Send a message to the server bypassing throttling.
        void immediateline(ThreadMessage.Immediateline, string line) scope
        {
            instance.immediateBuffer.put(OutgoingLine(line, cast(Quiet)instance.settings.hideOutgoing));
        }

        /// Echo a line to the terminal and send it to the server.
        void sendline(ThreadMessage.Sendline, string line) scope
        {
            instance.outbuffer.put(OutgoingLine(line, cast(Quiet)instance.settings.hideOutgoing));
        }

        /// Send a line to the server without echoing it.
        void quietline(ThreadMessage.Quietline, string line) scope
        {
            instance.outbuffer.put(OutgoingLine(line, Yes.quiet));
        }

        /// Respond to `PING` with `PONG` to the supplied text as target.
        void pong(ThreadMessage.Pong, string target) scope
        {
            instance.outbuffer.put(OutgoingLine("PONG :" ~ target, Yes.quiet));
        }

        /// Quit the server with the supplied reason, or the default.
        void quitServer(ThreadMessage.Quit, string givenReason,
            Flag!"quiet" quiet) scope
        {
            // This will automatically close the connection.
            immutable reason = givenReason.length ? givenReason : instance.bot.quitReason;
            instance.priorityBuffer.put(OutgoingLine("QUIT :" ~
                reason.replaceTokens(instance.parser.client), quiet));
            next = Next.returnSuccess;
        }

        /// Disconnects from and reconnects to the server.
        void reconnect(ThreadMessage.Reconnect) scope
        {
            instance.priorityBuffer.put(OutgoingLine("QUIT :Reconnecting.", No.quiet));
            next = Next.retry;
        }

        /// Saves current configuration to disk.
        void save(ThreadMessage.Save) scope
        {
            import kameloso.config : writeConfigurationFile;
            instance.writeConfigurationFile(instance.settings.configFile);
        }

        /++
           Constructs an associative array of all commands of all plugins and
           calls the passed delegate with it as argument.
        +/
        void peekCommands(ThreadMessage.PeekCommands,
            shared void delegate(IRCPlugin.CommandMetadata[string][string]) dg)
        {
            IRCPlugin.CommandMetadata[string][string] commandAA;

            foreach (plugin; instance.plugins)
            {
                commandAA[plugin.name] = plugin.commands;
            }

            dg(commandAA);
        }

        /++
            Applies a `plugin.setting=value` change in setting to whichever plugin
            matches the expression.

            For some reason the sending site really really wants the delegate to
            be `@safe`, so we'll just have to cater to its whims:

            Main thread message fiber received unknown Variant:
            std.typecons.Tuple!(kameloso.thread.ThreadMessage.ChangeSetting,
                shared(void delegate(bool) @safe), immutable(char)[]).Tuple
         +/
        void changeSetting(ThreadMessage.ChangeSetting,
            shared(void delegate(bool) @safe) dg, string expression)
        {
            import kameloso.plugins.common.misc : applyCustomSettings;

            // Borrow settings from the first plugin. It's taken by value
            immutable success = applyCustomSettings(instance.plugins,
                [ expression ], instance.plugins[0].state.settings);
            dg(success);
        }

        /// Reloads a particular plugin, or all if no plugin name passed.
        void reloadSpecificPlugin(ThreadMessage.Reload, string pluginToReload) scope
        {
            foreach (plugin; instance.plugins)
            {
                if (!plugin.isEnabled) continue;

                try
                {
                    if (!pluginToReload.length || (plugin.name == pluginToReload))
                    {
                        plugin.reload();
                    }
                }
                catch (Exception e)
                {
                    enum pattern = "The %s%s%s plugin threw an exception when reloading: %1$s%4$s";
                    logger.errorf(pattern, Tint.log, plugin.name, Tint.error, e.msg);
                    version(PrintStacktraces) logger.trace(e);
                }
            }
        }

        /// Reloads all plugins. Wraps and leverages [reloadSpecificPlugin].
        void reloadPlugins(ThreadMessage.Reload) scope
        {
            reloadSpecificPlugin(ThreadMessage.Reload(), string.init);
        }

        /// Passes a bus message to each plugin. Send to disabled plugins too.
        void dispatchBusMessage(ThreadMessage.BusMessage, string header, shared Sendable content) scope
        {
            foreach (plugin; instance.plugins)
            {
                plugin.onBusMessage(header, content);
            }
        }

        /// Passes an empty header-only bus message to each plugin. Send to disabled plugins too.
        void dispatchEmptyBusMessage(ThreadMessage.BusMessage, string header) scope
        {
            foreach (plugin; instance.plugins)
            {
                shared Sendable content;
                plugin.onBusMessage(header, content);
            }
        }

        /// Reverse-formats an event and sends it to the server.
        void eventToServer(Message m) scope
        {
            import lu.string : splitLineAtPosition;
            import std.conv : text;
            import std.format : format;

            enum maxIRCLineLength = 512-2;  // sans CRLF

            version(TwitchSupport)
            {
                immutable fast =
                    (instance.parser.server.daemon == IRCServer.Daemon.twitch) &&
                    (m.event.type != IRCEvent.Type.QUERY) &&
                    (m.properties & Message.Property.fast);
            }

            immutable background = (m.properties & Message.Property.background);
            immutable quietFlag = cast(Quiet)(instance.settings.hideOutgoing ||
                (m.properties & Message.Property.quiet));
            immutable force = (m.properties & Message.Property.forced);
            immutable priority = (m.properties & Message.Property.priority);
            immutable immediate = (m.properties & Message.Property.immediate);

            string line;
            string prelude;
            string[] lines;

            with (IRCEvent.Type)
            switch (m.event.type)
            {
            case CHAN:
                prelude = "PRIVMSG %s :".format(m.event.channel);
                lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
                break;

            case QUERY:
                version(TwitchSupport)
                {
                    if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
                    {
                        /*if (m.event.target.nickname == instance.parser.client.nickname)
                        {
                            // "You cannot whisper to yourself." (whisper_invalid_self)
                            return;
                        }*/

                        prelude = "PRIVMSG #%s :/w %s "
                            .format(instance.parser.client.nickname, m.event.target.nickname);
                    }
                }

                if (!prelude.length) prelude = "PRIVMSG %s :".format(m.event.target.nickname);
                lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
                break;

            case EMOTE:
                immutable emoteTarget = m.event.target.nickname.length ?
                    m.event.target.nickname : m.event.channel;

                version(TwitchSupport)
                {
                    if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
                    {
                        prelude = "PRIVMSG %s :/me ".format(emoteTarget);
                        lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
                    }
                }

                if (!prelude.length)
                {
                    import dialect.common : IRCControlCharacter;
                    enum pattern = "PRIVMSG %s :%cACTION %s%2$c";
                    line = format(pattern, emoteTarget, cast(char)IRCControlCharacter.ctcp, m.event.content);
                }
                break;

            case MODE:
                import lu.string : strippedRight;

                enum pattern = "MODE %s %s %s";
                line = format(pattern, m.event.channel, m.event.aux, m.event.content).strippedRight;
                break;

            case TOPIC:
                line = "TOPIC %s :%s".format(m.event.channel, m.event.content);
                break;

            case INVITE:
                line = "INVITE %s %s".format(m.event.channel, m.event.target.nickname);
                break;

            case JOIN:
                if (m.event.aux.length)
                {
                    // Key, assume only one channel
                    line = text("JOIN ", m.event.channel, ' ', m.event.aux);
                }
                else
                {
                    prelude = "JOIN ";
                    lines = m.event.channel.splitLineAtPosition(',', maxIRCLineLength-prelude.length);
                }
                break;

            case KICK:
                immutable reason = m.event.content.length ? " :" ~ m.event.content : string.init;
                enum pattern = "KICK %s %s%s";
                line = format(pattern, m.event.channel, m.event.target.nickname, reason);
                break;

            case PART:
                if (m.event.content.length)
                {
                    // Reason given, assume only one channel
                    line = text("PART ", m.event.channel, " :",
                        m.event.content.replaceTokens(instance.parser.client));
                }
                else
                {
                    prelude = "PART ";
                    lines = m.event.channel.splitLineAtPosition(',', maxIRCLineLength-prelude.length);
                }
                break;

            case NICK:
                line = "NICK " ~ m.event.target.nickname;
                break;

            case PRIVMSG:
                if (m.event.channel.length)
                {
                    goto case CHAN;
                }
                else
                {
                    goto case QUERY;
                }

            case RPL_WHOISACCOUNT:
                import kameloso.constants : Timeout;
                import std.datetime.systime : Clock;

                immutable now = Clock.currTime.toUnixTime;
                immutable then = instance.previousWhoisTimestamps.get(m.event.target.nickname, 0);
                immutable hysteresis = force ? 1 : Timeout.whoisRetry;

                version(TraceWhois)
                {
                    import std.stdio : writef, writefln, writeln;

                    enum pattern = "[TraceWhois] messageFiber caught request to " ~
                        "WHOIS \"%s\" from %s (quiet:%s, background:%s)";
                    writef(pattern, m.event.target.nickname, m.caller,
                        cast(bool)quietFlag, cast(bool)background);
                }

                if ((now - then) > hysteresis)
                {
                    version(TraceWhois)
                    {
                        writeln(" ...and actually issuing.");
                    }

                    line = "WHOIS " ~ m.event.target.nickname;
                    instance.previousWhoisTimestamps[m.event.target.nickname] = now;
                    instance.propagateWhoisTimestamps();
                }
                else
                {
                    version(TraceWhois)
                    {
                        writefln(" ...but already issued %d seconds ago.", (now - then));
                    }
                }
                break;

            case UNSET:
                line = m.event.content;
                break;

            default:
                import lu.conv : Enum;

                // Changing this to use Enum lowered compilation memory use from 4168 to 3775...
                logger.warning("No outgoing event case for type ",
                    Enum!(IRCEvent.Type).toString(m.event.type));
                break;
            }

            void appropriateline(const string finalLine)
            {
                if (immediate)
                {
                    instance.immediateBuffer.put(OutgoingLine(finalLine, quietFlag));
                    return;
                }

                version(TwitchSupport)
                {
                    if ((instance.parser.server.daemon == IRCServer.Daemon.twitch) && fast)
                    {
                        // Send a line via the fastbuffer, faster than normal sends.
                        instance.fastbuffer.put(OutgoingLine(finalLine, quietFlag));
                        return;
                    }
                }

                if (priority)
                {
                    instance.priorityBuffer.put(OutgoingLine(finalLine, quietFlag));
                }
                else if (background)
                {
                    // Send a line via the low-priority background buffer.
                    instance.backgroundBuffer.put(OutgoingLine(finalLine, quietFlag));
                }
                else if (quietFlag)
                {
                    instance.outbuffer.put(OutgoingLine(finalLine, Yes.quiet));
                }
                else
                {
                    instance.outbuffer.put(OutgoingLine(finalLine, cast(Quiet)instance.settings.hideOutgoing));
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

        /// Proxies the passed message to the [kameloso.common.logger].
        void proxyLoggerMessages(ThreadMessage.TerminalOutput logLevel, string message) scope
        {
            if (instance.settings.headless) return;

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

        /++
            Lowers the Socket read timeout temporarily, increasing responsiveness.
         +/
        void shortenReceiveTimeout(ThreadMessage.ShortenReceiveTimeout) scope
        {
            instance.wantReceiveTimeoutShortened = true;
        }

        /++
            Sets the `instance.wantsLiveSummary` flag to true, causing the main
            loop to print a connection summary to the terminal on the next iteration.
         +/
        void flagWantLiveSummary(ThreadMessage.WantLiveSummary) scope
        {
            instance.wantLiveSummary = true;
        }

        /++
            Sets the `instance.abort` flag to true, signaling the rest of the
            program to abort.
         +/
        void flagAbort(ThreadMessage.Abort) scope
        {
            *instance.abort = true;
        }

        import std.datetime.systime : Clock;
        import core.time : Duration, seconds;

        /// Did the concurrency receive catch something?
        bool receivedSomething;

        /// Timestamp of when the loop started.
        immutable loopStartTime = Clock.currTime;

        static immutable instant = Duration.zero;
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
                &shortenReceiveTimeout,
                &quitServer,
                &save,
                &reloadPlugins,
                &reloadSpecificPlugin,
                &peekCommands,
                &changeSetting,
                &reconnect,
                &dispatchBusMessage,
                &dispatchEmptyBusMessage,
                &flagWantLiveSummary,
                &flagAbort,
                (Variant v) scope
                {
                    // Caught an unhandled message
                    logger.warning("Main thread message fiber received unknown Variant: ", v.type);
                }
            );
        }
        while (!*instance.abort &&
            receivedSomething &&
            (next == Next.continue_) &&
            ((Clock.currTime - loopStartTime) <= oneSecond));

        yield(next);
    }

    assert(0, "`while (true)` loop break in `messageFiber`");
}


// mainLoop
/++
    This loops creates a [std.concurrency.Generator] [core.thread.fiber.Fiber] to loop
    over the connected [std.socket.Socket].

    Full lines are stored in [kameloso.net.ListenAttempt]s, which are
    yielded in the [std.concurrency.Generator] to be caught here, consequently
    parsed into [dialect.defs.IRCEvent]s, and then dispatched to all plugins.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].

    Returns:
        [lu.common.Next.returnFailure] if circumstances mean the bot
        should exit with a non-zero exit code,
        [lu.common.Next.returnSuccess] if it should exit by returning `0`,
        [lu.common.Next.retry] if the bot should reconnect to the server.
        [lu.common.Next.continue_] is never returned.
 +/
Next mainLoop(ref Kameloso instance)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ListenAttempt, listenFiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock;

    /// Variable denoting what we should do next loop.
    Next next;

    alias State = ListenAttempt.State;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(instance.conn, *instance.abort, Timeout.connectionLost));
    scope(exit) listener.reset();

    auto messenger = new Generator!Next(() =>
        messageFiber(instance));
    scope(exit) messenger.reset();

    /// The history entry for the current connection.
    Kameloso.ConnectionHistoryEntry* historyEntry;

    immutable historyEntryIndex = instance.connectionHistory.length;  // snapshot index, 0 at first
    instance.connectionHistory ~= Kameloso.ConnectionHistoryEntry.init;
    historyEntry = &instance.connectionHistory[historyEntryIndex];
    historyEntry.startTime = Clock.currTime.toUnixTime;
    historyEntry.stopTime = historyEntry.startTime;  // In case we abort before the first read is recorded

    /// UNIX timestamp of when the Socket receive timeout was shortened.
    long timeWhenReceiveWasShortened;

    // Set wantLiveSummary to false just in case a change happened in the middle
    // of the last connection. Otherwise the first thing to happen would be
    // that a summary gets printed.
    instance.wantLiveSummary = false;

    /// `Timeout.maxShortenDurationMsecs` in hecto-nanoseconds.
    enum maxShortenDurationHnsecs = Timeout.maxShortenDurationMsecs * 10_000;

    do
    {
        import core.thread : Fiber;

        if (*instance.abort) return Next.returnFailure;

        if (!instance.settings.headless && instance.wantLiveSummary)
        {
            // Live connection summary requested.
            instance.printSummary();
            instance.wantLiveSummary = false;
        }

        if (listener.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected by itself; reconnect
            return Next.retry;
        }

        immutable now = Clock.currTime;
        immutable nowInUnix = now.toUnixTime;
        immutable nowInHnsecs = now.stdTime;

        /// The timestamp of the next scheduled delegate or fiber across all plugins.
        long nextGlobalScheduledTimestamp;

        /// Whether or not blocking was disabled on the socket to force an instant read timeout.
        bool socketBlockingDisabled;

        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            if (!plugin.state.scheduledFibers.length &&
                !plugin.state.scheduledDelegates.length) continue;

            if (plugin.state.nextScheduledTimestamp <= nowInHnsecs)
            {
                plugin.processScheduledDelegates(nowInHnsecs);
                plugin.processScheduledFibers(nowInHnsecs);
                plugin.state.updateSchedule();  // Something is always removed
                instance.conn.socket.blocking = false;  // Instantly timeout read to check messages
                socketBlockingDisabled = true;
            }

            if (!nextGlobalScheduledTimestamp ||
                (plugin.state.nextScheduledTimestamp < nextGlobalScheduledTimestamp))
            {
                nextGlobalScheduledTimestamp = plugin.state.nextScheduledTimestamp;
            }
        }

        // Set timeout *before* the receive, else we'll just be applying the delay too late
        if (nextGlobalScheduledTimestamp)
        {
            immutable delayToNextMsecs =
                cast(uint)((nextGlobalScheduledTimestamp - nowInHnsecs) / 10_000);

            if (delayToNextMsecs < instance.conn.receiveTimeout)
            {
                instance.conn.receiveTimeout = (delayToNextMsecs > 0) ?
                    delayToNextMsecs : 1;
            }
        }

        // Once every 24h, clear the `previousWhoisTimestamps` AA.
        // That should be enough to stop it from being a memory leak.
        if ((nowInUnix % 86_400) == 0)
        {
            instance.previousWhoisTimestamps = null;
            instance.propagateWhoisTimestamps();
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
                historyEntry.bytesReceived += attempt.bytesReceived;
                historyEntry.stopTime = nowInUnix;
                // Drop down and continue
                break;

            case retry:
                // Break and try again
                historyEntry.stopTime = nowInUnix;
                break listenerloop;

            case returnSuccess:
                assert(0, "`listenAttemptToNext` returned `Next.returnSuccess`");

            case returnFailure:
                return Next.returnFailure;

            case crash:
                assert(0, "`listenAttemptToNext` returned `Next.crash`");
            }

            instance.processLineFromServer(attempt.line, nowInUnix);
            ++historyEntry.numEvents;
        }

        // Check concurrency messages to see if we should exit, else repeat
        try
        {
            messenger.call();
        }
        catch (Exception e)
        {
            enum pattern = "Unhandled messenger exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)";
            logger.warningf(pattern, Tint.log, e.msg, Tint.warning, e.file, e.line);
            version(PrintStacktraces) logger.trace(e);
        }

        if (messenger.state == Fiber.State.HOLD)
        {
            next = messenger.front;
        }
        else
        {
            logger.error("Internal error, thread messenger Fiber ended abruptly.");
            next = Next.returnFailure;
        }

        bool bufferHasMessages = (
            !instance.outbuffer.empty |
            !instance.backgroundBuffer.empty |
            !instance.immediateBuffer.empty |
            !instance.priorityBuffer.empty);

        version(TwitchSupport)
        {
            bufferHasMessages |= !instance.fastbuffer.empty;
        }

        /// Adjusted receive timeout based on outgoing message buffers.
        uint timeoutFromMessages = uint.max;

        if (bufferHasMessages)
        {
            immutable untilNext = sendLines(instance);

            if ((untilNext > 0.0) && (untilNext < instance.connSettings.messageBurst))
            {
                immutable untilNextMsecs = cast(uint)(untilNext * 1000);

                if (untilNextMsecs < instance.conn.receiveTimeout)
                {
                    timeoutFromMessages = untilNextMsecs;
                }
            }
        }

        if (instance.wantReceiveTimeoutShortened)
        {
            // Set the timestamp and unset the bool
            instance.wantReceiveTimeoutShortened = false;
            timeWhenReceiveWasShortened = nowInHnsecs;
        }

        if (timeWhenReceiveWasShortened &&
            (nowInHnsecs > (timeWhenReceiveWasShortened + maxShortenDurationHnsecs)))
        {
            // Shortened duration passed, reset timestamp to disable it
            timeWhenReceiveWasShortened = 0L;
        }

        if ((timeoutFromMessages < uint.max) || nextGlobalScheduledTimestamp ||
            timeWhenReceiveWasShortened)
        {
            import kameloso.constants : ConnectionDefaultFloats;
            import std.algorithm.comparison : min;

            immutable defaultTimeout = timeWhenReceiveWasShortened ?
                cast(uint)(Timeout.receiveMsecs * ConnectionDefaultFloats.receiveShorteningMultiplier) :
                instance.connSettings.receiveTimeout;

            immutable untilNextGlobalScheduled = nextGlobalScheduledTimestamp ?
                cast(uint)(nextGlobalScheduledTimestamp - nowInHnsecs)/10_000 :
                uint.max;

            immutable supposedNewTimeout =
                min(defaultTimeout, timeoutFromMessages, untilNextGlobalScheduled);

            if (supposedNewTimeout != instance.conn.receiveTimeout)
            {
                instance.conn.receiveTimeout = (supposedNewTimeout > 0) ?
                    supposedNewTimeout : 1;
            }
        }

        if (socketBlockingDisabled)
        {
            // Restore blocking behaviour.
            instance.conn.socket.blocking = true;
        }
    }
    while (next == Next.continue_);

    return next;
}


// sendLines
/++
    Sends strings to the server from the message buffers.

    Broken out of [mainLoop] to make it more legible.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].

    Returns:
        How many milliseconds until the next message in the buffers should be sent.
 +/
double sendLines(ref Kameloso instance)
{
    if (!instance.immediateBuffer.empty)
    {
        cast(void)instance.throttleline(instance.immediateBuffer, No.dryRun, No.sendFaster, Yes.immediate);
    }

    if (!instance.priorityBuffer.empty)
    {
        immutable untilNext = instance.throttleline(instance.priorityBuffer);
        if (untilNext > 0.0) return untilNext;
    }

    version(TwitchSupport)
    {
        if (!instance.fastbuffer.empty)
        {
            immutable untilNext = instance.throttleline(instance.fastbuffer,
                No.dryRun, Yes.sendFaster);
            if (untilNext > 0.0) return untilNext;
        }
    }

    if (!instance.outbuffer.empty)
    {
        immutable untilNext = instance.throttleline(instance.outbuffer);
        if (untilNext > 0.0) return untilNext;
    }

    if (!instance.backgroundBuffer.empty)
    {
        immutable untilNext = instance.throttleline(instance.backgroundBuffer);
        if (untilNext > 0.0) return untilNext;
    }

    return 0.0;
}


import kameloso.net : ListenAttempt;

// listenAttemptToNext
/++
    Translates the [kameloso.net.ListenAttempt.State] received from a
    [std.concurrency.Generator] into a [lu.common.Next], while also providing
    warnings and error messages.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
        attempt = The [kameloso.net.ListenAttempt] to map the `.state` value of.

    Returns:
        A [lu.common.Next] describing what action [mainLoop] should take next.
 +/
Next listenAttemptToNext(ref Kameloso instance, const ListenAttempt attempt)
{
    // Handle the attempt; switch on its state
    with (ListenAttempt.State)
    final switch (attempt.state)
    {
    case prelisten:  // Should never happen
        assert(0, "listener attempt yielded state `prelisten`");

    case isEmpty:
        // Empty line yielded means nothing received; break foreach and try again
        return Next.retry;

    case hasString:
        // hasString means we should drop down and continue processing
        return Next.continue_;

    case warning:
        // Benign socket error; break foreach and try again
        import kameloso.constants : Timeout;
        import core.thread : Thread;
        import core.time : msecs;

        version(Posix)
        {
            import kameloso.common : errnoStrings;
            enum pattern = "Connection error! (%s%s%s) (%1$s%4$s%3$s)";
            logger.warningf(pattern, Tint.log, attempt.error, Tint.warning, errnoStrings[attempt.errno]);
        }
        else version(Windows)
        {
            enum pattern = "Connection error! (%s%s%s) (%1$s%4$d%3$s)";
            logger.warningf(pattern, Tint.log, attempt.error, Tint.warning, attempt.errno);
        }
        else
        {
            enum pattern = "Connection error! (%s%s%s)";
            logger.warningf(pattern, Tint.log, attempt.error, Tint.warning);
        }

        // Sleep briefly so it won't flood the screen on chains of errors
        Thread.sleep(Timeout.readErrorGracePeriodMsecs.msecs);
        return Next.retry;

    case timeout:
        // No point printing the errno, it'll just be EAGAIN or EWOULDBLOCK.
        logger.error("Connection timed out.");
        instance.conn.connected = false;
        return Next.returnFailure;

    case error:
        if (attempt.bytesReceived == 0)
        {
            //logger.error("Connection error: empty server response!");
            logger.error("Connection lost.");
        }
        else
        {
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                enum pattern = "Connection error: invalid server response! (%s%s%s) (%1$s%4$s%3$s)";
                logger.errorf(pattern, Tint.log, attempt.error, Tint.error, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Connection error: invalid server response! (%s%s%s) (%1$s%4$d%3$s)";
                logger.errorf(pattern, Tint.log, attempt.error, Tint.error, attempt.errno);
            }
            else
            {
                enum pattern = "Connection error: invalid server response! (%s%s%s)";
                logger.errorf(pattern, Tint.log, attempt.error, Tint.error);
            }
        }

        instance.conn.connected = false;
        return Next.returnFailure;
    }
}


// processLineFromServer
/++
    Processes a line read from the server, constructing an [dialect.defs.IRCEvent]
    and dispatches it to all plugins.

    Params:
        instance = The current [kameloso.kameloso.Kameloso] instance.
        raw = A raw line as read from the server.
        nowInUnix = Current timestamp in UNIX time.
 +/
void processLineFromServer(ref Kameloso instance, const string raw, const long nowInUnix)
{
    import dialect.common : IRCParseException;
    import lu.string : NomException;
    import std.utf : UTFException;
    import core.exception : UnicodeException;

    // Delay initialising the event so we don't do it twice;
    // once here, once in toIRCEvent
    IRCEvent event = void;
    bool eventWasInitialised;

    scope(failure)
    {
        import lu.string : contains;
        import std.algorithm.searching : canFind;

        if (instance.settings.headless) return;

        // Something asserted
        logger.error("scopeguard tripped.");
        printEventDebugDetails(event, raw, eventWasInitialised);

        // Print the raw line char by char if it contains non-printables
        if (raw.canFind!((c) => c < ' '))
        {
            import std.stdio : writefln;
            import std.string : representation;

            foreach (immutable c; raw.representation)
            {
                writefln("%3d: '%c'", c, cast(char)c);
            }
        }
    }

    try
    {
        // Sanitise and try again once on UTF/Unicode exceptions
        import std.encoding : sanitize;

        try
        {
            event = instance.parser.toIRCEvent(raw);
        }
        catch (UTFException e)
        {
            event = instance.parser.toIRCEvent(sanitize(raw));
            event.errors ~= (event.errors.length ? " | " : string.init) ~
                "UTFException: " ~ e.msg;
        }
        catch (UnicodeException e)
        {
            event = instance.parser.toIRCEvent(sanitize(raw));
            event.errors ~= (event.errors.length ? " | " : string.init) ~
                "UnicodeException: " ~ e.msg;
        }

        eventWasInitialised = true;

        version(TwitchSupport)
        {
            // If it's an RPL_WELCOME event, record it as having been seen so we
            // know we can't reconnect without waiting a bit.
            if (event.type == IRCEvent.Type.RPL_WELCOME)
            {
                instance.sawWelcome = true;
            }
        }

        if (instance.parser.clientUpdated)
        {
            // Parsing changed the client; propagate
            instance.parser.clientUpdated = false;
            instance.propagate(instance.parser.client);
        }

        if (instance.parser.serverUpdated)
        {
            // Parsing changed the server; propagate
            instance.parser.serverUpdated = false;
            instance.propagate(instance.parser.server);
        }

        // Save timestamp in the event itself.
        event.time = nowInUnix;

        // Let each plugin postprocess the event
        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            try
            {
                plugin.postprocess(event);
            }
            catch (NomException e)
            {
                enum pattern = `Nom Exception %s.postprocess: tried to nom "%s%s%s" with "%2$s%5$s%4$s"`;
                logger.warningf(pattern, plugin.name, Tint.log, e.haystack, Tint.warning, e.needle);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UTFException e)
            {
                enum pattern = "UTFException %s.postprocess: %s%s";
                logger.warningf(pattern, plugin.name, Tint.log, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UnicodeException e)
            {
                enum pattern = "UnicodeException %s.postprocess: %s%s";
                logger.warningf(pattern, plugin.name, Tint.log, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s.postprocess: %s%s";
                logger.warningf(pattern, plugin.name, Tint.log, e.msg);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e);
            }
            finally
            {
                if (plugin.state.updates != typeof(plugin.state.updates).nothing)
                {
                    instance.checkPluginForUpdates(plugin);
                }
            }
        }

        // Let each plugin process the event
        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            try
            {
                plugin.onEvent(event);
                if (plugin.state.hasReplays) processReplays(instance, plugin);
                if (plugin.state.reparses.length) processReparses(instance, plugin);
                processAwaitingDelegates(plugin, event);
                processAwaitingFibers(plugin, event);
                if (*instance.abort) return;  // handled in mainLoop listenerloop
            }
            catch (NomException e)
            {
                enum pattern = `Nom Exception %s: tried to nom "%s%s%s" with "%2$s%5$s%4$s"`;
                logger.warningf(pattern, plugin.name, Tint.log, e.haystack, Tint.warning, e.needle);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UTFException e)
            {
                enum pattern = "UTFException %s: %s%s";
                logger.warningf(pattern, plugin.name, Tint.log, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s: %s%s";
                logger.warningf(pattern, plugin.name, Tint.log, e.msg);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e);
            }
            finally
            {
                if (plugin.state.updates != typeof(plugin.state.updates).nothing)
                {
                    instance.checkPluginForUpdates(plugin);
                }
            }
        }

        // Take some special actions on select event types
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
            // we're a moderator. For now, just assume we're moderator
            // in all our home channels.

            import std.typecons : Flag, No, Yes;

            version(TwitchSupport)
            {
                import std.algorithm.searching : canFind;

                // Send faster in home channels. Assume we're a mod and won't be throttled.
                // (There's no easy way to tell from here.)
                if (event.channel.length && instance.bot.homeChannels.canFind(event.channel))
                {
                    instance.throttleline(instance.fastbuffer, Yes.dryRun, Yes.sendFaster);
                }
                else
                {
                    instance.throttleline(instance.outbuffer, Yes.dryRun);
                }
            }
            else
            {
                instance.throttleline(instance.outbuffer, Yes.dryRun);
            }
            break;

        case QUIT:
            // Remove users from the WHOIS history when they quit the server.
            instance.previousWhoisTimestamps.remove(event.sender.nickname);
            break;

        case NICK:
            // Transfer WHOIS history timestamp when a user changes its nickname.
            if (const timestamp = event.sender.nickname in instance.previousWhoisTimestamps)
            {
                instance.previousWhoisTimestamps[event.target.nickname] = *timestamp;
                instance.previousWhoisTimestamps.remove(event.sender.nickname);
            }
            break;

        default:
            break;
        }
    }
    catch (IRCParseException e)
    {
        enum pattern = "IRC Parse Exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)";
        logger.warningf(pattern, Tint.log, e.msg, Tint.warning, e.file, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (NomException e)
    {
        enum pattern = `Nom Exception: tried to nom "%s%s%s" with "%1$s%4$s%3$s"`;
        logger.warningf(pattern, Tint.log, e.haystack, Tint.warning, e.needle);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UTFException e)
    {
        logger.warning("UTFException: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UnicodeException e)
    {
        logger.warning("UnicodeException: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unhandled exception: %s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)";
        logger.warningf(pattern, Tint.log, e.msg, Tint.warning, e.file, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e);
    }
}


// processAwaitingDelegates
/++
    Processes the awaiting delegates of an [kameloso.plugins.common.core.IRCPlugin].

    Does not remove delegates after calling them. They are expected to remove
    themselves after finishing if they aren't awaiting any further events.

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin] whose
            [dialect.defs.IRCEvent.Type]-awaiting delegates to iterate and process.
        event = The triggering const [dialect.defs.IRCEvent].
 +/
void processAwaitingDelegates(IRCPlugin plugin, const ref IRCEvent event)
{
    import core.thread : Fiber;

    alias Dg = void delegate(const IRCEvent);

    /++
        Handle awaiting delegates of a specified type.
     +/
    static void processImpl(IRCPlugin plugin, const ref IRCEvent event, Dg[] dgsForType)
    {
        foreach (immutable i, dg; dgsForType)
        {
            try
            {
                dg(event);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s.awaitingDelegates[%d]: %s%s";
                logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
                printEventDebugDetails(event, event.raw);
                version(PrintStacktraces) logger.trace(e);
            }
        }
    }

    if (plugin.state.awaitingDelegates[event.type].length)
    {
        processImpl(plugin, event, plugin.state.awaitingDelegates[event.type]);
    }

    if (plugin.state.awaitingDelegates[IRCEvent.Type.ANY].length)
    {
        processImpl(plugin, event, plugin.state.awaitingDelegates[IRCEvent.Type.ANY]);
    }
}


// processAwaitingFibers
/++
    Processes the awaiting [core.thread.fiber.Fiber]s of an
    [kameloso.plugins.common.core.IRCPlugin].

    Don't delete [core.thread.fiber.Fiber]s, as they can be reset and reused.

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin] whose
            [dialect.defs.IRCEvent.Type]-awaiting [core.thread.fiber.Fiber]s to
            iterate and process.
        event = The triggering [dialect.defs.IRCEvent].
 +/
void processAwaitingFibers(IRCPlugin plugin, const ref IRCEvent event)
{
    import core.thread : Fiber;

    /++
        Handle awaiting Fibers of a specified type.
     +/
    static void processAwaitingFibersImpl(IRCPlugin plugin, const ref IRCEvent event,
        Fiber[] fibersForType, ref Fiber[] expiredFibers)
    {
        foreach (immutable i, fiber; fibersForType)
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
            catch (Exception e)
            {
                enum pattern = "Exception %s.awaitingFibers[%d]: %s%s";
                logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
                printEventDebugDetails(event, event.raw);
                version(PrintStacktraces) logger.trace(e);
                expiredFibers ~= fiber;
            }
        }
    }

    Fiber[] expiredFibers;

    if (plugin.state.awaitingFibers[event.type].length)
    {
        processAwaitingFibersImpl(plugin, event,
            plugin.state.awaitingFibers[event.type], expiredFibers);
    }

    if (plugin.state.awaitingFibers[IRCEvent.Type.ANY].length)
    {
        processAwaitingFibersImpl(plugin, event,
            plugin.state.awaitingFibers[IRCEvent.Type.ANY], expiredFibers);
    }

    if (!expiredFibers.length) return;

    // Clean up processed Fibers
    foreach (expiredFiber; expiredFibers)
    {
        foreach (ref fibersByType; plugin.state.awaitingFibers)
        {
            foreach_reverse (immutable i, /*ref*/ fiber; fibersByType)
            {
                import std.algorithm.mutation : SwapStrategy, remove;

                if (fiber is expiredFiber)
                {
                    fibersByType = fibersByType.remove!(SwapStrategy.unstable)(i);
                }
            }
        }
    }
}


// processScheduledDelegates
/++
    Processes the queued [kameloso.thread.ScheduledDelegate]s of an
    [kameloso.plugins.common.core.IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin] whose queued
            [kameloso.thread.ScheduledDelegate]s to iterate and process.
        nowInHnsecs = Current timestamp to compare the [kameloso.thread.ScheduledDelegate]'s
            timestamp with.
 +/
void processScheduledDelegates(IRCPlugin plugin, const long nowInHnsecs)
in ((nowInHnsecs > 0), "Tried to process queued `ScheduledDelegate`s with an unset timestamp")
{
    size_t[] toRemove;

    foreach (immutable i, scheduledDg; plugin.state.scheduledDelegates)
    {
        if (scheduledDg.timestamp > nowInHnsecs) continue;

        try
        {
            scheduledDg.dg();
        }
        catch (Exception e)
        {
            enum pattern = "Exception %s.scheduledDelegates[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }

        toRemove ~= i;  // Always removed a scheduled delegate after processing
    }

    // Clean up processed delegates
    foreach_reverse (immutable i; toRemove)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        plugin.state.scheduledDelegates = plugin.state.scheduledDelegates
            .remove!(SwapStrategy.unstable)(i);
    }
}


// processScheduledFibers
/++
    Processes the queued [kameloso.thread.ScheduledFiber]s of an
    [kameloso.plugins.common.core.IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin] whose queued
            [kameloso.thread.ScheduledFiber]s to iterate and process.
        nowInHnsecs = Current timestamp to compare the [kameloso.thread.ScheduledFiber]'s
            timestamp with.
 +/
void processScheduledFibers(IRCPlugin plugin, const long nowInHnsecs)
in ((nowInHnsecs > 0), "Tried to process queued `ScheduledFiber`s with an unset timestamp")
{
    size_t[] toRemove;

    foreach (immutable i, scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.timestamp > nowInHnsecs) continue;

        try
        {
            import core.thread : Fiber;

            if (scheduledFiber.fiber.state == Fiber.State.HOLD)
            {
                scheduledFiber.fiber.call();
            }
        }
        catch (Exception e)
        {
            enum pattern = "Exception %s.scheduledFibers[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }

        // Always removed a scheduled Fiber after processing
        toRemove ~= i;
    }

    // Clean up processed Fibers
    foreach_reverse (immutable i; toRemove)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        plugin.state.scheduledFibers = plugin.state.scheduledFibers
            .remove!(SwapStrategy.unstable)(i);
    }
}


// processReparses
/++
    Handles the reparse queue, re-postprocessing ("reparsing") events from the
    current (main loop) context, outside of any plugin.

    Params:
        instance = Reference to the current bot instance.
        plugin = The current [kameloso.plugins.common.core.IRCPlugin].
 +/
void processReparses(ref Kameloso instance, IRCPlugin plugin)
{
    import lu.string : NomException;
    import std.utf : UTFException;
    import core.exception : UnicodeException;
    import core.memory : GC;
    import core.thread : Fiber;

    foreach (immutable i, reparse; plugin.state.reparses)
    {
        version(WithPersistenceService)
        {
            // Postprocessing will reapply class, but not if there is already
            // a custom class (assuming channel cache hit)
            reparse.replay.event.sender.class_ = IRCUser.Class.unset;
            reparse.replay.event.target.class_ = IRCUser.Class.unset;
        }

        try
        {
            foreach (postprocessor; instance.plugins)
            {
                postprocessor.postprocess(reparse.replay.event);
            }
        }
        catch (NomException e)
        {
            enum pattern = "Nom Exception postprocessing %s.state.reparses[%d]: " ~
                `tried to nom "%s%s%s" with "%3$s%6$s%5$s"`;
            logger.warningf(pattern, plugin.name, i, Tint.log, e.haystack, Tint.warning, e.needle);
            printEventDebugDetails(reparse.replay.event, reparse.replay.event.raw);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (UTFException e)
        {
            enum pattern = "UTFException postprocessing %s.state.reparses[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (UnicodeException e)
        {
            enum pattern = "UnicodeException postprocessing %s.state.reparses[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (Exception e)
        {
            enum pattern = "Exception postprocessing %s.state.reparses[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            printEventDebugDetails(reparse.replay.event, reparse.replay.event.raw);
            version(PrintStacktraces) logger.trace(e);
            continue;
        }

        // If we're here no exceptions were thrown

        try
        {
            reparse.dg(reparse.replay);
        }
        catch (Exception e)
        {
            enum pattern = "Exception %s.state.reparses[%d]: %s%s";
            logger.warningf(pattern, plugin.name, i, Tint.log, e.msg);
            printEventDebugDetails(reparse.replay.event, reparse.replay.event.raw);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    // All reparses guaranteed exhausted
    plugin.state.reparses = null;
}


// processReplays
/++
    Takes a queue of [kameloso.plugins.common.core.Replay] objects and issues WHOIS queries for each one,
    unless it has already been done recently (within
    [kameloso.constants.Timeout.whoisRetry] seconds).

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
        plugin = The relevant [kameloso.plugins.common.core.IRCPlugin].
 +/
void processReplays(ref Kameloso instance, IRCPlugin plugin)
{
    import kameloso.common : OutgoingLine;
    import kameloso.constants : Timeout;
    import std.datetime.systime : Clock;

    // Walk through replays and call WHOIS on those that haven't been
    // WHOISed in the last Timeout.whoisRetry seconds

    immutable now = Clock.currTime.toUnixTime;

    foreach (immutable nickname, const replaysForNickname; plugin.state.replays)
    {
        assert(nickname.length, "Empty nickname in replay queue");

        version(TraceWhois)
        {
            import std.stdio : writef, writefln, writeln;

            if (!instance.settings.headless)
            {
                import std.algorithm.iteration : map;

                auto callerNames = replaysForNickname.map!(replay => replay.caller);
                enum pattern = "[TraceWhois] processReplays saw request to " ~
                    "WHOIS \"%s\" from: %-(%s, %)";
                writef(pattern, nickname, callerNames);
            }
        }

        immutable then = instance.previousWhoisTimestamps.get(nickname, 0);

        if ((now - then) > Timeout.whoisRetry)
        {
            version(TraceWhois)
            {
                if (!instance.settings.headless) writeln(" ...and actually issuing.");
            }

            instance.outbuffer.put(OutgoingLine("WHOIS " ~ nickname,
                cast(Flag!"quiet")instance.settings.hideOutgoing));
            instance.previousWhoisTimestamps[nickname] = now;
            instance.propagateWhoisTimestamps();
        }
        else
        {
            version(TraceWhois)
            {
                writefln(" ...but already issued %d seconds ago.", (now - then));
            }
        }
    }
}


// setupSignals
/++
    Registers some process signals to redirect to our own [signalHandler], so we
    can (for instance) catch Ctrl+C and gracefully shut down.

    On Posix, additionally ignore `SIGPIPE` so that we can catch SSL errors and
    not just immediately terminate.
 +/
void setupSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIGINT, SIGTERM;

    signal(SIGINT, &signalHandler);
    signal(SIGTERM, &signalHandler);

    version(Posix)
    {
        import core.sys.posix.signal : SIG_IGN, SIGHUP, SIGPIPE, SIGQUIT;

        signal(SIGHUP, &signalHandler);
        signal(SIGQUIT, &signalHandler);
        signal(SIGPIPE, SIG_IGN);
    }
}


// resetSignals
/++
    Resets signal handlers to the system default.
 +/
void resetSignals() nothrow @nogc
{
    import core.stdc.signal : signal, SIG_DFL, SIGINT, SIGTERM;

    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);

    version(Posix)
    {
        import core.sys.posix.signal : SIGHUP, SIGQUIT;

        signal(SIGHUP, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
    }
}


// tryGetopt
/++
    Attempt handling `getopt`, wrapped in try-catch blocks.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
        args = The arguments passed to the program.
        customSettings = Out reference to the dynamic array of custom settings as
            specified with `--set plugin.setting=value` on the command line.

    Returns:
        [lu.common.Next].* depending on what action the calling site should take.
 +/
Next tryGetopt(ref Kameloso instance, string[] args, out string[] customSettings)
{
    import kameloso.config : ConfigurationFileReadFailureException, handleGetopt;
    import lu.common : FileTypeMismatchException;
    import lu.serialisation : DeserialisationException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;
    import std.process : ProcessException;

    try
    {
        // Act on arguments getopt, pass return value to main
        return instance.handleGetopt(args, customSettings);
    }
    catch (GetOptException e)
    {
        logger.error("Error parsing command-line arguments: ", Tint.log, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConvException e)
    {
        logger.error("Error converting command-line arguments: ", Tint.log, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (FileTypeMismatchException e)
    {
        enum pattern = "Specified configuration file %s%s%s is not a file!";
        logger.errorf(pattern, Tint.log, e.filename, Tint.error);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConfigurationFileReadFailureException e)
    {
        enum pattern = "Error reading and decoding configuration file [%s%s%s]: %1$s%4$s";
        logger.errorf(pattern, Tint.log, e.filename, Tint.error, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (DeserialisationException e)
    {
        logger.error("Error parsing configuration file: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ProcessException e)
    {
        enum pattern = "Failed to open %s%s%s in an editor: %1$s%4$s";
        logger.errorf(pattern, Tint.log, instance.settings.configFile, Tint.error, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        logger.error("Unexpected exception: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e);
    }

    return Next.returnFailure;
}


// tryConnect
/++
    Tries to connect to the IPs in [kameloso.kameloso.Kameloso.conn.ips] by
    leveraging [kameloso.net.connectFiber], reacting on the
    [kameloso.net.ConnectAttempt]s it yields to provide feedback to the user.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].

    Returns:
        [lu.common.Next.continue_] if connection succeeded,
        [lu.common.Next.returnFailure] if connection failed and the
        program should exit.
 +/
Next tryConnect(ref Kameloso instance)
{
    import kameloso.constants : ConnectionDefaultIntegers, ConnectionDefaultFloats, Timeout;
    import kameloso.net : ConnectionAttempt, connectFiber;
    import kameloso.thread : interruptibleSleep;
    import std.concurrency : Generator;

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(instance.conn, ConnectionDefaultIntegers.retries, *instance.abort));
    scope(exit) connector.reset();

    connector.call();

    uint incrementedRetryDelay = Timeout.connectionRetry;

    foreach (const attempt; connector)
    {
        import lu.string : beginsWith;
        import core.time : seconds;

        if (*instance.abort) return Next.returnFailure;

        immutable lastRetry = (attempt.retryNum+1 == ConnectionDefaultIntegers.retries);

        enum unableToConnectString = "Unable to connect socket: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.beginsWith(unableToConnectString) ?
                attempt.error[unableToConnectString.length..$] :
                attempt.error) :
            string.init;

        void verboselyDelay()
        {
            enum pattern = "Retrying in %s%d%s seconds...";
            logger.logf(pattern, Tint.info, incrementedRetryDelay, Tint.log);
            interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);

            import std.algorithm.comparison : min;
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay *
                ConnectionDefaultFloats.delayIncrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay, Timeout.connectionDelayCap);
        }

        void verboselyDelayToNextIP()
        {
            enum pattern = "Failed to connect to IP. Trying next IP in %s%d%s seconds.";
            logger.logf(pattern, Tint.info, Timeout.connectionRetry, Tint.log);
            incrementedRetryDelay = Timeout.connectionRetry;
            interruptibleSleep(Timeout.connectionRetry.seconds, *instance.abort);
        }

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case preconnect:
            import lu.common : sharedDomains;
            import std.socket : AddressException, AddressFamily;

            string resolvedHost;

            if (!instance.settings.numericAddresses)
            {
                try
                {
                    resolvedHost = attempt.ip.toHostNameString;
                }
                catch (AddressException e)
                {
                    /*
                    std.socket.AddressException@std/socket.d(1301): Could not get host name: Success
                    ----------------
                    ??:? pure @safe bool std.exception.enforce!(bool).enforce(bool, lazy object.Throwable) [0x2cf5f0]
                    ??:? const @trusted immutable(char)[] std.socket.Address.toHostString(bool) [0x4b2d7c6]
                    */
                    // Just let the string be empty
                }

                if (*instance.abort) return Next.returnFailure;
            }

            immutable rtPattern = !resolvedHost.length &&
                (attempt.ip.addressFamily == AddressFamily.INET6) ?
                "Connecting to [%s%s%s]:%1$s%4$s%3$s %5$s..." :
                "Connecting to %s%s%s:%1$s%4$s%3$s %5$s...";

            immutable ssl = instance.conn.ssl ? "(SSL) " : string.init;

            immutable address = (!resolvedHost.length ||
                (instance.parser.server.address == resolvedHost) ||
                (sharedDomains(instance.parser.server.address, resolvedHost) < 2)) ?
                attempt.ip.toAddrString : resolvedHost;

            logger.logf(rtPattern, Tint.info, address, Tint.log, attempt.ip.toPortString, ssl);
            continue;

        case connected:
            logger.log("Connected!");
            return Next.continue_;

        case delayThenReconnect:
            version(Posix)
            {
                import core.stdc.errno : EINPROGRESS;
                enum errnoInProgress = EINPROGRESS;
            }
            else version(Windows)
            {
                import core.sys.windows.winsock2 : WSAEINPROGRESS;
                enum errnoInProgress = WSAEINPROGRESS;
            }

            if (attempt.errno == errnoInProgress)
            {
                logger.warning("Connection timed out.");
            }
            else if (attempt.errno == 0)
            {
                logger.warning("Connection failed.");
            }
            else
            {
                version(Posix)
                {
                    import kameloso.common : errnoStrings;
                    enum pattern = "Connection failed with %s%s%s: %1$s%4$s";
                    logger.warningf(pattern, Tint.log, errnoStrings[attempt.errno], Tint.warning, errorString);
                }
                else version(Windows)
                {
                    enum pattern = "Connection failed with error %s%d%s: %1$s%4$s";
                    logger.warningf(pattern, Tint.log, attempt.errno, Tint.warning, errorString);
                }
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) verboselyDelay();
            continue;

        case delayThenNextIP:
            // Check abort before delaying and then again after
            if (*instance.abort) return Next.returnFailure;
            verboselyDelayToNextIP();
            if (*instance.abort) return Next.returnFailure;
            continue;

        /*case noMoreIPs:
            logger.warning("Could not connect to server!");
            return Next.returnFailure;*/

        case ipv6Failure:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                enum pattern = "IPv6 connection failed with %s%s%s: %1$s%4$s";
                logger.warningf(pattern, Tint.log, errnoStrings[attempt.errno], Tint.warning, errorString);
            }
            else version(Windows)
            {
                enum pattern = "IPv6 connection failed with error %s%d%s: %1$s%4$s";
                logger.warningf(pattern, Tint.log, attempt.errno, Tint.warning, errorString);
            }
            else
            {
                logger.warning("IPv6 connection failed. Disabling IPv6.");
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) goto case delayThenNextIP;
            continue;

        case sslFailure:
            // This can be transient?
            // "Failed to establish SSL connection after successful connect (system lib)"
            logger.error("Failed to connect: ", Tint.log, attempt.error);
            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) verboselyDelay();
            continue;

        case invalidConnectionError:
        case error:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                enum pattern = "Failed to connect: %s%s%s (%1$s%4$s%3$s)";
                logger.errorf(pattern, Tint.log, errorString, Tint.error, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Failed to connect: %s%s%s (%1$s%4$d%3$s)";
                logger.errorf(pattern, Tint.log, errorString, Tint.error, attempt.errno);
            }
            else
            {
                logger.error("Failed to connect: ", Tint.log, errorString);
            }

            if (attempt.state == invalidConnectionError)
            {
                goto case delayThenNextIP;
            }
            else
            {
                return Next.returnFailure;
            }
        }
    }

    return Next.returnFailure;
}


// tryResolve
/++
    Tries to resolve the address in [instance.parser.server] to IPs, by
    leveraging [kameloso.net.resolveFiber], reacting on the
    [kameloso.net.ResolveAttempt]s it yields to provide feedback to the user.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
        firstConnect = Whether or not this is the first time we're attempting a connection.

    Returns:
        [lu.common.Next.continue_] if resolution succeeded,
        [lu.common.Next.returnFailure] if it failed and the program should exit.
 +/
Next tryResolve(ref Kameloso instance, const Flag!"firstConnect" firstConnect)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ResolveAttempt, resolveFiber;
    import std.concurrency : Generator;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(instance.conn, instance.parser.server.address,
            instance.parser.server.port, instance.connSettings.ipv6, *instance.abort));
    scope(exit) resolver.reset();

    uint incrementedRetryDelay = Timeout.connectionRetry;
    enum incrementMultiplier = 1.2;

    void delayOnNetworkDown()
    {
        import kameloso.thread : interruptibleSleep;
        import std.algorithm.comparison : min;
        import core.time : seconds;

        enum pattern = "Network down? Retrying in %s%d%s seconds.";
        logger.logf(pattern, Tint.info, incrementedRetryDelay, Tint.log);
        interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);
        if (*instance.abort) return;

        enum delayCap = 10*60;  // seconds
        incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
        incrementedRetryDelay = min(incrementedRetryDelay, delayCap);
    }

    foreach (const attempt; resolver)
    {
        import lu.string : beginsWith;

        enum getaddrinfoErrorString = "getaddrinfo error: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.beginsWith(getaddrinfoErrorString) ?
                attempt.error[getaddrinfoErrorString.length..$] :
                attempt.error) :
            string.init;

        with (ResolveAttempt.State)
        final switch (attempt.state)
        {
        case preresolve:
            // No message for this
            continue;

        case success:
            import lu.string : plurality;
            enum pattern = "%s%s resolved into %s%s%2$s %5$s.";
            logger.infof(pattern, instance.parser.server.address, Tint.log,
                Tint.info, instance.conn.ips.length,
                instance.conn.ips.length.plurality("IP", "IPs"));
            return Next.continue_;

        case exception:
            enum pattern = "Could not resolve server address: %s%s%s (%1$s%4$d%3$s)";
            logger.warningf(pattern, Tint.log, errorString, Tint.warning, attempt.errno);
            delayOnNetworkDown();
            if (*instance.abort) return Next.returnFailure;
            continue;

        case error:
            enum pattern = "Could not resolve server address: %s%s%s (%1$s%4$d%3$s)";
            logger.errorf(pattern, Tint.log, errorString, Tint.error, attempt.errno);

            if (firstConnect)
            {
                // First attempt and a failure; something's wrong, abort
                enum firstConnectPattern = "Failed to resolve host. Verify that you " ~
                    "are connected to the Internet and that the server address (%s%s%s) is correct.";
                logger.logf(firstConnectPattern, Tint.info, instance.parser.server.address, Tint.log);
                return Next.returnFailure;
            }
            else
            {
                // Not the first attempt yet failure; transient error? retry
                delayOnNetworkDown();
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


// postInstanceSetup
/++
    Sets up the program (terminal) environment.

    Depending on your platform it may set any of thread name, terminal title and
    console codepages.

    This is called very early during execution.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso] instance.
 +/
void postInstanceSetup(ref Kameloso instance)
{
    import kameloso.terminal : isTTY;

    version(Windows)
    {
        import kameloso.terminal : setConsoleModeAndCodepage;

        // Set up the console to display text and colours properly.
        setConsoleModeAndCodepage();
    }

    version(Posix)
    {
        import kameloso.thread : setThreadName;
        setThreadName("kameloso");
    }

    if (isTTY)
    {
        import kameloso.constants : KamelosoInfo;
        import kameloso.terminal : setTitle;

        enum terminalTitle = "kameloso v" ~ cast(string)KamelosoInfo.version_;
        setTitle(terminalTitle);
    }
    else
    {
        // Non-TTYs (eg. pagers) can't show colours
        instance.settings.monochrome = true;
    }
}


// expandPaths
/++
    Sets up the passed [kameloso.kameloso.CoreSettings], expanding paths.

    This is called during early execution.

    Params:
        settings = A reference to the [kameloso.kameloso.CoreSettings] we want to set up.
 +/
void expandPaths(ref CoreSettings settings)
{
    import kameloso.constants : KamelosoFilenames;
    import kameloso.platform : configurationBaseDirectory, resourceBaseDirectory;
    import std.path : buildNormalizedPath;

    // Default values
    settings.configFile = buildNormalizedPath(configurationBaseDirectory,
        "kameloso", KamelosoFilenames.configuration);
    settings.resourceDirectory = buildNormalizedPath(resourceBaseDirectory, "kameloso");
}


// verifySettings
/++
    Verifies some settings and returns whether the program should continue
    executing (or whether there were errors such that we should exit).

    This is called after command-line arguments have been parsed.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].

    Returns:
        [lu.common.Next.returnFailure] if the program should exit, [lu.common.Next.continue_] otherwise.
 +/
Next verifySettings(ref Kameloso instance)
{
    if (!instance.settings.force)
    {
        import dialect.common : isValidNickname;

        IRCServer conservativeServer;
        conservativeServer.maxNickLength = 25;  // Twitch max, should be enough

        if (!instance.parser.client.nickname.isValidNickname(conservativeServer))
        {
            // No need to print the nickname, visible from printObjects preivously
            logger.error("Invalid nickname!");
            return Next.returnFailure;
        }

        if (!instance.settings.prefix.length)
        {
            logger.error("No prefix configured!");
            return Next.returnFailure;
        }
    }

    // No point having these checks be bypassable with --force
    if (instance.connSettings.messageRate <= 0)
    {
        logger.error("Message rate must be a number greater than zero!");
        return Next.returnFailure;
    }
    else if (instance.connSettings.messageBurst <= 0)
    {
        logger.error("Message burst must be a number greater than zero!");
        return Next.returnFailure;
    }

    version(Posix)
    {
        import lu.string : contains;

        // Workaround for Issue 19247:
        // Segmentation fault when resolving address with std.socket.getAddress inside a Fiber
        // the workaround being never resolve addresses that don't contain at least one dot
        immutable addressIsResolvable = instance.settings.force ||
            instance.parser.server.address == "localhost" ||
            instance.parser.server.address.contains('.') ||
            instance.parser.server.address.contains(':');
    }
    else
    {
        // On Windows this doesn't happen, so allow all addresses.
        enum addressIsResolvable = true;
    }

    if (!addressIsResolvable)
    {
        enum pattern = "Invalid address! [%s%s%s]";
        logger.errorf(pattern, Tint.log, instance.parser.server.address, Tint.error);
        return Next.returnFailure;
    }

    return Next.continue_;
}


// resolveResourceDirectory
/++
    Resolves resource directories verbosely.

    This is called after settings have been verified, before plugins are initialised.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
 +/
void resolveResourceDirectory(ref Kameloso instance)
{
    import std.file : exists;
    import std.path : buildNormalizedPath, dirName;

    // Resolve and create the resource directory
    version(Windows)
    {
        import std.string : replace;
        instance.settings.resourceDirectory = buildNormalizedPath(instance.settings.resourceDirectory,
            "server", instance.parser.server.address.replace(":", "_"));
    }
    else
    {
        instance.settings.resourceDirectory = buildNormalizedPath(instance.settings.resourceDirectory,
            "server", instance.parser.server.address);
    }

    instance.settings.configDirectory = instance.settings.configFile.dirName;

    if (!instance.settings.resourceDirectory.exists)
    {
        import std.file : mkdirRecurse;

        mkdirRecurse(instance.settings.resourceDirectory);
        logger.log("Created resource directory ", Tint.info,
            instance.settings.resourceDirectory);
    }
}


// startBot
/++
    Main connection logic.

    This function *starts* the bot, after it has been sufficiently initialised.
    It resolves and connects to servers, then hands off execution to [mainLoop].

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
        attempt = [AttemptState] aggregate of state variables used when connecting.
 +/
void startBot(ref Kameloso instance, ref AttemptState attempt)
{
    import kameloso.constants : ShellReturnValue;
    import kameloso.terminal : TerminalToken, isTTY;
    import std.algorithm.comparison : among;

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    enum bellString = ("" ~ cast(char)(TerminalToken.bell));
    immutable bell = isTTY ? bellString : string.init;

    outerloop:
    do
    {
        // *instance.abort is guaranteed to be false here.

        attempt.silentExit = true;

        if (!attempt.firstConnect)
        {
            import kameloso.constants : Timeout;
            import kameloso.thread : exhaustMessages, interruptibleSleep;
            import core.time : seconds;

            // Carry some values but otherwise restore the pristine client backup
            backupClient.nickname = instance.parser.client.nickname;
            //instance.parser.client = backupClient;  // Initialised below

            // Exhaust leftover queued messages
            exhaustMessages();

            // Clear outgoing messages
            instance.outbuffer.clear();
            instance.backgroundBuffer.clear();
            instance.priorityBuffer.clear();
            instance.immediateBuffer.clear();

            version(TwitchSupport)
            {
                instance.fastbuffer.clear();
            }

            auto gracePeriodBeforeReconnect = Timeout.connectionRetry.seconds;

            version(TwitchSupport)
            {
                import std.algorithm.searching : endsWith;
                import core.time : msecs;

                if (instance.parser.server.address.endsWith(".twitch.tv") && !instance.sawWelcome)
                {
                    // We probably saw an instant disconnect before even getting to RPL_WELCOME
                    // Quickly attempt again
                    gracePeriodBeforeReconnect = 500.msecs;
                }
            }

            logger.log("One moment...");
            interruptibleSleep(gracePeriodBeforeReconnect, *instance.abort);
            if (*instance.abort) break outerloop;

            // Re-init plugins here so it isn't done on the first connect attempt
            instance.initPlugins(attempt.customSettings);

            // Reset throttling, in case there were queued messages.
            instance.throttle.reset();

            // Clear WHOIS history
            instance.previousWhoisTimestamps = null;

            // Reset the server but keep the address and port
            immutable addressSnapshot = instance.parser.server.address;
            immutable portSnapshot = instance.parser.server.port;
            instance.parser.server = typeof(instance.parser.server).init;  // TODO: Add IRCServer constructor
            instance.parser.server.address = addressSnapshot;
            instance.parser.server.port = portSnapshot;

            version(TwitchSupport)
            {
                instance.sawWelcome = false;
            }
        }

        scope(exit)
        {
            // Always teardown when exiting this loop (for whatever reason)
            instance.teardownPlugins();
        }

        // May as well check once here, in case something in initPlugins aborted or so.
        if (*instance.abort) break outerloop;

        instance.conn.reset();

        // reset() sets the receive timeout to the enum default, so make sure to
        // update it to any custom value after each reset() call.
        instance.conn.receiveTimeout = instance.connSettings.receiveTimeout;

        immutable actionAfterResolve = tryResolve(instance, cast(Flag!"firstConnect")(attempt.firstConnect));
        if (*instance.abort) break outerloop;  // tryResolve interruptibleSleep can abort

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case retry:  // should never happen
            assert(0, "`tryResolve` returned `Next.retry`");

        case returnFailure:
            // No need to teardown; the scopeguard does it for us.
            attempt.retval = ShellReturnValue.resolutionFailure;
            break outerloop;

        case returnSuccess:
            // Ditto
            attempt.retval = ShellReturnValue.success;
            break outerloop;

        case crash:
            assert(0, "`tryResolve` returned `Next.crash`");
        }

        immutable actionAfterConnect = tryConnect(instance);
        if (*instance.abort) break outerloop;  // tryConnect interruptibleSleep can abort

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnSuccess:  // should never happen
            assert(0, "`tryConnect` returned `Next.returnSuccess`");

        case retry:  // should never happen
            assert(0, "`tryConnect` returned `Next.retry`");

        case returnFailure:
            // No need to saveOnExit, the scopeguard takes care of that
            attempt.retval = ShellReturnValue.connectionFailure;
            break outerloop;

        case crash:
            assert(0, "`tryConnect` returned `Next.crash`");
        }

        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
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

            enum pattern = "The %s%s%s plugin failed to load its resources: " ~
                "%1$s%4$s%3$s (at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s";
            logger.warningf(pattern, Tint.log, e.file.baseName[0..$-2], Tint.warning,
                e.msg, e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = ShellReturnValue.pluginResourceLoadFailure;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;

            enum pattern = "An error occurred while initialising the %s%s%s " ~
                "plugin's resources: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s";
            logger.warningf(pattern, Tint.log, e.file.baseName[0..$-2], Tint.warning,
                e.msg, e.file, e.line, bell);
            version(PrintStacktraces) logger.trace(e);
            attempt.retval = ShellReturnValue.pluginResourceLoadException;
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

            enum pattern = "The %s%s%s plugin failed to start up: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s";
            logger.warningf(pattern, Tint.log, e.file.baseName[0..$-2], Tint.warning,
                e.msg, e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = ShellReturnValue.pluginStartFailure;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;

            enum pattern = "An error occurred while starting up the %s%s%s plugin: " ~
                "%1$s%4$s%3$s (at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s";
            logger.warningf(pattern, Tint.log, e.file.baseName[0..$-2], Tint.warning,
                e.msg, e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e);
            attempt.retval = ShellReturnValue.pluginStartException;
            break outerloop;
        }

        // Do verbose exits if mainLoop causes a return
        attempt.silentExit = false;

        // Start the main loop
        attempt.next = instance.mainLoop();
        attempt.firstConnect = false;
    }
    while (!*instance.abort && attempt.next.among!(Next.continue_, Next.retry, Next.returnFailure));
}


// printEventDebugDetails
/++
    Print what we know about an event, from an error perspective.

    Params:
        event = The [dialect.defs.IRCEvent] in question.
        raw = The raw string that `event` was parsed from, as read from the IRC server.
        eventWasInitialised = Whether the [dialect.defs.IRCEvent] was initialised
            or if it was only ever set to `void`.
 +/
void printEventDebugDetails(const ref IRCEvent event,
    const string raw,
    const bool eventWasInitialised = true)
{
    if (globalHeadless || !raw.length) return;

    if (!eventWasInitialised || (event == IRCEvent.init))
    {
        enum pattern = `Offending line: "%s%s%s"`;
        logger.warningf(pattern, Tint.log, raw, Tint.warning);
    }
    else
    {
        import kameloso.printing : printObject;
        import std.typecons : Flag, No, Yes;

        // Offending line included in event, in raw
        printObject!(Yes.all)(event);

        if (event.sender != IRCUser.init)
        {
            logger.trace("sender:");
            printObject(event.sender);
        }

        if (event.target != IRCUser.init)
        {
            logger.trace("target:");
            printObject(event.target);
        }
    }
}


// printSummary
/++
    Prints a summary of the connection(s) made and events parsed this execution.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso].
 +/
void printSummary(const ref Kameloso instance)
{
    import kameloso.common : timeSince;
    import core.time : Duration;

    Duration totalTime;
    long totalBytesReceived;
    uint i;

    logger.info("-- Connection summary --");

    foreach (const entry; instance.connectionHistory)
    {
        import std.datetime.systime : SysTime;
        import std.format : format;
        import std.stdio : writefln;
        import core.time : hnsecs;

        if (!entry.bytesReceived) continue;

        enum onlyTimePattern = "%02d:%02d:%02d";
        enum fullDatePattern = "%d-%02d-%02d " ~ onlyTimePattern;

        auto start = SysTime.fromUnixTime(entry.startTime);
        immutable startString = fullDatePattern
            .format(start.year, start.month, start.day, start.hour, start.minute, start.second);

        auto stop = SysTime.fromUnixTime(entry.stopTime);
        immutable stopString = (start.dayOfGregorianCal == stop.dayOfGregorianCal) ?
            onlyTimePattern.format(stop.hour, stop.minute, stop.second) :
            fullDatePattern.format(stop.year, stop.month, stop.day, stop.hour, stop.minute, stop.second);

        start.fracSecs = 0.hnsecs;
        stop.fracSecs = 0.hnsecs;
        immutable duration = (stop - start);
        totalTime += duration;
        totalBytesReceived += entry.bytesReceived;

        enum pattern = "%2d: %s, %d events parsed in %,d bytes (%s to %s)";
        writefln(pattern, ++i, duration.timeSince!(7, 0)(Yes.abbreviate),
            entry.numEvents, entry.bytesReceived, startString, stopString);
    }

    enum pattern = "Total received: %s%,d%s bytes";
    logger.info("Total time connected: ", Tint.log, totalTime.timeSince!(7, 1));
    logger.infof(pattern, Tint.log, totalBytesReceived, Tint.info);
}


/++
    Aggregate of state values used in an execution of the program.
 +/
struct AttemptState
{
    /// Enum denoting what we should do next loop in an execution attempt.
    Next next;

    /++
        An array for [handleGetopt] to fill by ref with custom settings
        set on the command-line using `--set plugin.setting=value`.
     +/
    string[] customSettings;

    /++
        Bool whether this is the first connection attempt or if we have
        connected at least once already.
     +/
    bool firstConnect = true;

    /// Whether or not "Exiting..." should be printed at program exit.
    bool silentExit;

    /// Shell return value to exit with.
    int retval;
}


public:


// run
/++
    Entry point of the program.

    This function is very long, but mostly because it's tricky to split up into
    free functions and have them convey "parent function should exit".

    Params:
        args = Command-line arguments passed to the program.

    Returns:
        `0` on success, non-`0` on failure.
 +/
int run(string[] args)
{
    static import kameloso.common;
    import kameloso.common : initLogger;
    import kameloso.constants : ShellReturnValue;
    import std.exception : ErrnoException;
    import core.stdc.errno : errno;

    // Set up the Kameloso instance.
    Kameloso instance;
    postInstanceSetup(instance);

    // Set pointers.
    kameloso.common.settings = &instance.settings;
    instance.abort = &globalAbort;

    // Declare AttemptState instance.
    AttemptState attempt;

    // Set up `kameloso.common.settings`, expanding paths.
    expandPaths(instance.settings);

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for monochrome and headless
    initLogger(
        cast(Flag!"monochrome")instance.settings.monochrome,
        cast(Flag!"brightTerminal")instance.settings.brightTerminal,
        cast(Flag!"headless")instance.settings.headless);

    // Set up signal handling so that we can gracefully catch Ctrl+C.
    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken, isTTY;

        if (!instance.settings.headless)
        {
            enum bellString = ("" ~ cast(char)(TerminalToken.bell));
            immutable bell = isTTY ? bellString : string.init;
            logger.error("We just crashed!", bell);
        }

        *instance.abort = true;
        resetSignals();
    }

    immutable actionAfterGetopt = instance.tryGetopt(args, attempt.customSettings);
    globalHeadless = instance.settings.headless;

    with (Next)
    final switch (actionAfterGetopt)
    {
    case continue_:
        break;

    case retry:  // should never happen
        assert(0, "`tryGetopt` returned `Next.retry`");

    case returnSuccess:
        return ShellReturnValue.success;

    case returnFailure:
        return ShellReturnValue.getoptFailure;

    case crash:
        assert(0, "`tryGetopt` returned `Next.crash`");
    }

    try
    {
        import kameloso.terminal : ensureAppropriateBuffering;

        // Ensure stdout is buffered by line on Cygwin and vscode.
        ensureAppropriateBuffering(cast(Flag!"override_")instance.settings.flush);
    }
    catch (ErrnoException e)
    {
        import std.stdio : writeln;
        if (!instance.settings.headless) writeln("Failed to set stdout buffer mode/size! errno:", errno);
        if (!instance.settings.force) return ShellReturnValue.terminalSetupFailure;
    }
    catch (Exception e)
    {
        if (!instance.settings.headless)
        {
            import std.stdio : writeln;
            writeln("Failed to set stdout buffer mode/size!");
            writeln(e);
        }

        if (!instance.settings.force) return ShellReturnValue.terminalSetupFailure;
    }

    // Apply some defaults to empty members, as stored in `kameloso.constants`.
    // It's done before in tryGetopt but do it again to ensure we don't have an empty nick etc
    // Skip if --force was passed.
    if (!instance.settings.force)
    {
        import kameloso.config : applyDefaults;
        applyDefaults(instance.parser.client, instance.parser.server, instance.bot);
    }

    import std.algorithm.comparison : among;

    // Copy some stuff over to our Connection
    instance.conn.certFile = instance.connSettings.certFile;
    instance.conn.privateKeyFile = instance.connSettings.privateKeyFile;
    instance.conn.ssl = instance.connSettings.ssl;

    // Additionally if the port is an SSL-like port, assume SSL,
    // but only if the user isn't forcing settings
    if (!instance.conn.ssl && !instance.settings.force &&
        instance.parser.server.port.among!(6697, 7000, 7001, 7029, 7070, 9999, 443))
    {
        instance.connSettings.ssl = true;  // Is this wise?
        instance.conn.ssl = true;
    }

    import kameloso.common : replaceTokens, printVersionInfo;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    if (!instance.settings.headless)
    {
        printVersionInfo();
        writeln();

        // Print the current settings to show what's going on.
        IRCClient prettyClient = instance.parser.client;
        prettyClient.realName = replaceTokens(prettyClient.realName);
        printObjects(prettyClient, instance.bot, instance.parser.server);

        if (!instance.bot.homeChannels.length && !instance.bot.admins.length)
        {
            import kameloso.config : notifyAboutIncompleteConfiguration;
            notifyAboutIncompleteConfiguration(instance.settings.configFile, args[0]);
        }
    }

    // Verify that settings are as they should be (nickname exists and not too long, etc)
    immutable actionAfterVerification = instance.verifySettings();

    with (Next)
    final switch (actionAfterVerification)
    {
    case continue_:
        break;

    case retry:  // should never happen
        assert(0, "`verifySettings` returned `Next.retry`");

    case returnSuccess:
        return ShellReturnValue.success;

    case returnFailure:
        return ShellReturnValue.settingsVerificationFailure;

    case crash:
        assert(0, "`verifySettings` returned `Next.crash`");
    }

    // Resolve resource directory paths.
    instance.resolveResourceDirectory();

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Initialise plugins outside the loop once, for the error messages
    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import std.conv : ConvException;

    try
    {
        import std.file : exists;

        string[][string] missingEntries;
        string[][string] invalidEntries;

        instance.initPlugins(attempt.customSettings, missingEntries, invalidEntries);

        if (!instance.settings.headless && missingEntries.length && instance.settings.configFile.exists)
        {
            import kameloso.config : notifyAboutMissingSettings;
            notifyAboutMissingSettings(missingEntries, args[0], instance.settings.configFile);
        }
    }
    catch (ConvException e)
    {
        // Configuration file/--set argument syntax error
        logger.error(e.msg);
        if (!instance.settings.force) return ShellReturnValue.customConfigSyntaxFailure;
    }
    catch (IRCPluginSettingsException e)
    {
        // --set plugin/setting name error
        logger.error(e.msg);
        if (!instance.settings.force) return ShellReturnValue.customConfigFailure;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Go!
    instance.startBot(attempt);

    // If we're here, we should exit. The only question is in what way.

    if (*instance.abort && instance.conn.connected)
    {
        import kameloso.thread : ThreadMessage;
        import std.concurrency : receiveTimeout;
        import std.variant : Variant;
        import core.time : Duration;

        // Connected and aborting
        // Catch any queued quit calls and use their reasons and quit settings
        // Also catch Variants so as not to throw an exception on missed priority messages

        string reason = instance.bot.quitReason;
        bool quiet;
        bool notEmpty;

        do
        {
            notEmpty = receiveTimeout(Duration.zero,
                (ThreadMessage.Quit, string givenReason, Flag!"quiet" givenQuiet) scope
                {
                    reason = givenReason;
                    quiet = givenQuiet;
                },
                (Variant _) scope {},
            );
        }
        while (notEmpty);

        if ((!instance.settings.hideOutgoing && !quiet) || instance.settings.trace)
        {
            bool printed;

            version(Colours)
            {
                if (!instance.settings.monochrome)
                {
                    import kameloso.irccolours : mapEffects;

                    logger.trace("--> QUIT :", reason
                        .mapEffects
                        .replaceTokens(instance.parser.client));
                    printed = true;
                }
            }

            if (!printed)
            {
                import kameloso.irccolours : stripEffects;

                logger.trace("--> QUIT :", reason
                    .stripEffects
                    .replaceTokens(instance.parser.client));
            }
        }

        instance.conn.sendline("QUIT :" ~ reason.replaceTokens(instance.parser.client));
    }

    // Save if we're exiting and configuration says we should.
    if (instance.settings.saveOnExit)
    {
        try
        {
            import kameloso.config : writeConfigurationFile;
            instance.writeConfigurationFile(instance.settings.configFile);
        }
        catch (Exception e)
        {
            enum pattern = "Caught Exception when saving settings: " ~
                "%s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)";
            logger.warningf(pattern, Tint.log, e.msg, Tint.warning, e.file, e.line);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    if (!instance.settings.headless)
    {
        if (instance.settings.exitSummary && instance.connectionHistory.length)
        {
            instance.printSummary();
        }

        version(GCStatsOnExit)
        {
            import core.memory : GC;

            immutable stats = GC.stats();

            static if (__VERSION__ >= 2087L)
            {
                immutable allocated = stats.allocatedInCurrentThread;
                enum pattern = "Allocated in current thread: %s%,d%s bytes";
                logger.infof(pattern, Tint.log, allocated, Tint.info);
            }

            enum memoryUsedPattern = "Memory used: %s%,d%s bytes, free: %1$s%4$,d%3$s bytes";
            logger.infof(memoryUsedPattern, Tint.log, stats.usedSize, Tint.info, stats.freeSize);
        }

        if (*instance.abort)
        {
            logger.error("Aborting...");
        }
        else if (!attempt.silentExit)
        {
            logger.info("Exiting...");
        }
    }

    if (*instance.abort)
    {
        // Ctrl+C
        version(Posix)
        {
            if (signalRaised > 0) attempt.retval = (128 + signalRaised);
        }

        if (attempt.retval == 0)
        {
            // Pass through any specific values, set to failure if unset
            attempt.retval = ShellReturnValue.failure;
        }
    }

    return attempt.retval;
}

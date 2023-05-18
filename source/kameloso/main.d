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

import kameloso.common : logger;
import kameloso.kameloso : Kameloso;
import kameloso.net : ListenAttempt;
import kameloso.plugins.common.core : IRCPlugin;
import kameloso.pods : CoreSettings;
import dialect.defs;
import lu.common : Next;
import std.stdio : stdout;
import std.typecons : Flag, No, Yes;


// gcOptions
/++
    A value line for [rt_options] to fine-tune the garbage collector.

    Older compilers don't support all the garbage collector options newer
    compilers do (breakpoints being at `2.085` for the precise garbage collector
    and cleanup behaviour, and `2.098` for the forking one). So in one way or
    another we need to specialise for compiler versions. This is one way.

    See_Also:
        [rt_options]
        https://dlang.org/spec/garbage.html
 +/
enum gcOptions = ()
{
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(128);
    sink.put("gcopt=");

    version(GCStatsOnExit)
    {
        sink.put("profile:1 ");
    }
    else version(unittest)
    {
        // Always print profile information on unittest builds
        sink.put("profile:1 ");
    }

    sink.put("cleanup:finalize ");

    version(PreciseGC)
    {
        sink.put("gc:precise ");
    }

    static if (__VERSION__ >= 2098L)
    {
        version(ConcurrentGC)
        {
            sink.put("fork:1 ");
        }
    }

    // Tweak these numbers as we see fit
    sink.put("initReserve:8 minPoolSize:8 incPoolSize:16");

    return sink.data;
}().idup;


// rt_options
/++
    Fine-tune the garbage collector.

    See_Also:
        [gcOptions]
        https://dlang.org/spec/garbage.html
 +/
extern(C)
public __gshared const string[] rt_options =
[
    /++
        Garbage collector options.
     +/
    gcOptions,

    /++
        Tells the garbage collector to scan the DATA and TLS segments precisely,
        on Windows.
     +/
    "scanDataSeg=precise",
];


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

    if (!globalHeadless && (sig < signalNames.length))
    {
        if (!globalAbort)
        {
            printf("...caught signal SIG%s!\n", signalNames[sig].ptr);
        }
        else if (sig == 2)
        {
            printf("...caught another signal SIG%s! " ~
                "(press Enter if nothing happens, or Ctrl+C again)\n", signalNames[sig].ptr);
        }
    }

    if (globalAbort) resetSignals();
    globalAbort = true;

    version(Posix)
    {
        signalRaised = sig;
    }
}


// messageFiber
/++
    A Generator Fiber function that checks for concurrency messages and performs
    action based on what was received.

    The return value yielded to the caller tells it whether the received action
    means the bot should exit or not.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void messageFiber(ref Kameloso instance)
{
    import kameloso.common : OutgoingLine;
    import kameloso.constants : Timeout;
    import kameloso.messaging : Message;
    import kameloso.string : replaceTokens;
    import kameloso.thread : OutputRequest, ThreadMessage;
    import std.concurrency : yield;
    import std.datetime.systime : Clock;
    import core.time : Duration, msecs;

    // The Generator we use this function with popFronts the first thing it does
    // after being instantiated. We're not ready for that yet, so catch the next
    // yield (which is upon messenger.call()).
    yield(Next.init);

    // Loop forever; we'll just terminate the Generator when we want to quit.
    while (true)
    {
        auto next = Next.continue_;

        /++
            Handle [kameloso.thread.ThreadMessage]s based on their
            [kameloso.thread.ThreadMessage.Type|Type]s.
         +/
        void onThreadMessage(ThreadMessage message) scope
        {
            with (ThreadMessage.Type)
            switch (message.type)
            {
            case pong:
                /+
                    PONGs literally always have the same content, so micro-optimise
                    this a bit by only allocating the string once and keeping it
                    if the contents don't change.
                 +/
                static string pongline;

                if (!pongline.length || (pongline[6..$] != message.content))
                {
                    pongline = "PONG :" ~ message.content;
                }

                instance.priorityBuffer.put(OutgoingLine(pongline, Yes.quiet));
                break;

            case ping:
                // No need to micro-optimise here, PINGs should be very rare
                immutable pingline = "PING :" ~ message.content;
                instance.priorityBuffer.put(OutgoingLine(pingline, Yes.quiet));
                break;

            case sendline:
                instance.outbuffer.put(OutgoingLine(
                    message.content,
                    cast(Flag!"quiet")instance.settings.hideOutgoing));
                break;

            case quietline:
                instance.outbuffer.put(OutgoingLine(
                    message.content,
                    Yes.quiet));
                break;

            case immediateline:
                instance.immediateBuffer.put(OutgoingLine(
                    message.content,
                    cast(Flag!"quiet")instance.settings.hideOutgoing));
                break;

            case shortenReceiveTimeout:
                instance.wantReceiveTimeoutShortened = true;
                break;

            case busMessage:
                foreach (plugin; instance.plugins)
                {
                    plugin.onBusMessage(message.content, message.payload);
                }
                break;

            case quit:
                // This will automatically close the connection.
                immutable reason = message.content.length ?
                    message.content :
                    instance.bot.quitReason;
                immutable quitMessage = "QUIT :" ~ reason.replaceTokens(instance.parser.client);
                instance.priorityBuffer.put(OutgoingLine(
                    quitMessage,
                    cast(Flag!"quiet")message.quiet));
                next = Next.returnSuccess;
                break;

            case reconnect:
                instance.priorityBuffer.put(OutgoingLine(
                    "QUIT :Reconnecting.",
                    No.quiet));
                next = Next.retry;
                break;

            case wantLiveSummary:
                instance.wantLiveSummary = true;
                break;

            case abort:
                *instance.abort = true;
                break;

            case reload:
                foreach (plugin; instance.plugins)
                {
                    if (!plugin.isEnabled) continue;

                    try
                    {
                        if (!message.content.length || (plugin.name == message.content))
                        {
                            plugin.reload();
                        }
                    }
                    catch (Exception e)
                    {
                        enum pattern = "The <l>%s</> plugin threw an exception when reloading: <l>%s";
                        logger.errorf(pattern, plugin.name, e.msg);
                        version(PrintStacktraces) logger.trace(e);
                    }
                }
                break;

            case save:
                import kameloso.config : writeConfigurationFile;
                instance.syncGuestChannels();
                instance.writeConfigurationFile(instance.settings.configFile);
                break;

            case popCustomSetting:
                size_t[] toRemove;

                foreach (immutable i, immutable line; instance.customSettings)
                {
                    import lu.string : nom;

                    string slice = line;  // mutable
                    immutable setting = slice.nom!(Yes.inherit)('=');
                    if (setting == message.content) toRemove ~= i;
                }

                foreach_reverse (immutable i; toRemove)
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    instance.customSettings = instance.customSettings
                        .remove!(SwapStrategy.unstable)(i);
                }
                break;

            case putUser:
                import kameloso.thread : Boxed;

                auto boxedUser = cast(Boxed!IRCUser)message.payload;
                assert(boxedUser, "Incorrectly cast message payload: " ~ typeof(boxedUser).stringof);

                auto user = boxedUser.payload;

                foreach (plugin; instance.plugins)
                {
                    if (auto existingUser = user.nickname in plugin.state.users)
                    {
                        immutable prevClass = existingUser.class_;
                        *existingUser = user;
                        existingUser.class_ = prevClass;
                    }
                    else
                    {
                        plugin.state.users[user.nickname] = user;
                    }
                }
                break;

            default:
                enum pattern = "onThreadMessage received unexpected message type: <l>%s";
                logger.errorf(pattern, message.type);
                if (instance.settings.flush) stdout.flush();
                break;
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
                // The first two checks are probably superfluous
                immutable fast =
                    (instance.parser.server.daemon == IRCServer.Daemon.twitch) &&
                    (m.event.type != IRCEvent.Type.QUERY) &&
                    (m.properties & Message.Property.fast);
            }

            immutable background = (m.properties & Message.Property.background);
            immutable quietFlag = cast(Flag!"quiet")
                (instance.settings.hideOutgoing || (m.properties & Message.Property.quiet));
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
                enum pattern = "PRIVMSG %s :";
                prelude = pattern.format(m.event.channel);
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

                        enum pattern = "PRIVMSG #%s :/w %s ";
                        prelude = pattern.format(instance.parser.client.nickname, m.event.target.nickname);
                    }
                }

                enum pattern = "PRIVMSG %s :";
                if (!prelude.length) prelude = pattern.format(m.event.target.nickname);
                lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
                break;

            case EMOTE:
                immutable emoteTarget = m.event.target.nickname.length ?
                    m.event.target.nickname :
                    m.event.channel;

                version(TwitchSupport)
                {
                    if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
                    {
                        enum pattern = "PRIVMSG %s :/me ";
                        prelude = pattern.format(emoteTarget);
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
                line = format(pattern, m.event.channel, m.event.aux[0], m.event.content.strippedRight);
                break;

            case TOPIC:
                enum pattern = "TOPIC %s :%s";
                line = pattern.format(m.event.channel, m.event.content);
                break;

            case INVITE:
                enum pattern = "INVITE %s %s";
                line = pattern.format(m.event.channel, m.event.target.nickname);
                break;

            case JOIN:
                if (m.event.aux[0].length)
                {
                    // Key, assume only one channel
                    line = text("JOIN ", m.event.channel, ' ', m.event.aux[0]);
                }
                else
                {
                    prelude = "JOIN ";
                    lines = m.event.channel.splitLineAtPosition(',', maxIRCLineLength-prelude.length);
                }
                break;

            case KICK:
                immutable reason = m.event.content.length ?
                    " :" ~ m.event.content :
                    string.init;
                enum pattern = "KICK %s %s%s";
                line = format(pattern, m.event.channel, m.event.target.nickname, reason);
                break;

            case PART:
                if (m.event.content.length)
                {
                    // Reason given, assume only one channel
                    line = text(
                        "PART ", m.event.channel, " :",
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
                    writef(
                        pattern,
                        m.event.target.nickname,
                        m.caller,
                        cast(bool)quietFlag,
                        cast(bool)background);
                }

                if ((now - then) > hysteresis)
                {
                    version(TraceWhois)
                    {
                        writeln(" ...and actually issuing.");
                    }

                    line = "WHOIS " ~ m.event.target.nickname;
                    instance.previousWhoisTimestamps[m.event.target.nickname] = now;
                    instance.propagateWhoisTimestamp(m.event.target.nickname, now);
                }
                else
                {
                    version(TraceWhois)
                    {
                        writefln(" ...but already issued %d seconds ago.", (now - then));
                    }
                }

                version(TraceWhois)
                {
                    if (instance.settings.flush) stdout.flush();
                }
                break;

            case QUIT:
                immutable rawReason = m.event.content.length ?
                    m.event.content :
                    instance.bot.quitReason;
                immutable reason = rawReason.replaceTokens(instance.parser.client);
                line = "QUIT :" ~ reason;
                next = Next.returnSuccess;
                break;

            case UNSET:
                line = m.event.content;
                break;

            default:
                logger.error("No outgoing event case for type <l>", m.event.type);
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
                    if (/*(instance.parser.server.daemon == IRCServer.Daemon.twitch) &&*/ fast)
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
                    instance.outbuffer.put(OutgoingLine(finalLine, cast(Flag!"quiet")instance.settings.hideOutgoing));
                }
            }

            if (lines.length)
            {
                foreach (immutable i, immutable splitLine; lines)
                {
                    immutable finalLine = m.event.tags.length ?
                        text('@', m.event.tags, ' ', prelude, splitLine) :
                        text(prelude, splitLine);
                    appropriateline(finalLine);
                }
            }
            else if (line.length)
            {
                if (m.event.tags.length) line = text('@', m.event.tags, ' ', line);
                appropriateline(line);
            }
        }

        /// Proxies the passed message to the [kameloso.logger.logger].
        void proxyLoggerMessages(OutputRequest request) scope
        {
            if (instance.settings.headless) return;

            with (OutputRequest.Level)
            final switch (request.logLevel)
            {
            case writeln:
                import kameloso.logger : LogLevel;
                import kameloso.terminal.colours.tags : expandTags;
                import std.stdio : writeln;

                writeln(request.line.expandTags(LogLevel.off));
                if (instance.settings.flush) stdout.flush();
                break;

            case trace:
                logger.trace(request.line);
                break;

            case log:
                logger.log(request.line);
                break;

            case info:
                logger.info(request.line);
                break;

            case warning:
                logger.warning(request.line);
                break;

            case error:
                logger.error(request.line);
                break;

            case critical:
                logger.critical(request.line);
                break;

            case fatal:
                logger.fatal(request.line);
                break;
            }
        }

        /// Timestamp of when the loop started.
        immutable loopStartTime = Clock.currTime;
        static immutable maxReceiveTime = Timeout.messageReadMsecs.msecs;

        while (!*instance.abort &&
            (next == Next.continue_) &&
            ((Clock.currTime - loopStartTime) <= maxReceiveTime))
        {
            import std.concurrency : receiveTimeout;
            import std.variant : Variant;

            immutable receivedSomething = receiveTimeout(Duration.zero,
                &onThreadMessage,
                &eventToServer,
                &proxyLoggerMessages,
                (Variant v) scope
                {
                    // Caught an unhandled message
                    enum pattern = "Main thread message fiber received unknown Variant: <l>%s";
                    logger.warningf(pattern, v.type);
                }
            );

            if (!receivedSomething) break;
        }

        yield(next);
    }

    assert(0, "`while (true)` loop break in `messageFiber`");
}


// mainLoop
/++
    This loops creates a [std.concurrency.Generator|Generator]
    [core.thread.fiber.Fiber|Fiber] to loop over the connected [std.socket.Socket|Socket].

    Full lines are stored in [kameloso.net.ListenAttempt|ListenAttempt]s, which
    are yielded in the [std.concurrency.Generator|Generator] to be caught here,
    consequently parsed into [dialect.defs.IRCEvent|IRCEvent]s, and then dispatched
    to all plugins.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].

    Returns:
        [lu.common.Next.returnFailure|Next.returnFailure] if circumstances mean
        the bot should exit with a non-zero exit code,
        [lu.common.Next.returnSuccess|Next.returnSuccess] if it should exit by
        returning `0`,
        [lu.common.Next.retry|Next.retry] if the bot should reconnect to the server.
        [lu.common.Next.continue_|Next.continue_] is never returned.
 +/
auto mainLoop(ref Kameloso instance)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ListenAttempt, listenFiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock;
    import core.thread : Fiber;

    /// Variable denoting what we should do next loop.
    Next next;

    alias State = ListenAttempt.State;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(
            instance.conn,
            *instance.abort,
            Timeout.connectionLost));
    auto messenger = new Generator!Next(() => messageFiber(instance));

    scope(exit)
    {
        destroy(listener);
        destroy(messenger);
    }

    /++
        Invokes the messenger generator.
     +/
    Next callMessenger()
    {
        try
        {
            messenger.call();
        }
        catch (Exception e)
        {
            enum pattern = "Unhandled messenger exception: <l>%s</> (at <l>%s</>:<l>%d</>)";
            logger.warningf(pattern, e.msg, e.file, e.line);
            version(PrintStacktraces) logger.trace(e);
            return Next.returnFailure;
        }

        if (messenger.state == Fiber.State.HOLD)
        {
            return messenger.front;
        }
        else
        {
            logger.error("Internal error, thread messenger Fiber ended abruptly.");
            return Next.returnFailure;
        }
    }

    // Start plugins before the loop starts and immediately read messages sent.
    try
    {
        instance.startPlugins();
        immutable messengerNext = callMessenger();
        if (messengerNext != Next.continue_) return messengerNext;
    }
    catch (Exception e)
    {
        enum pattern = "Exception thrown when starting plugins: <l>%s";
        logger.errorf(pattern, e.msg);
        logger.trace(e.info);
        return Next.returnFailure;
    }

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

            if (plugin.state.specialRequests.length)
            {
                processSpecialRequests(instance, plugin);
            }

            if (plugin.state.scheduledFibers.length ||
                plugin.state.scheduledDelegates.length)
            {
                if (plugin.state.nextScheduledTimestamp <= nowInHnsecs)
                {
                    plugin.processScheduledDelegates(nowInHnsecs);
                    plugin.processScheduledFibers(nowInHnsecs);
                    plugin.state.updateSchedule();  // Something is always removed
                    instance.conn.socket.blocking = false;  // Instantly timeout read to check messages
                    socketBlockingDisabled = true;

                    if (*instance.abort) return Next.returnFailure;
                }

                if (!nextGlobalScheduledTimestamp ||
                    (plugin.state.nextScheduledTimestamp < nextGlobalScheduledTimestamp))
                {
                    nextGlobalScheduledTimestamp = plugin.state.nextScheduledTimestamp;
                }
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
                    delayToNextMsecs :
                    1;
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
                import std.algorithm.comparison : max;

                historyEntry.bytesReceived += max(attempt.bytesReceived, 0);
                historyEntry.stopTime = nowInUnix;
                ++historyEntry.numEvents;
                instance.processLineFromServer(attempt.line, nowInUnix);
                break;

            case retry:
                // Break and try again
                historyEntry.stopTime = nowInUnix;
                break listenerloop;

            case returnSuccess:
                assert(0, "`listenAttemptToNext` returned `Next.returnSuccess`");

            case returnFailure:
                return Next.retry;

            case crash:
                assert(0, "`listenAttemptToNext` returned `Next.crash`");
            }
        }

        // Check concurrency messages to see if we should exit
        next = callMessenger();
        if (*instance.abort) return Next.returnFailure;
        else if (next != Next.continue_) return next;

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

        if (timeWhenReceiveWasShortened &&
            (nowInHnsecs > (timeWhenReceiveWasShortened + maxShortenDurationHnsecs)))
        {
            // Shortened duration passed, reset timestamp to disable it
            timeWhenReceiveWasShortened = 0L;
        }

        if (instance.wantReceiveTimeoutShortened)
        {
            // Set the timestamp and unset the bool
            instance.wantReceiveTimeoutShortened = false;
            timeWhenReceiveWasShortened = nowInHnsecs;
        }

        if ((timeoutFromMessages < uint.max) ||
            nextGlobalScheduledTimestamp ||
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
                    supposedNewTimeout :
                    1;
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
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].

    Returns:
        How many milliseconds until the next message in the buffers should be sent.
 +/
auto sendLines(ref Kameloso instance)
{
    if (!instance.immediateBuffer.empty)
    {
        cast(void)instance.throttleline(
            instance.immediateBuffer,
            No.dryRun,
            No.sendFaster,
            Yes.immediate);
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
            immutable untilNext = instance.throttleline(
                instance.fastbuffer,
                No.dryRun,
                Yes.sendFaster);
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


// listenAttemptToNext
/++
    Translates the [kameloso.net.ListenAttempt.State|ListenAttempt.State]
    received from a [std.concurrency.Generator|Generator] into a [lu.common.Next|Next],
    while also providing warnings and error messages.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        attempt = The [kameloso.net.ListenAttempt|ListenAttempt] to map the `.state` value of.

    Returns:
        A [lu.common.Next|Next] describing what action [mainLoop] should take next.
 +/
auto listenAttemptToNext(ref Kameloso instance, const ListenAttempt attempt)
{
    // Handle the attempt; switch on its state
    with (ListenAttempt.State)
    final switch (attempt.state)
    {
    case unset:
    case prelisten:
        // Should never happen
        assert(0, "listener yielded invalid state");

    case isEmpty:
        // Empty line yielded means nothing received; break foreach and try again
        return Next.retry;

    case hasString:
        // hasString means we should drop down and continue processing
        return Next.continue_;

    case warning:
        // Benign socket error; break foreach and try again
        import kameloso.constants : Timeout;
        import kameloso.thread : interruptibleSleep;
        import core.time : msecs;

        version(Posix)
        {
            import kameloso.common : errnoStrings;
            enum pattern = "Connection error! (<l>%s</>) (<t>%s</>)";
            logger.warningf(pattern, attempt.error, errnoStrings[attempt.errno]);
        }
        else version(Windows)
        {
            enum pattern = "Connection error! (<l>%s</>) (<t>%d</>)";
            logger.warningf(pattern, attempt.error, attempt.errno);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        // Sleep briefly so it won't flood the screen on chains of errors
        static immutable readErrorGracePeriod = Timeout.readErrorGracePeriodMsecs.msecs;
        interruptibleSleep(readErrorGracePeriod, *instance.abort);
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
                enum pattern = "Connection error: invalid server response! (<l>%s</>) (<t>%s</>)";
                logger.errorf(pattern, attempt.error, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Connection error: invalid server response! (<l>%s</>) (<t>%d</>)";
                logger.errorf(pattern, attempt.error, attempt.errno);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }
        }

        instance.conn.connected = false;
        return Next.returnFailure;
    }
}


// processLineFromServer
/++
    Processes a line read from the server, constructing an
    [dialect.defs.IRCEvent|IRCEvent] and dispatches it to all plugins.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        raw = A raw line as read from the server.
        nowInUnix = Current timestamp in UNIX time.
 +/
void processLineFromServer(ref Kameloso instance, const string raw, const long nowInUnix)
{
    import dialect.common : IRCParseException;
    import lu.string : NomException;
    import std.typecons : Flag, No, Yes;
    import std.utf : UTFException;
    import core.exception : UnicodeException;

    // Delay initialising the event so we don't do it twice;
    // once here, once in toIRCEvent
    IRCEvent event = void;
    bool eventWasInitialised;

    scope(failure)
    {
        if (!instance.settings.headless)
        {
            import lu.string : contains;
            import std.algorithm.searching : canFind;

            // Something asserted
            logger.error("scopeguard tripped.");
            printEventDebugDetails(event, raw, cast(Flag!"eventWasInitialised")eventWasInitialised);

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

            if (instance.settings.flush) stdout.flush();
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
            if (event.errors.length) event.errors ~= " | ";
            event.errors ~= "UTFException: " ~ e.msg;
        }
        catch (UnicodeException e)
        {
            event = instance.parser.toIRCEvent(sanitize(raw));
            if (event.errors.length) event.errors ~= " | ";
            event.errors ~= "UnicodeException: " ~ e.msg;
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
                enum pattern = `NomException %s.postprocess: tried to nom "<l>%s</>" with "<l>%s</>"`;
                logger.warningf(pattern, plugin.name, e.haystack, e.needle);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UTFException e)
            {
                enum pattern = "UTFException %s.postprocess: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UnicodeException e)
            {
                enum pattern = "UnicodeException %s.postprocess: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s.postprocess: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
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
                if (plugin.state.hasPendingReplays) processPendingReplays(instance, plugin);
                if (plugin.state.readyReplays.length) processReadyReplays(instance, plugin);
                processAwaitingDelegates(plugin, event);
                processAwaitingFibers(plugin, event);
                if (*instance.abort) return;  // handled in mainLoop listenerloop
            }
            catch (NomException e)
            {
                enum pattern = `NomException %s: tried to nom "<l>%s</>" with "<l>%s</>"`;
                logger.warningf(pattern, plugin.name, e.haystack, e.needle);
                printEventDebugDetails(event, raw);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UTFException e)
            {
                enum pattern = "UTFException %s: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (UnicodeException e)
            {
                enum pattern = "UnicodeException %s: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
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
        enum pattern = "IRCParseException: <l>%s</> (at <l>%s</>:<l>%d</>)";
        logger.warningf(pattern, e.msg, e.file, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (NomException e)
    {
        enum pattern = `NomException: tried to nom "<l>%s</>" with "<l>%s</>" (at <l>%s</>:<l>%d</>)`;
        logger.warningf(pattern, e.haystack, e.needle, e.file, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UTFException e)
    {
        enum pattern = "UTFException: <l>%s";
        logger.warningf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UnicodeException e)
    {
        enum pattern = "UnicodeException: <l>%s";
        logger.warningf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unhandled exception: <l>%s</> (at <l>%s</>:<l>%d</>)";
        logger.warningf(pattern, e.msg, e.file, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e);
    }
}


// processAwaitingDelegates
/++
    Processes the awaiting delegates of an
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].

    Does not remove delegates after calling them. They are expected to remove
    themselves after finishing if they aren't awaiting any further events.

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] whose
            [dialect.defs.IRCEvent.Type|IRCEvent.Type]-awaiting delegates to
            iterate and process.
        event = The triggering const [dialect.defs.IRCEvent|IRCEvent].
 +/
void processAwaitingDelegates(IRCPlugin plugin, const ref IRCEvent event)
{
    /++
        Handle awaiting delegates of a specified type.
     +/
    void processImpl(void delegate(IRCEvent)[] dgsForType)
    {
        foreach (immutable i, dg; dgsForType)
        {
            try
            {
                dg(event);
            }
            catch (Exception e)
            {
                enum pattern = "Exception %s.awaitingDelegates[%d]: <l>%s";
                logger.warningf(pattern, plugin.name, i, e.msg);
                printEventDebugDetails(event, event.raw);
                version(PrintStacktraces) logger.trace(e);
            }
        }
    }

    if (plugin.state.awaitingDelegates[event.type].length)
    {
        processImpl(plugin.state.awaitingDelegates[event.type]);
    }

    if (plugin.state.awaitingDelegates[IRCEvent.Type.ANY].length)
    {
        processImpl(plugin.state.awaitingDelegates[IRCEvent.Type.ANY]);
    }
}


// processAwaitingFibers
/++
    Processes the awaiting [core.thread.fiber.Fiber|Fiber]s of an
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].

    Don't delete [core.thread.fiber.Fiber|Fiber]s, as they can be reset and reused.

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] whose
            [dialect.defs.IRCEvent.Type|IRCEvent.Type]-awaiting
            [core.thread.fiber.Fiber|Fiber]s to iterate and process.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
 +/
void processAwaitingFibers(IRCPlugin plugin, const ref IRCEvent event)
{
    import core.thread : Fiber;

    /++
        Handle awaiting Fibers of a specified type.
     +/
    void processAwaitingFibersImpl(
        Fiber[] fibersForType,
        ref Fiber[] expiredFibers)
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
                        carryingFiber.payload = event;
                        carryingFiber.call();

                        // We need to reset the payload so that we can differentiate
                        // between whether the Fiber was called due to an incoming
                        // (awaited) event or due to a timer. delegates will have
                        // to cache the event if they don't want it to get reset.
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
                enum pattern = "Exception %s.awaitingFibers[%d]: <l>%s";
                logger.warningf(pattern, plugin.name, i, e.msg);
                printEventDebugDetails(event, event.raw);
                version(PrintStacktraces) logger.trace(e);
                expiredFibers ~= fiber;
            }
        }
    }

    Fiber[] expiredFibers;

    if (plugin.state.awaitingFibers[event.type].length)
    {
        processAwaitingFibersImpl(
            plugin.state.awaitingFibers[event.type],
            expiredFibers);
    }

    if (plugin.state.awaitingFibers[IRCEvent.Type.ANY].length)
    {
        processAwaitingFibersImpl(
            plugin.state.awaitingFibers[IRCEvent.Type.ANY],
            expiredFibers);
    }

    // Clean up processed Fibers
    foreach (expiredFiber; expiredFibers)
    {
        // Detect duplicates that were already destroyed and skip
        if (!expiredFiber) continue;

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

        destroy(expiredFiber);
    }
}


// processScheduledDelegates
/++
    Processes the queued [kameloso.thread.ScheduledDelegate|ScheduledDelegate]s of an
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] whose
            queued [kameloso.thread.ScheduledDelegate|ScheduledDelegate]s to
            iterate and process.
        nowInHnsecs = Current timestamp to compare the
            [kameloso.thread.ScheduledDelegate|ScheduledDelegate]'s timestamp with.
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
            enum pattern = "Exception %s.scheduledDelegates[%d]: <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }
        finally
        {
            destroy(scheduledDg.dg);
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
    Processes the queued [kameloso.thread.ScheduledFiber|ScheduledFiber]s of an
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] whose
            queued [kameloso.thread.ScheduledFiber|ScheduledFiber]s to iterate
            and process.
        nowInHnsecs = Current timestamp to compare the
            [kameloso.thread.ScheduledFiber|ScheduledFiber]'s timestamp with.
 +/
void processScheduledFibers(IRCPlugin plugin, const long nowInHnsecs)
in ((nowInHnsecs > 0), "Tried to process queued `ScheduledFiber`s with an unset timestamp")
{
    import core.thread : Fiber;

    size_t[] toRemove;

    foreach (immutable i, scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.timestamp > nowInHnsecs) continue;

        try
        {
            if (scheduledFiber.fiber.state == Fiber.State.HOLD)
            {
                scheduledFiber.fiber.call();
            }
        }
        catch (Exception e)
        {
            enum pattern = "Exception %s.scheduledFibers[%d]: <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }
        finally
        {
            // destroy the Fiber if it has ended
            if (scheduledFiber.fiber.state == Fiber.State.TERM)
            {
                destroy(scheduledFiber.fiber);
            }
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


// processReadyReplays
/++
    Handles the queue of ready-to-replay objects, re-postprocessing events from the
    current (main loop) context, outside of any plugin.

    Params:
        instance = Reference to the current bot instance.
        plugin = The current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].
 +/
void processReadyReplays(ref Kameloso instance, IRCPlugin plugin)
{
    import lu.string : NomException;
    import std.utf : UTFException;
    import core.exception : UnicodeException;
    import core.thread : Fiber;

    foreach (immutable i, replay; plugin.state.readyReplays)
    {
        version(WithPersistenceService)
        {
            // Postprocessing will reapply class, but not if there is already
            // a custom class (assuming channel cache hit)
            replay.event.sender.class_ = IRCUser.Class.unset;
            replay.event.target.class_ = IRCUser.Class.unset;
        }

        try
        {
            foreach (postprocessor; instance.plugins)
            {
                postprocessor.postprocess(replay.event);
            }
        }
        catch (NomException e)
        {
            enum pattern = "NomException postprocessing %s.state.readyReplays[%d]: " ~
                `tried to nom "<l>%s</>" with "<l>%s</>"`;
            logger.warningf(pattern, plugin.name, i, e.haystack, e.needle);
            printEventDebugDetails(replay.event, replay.event.raw);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (UTFException e)
        {
            enum pattern = "UTFException postprocessing %s.state.readyReplace[%d]: <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (UnicodeException e)
        {
            enum pattern = "UnicodeException postprocessing %s.state.readyReplace[%d]: <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            continue;
        }
        catch (Exception e)
        {
            enum pattern = "Exception postprocessing %s.state.readyReplace[%d]: <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            printEventDebugDetails(replay.event, replay.event.raw);
            version(PrintStacktraces) logger.trace(e);
            continue;
        }

        // If we're here no exceptions were thrown

        try
        {
            replay.dg(replay);
        }
        catch (Exception e)
        {
            enum pattern = "Exception %s.state.readyReplays[%d].dg(): <l>%s";
            logger.warningf(pattern, plugin.name, i, e.msg);
            printEventDebugDetails(replay.event, replay.event.raw);
            version(PrintStacktraces) logger.trace(e);
        }
        finally
        {
            destroy(replay.dg);
        }
    }

    // All ready replays guaranteed exhausted
    plugin.state.readyReplays = null;
}


// processPendingReplay
/++
    Takes a queue of pending [kameloso.plugins.common.core.Replay|Replay]
    objects and issues WHOIS queries for each one, unless it has already been done
    recently (within [kameloso.constants.Timeout.whoisRetry|Timeout.whoisRetry] seconds).

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        plugin = The relevant [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].
 +/
void processPendingReplays(ref Kameloso instance, IRCPlugin plugin)
{
    import kameloso.constants : Timeout;
    import kameloso.messaging : Message, whois;
    import std.datetime.systime : Clock;

    // Walk through replays and call WHOIS on those that haven't been
    // WHOISed in the last Timeout.whoisRetry seconds

    immutable now = Clock.currTime.toUnixTime;

    foreach (immutable nickname, replaysForNickname; plugin.state.pendingReplays)
    {
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

        immutable lastWhois = instance.previousWhoisTimestamps.get(nickname, 0L);

        if ((now - lastWhois) > Timeout.whoisRetry)
        {
            version(TraceWhois)
            {
                if (!instance.settings.headless)
                {
                    writeln(" ...and actually issuing.");
                }
            }

            /*instance.outbuffer.put(OutgoingLine("WHOIS " ~ nickname,
                cast(Flag!"quiet")instance.settings.hideOutgoing));
            instance.previousWhoisTimestamps[nickname] = now;
            instance.propagateWhoisTimestamp(nickname, now);*/

            enum properties = (Message.Property.forced | Message.Property.quiet);
            whois(plugin.state, nickname, properties);
        }
        else
        {
            version(TraceWhois)
            {
                if (!instance.settings.headless)
                {
                    writefln(" ...but already issued %d seconds ago.", (now - lastWhois));
                }
            }
        }

        version(TraceWhois)
        {
            if (instance.settings.flush) stdout.flush();
        }
    }
}


// processSpecialRequests
/++
    Iterates through a plugin's array of [kameloso.plugins.core.SpecialRequest|SpecialRequest]s.
    Depending on what their [kameloso.plugins.core.SpecialRequest.fiber|fiber] member
    (which is in actualy a [kameloso.thread.CarryingFiber|CarryingFiber]) can be
    cast to, it prepares a payload, assigns it to the
    [kameloso.thread.CarryingFiber|CarryingFiber], and calls it.

    If plugins need support for new types of requests, they must be defined and
    hardcoded here. There's no way to let plugins process the requests themselves
    without letting them peek into [kameloso.kameloso.Kameloso|the Kameloso instance].

    The array is always cleared after iteration, so requests that yield must
    first re-queue themselves.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        plugin = The relevant [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].
 +/
void processSpecialRequests(ref Kameloso instance, IRCPlugin plugin)
{
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;
    import core.thread : Fiber;

    auto specialRequestsSnapshot = plugin.state.specialRequests;
    plugin.state.specialRequests = null;

    top:
    foreach (request; specialRequestsSnapshot)
    {
        scope(exit)
        {
            if (request.fiber.state == Fiber.State.TERM)
            {
                // Clean up
                destroy(request.fiber);
            }

            destroy(request);
        }

        alias PeekCommandsPayload = Tuple!(IRCPlugin.CommandMetadata[string][string]);
        alias GetSettingPayload = Tuple!(string, string, string);
        alias SetSettingPayload = Tuple!(bool);

        if (auto fiber = cast(CarryingFiber!(PeekCommandsPayload))(request.fiber))
        {
            immutable channelName = request.context;

            IRCPlugin.CommandMetadata[string][string] commandAA;

            foreach (thisPlugin; instance.plugins)
            {
                if (channelName.length)
                {
                    commandAA[thisPlugin.name] = thisPlugin.channelSpecificCommands(channelName);
                }
                else
                {
                    commandAA[thisPlugin.name] = thisPlugin.commands;
                }
            }

            fiber.payload[0] = commandAA;
            fiber.call();
            continue;
        }
        else if (auto fiber = cast(CarryingFiber!(GetSettingPayload))(request.fiber))
        {
            import lu.string : beginsWith, nom;
            import std.array : Appender;
            import std.algorithm.iteration : splitter;

            immutable expression = request.context;
            string slice = expression;  // mutable
            immutable pluginName = slice.nom!(Yes.inherit)('.');
            alias setting = slice;

            Appender!(char[]) sink;
            sink.reserve(256);  // guesstimate

            void apply()
            {
                if (setting.length)
                {
                    import lu.string : strippedLeft;

                    foreach (const line; sink.data.splitter('\n'))
                    {
                        string lineslice = cast(string)line;  // need a string for nom and strippedLeft...
                        if (lineslice.beginsWith('#')) lineslice = lineslice[1..$];
                        const thisSetting = lineslice.nom!(Yes.inherit)(' ');

                        if (thisSetting != setting) continue;

                        const value = lineslice.strippedLeft;
                        fiber.payload[0] = pluginName;
                        fiber.payload[1] = setting;
                        fiber.payload[2] = value;
                        fiber.call();
                        return;
                    }
                }
                else
                {
                    import std.conv : to;

                    string[] allSettings;

                    foreach (const line; sink.data.splitter('\n'))
                    {
                        string lineslice = cast(string)line;  // need a string for nom and strippedLeft...
                        if (!lineslice.beginsWith('[')) allSettings ~= lineslice.nom!(Yes.inherit)(' ');
                    }

                    fiber.payload[0] = pluginName;
                    //fiber.payload[1] = string.init;
                    fiber.payload[2] = allSettings.to!string;
                    fiber.call();
                    return;
                }

                // If we're here, no such setting was found
                fiber.payload[0] = pluginName;
                //fiber.payload[1] = string.init;
                //fiber.payload[2] = string.init;
                fiber.call();
                return;
            }

            switch (pluginName)
            {
            case "core":
                import lu.serialisation : serialise;
                sink.serialise(instance.settings);
                apply();
                continue;

            case "connection":
                // May leak secrets? certFile, privateKey etc...
                // Careful with how we make this functionality available
                import lu.serialisation : serialise;
                sink.serialise(instance.connSettings);
                apply();
                continue;

            default:
                foreach (thisPlugin; instance.plugins)
                {
                    if (thisPlugin.name != pluginName) continue;
                    thisPlugin.serialiseConfigInto(sink);
                    apply();
                    continue top;
                }

                // If we're here, no plugin was found
                //fiber.payload[0] = string.init;
                //fiber.payload[1] = string.init;
                //fiber.payload[2] = string.init;
                fiber.call();
                continue;
            }
        }
        else if (auto fiber = cast(CarryingFiber!(SetSettingPayload))(request.fiber))
        {
            import kameloso.plugins.common.misc : applyCustomSettings;

            immutable expression = request.context;

            // Borrow settings from the first plugin. It's taken by value
            immutable success = applyCustomSettings(
                instance.plugins,
                [ expression ],
                instance.plugins[0].state.settings);

            fiber.payload[0] = success;
            fiber.call();
            continue;
        }
        else
        {
            logger.error("Unknown special request type: " ~ typeof(request).stringof);
        }
    }

    if (plugin.state.specialRequests.length)
    {
        // One or more new requests were added while processing these ones
        return processSpecialRequests(instance, plugin);
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
    import core.stdc.signal : SIGINT, SIGTERM, signal;

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
    import core.stdc.signal : SIG_DFL, SIGINT, SIGTERM, signal;

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
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        args = The arguments passed to the program.

    Returns:
        [lu.common.Next|Next].* depending on what action the calling site should take.
 +/
auto tryGetopt(ref Kameloso instance, string[] args)
{
    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import kameloso.config : handleGetopt;
    import kameloso.configreader : ConfigurationFileReadFailureException;
    import lu.common : FileTypeMismatchException;
    import lu.serialisation : DeserialisationException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;
    import std.process : ProcessException;

    try
    {
        // Act on arguments getopt, pass return value to main
        return instance.handleGetopt(args);
    }
    catch (GetOptException e)
    {
        enum pattern = "Error parsing command-line arguments: <l>%s";
        logger.errorf(pattern, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConvException e)
    {
        enum pattern = "Error converting command-line arguments: <l>%s";
        logger.errorf(pattern, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (FileTypeMismatchException e)
    {
        enum pattern = "Specified configuration file <l>%s</> is not a file!";
        logger.errorf(pattern, e.filename);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConfigurationFileReadFailureException e)
    {
        enum pattern = "Error reading and decoding configuration file [<l>%s</>]: <l>%s";
        logger.errorf(pattern, e.filename, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (DeserialisationException e)
    {
        enum pattern = "Error parsing configuration file: <l>%s";
        logger.errorf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ProcessException e)
    {
        enum pattern = "Failed to open <l>%s</> in an editor: <l>%s";
        logger.errorf(pattern, instance.settings.configFile, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (IRCPluginSettingsException e)
    {
        // Can be thrown from printSettings
        logger.error(e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unexpected exception: <l>%s";
        logger.errorf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e);
    }

    return Next.returnFailure;
}


// tryConnect
/++
    Tries to connect to the IPs in
    [kameloso.kameloso.Kameloso.conn.ips|Kameloso.conn.ips] by leveraging
    [kameloso.net.connectFiber|connectFiber], reacting on the
    [kameloso.net.ConnectionAttempt|ConnectionAttempt]s it yields to provide feedback
    to the user.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].

    Returns:
        [lu.common.Next.continue_|Next.continue_] if connection succeeded,
        [lu.common.Next.returnFailure|Next.returnFailure] if connection failed
        and the program should exit.
 +/
auto tryConnect(ref Kameloso instance)
{
    import kameloso.constants : ConnectionDefaultFloats,
        ConnectionDefaultIntegers, MagicErrorStrings, Timeout;
    import kameloso.net : ConnectionAttempt, connectFiber;
    import kameloso.thread : interruptibleSleep;
    import std.concurrency : Generator;

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(instance.conn, ConnectionDefaultIntegers.retries, *instance.abort));

    scope(exit) destroy(connector);

    try
    {
        connector.call();
    }
    catch (Exception e)
    {
        /+
            We can only detect SSL context creation failure based on the string
            in the generic Exception thrown, sadly.
         +/
        if (e.msg == MagicErrorStrings.sslContextCreationFailure)
        {
            enum message = "Connection error: <l>" ~
                MagicErrorStrings.sslLibraryNotFoundRewritten ~
                " <t>(is OpenSSL installed?)";
            enum wikiMessage = cast(string)MagicErrorStrings.visitWikiOneliner;
            logger.error(message);
            logger.error(wikiMessage);

            version(Windows)
            {
                enum getoptMessage = cast(string)MagicErrorStrings.getOpenSSLSuggestion;
                logger.error(getoptMessage);
            }
        }
        else
        {
            enum pattern = "Connection error: <l>%s";
            logger.errorf(pattern, e.msg);
        }

        return Next.returnFailure;
    }

    uint incrementedRetryDelay = Timeout.connectionRetry;
    enum transientSSLFailureTolerance = 10;
    uint numTransientSSLFailures;

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
            enum pattern = "Retrying in <i>%d</> seconds...";
            logger.logf(pattern, incrementedRetryDelay);
            interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);

            import std.algorithm.comparison : min;
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay *
                ConnectionDefaultFloats.delayIncrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay, Timeout.connectionDelayCap);
        }

        void verboselyDelayToNextIP()
        {
            enum pattern = "Failed to connect to IP. Trying next IP in <i>%d</> seconds.";
            logger.logf(pattern, Timeout.connectionRetry);
            incrementedRetryDelay = Timeout.connectionRetry;
            interruptibleSleep(Timeout.connectionRetry.seconds, *instance.abort);
        }

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case unset:
            // Should never happen
            assert(0, "connector yielded `unset` state");

        case preconnect:
            import lu.common : sharedDomains;
            import std.socket : AddressException, AddressFamily;

            string resolvedHost;  // mutable

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
                    "Connecting to [<i>%s</>]:<i>%s</> %s..." :
                    "Connecting to <i>%s</>:<i>%s</> %s...";

            immutable ssl = instance.conn.ssl ? "(SSL) " : string.init;

            immutable address = (!resolvedHost.length ||
                (instance.parser.server.address == resolvedHost) ||
                (sharedDomains(instance.parser.server.address, resolvedHost) < 2)) ?
                    attempt.ip.toAddrString :
                    resolvedHost;

            logger.logf(rtPattern, address, attempt.ip.toPortString, ssl);
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
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
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
                    enum pattern = "Connection failed with <l>%s</>: <t>%s";
                    logger.warningf(pattern, errnoStrings[attempt.errno], errorString);
                }
                else version(Windows)
                {
                    enum pattern = "Connection failed with error <l>%d</>: <t>%s";
                    logger.warningf(pattern, attempt.errno, errorString);
                }
                else
                {
                    static assert(0, "Unsupported platform, please file a bug.");
                }
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) verboselyDelay();
            numTransientSSLFailures = 0;
            continue;

        case delayThenNextIP:
            // Check abort before delaying and then again after
            if (*instance.abort) return Next.returnFailure;
            verboselyDelayToNextIP();
            if (*instance.abort) return Next.returnFailure;
            numTransientSSLFailures = 0;
            continue;

        /*case noMoreIPs:
            logger.warning("Could not connect to server!");
            return Next.returnFailure;*/

        case ipv6Failure:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                enum pattern = "IPv6 connection failed with <l>%s</>: <t>%s";
                logger.warningf(pattern, errnoStrings[attempt.errno], errorString);
            }
            else version(Windows)
            {
                enum pattern = "IPv6 connection failed with error <l>%d</>: <t>%s";
                logger.warningf(pattern, attempt.errno, errorString);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) goto case delayThenNextIP;
            numTransientSSLFailures = 0;
            continue;

        case transientSSLFailure:
            import lu.string : contains;

            // "Failed to establish SSL connection after successful connect (system lib)"
            // "Failed to establish SSL connection after successful connect" --> attempted SSL on non-SSL server

            enum pattern = "Failed to connect: <l>%s";
            logger.errorf(pattern, attempt.error);
            if (*instance.abort) return Next.returnFailure;

            if ((numTransientSSLFailures++ < transientSSLFailureTolerance) &&
                attempt.error.contains("(system lib)"))
            {
                // Random failure, just reconnect immediately
                // but only `transientSSLFailureTolerance` times
            }
            else
            {
                if (!lastRetry) verboselyDelay();
            }
            continue;

        case fatalSSLFailure:
            enum pattern = "Failed to connect: <l>%s";
            logger.errorf(pattern, attempt.error);
            return Next.returnFailure;

        case invalidConnectionError:
        case error:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                enum pattern = "Failed to connect: <l>%s</> (<l>%s</>)";
                logger.errorf(pattern, errorString, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Failed to connect: <l>%s</> (<l>%d</>)";
                logger.errorf(pattern, errorString, attempt.errno);
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
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
    Tries to resolve the address in
    [kameloso.kameloso.Kameloso.parser.server|Kameloso.parser.server] to IPs, by
    leveraging [kameloso.net.resolveFiber|resolveFiber], reacting on the
    [kameloso.net.ResolveAttempt|ResolveAttempt]s it yields to provide feedback
    to the user.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        firstConnect = Whether or not this is the first time we're attempting a connection.

    Returns:
        [lu.common.Next.continue_|Next.continue_] if resolution succeeded,
        [lu.common.Next.returnFailure|Next.returnFailure] if it failed and the
        program should exit.
 +/
auto tryResolve(ref Kameloso instance, const Flag!"firstConnect" firstConnect)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ResolveAttempt, resolveFiber;
    import std.concurrency : Generator;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(
            instance.conn,
            instance.parser.server.address,
            instance.parser.server.port,
            instance.connSettings.ipv6,
            *instance.abort));

    scope(exit) destroy(resolver);

    uint incrementedRetryDelay = Timeout.connectionRetry;
    enum incrementMultiplier = 1.2;

    void delayOnNetworkDown()
    {
        import kameloso.thread : interruptibleSleep;
        import std.algorithm.comparison : min;
        import core.time : seconds;

        enum pattern = "Network down? Retrying in <i>%d</> seconds.";
        logger.logf(pattern, incrementedRetryDelay);
        interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);
        if (*instance.abort) return;

        enum delayCap = 10*60;  // seconds
        incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
        incrementedRetryDelay = min(incrementedRetryDelay, delayCap);
    }

    foreach (const attempt; resolver)
    {
        import lu.string : beginsWith;

        if (*instance.abort) return Next.returnFailure;

        enum getaddrinfoErrorString = "getaddrinfo error: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.beginsWith(getaddrinfoErrorString) ?
                attempt.error[getaddrinfoErrorString.length..$] :
                attempt.error) :
            string.init;

        with (ResolveAttempt.State)
        final switch (attempt.state)
        {
        case unset:
            // Should never happen
            assert(0, "resolver yielded `unset` state");

        case preresolve:
            // No message for this
            continue;

        case success:
            import lu.string : plurality;
            enum pattern = "<i>%s</> resolved into <i>%d</> %s.";
            logger.logf(
                pattern,
                instance.parser.server.address,
                instance.conn.ips.length,
                instance.conn.ips.length.plurality("IP", "IPs"));
            return Next.continue_;

        case exception:
            enum pattern = "Could not resolve server address: <l>%s</> (<l>%d</>)";
            logger.warningf(pattern, errorString, attempt.errno);
            delayOnNetworkDown();
            if (*instance.abort) return Next.returnFailure;
            continue;

        case error:
            enum pattern = "Could not resolve server address: <l>%s</> (<l>%d</>)";
            logger.errorf(pattern, errorString, attempt.errno);

            if (firstConnect)
            {
                // First attempt and a failure; something's wrong, abort
                enum firstConnectPattern = "Failed to resolve host. Verify that you are " ~
                    "connected to the Internet and that the server address (<i>%s</>) is correct.";
                logger.logf(firstConnectPattern, instance.parser.server.address);
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
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void postInstanceSetup(ref Kameloso instance)
{
    import kameloso.constants : KamelosoInfo;
    import kameloso.terminal : isTerminal, setTitle;

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

    if (isTerminal)
    {
        // TTY or whitelisted pseudo-TTY
        enum terminalTitle = "kameloso v" ~ cast(string)KamelosoInfo.version_;
        setTitle(terminalTitle);
    }
}


// setDefaultDirectories
/++
    Sets default directories in the passed [kameloso.pods.CoreSettings|CoreSettings].

    This is called during early execution.

    Params:
        settings = A reference to some [kameloso.pods.CoreSettings|CoreSettings].
 +/
void setDefaultDirectories(ref CoreSettings settings)
{
    import kameloso.constants : KamelosoFilenames;
    import kameloso.platform : cbd = configurationBaseDirectory, rbd = resourceBaseDirectory;
    import std.path : buildNormalizedPath;

    settings.configFile = buildNormalizedPath(cbd, "kameloso", KamelosoFilenames.configuration);
    settings.resourceDirectory = buildNormalizedPath(rbd, "kameloso");
}


// verifySettings
/++
    Verifies some settings and returns whether the program should continue
    executing (or whether there were errors such that we should exit).

    This is called after command-line arguments have been parsed.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].

    Returns:
        [lu.common.Next.returnFailure|Next.returnFailure] if the program should exit,
        [lu.common.Next.continue_|Next.continue_] otherwise.
 +/
auto verifySettings(ref Kameloso instance)
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
    else version(Windows)
    {
        // On Windows this doesn't happen, so allow all addresses.
        enum addressIsResolvable = true;
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }

    if (!addressIsResolvable)
    {
        enum pattern = "Invalid address! [<l>%s</>]";
        logger.errorf(pattern, instance.parser.server.address);
        return Next.returnFailure;
    }

    return Next.continue_;
}


// resolvePaths
/++
    Resolves resource directory private key/certificate file paths semi-verbosely.

    This is called after settings have been verified, before plugins are initialised.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void resolvePaths(ref Kameloso instance)
{
    import kameloso.platform : rbd = resourceBaseDirectory;
    import std.file : exists;
    import std.path : absolutePath, buildNormalizedPath, dirName, expandTilde, isAbsolute;
    import std.range : only;

    immutable defaultResourceDir = buildNormalizedPath(rbd, "kameloso");

    version(Posix)
    {
        instance.settings.resourceDirectory = instance.settings.resourceDirectory.expandTilde();
    }

    // Resolve and create the resource directory
    // Assume nothing has been entered if it is the default resource dir sans server etc
    if (instance.settings.resourceDirectory == defaultResourceDir)
    {
        version(Windows)
        {
            import std.string : replace;
            instance.settings.resourceDirectory = buildNormalizedPath(
                defaultResourceDir,
                "server",
                instance.parser.server.address.replace(':', '_'));
        }
        else version(Posix)
        {
            instance.settings.resourceDirectory = buildNormalizedPath(
                defaultResourceDir,
                "server",
                instance.parser.server.address);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }
    }

    if (!instance.settings.resourceDirectory.exists)
    {
        import std.file : mkdirRecurse;

        mkdirRecurse(instance.settings.resourceDirectory);
        enum pattern = "Created resource directory <i>%s";
        logger.logf(pattern, instance.settings.resourceDirectory);
    }

    instance.settings.configDirectory = instance.settings.configFile.dirName;

    auto filerange = only(
        &instance.connSettings.caBundleFile,
        &instance.connSettings.privateKeyFile,
        &instance.connSettings.certFile);

    foreach (/*const*/ file; filerange)
    {
        if (!file.length) continue;

        *file = (*file).expandTilde;

        if (!(*file).isAbsolute && !(*file).exists)
        {
            immutable fullPath = instance.settings.configDirectory.isAbsolute ?
                absolutePath(*file, instance.settings.configDirectory) :
                buildNormalizedPath(instance.settings.configDirectory, *file);

            if (fullPath.exists)
            {
                *file = fullPath;
            }
            // else leave as-is
        }
    }
}


// startBot
/++
    Main connection logic.

    This function *starts* the bot, after it has been sufficiently initialised.
    It resolves and connects to servers, then hands off execution to [mainLoop].

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        attempt = [AttemptState] aggregate of state variables used when connecting.
 +/
void startBot(ref Kameloso instance, ref AttemptState attempt)
{
    import kameloso.plugins.common.misc : IRCPluginInitialisationException,
        pluginNameOfFilename, pluginFileBaseName;
    import kameloso.constants : ShellReturnValue;
    import kameloso.terminal : TerminalToken, isTerminal;
    import dialect.parsing : IRCParser;
    import std.algorithm.comparison : among;

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    enum bellString = "" ~ cast(char)(TerminalToken.bell);
    immutable bell = isTerminal ? bellString : string.init;

    outerloop:
    do
    {
        // *instance.abort is guaranteed to be false here.

        instance.generateNewConnectionID();
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

            auto gracePeriodBeforeReconnect = Timeout.connectionRetry.seconds;  // mutable

            version(TwitchSupport)
            {
                import std.algorithm.searching : endsWith;
                import core.time : msecs;

                if (instance.parser.server.address.endsWith(".twitch.tv") && !instance.sawWelcome)
                {
                    // We probably saw an instant disconnect before even getting to RPL_WELCOME
                    // Quickly attempt again
                    static immutable twitchRegistrationFailConnectionRetry =
                        Timeout.twitchRegistrationFailConnectionRetryMsecs.msecs;
                    gracePeriodBeforeReconnect = twitchRegistrationFailConnectionRetry;
                }
            }

            logger.log("One moment...");
            interruptibleSleep(gracePeriodBeforeReconnect, *instance.abort);
            if (*instance.abort) break outerloop;

            // Re-init plugins here so it isn't done on the first connect attempt
            instance.initPlugins();

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

        immutable actionAfterResolve = tryResolve(
            instance,
            cast(Flag!"firstConnect")(attempt.firstConnect));
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

        // Ensure initialised resources after resolve so we know we have a
        // valid server to create a directory for.
        try
        {
            instance.initPluginResources();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            if (e.malformedFilename.length)
            {
                enum pattern = "The <l>%s</> plugin failed to load its resources; " ~
                    "<l>%s</> is malformed. (at <l>%s</>:<l>%d</>)%s";
                logger.warningf(
                    pattern,
                    e.pluginName,
                    e.malformedFilename,
                    e.file.pluginFileBaseName,
                    e.line,
                    bell);
            }
            else
            {
                enum pattern = "The <l>%s</> plugin failed to load its resources; " ~
                    "<l>%s</> (at <l>%s</>:<l>%d</>)%s";
                logger.warningf(
                    pattern,
                    e.pluginName,
                    e.msg,
                    e.file.pluginFileBaseName,
                    e.line,
                    bell);
            }

            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = ShellReturnValue.pluginResourceLoadFailure;
            break outerloop;
        }
        catch (Exception e)
        {
            enum pattern = "An unexpected error occurred while initialising " ~
                "plugin resources: <l>%s</> (at <l>%s</>:<l>%d</>)%s";
            logger.warningf(
                pattern,
                e.msg,
                e.file.pluginFileBaseName,
                e.line,
                bell);

            version(PrintStacktraces) logger.trace(e);
            attempt.retval = ShellReturnValue.pluginResourceLoadException;
            break outerloop;
        }

        // Reinit with its own server.
        instance.parser = IRCParser(backupClient, instance.parser.server);

        try
        {
            instance.setupPlugins();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            if (e.malformedFilename.length)
            {
                enum pattern = "The <l>%s</> plugin failed to setup; " ~
                    "<l>%s</> is malformed. (at <l>%s</>:<l>%d</>)%s";
                logger.warningf(
                    pattern,
                    e.pluginName,
                    e.malformedFilename,
                    e.file.pluginFileBaseName,
                    e.line,
                    bell);
            }
            else
            {
                enum pattern = "The <l>%s</> plugin failed to setup; " ~
                    "<l>%s</> (at <l>%s</>:<l>%d</>)%s";
                logger.warningf(
                    pattern,
                    e.pluginName,
                    e.msg,
                    e.file.pluginFileBaseName,
                    e.line,
                    bell);
            }

            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = ShellReturnValue.pluginSetupFailure;
            break outerloop;
        }
        catch (Exception e)
        {
            enum pattern = "An unexpected error occurred while setting up the <l>%s</> plugin: " ~
                "<l>%s</> (at <l>%s</>:<l>%d</>)%s";
            logger.warningf(
                pattern,
                e.file.pluginNameOfFilename,
                e.msg,
                e.file,
                e.line,
                bell);

            version(PrintStacktraces) logger.trace(e);
            attempt.retval = ShellReturnValue.pluginSetupException;
            break outerloop;
        }

        // Do verbose exits if mainLoop causes a return
        attempt.silentExit = false;

        /+
            If version Callgrind, do a callgrind dump before the main loop starts,
            and then once again on disconnect. That way the dump won't contain
            uninteresting profiling about resolving and connecting and such.
         +/
        version(Callgrind)
        {
            void dumpCallgrind()
            {
                import lu.string : beginsWith;
                import std.conv : to;
                import std.process : execute, thisProcessID;
                import std.stdio : writeln;
                import std.string : chomp;

                immutable dumpCommand =
                [
                    "callgrind_control",
                    "-d",
                    thisProcessID.to!string,
                ];

                logger.info("$ callgrind_control -d ", thisProcessID);
                immutable result = execute(dumpCommand);
                writeln(result.output.chomp);
                instance.callgrindRunning = !result.output.beginsWith("Error: Callgrind task with PID");
            }

            if (instance.callgrindRunning)
            {
                // Dump now and on scope exit
                dumpCallgrind();
            }

            scope(exit) if (instance.callgrindRunning) dumpCallgrind();
        }

        // Start the main loop
        attempt.next = instance.mainLoop();
        attempt.firstConnect = false;
    }
    while (
        !*instance.abort &&
        attempt.next.among!(Next.continue_, Next.retry));
}


// printEventDebugDetails
/++
    Print what we know about an event, from an error perspective.

    Params:
        event = The [dialect.defs.IRCEvent|IRCEvent] in question.
        raw = The raw string that `event` was parsed from, as read from the IRC server.
        eventWasInitialised = Whether the [dialect.defs.IRCEvent|IRCEvent] was
            initialised or if it was only ever set to `void`.
 +/
void printEventDebugDetails(
    const ref IRCEvent event,
    const string raw,
    const Flag!"eventWasInitialised" eventWasInitialised = Yes.eventWasInitialised)
{
    if (globalHeadless || !raw.length) return;

    version(IncludeHeavyStuff)
    {
        enum onlyPrintRaw = false;
    }
    else
    {
        enum onlyPrintRaw = true;
    }

    if (onlyPrintRaw || !eventWasInitialised || !event.raw.length) // == IRCEvent.init
    {
        enum pattern = `Offending line: "<l>%s</>"`;
        logger.warningf(pattern, raw);
    }
    else
    {
        version(IncludeHeavyStuff)
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
}


// printSummary
/++
    Prints a summary of the connection(s) made and events parsed this execution.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void printSummary(const ref Kameloso instance)
{
    import kameloso.time : timeSince;
    import core.time : Duration;

    Duration totalTime;
    ulong totalBytesReceived;
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
        immutable startString = fullDatePattern.format(
            start.year,
            start.month,
            start.day,
            start.hour,
            start.minute,
            start.second);

        auto stop = SysTime.fromUnixTime(entry.stopTime);
        immutable stopString = (start.dayOfGregorianCal == stop.dayOfGregorianCal) ?
            onlyTimePattern.format(
                stop.hour,
                stop.minute,
                stop.second) :
            fullDatePattern.format(
                stop.year,
                stop.month,
                stop.day,
                stop.hour,
                stop.minute,
                stop.second);

        start.fracSecs = 0.hnsecs;
        stop.fracSecs = 0.hnsecs;
        immutable duration = (stop - start);
        totalTime += duration;
        totalBytesReceived += entry.bytesReceived;

        enum pattern = "%2d: %s, %d events parsed in %,d bytes (%s to %s)";
        writefln(
            pattern,
            ++i,
            duration.timeSince!(7, 0)(Yes.abbreviate),
            entry.numEvents,
            entry.bytesReceived,
            startString,
            stopString);
    }

    enum timeConnectedPattern = "Total time connected: <l>%s";
    logger.infof(timeConnectedPattern, totalTime.timeSince!(7, 1));
    enum receivedPattern = "Total received: <l>%,d</> bytes";
    logger.infof(receivedPattern, totalBytesReceived);
}


// AttemptState
/++
    Aggregate of state values used in an execution of the program.
 +/
struct AttemptState
{
    /// Enum denoting what we should do next loop in an execution attempt.
    Next next;

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


// syncGuestChannels
/++
    Syncs currently joined channels with [IRCBot.guestChannels|guestChannels],
    adding entries in the latter where the former is missing.

    We can't just check the first plugin at `instance.plugins[0]` since there's
    no way to be certain it mixes in [kameloso.plugins.common.mixins.ChannelAwareness|ChannelAwareness].

    Used when saving to configuration file, to ensure the current state is saved.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void syncGuestChannels(ref Kameloso instance)
{
    foreach (plugin; instance.plugins)
    {
        // Skip plugins that don't seem to mix in ChannelAwareness
        if (!plugin.state.channels.length) continue;

        foreach (immutable channelName; plugin.state.channels.byKey)
        {
            import std.algorithm.searching : canFind;

            if (!instance.bot.homeChannels.canFind(channelName) &&
                !instance.bot.guestChannels.canFind(channelName))
            {
                // We're in a channel that isn't tracked as home or guest
                // We're also saving, so save it as guest
                instance.bot.guestChannels ~= channelName;
            }
        }

        // We only need the channels from one plugin, as we can be reasonably sure
        // every plugin that have channels have the same channels
        break;
    }
}


// getQuitMessageInFlight
/++
    Get any QUIT concurrency messages currently in the mailbox. Also catch Variants
    so as not to throw an exception on missed priority messages.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].

    Returns:
        A [kameloso.thread.ThreadMessage|ThreadMessage] with its `content` message
        containing any quit reasons encountered.
 +/
auto getQuitMessageInFlight(ref Kameloso instance)
{
    import kameloso.string : replaceTokens;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : receiveTimeout;
    import std.variant : Variant;
    import core.time : Duration;

    ThreadMessage returnMessage;
    bool receivedSomething;
    bool halt;

    do
    {
        receivedSomething = receiveTimeout(Duration.zero,
            (ThreadMessage message) scope
            {
                if (message.type == ThreadMessage.Type.quit)
                {
                    returnMessage = message;
                    halt = true;
                }
            },
            (Variant _) scope {},
        );
    }
    while (!halt && receivedSomething);

    return returnMessage;
}


// echoQuitMessage
/++
    Echos the quit message to the local terminal, to fake it being sent verbosely
    to the server. It is sent, but later, bypassing the message Fiber which would
    otherwise do the echoing.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        reason = Quit reason.
 +/
void echoQuitMessage(ref Kameloso instance, const string reason)
{
    bool printed;

    version(Colours)
    {
        if (!instance.settings.monochrome)
        {
            import kameloso.irccolours : mapEffects;
            logger.trace("--> QUIT :", reason.mapEffects);
            printed = true;
        }
    }

    if (!printed)
    {
        import kameloso.irccolours : stripEffects;
        logger.trace("--> QUIT :", reason.stripEffects);
    }
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
auto run(string[] args)
{
    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import kameloso.constants : ShellReturnValue;
    import kameloso.logger : KamelosoLogger;
    import kameloso.string : replaceTokens;
    import std.algorithm.comparison : among;
    import std.conv : ConvException;
    import std.exception : ErrnoException;
    static import kameloso.common;

    // Set up the Kameloso instance.
    Kameloso instance;
    instance.postInstanceSetup();

    // Set pointers.
    kameloso.common.settings = &instance.settings;
    instance.abort = &globalAbort;

    // Declare AttemptState instance.
    AttemptState attempt;

    // Set up default directories in the settings.
    setDefaultDirectories(instance.settings);

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for monochrome and headless
    kameloso.common.logger = new KamelosoLogger(instance.settings);

    // Set up signal handling so that we can gracefully catch Ctrl+C.
    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken, isTerminal;

        if (!instance.settings.headless)
        {
            enum bellString = "" ~ cast(char)(TerminalToken.bell);
            immutable bell = isTerminal ? bellString : string.init;
            logger.error("We just crashed!", bell);
        }

        *instance.abort = true;
        resetSignals();
    }

    immutable actionAfterGetopt = instance.tryGetopt(args);
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

    case crash:  // as above
        assert(0, "`tryGetopt` returned `Next.crash`");
    }

    if (!instance.settings.headless || instance.settings.force)
    {
        try
        {
            import kameloso.terminal : ensureAppropriateBuffering;

            // Ensure stdout is buffered by line if we think it isn't being
            ensureAppropriateBuffering();
        }
        catch (ErrnoException e)
        {
            import std.stdio : writeln;
            if (!instance.settings.headless) writeln("Failed to set stdout buffer mode/size! errno:", e.errno);
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
        finally
        {
            if (instance.settings.flush) stdout.flush();
        }
    }

    // Apply some defaults to empty members, as stored in `kameloso.constants`.
    // It's done before in tryGetopt but do it again to ensure we don't have an empty nick etc
    // Skip if --force was passed.
    if (!instance.settings.force)
    {
        import kameloso.config : applyDefaults;
        applyDefaults(instance.parser.client, instance.parser.server, instance.bot);
    }

    // Additionally if the port is an SSL-like port, assume SSL,
    // but only if the user isn't forcing settings
    if (!instance.connSettings.ssl &&
        !instance.settings.force &&
        instance.parser.server.port.among!(6697, 7000, 7001, 7029, 7070, 9999, 443))
    {
        instance.connSettings.ssl = true;
    }

    // Copy ssl setting to the Connection after the above
    instance.conn.ssl = instance.connSettings.ssl;

    if (!instance.settings.headless)
    {
        import kameloso.common : printVersionInfo;
        import kameloso.printing : printObjects;
        import std.stdio : writeln;

        printVersionInfo();
        writeln();
        if (instance.settings.flush) stdout.flush();

        // Print the current settings to show what's going on.
        IRCClient prettyClient = instance.parser.client;
        prettyClient.realName = replaceTokens(prettyClient.realName);
        printObjects(prettyClient, instance.bot, instance.parser.server);

        if (!instance.bot.homeChannels.length && !instance.bot.admins.length)
        {
            import kameloso.config : giveBrightTerminalHint, notifyAboutIncompleteConfiguration;

            giveBrightTerminalHint();
            logger.trace();
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

    case returnSuccess:  // as above
        assert(0, "`verifySettings` returned `Next.returnSuccess`");

    case returnFailure:
        return ShellReturnValue.settingsVerificationFailure;

    case crash:  // as above
        assert(0, "`verifySettings` returned `Next.crash`");
    }

    // Resolve resource and private key/certificate paths.
    instance.resolvePaths();
    instance.conn.certFile = instance.connSettings.certFile;
    instance.conn.privateKeyFile = instance.connSettings.privateKeyFile;

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Initialise plugins outside the loop once, for the error messages
    try
    {
        import std.file : exists;

        instance.initPlugins();

        if (!instance.settings.headless &&
            instance.missingConfigurationEntries.length &&
            instance.settings.configFile.exists)
        {
            import kameloso.config : notifyAboutMissingSettings;

            notifyAboutMissingSettings(
                instance.missingConfigurationEntries,
                args[0],
                instance.settings.configFile);
        }
    }
    catch (ConvException e)
    {
        // Configuration file/--set argument syntax error
        logger.error(e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        if (!instance.settings.force) return ShellReturnValue.customConfigSyntaxFailure;
    }
    catch (IRCPluginSettingsException e)
    {
        // --set plugin/setting name error
        logger.error(e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        if (!instance.settings.force) return ShellReturnValue.customConfigFailure;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Go!
    instance.startBot(attempt);

    // If we're here, we should exit. The only question is in what way.

    if (instance.conn.connected)
    {
        // Send a proper QUIT, optionally verbosely
        string reason;  // mutable

        if (!*instance.abort && !instance.settings.headless && !instance.settings.hideOutgoing)
        {
            const message = instance.getQuitMessageInFlight();
            reason = message.content.length ?
                message.content :
                instance.bot.quitReason;
            reason = reason.replaceTokens(instance.parser.client);

            instance.echoQuitMessage(reason);
        }

        if (!reason.length)
        {
            reason = instance.bot.quitReason.replaceTokens(instance.parser.client);
        }

        instance.conn.sendline("QUIT :" ~ reason);
    }

    // Save if we're exiting and configuration says we should.
    if (instance.settings.saveOnExit)
    {
        try
        {
            import kameloso.config : writeConfigurationFile;
            instance.syncGuestChannels();
            instance.writeConfigurationFile(instance.settings.configFile);
        }
        catch (Exception e)
        {
            enum pattern = "Caught Exception when saving settings: " ~
                "<l>%s</> (at <l>%s</>:<l>%d</>)";
            logger.warningf(pattern, e.msg, e.file, e.line);
            version(PrintStacktraces) logger.trace(e);
        }
    }

    // Print connection summary
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
                enum pattern = "Allocated in current thread: <l>%,d</> bytes";
                logger.infof(pattern, allocated);
            }

            enum memoryUsedPattern = "Memory used: <l>%,d</> bytes, free <l>%,d</> bytes";
            logger.infof(memoryUsedPattern,
                stats.usedSize, stats.freeSize);
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

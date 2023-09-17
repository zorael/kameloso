/++
    The main module, housing startup logic and the main event loop.

    No module (save [kameloso.entrypoint]) should be importing this.

    See_Also:
        [kameloso.kameloso],
        [kameloso.common],
        [kameloso.config]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
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
    import std.exception : assumeUnique;

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
    sink.put("initReserve:8 minPoolSize:8"); // incPoolSize:16
    return sink.data.assumeUnique();
}();


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

    Sets the [kameloso.common.globalAbort|globalAbort] global to `Yes.abort`
    so other parts of the program knows to gracefully shut down.

    Params:
        sig = Integer value of the signal raised.
 +/
extern (C)
void signalHandler(int sig) nothrow @nogc @system
{
    import core.stdc.stdio : printf;
    static import kameloso.common;

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

    if (kameloso.common.globalHeadless && (sig < signalNames.length))
    {
        if (!kameloso.common.globalAbort)
        {
            printf("...caught signal SIG%s!\n", signalNames[sig].ptr);
        }
        else if (sig == 2)
        {
            printf("...caught another signal SIG%s! " ~
                "(press Enter if nothing happens, or Ctrl+C again)\n", signalNames[sig].ptr);
        }
    }

    if (kameloso.common.globalAbort) resetSignals();
    else kameloso.common.globalAbort = Yes.abort;

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
    import core.time : Duration, MonoTime, msecs;

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
                    cast(Flag!"quiet")(message.quiet || instance.settings.hideOutgoing)));
                break;

            case quietline:
                instance.outbuffer.put(OutgoingLine(
                    message.content,
                    Yes.quiet));
                break;

            case immediateline:
                instance.immediateBuffer.put(OutgoingLine(
                    message.content,
                    cast(Flag!"quiet")(message.quiet || instance.settings.hideOutgoing)));
                break;

            case shortenReceiveTimeout:
                instance.flags.wantReceiveTimeoutShortened = true;
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
                instance.flags.quitMessageSent = true;
                next = Next.returnSuccess;
                break;

            case reconnect:
                import kameloso.thread : Boxed;

                if (auto boxedReexecFlag = cast(Boxed!bool)message.payload)
                {
                    // Re-exec explicitly requested
                    instance.flags.askedToReexec = boxedReexecFlag.payload;
                }
                else
                {
                    // Normal reconnect
                    instance.flags.askedToReconnect = true;
                }

                immutable quitMessage = message.content.length ?
                    message.content :
                    "Reconnecting.";
                instance.priorityBuffer.put(OutgoingLine(
                    "QUIT :" ~ quitMessage,
                    Yes.quiet));
                instance.flags.quitMessageSent = true;
                next = Next.retry;
                break;

            case wantLiveSummary:
                instance.flags.wantLiveSummary = true;
                break;

            case abort:
                *instance.abort = Yes.abort;
                break;

            case reload:
                pluginForeach:
                foreach (plugin; instance.plugins)
                {
                    if (!plugin.isEnabled) continue;

                    try
                    {
                        if (!message.content.length) plugin.reload();
                        else if (message.content == plugin.name)
                        {
                            plugin.reload();
                            break pluginForeach;
                        }
                    }
                    catch (Exception e)
                    {
                        enum pattern = "The <l>%s</> plugin threw an exception when reloading: <t>%s";
                        logger.errorf(pattern, plugin.name, e.msg);
                        version(PrintStacktraces) logger.trace(e);
                    }
                }
                break;

            case save:
                import kameloso.config : writeConfigurationFile;
                syncGuestChannels(instance);
                writeConfigurationFile(instance, instance.settings.configFile);
                break;

            case popCustomSetting:
                size_t[] toRemove;

                foreach (immutable i, immutable line; instance.customSettings)
                {
                    import lu.string : advancePast;

                    string slice = line;  // mutable
                    immutable setting = slice.advancePast('=', Yes.inherit);
                    if (setting == message.content) toRemove ~= i;
                }

                foreach_reverse (immutable i; toRemove)
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    instance.customSettings = instance.customSettings
                        .remove!(SwapStrategy.unstable)(i);
                }

                toRemove = null;
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
                import std.stdio : stdout;

                enum pattern = "onThreadMessage received unexpected message type: <l>%s";
                logger.errorf(pattern, message.type);
                if (instance.settings.flush) stdout.flush();
                break;
            }
        }

        /++
            Reverse-formats an event and sends it to the server.
         +/
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
                    line = pattern.format(emoteTarget, cast(char)IRCControlCharacter.ctcp, m.event.content);
                }
                break;

            case MODE:
                import lu.string : strippedRight;

                enum pattern = "MODE %s %s %s";
                line = pattern.format(m.event.channel, m.event.aux[0], m.event.content.strippedRight);
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
                line = pattern.format(m.event.channel, m.event.target.nickname, reason);
                break;

            case PART:
                if (m.event.content.length)
                {
                    // Reason given, assume only one channel
                    line = text(
                        "PART ",
                        m.event.channel,
                        " :",
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

                immutable nowInUnix = Clock.currTime.toUnixTime();
                immutable then = instance.previousWhoisTimestamps.get(m.event.target.nickname, 0);
                immutable hysteresis = force ? 1 : Timeout.whoisRetry;

                version(TraceWhois)
                {
                    version(unittest) {}
                    else
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
                        // flush stdout with writeln later below
                    }
                }

                immutable delta = (nowInUnix - then);

                if (delta > hysteresis)
                {
                    version(TraceWhois)
                    {
                        version(unittest) {}
                        else
                        {
                            writeln(" ...and actually issuing.");
                        }
                    }

                    line = "WHOIS " ~ m.event.target.nickname;
                    propagateWhoisTimestamp(instance, m.event.target.nickname, nowInUnix);
                }
                else
                {
                    version(TraceWhois)
                    {
                        version(unittest) {}
                        else
                        {
                            enum alreadyIssuedPattern = " ...but already issued %d seconds ago.";
                            writefln(alreadyIssuedPattern, (nowInUnix - then));
                        }
                    }
                }

                version(TraceWhois)
                {
                    import std.stdio : stdout;
                    if (instance.settings.flush) stdout.flush();
                }
                break;

            case QUIT:
                immutable rawReason = m.event.content.length ?
                    m.event.content :
                    instance.bot.quitReason;
                immutable reason = rawReason.replaceTokens(instance.parser.client);
                line = "QUIT :" ~ reason;
                instance.flags.quitMessageSent = true;
                next = Next.returnSuccess;
                break;

            case UNSET:
                line = m.event.content;
                break;

            default:
                // No need to use Enum!(IRCEvent.Type) here, logger does it internally
                logger.error("<l>messageFiber</>.<l>eventToServer</> missing case " ~
                    "for outgoing event type <l>", m.event.type);
                break;
            }

            void appropriateline(const string finalLine)
            {
                if (immediate)
                {
                    return instance.immediateBuffer.put(OutgoingLine(finalLine, quietFlag));
                }

                version(TwitchSupport)
                {
                    if (/*(instance.parser.server.daemon == IRCServer.Daemon.twitch) &&*/ fast)
                    {
                        // Send a line via the fastbuffer, faster than normal sends.
                        return instance.fastbuffer.put(OutgoingLine(finalLine, quietFlag));
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

            lines = null;
        }

        /++
            Proxies the passed message to the [kameloso.logger.logger].
         +/
        void proxyLoggerMessages(OutputRequest request) scope
        {
            if (instance.settings.headless) return;

            with (OutputRequest.Level)
            final switch (request.logLevel)
            {
            case writeln:
                import kameloso.logger : LogLevel;
                import kameloso.terminal.colours.tags : expandTags;
                import std.stdio : stdout, writeln;

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

        /++
            Timestamp of when the loop started.
         +/
        immutable loopStartTime = MonoTime.currTime;
        static immutable maxReceiveTime = Timeout.messageReadMsecs.msecs;

        while (
            !*instance.abort &&
            (next == Next.continue_) &&
            ((MonoTime.currTime - loopStartTime) <= maxReceiveTime))
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
    import kameloso.net : ListenAttempt, SocketSendException, listenFiber;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock, SysTime;
    import core.thread : Fiber;

    /// Variable denoting what we should do next loop.
    Next next;

    alias State = ListenAttempt.State;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(
            instance.conn,
            instance.abort,
            Timeout.connectionLost));

    // Likewise a Generator to handle concurrency messages
    auto messenger = new Generator!Next(() => messageFiber(instance));

    scope(exit)
    {
        destroy(listener);
        destroy(messenger);
        listener = null;
        messenger = null;
    }

    /++
        Invokes the messenger Generator.
     +/
    Next callMessenger()
    {
        try
        {
            messenger.call();
        }
        catch (Exception e)
        {
            import kameloso.string : doublyBackslashed;

            enum pattern = "Unhandled messenger exception: <t>%s</> (at <l>%s</>:<l>%d</>)";
            logger.warningf(pattern, e.msg, e.file.doublyBackslashed, e.line);
            version(PrintStacktraces) logger.trace(e);
            return Next.returnFailure;
        }

        if (messenger.state == Fiber.State.HOLD)
        {
            return messenger.front;
        }
        else
        {
            logger.error("Internal error, thread messenger Fiber ended unexpectedly.");
            return Next.returnFailure;
        }
    }

    /++
        Processes buffers and sends queued messages to the server.
     +/
    void processBuffers(ref uint timeoutFromMessages)
    {
        bool buffersHaveMessages = (
            !instance.outbuffer.empty |
            !instance.backgroundBuffer.empty |
            !instance.immediateBuffer.empty |
            !instance.priorityBuffer.empty);

        version(TwitchSupport)
        {
            buffersHaveMessages |= !instance.fastbuffer.empty;
        }

        if (buffersHaveMessages)
        {
            immutable untilNext = sendLines(instance);

            if (untilNext > 0.0)
            {
                timeoutFromMessages = cast(uint)(untilNext * 1000);
            }
        }
    }

    // Immediately check for messages, in case starting plugins left some
    next = callMessenger();
    if (next != Next.continue_) return next;

    /// The history entry for the current connection.
    Kameloso.ConnectionHistoryEntry* historyEntry;

    immutable historyEntryIndex = instance.connectionHistory.length;  // snapshot index, 0 at first
    instance.connectionHistory ~= Kameloso.ConnectionHistoryEntry.init;
    historyEntry = &instance.connectionHistory[historyEntryIndex];
    historyEntry.startTime = Clock.currTime.toUnixTime();
    historyEntry.stopTime = historyEntry.startTime;  // In case we abort before the first read is recorded

    /// UNIX timestamp of when the Socket receive timeout was shortened.
    long timeWhenReceiveWasShortened;

    /// `Timeout.maxShortenDurationMsecs` in hecto-nanoseconds.
    enum maxShortenDurationHnsecs = Timeout.maxShortenDurationMsecs * 10_000;

    /++
        The timestamp of when the previous loop started.
        Start at `SysTime.init` so the first tick always runs.
     +/
    SysTime previousLoop; // = Clock.currTime;

    do
    {
        if (*instance.abort) return Next.returnFailure;

        if (!instance.settings.headless && instance.flags.wantLiveSummary)
        {
            // Live connection summary requested.
            printSummary(instance);
            instance.flags.wantLiveSummary = false;
        }

        if (listener.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected by itself; reconnect
            return Next.retry;
        }

        immutable now = Clock.currTime;
        immutable nowInUnix = now.toUnixTime();
        immutable nowInHnsecs = now.stdTime;
        immutable elapsed = (now - previousLoop);

        /// The timestamp of the next scheduled delegate or fiber across all plugins.
        long nextGlobalScheduledTimestamp;

        /// Whether or not blocking was disabled on the socket to force an instant read timeout.
        bool socketBlockingDisabled;

        /// Whether or not to check messages after doing the pre-onEvent routines
        bool shouldCheckMessages;

        /// Adjusted receive timeout based on outgoing message buffers.
        uint timeoutFromMessages = uint.max;

        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            // Tick the plugin, and flag to check for messages if it returns true
            shouldCheckMessages |= plugin.tick(elapsed);

            if (plugin.state.specialRequests.length)
            {
                try
                {
                    processSpecialRequests(instance, plugin);
                }
                catch (Exception e)
                {
                    logPluginActionException(
                        e,
                        plugin,
                        IRCEvent.init,
                        "specialRequests");
                }

                if (*instance.abort) return Next.returnFailure;
                instance.checkPluginForUpdates(plugin);
            }

            if (plugin.state.scheduledFibers.length ||
                plugin.state.scheduledDelegates.length)
            {
                if (plugin.state.nextScheduledTimestamp <= nowInHnsecs)
                {
                    // These handle exceptions internally
                    processScheduledDelegates(plugin, nowInHnsecs);
                    if (*instance.abort) return Next.returnFailure;
                    processScheduledFibers(plugin, nowInHnsecs);
                    if (*instance.abort) return Next.returnFailure;
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
        }

        if (shouldCheckMessages)
        {
            next = callMessenger();
            if (*instance.abort) return Next.returnFailure;

            try
            {
                processBuffers(timeoutFromMessages);
            }
            catch (SocketSendException _)
            {
                logger.error("Failure sending data to server! Connection lost?");
                return Next.retry;
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
            propagateWhoisTimestamps(instance);
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
                processLineFromServer(instance, attempt.line, nowInUnix);
                break;

            case retry:
                // Break and try again
                historyEntry.stopTime = nowInUnix;
                break listenerloop;

            case returnFailure:
                return Next.retry;

            case returnSuccess:  // should never happen
            case crash:  // ditto
                import lu.conv : Enum;
                import std.conv : text;

                immutable message = text(
                    "`listenAttemptToNext` returned `",
                    Enum!Next.toString(actionAfterListen),
                    "`");
                assert(0, message);
            }
        }

        // Check concurrency messages to see if we should exit
        next = callMessenger();
        if (*instance.abort) return Next.returnFailure;
        //else if (next != Next.continue_) return next;  // process buffers before passing on Next.retry

        try
        {
            processBuffers(timeoutFromMessages);
        }
        catch (SocketSendException _)
        {
            logger.error("Failure sending data to server! Connection lost?");
            return Next.retry;
        }

        if (timeWhenReceiveWasShortened &&
            (nowInHnsecs > (timeWhenReceiveWasShortened + maxShortenDurationHnsecs)))
        {
            // Shortened duration passed, reset timestamp to disable it
            timeWhenReceiveWasShortened = 0L;
        }

        if (instance.flags.wantReceiveTimeoutShortened)
        {
            // Set the timestamp and unset the bool
            instance.flags.wantReceiveTimeoutShortened = false;
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

            immutable supposedNewTimeout = min(
                defaultTimeout,
                timeoutFromMessages,
                untilNextGlobalScheduled);

            if (supposedNewTimeout != instance.conn.receiveTimeout)
            {
                instance.conn.receiveTimeout = (supposedNewTimeout > 0) ?
                    supposedNewTimeout :
                    1;
            }
        }
        else if (instance.conn.receiveTimeout != instance.connSettings.receiveTimeout)
        {
            instance.conn.receiveTimeout = instance.connSettings.receiveTimeout;
        }

        if (socketBlockingDisabled)
        {
            // Restore blocking behaviour.
            instance.conn.socket.blocking = true;
        }

        previousLoop = now;
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
    case unset:  // should never happen
    case prelisten:  // ditto
        import lu.conv : Enum;
        import std.conv : text;
        assert(0, text("listener yielded `", Enum!(ListenAttempt.State).toString(attempt.state), "` state"));

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
            enum pattern = "Connection error! (<l>%s</>) <t>(%s)";
            logger.warningf(pattern, attempt.error, errnoStrings[attempt.errno]);
        }
        else version(Windows)
        {
            enum pattern = "Connection error! (<l>%s</>) <t>(%d)";
            logger.warningf(pattern, attempt.error, attempt.errno);
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        // Sleep briefly so it won't flood the screen on chains of errors
        static immutable readErrorGracePeriod = Timeout.readErrorGracePeriodMsecs.msecs;
        interruptibleSleep(readErrorGracePeriod, instance.abort);
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
                enum pattern = "Connection error: invalid server response! (<l>%s</>) <t>(%s)";
                logger.errorf(pattern, attempt.error, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Connection error: invalid server response! (<l>%s</>) <t>(%d)";
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


// logPluginActionException
/++
    Logs an exception thrown by a plugin action.

    Params:
        base = The exception thrown.
        plugin = The plugin that threw the exception.
        event = The event that triggered the plugin action.
        fun = The name of the plugin action that threw the exception.
 +/
void logPluginActionException(
    Exception base,
    const IRCPlugin plugin,
    const IRCEvent event,
    const string fun)
{
    import lu.string : AdvanceException;
    import std.utf : UTFException;
    import core.exception : UnicodeException;

    if (auto e = cast(AdvanceException)base)
    {
        enum pattern = `AdvanceException %s.%s: tried to advance past "<t>%s</>" with "<l>%s</>"`;
        logger.warningf(pattern, plugin.name, fun, e.haystack, e.needle);
        if (event.raw.length) printEventDebugDetails(event, event.raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else if (auto e = cast(UTFException)base)
    {
        enum pattern = "UTFException %s.%s: <t>%s";
        logger.warningf(pattern, plugin.name, fun, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else if (auto e = cast(UnicodeException)base)
    {
        enum pattern = "UnicodeException %s.%s: <t>%s";
        logger.warningf(pattern, plugin.name, fun, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else
    {
        enum pattern = "Exception %s.%s: <t>%s";
        logger.warningf(pattern, plugin.name, fun, base.msg);
        if (event.raw.length) printEventDebugDetails(event, event.raw);
        version(PrintStacktraces) logger.trace(base);
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
void processLineFromServer(
    ref Kameloso instance,
    const string raw,
    const long nowInUnix)
{
    import kameloso.string : doublyBackslashed;
    import dialect.common : IRCParseException;
    import lu.string : AdvanceException;
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
            import std.algorithm.searching : canFind;
            import std.stdio : stdout;

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
                    enum pattern = "%3d: '%c'";
                    writefln(pattern, c, cast(char)c);
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

        // Save timestamp in the event itself.
        event.time = nowInUnix;

        version(TwitchSupport)
        {
            if (instance.parser.server.daemon == IRCServer.Daemon.twitch && event.content.length)
            {
                import std.algorithm.searching : endsWith;

                /+
                    On Twitch, sometimes the content string ends with an invisible
                    [ 243, 160, 128, 128 ], possibly because of a browser extension
                    circumventing the duplicate message block.

                    It wrecks things. So slice it away if detected.
                 +/

                static immutable ubyte[4] badTail = [ 243, 160, 128, 128 ];

                if ((cast(ubyte[])event.content).endsWith(badTail[]))
                {
                    event.content = event.content[0..$-badTail.length];
                }
            }
        }

        version(TwitchSupport)
        {
            // If it's an RPL_WELCOME event, record it as having been seen so we
            // know we can't reconnect without waiting a bit.
            if (event.type == IRCEvent.Type.RPL_WELCOME)
            {
                instance.flags.sawWelcome = true;
            }
        }

        alias ParserUpdates = typeof(instance.parser.updates);

        if (instance.parser.updates & ParserUpdates.client)
        {
            // Parsing changed the client; propagate
            instance.parser.updates &= ~ParserUpdates.client;
            instance.propagate(instance.parser.client);
        }

        if (instance.parser.updates & ParserUpdates.server)
        {
            // Parsing changed the server; propagate
            instance.parser.updates &= ~ParserUpdates.server;
            instance.propagate(instance.parser.server);
        }

        // Let each plugin postprocess the event
        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            try
            {
                plugin.postprocess(event);
            }
            catch (Exception e)
            {
                logPluginActionException(
                    e,
                    plugin,
                    event,
                    "postprocess");
            }

            if (*instance.abort) return;  // handled in mainLoop listenerloop
            instance.checkPluginForUpdates(plugin);
        }

        // Let each plugin process the event
        foreach (plugin; instance.plugins)
        {
            if (!plugin.isEnabled) continue;

            try
            {
                plugin.onEvent(event);
            }
            catch (Exception e)
            {
                logPluginActionException(
                    e,
                    plugin,
                    event,
                    "onEvent");
            }

            // These handle exceptions internally
            if (*instance.abort) return;
            if (plugin.state.hasPendingReplays) processPendingReplays(instance, plugin);
            if (plugin.state.readyReplays.length) processReadyReplays(instance, plugin);
            if (*instance.abort) return;
            processAwaitingDelegates(plugin, event);
            processAwaitingFibers(plugin, event);
            if (*instance.abort) return;
            instance.checkPluginForUpdates(plugin);
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
        enum pattern = "IRCParseException: <t>%s</> (at <l>%s</>:<l>%d</>)";
        logger.warningf(pattern, e.msg, e.file.doublyBackslashed, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (AdvanceException e)
    {
        enum pattern = `AdvanceException: tried to advance past "<l>%s</>" with "<l>%s</>" (at <l>%s</>:<l>%d</>)`;
        logger.warningf(pattern, e.haystack, e.needle, e.file.doublyBackslashed, e.line);
        printEventDebugDetails(event, raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UTFException e)
    {
        enum pattern = "UTFException: <t>%s";
        logger.warningf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (UnicodeException e)
    {
        enum pattern = "UnicodeException: <t>%s";
        logger.warningf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (Exception e)
    {
        enum pattern = "Unhandled exception: <t>%s</> (at <l>%s</>:<l>%d</>)";
        logger.warningf(pattern, e.msg, e.file.doublyBackslashed, e.line);
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
                enum pattern = "Exception %s.awaitingDelegates[%d]: <t>%s";
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
                logPluginActionException(
                    e,
                    plugin,
                    event,
                    "awaitingFibers");
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
    foreach (ref expiredFiber; expiredFibers)
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
        expiredFiber = null;  // needs ref
    }

    expiredFibers = null;
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
            logPluginActionException(
                e,
                plugin,
                IRCEvent.init,
                "scheduledDelegates");
        }
        finally
        {
            destroy(scheduledDg.dg);
            scheduledDg.dg = null;
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

    toRemove = null;
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

    foreach (immutable i, ref scheduledFiber; plugin.state.scheduledFibers)
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
            logPluginActionException(
                e,
                plugin,
                IRCEvent.init,
                "scheduledFibers");
        }
        finally
        {
            // destroy the Fiber if it has ended
            if (scheduledFiber.fiber.state == Fiber.State.TERM)
            {
                destroy(scheduledFiber.fiber);
                scheduledFiber.fiber = null;  // needs ref
            }
        }

        // Always remove a scheduled Fiber after processing
        toRemove ~= i;
    }

    // Clean up processed Fibers
    foreach_reverse (immutable i; toRemove)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        plugin.state.scheduledFibers = plugin.state.scheduledFibers
            .remove!(SwapStrategy.unstable)(i);
    }

    toRemove = null;
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

        foreach (postprocessor; instance.plugins)
        {
            try
            {
                postprocessor.postprocess(replay.event);
            }
            catch (Exception e)
            {
                logPluginActionException(
                    e,
                    postprocessor,
                    replay.event,
                    "postprocessReadyReplay");
            }
        }

        // If we're here no exceptions were thrown

        try
        {
            replay.dg(replay);
        }
        catch (Exception e)
        {
            logPluginActionException(
                e,
                plugin,
                replay.event,
                "readyReplay");
        }
        finally
        {
            destroy(replay.dg);
            replay.dg = null;
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

    immutable nowInUnix = Clock.currTime.toUnixTime();

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

        if ((nowInUnix - lastWhois) > Timeout.whoisRetry)
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
            propagateWhoisTimestamp(instance, nickname, nowInUnix);*/

            enum properties = (Message.Property.forced | Message.Property.quiet);
            whois(plugin.state, nickname, properties);
        }
        else
        {
            version(TraceWhois)
            {
                if (!instance.settings.headless)
                {
                    enum pattern = " ...but already issued %d seconds ago.";
                    writefln(pattern, (nowInUnix - lastWhois));
                }
            }
        }

        version(TraceWhois)
        {
            import std.stdio : stdout;
            if (instance.settings.flush) stdout.flush();
        }
    }
}


// processSpecialRequests
/++
    Iterates through a plugin's array of [kameloso.plugins.common.core.SpecialRequest|SpecialRequest]s.
    Depending on what their [kameloso.plugins.common.core.SpecialRequest.fiber|fiber] member
    (which is in actually a [kameloso.thread.CarryingFiber|CarryingFiber]) can be
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
    foreach (ref request; specialRequestsSnapshot)
    {
        scope(exit)
        {
            if (request.fiber.state == Fiber.State.TERM)
            {
                // Clean up
                destroy(request.fiber);
            }

            destroy(request);
            request = null;
        }

        version(WantGetSetSettingHandlers)
        {
            enum wantGetSettingHandler = true;
            enum wantSetSettingHandler = true;
        }
        else version(WithAdminPlugin)
        {
            enum wantGetSettingHandler = true;
            enum wantSetSettingHandler = true;
        }
        else
        {
            enum wantGetSettingHandler = false;
            enum wantSetSettingHandler = false;
        }

        version(WantPeekCommandsHandler)
        {
            enum wantPeekCommandsHandler = true;
        }
        else version(WithHelpPlugin)
        {
            enum wantPeekCommandsHandler = true;
        }
        else version(WithCounterPlugin)
        {
            enum wantPeekCommandsHandler = true;
        }
        else version(WithOnelinerPlugin)
        {
            enum wantPeekCommandsHandler = true;
        }
        else
        {
            enum wantPeekCommandsHandler = false;
        }

        static if (wantPeekCommandsHandler)
        {
            alias PeekCommandsPayload = Tuple!(IRCPlugin.CommandMetadata[string][string]);

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
        }

        static if (wantGetSettingHandler)
        {
            alias GetSettingPayload = Tuple!(string, string, string);

            if (auto fiber = cast(CarryingFiber!(GetSettingPayload))(request.fiber))
            {
                import lu.string : advancePast;
                import std.algorithm.iteration : splitter;
                import std.algorithm.searching : startsWith;
                import std.array : Appender;

                immutable expression = request.context;
                string slice = expression;  // mutable
                immutable pluginName = slice.advancePast('.', Yes.inherit);
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
                            string lineslice = cast(string)line;  // need a string for advancePast and strippedLeft...
                            if (lineslice.startsWith('#')) lineslice = lineslice[1..$];
                            const thisSetting = lineslice.advancePast(' ', Yes.inherit);

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
                            string lineslice = cast(string)line;  // need a string for advancePast and strippedLeft...
                            if (!lineslice.startsWith('[')) allSettings ~= lineslice.advancePast(' ', Yes.inherit);
                        }

                        fiber.payload[0] = pluginName;
                        //fiber.payload[1] = string.init;
                        fiber.payload[2] = allSettings.to!string;
                        fiber.call();
                        allSettings = null;
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
                    break;

                case "connection":
                    // May leak secrets? certFile, privateKey etc...
                    // Careful with how we make this functionality available
                    import lu.serialisation : serialise;
                    sink.serialise(instance.connSettings);
                    apply();
                    break;

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
                    break;
                }
                continue;
            }
        }

        static if (wantSetSettingHandler)
        {
            alias SetSettingPayload = Tuple!(bool);

            if (auto fiber = cast(CarryingFiber!(SetSettingPayload))(request.fiber))
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
        }

        // If we're here, nothing matched
        logger.error("Unhandled special request type: <l>" ~ typeof(request).stringof);
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

    Returns:
        [lu.common.Next|Next].* depending on what action the calling site should take.
 +/
auto tryGetopt(ref Kameloso instance)
{
    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import kameloso.config : handleGetopt;
    import kameloso.configreader : ConfigurationFileReadFailureException;
    import kameloso.string : doublyBackslashed;
    import lu.common : FileTypeMismatchException;
    import lu.serialisation : DeserialisationException;
    import std.conv : ConvException;
    import std.getopt : GetOptException;
    import std.process : ProcessException;

    try
    {
        // Act on arguments getopt, pass return value to main
        return handleGetopt(instance);
    }
    catch (GetOptException e)
    {
        enum pattern = "Error parsing command-line arguments: <t>%s";
        logger.errorf(pattern, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConvException e)
    {
        enum pattern = "Error converting command-line arguments: <t>%s";
        logger.errorf(pattern, e.msg);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (FileTypeMismatchException e)
    {
        enum pattern = "Specified configuration file <l>%s</> is not a file!";
        logger.errorf(pattern, e.filename.doublyBackslashed);
        //version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ConfigurationFileReadFailureException e)
    {
        enum pattern = "Error reading and decoding configuration file [<l>%s</>]: <l>%s";
        logger.errorf(pattern, e.filename.doublyBackslashed, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (DeserialisationException e)
    {
        enum pattern = "Error parsing configuration file: <t>%s";
        logger.errorf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }
    catch (ProcessException e)
    {
        enum pattern = "Failed to open <l>%s</> in an editor: <t>%s";
        logger.errorf(pattern, instance.settings.configFile.doublyBackslashed, e.msg);
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
        enum pattern = "Unexpected exception: <t>%s";
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
    import kameloso.constants :
        ConnectionDefaultFloats,
        ConnectionDefaultIntegers,
        MagicErrorStrings,
        Timeout;
    import kameloso.net : ConnectionAttempt, connectFiber;
    import kameloso.thread : interruptibleSleep;
    import std.concurrency : Generator;

    auto connector = new Generator!ConnectionAttempt(() =>
        connectFiber(
            instance.conn,
            ConnectionDefaultIntegers.retries,
            instance.abort));

    scope(exit)
    {
        destroy(connector);
        connector = null;
    }

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
        import std.algorithm.searching : startsWith;
        import core.time : seconds;

        if (*instance.abort) return Next.returnFailure;

        immutable lastRetry = (attempt.retryNum+1 == ConnectionDefaultIntegers.retries);

        enum unableToConnectString = "Unable to connect socket: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.startsWith(unableToConnectString) ?
                attempt.error[unableToConnectString.length..$] :
                attempt.error) :
            string.init;

        void verboselyDelay()
        {
            enum pattern = "Retrying in <i>%d</> seconds...";
            logger.logf(pattern, incrementedRetryDelay);
            interruptibleSleep(incrementedRetryDelay.seconds, instance.abort);

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
            interruptibleSleep(Timeout.connectionRetry.seconds, instance.abort);
        }

        with (ConnectionAttempt.State)
        final switch (attempt.state)
        {
        case unset:  // should never happen
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
            import std.string : indexOf;

            // "Failed to establish SSL connection after successful connect (system lib)"
            // "Failed to establish SSL connection after successful connect" --> attempted SSL on non-SSL server

            enum pattern = "Failed to connect: <l>%s";
            logger.errorf(pattern, attempt.error);
            if (*instance.abort) return Next.returnFailure;

            if ((numTransientSSLFailures++ < transientSSLFailureTolerance) &&
                (attempt.error.indexOf("(system lib)") != -1))
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
                enum pattern = "Failed to connect: <l>%s</> (<t>%s</>)";
                logger.errorf(pattern, errorString, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                enum pattern = "Failed to connect: <l>%s</> (<t>%d</>)";
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
            cast(Flag!"useIPv6")instance.connSettings.ipv6,
            instance.abort));

    scope(exit)
    {
        destroy(resolver);
        resolver = null;
    }

    uint incrementedRetryDelay = Timeout.connectionRetry;
    enum incrementMultiplier = 1.2;

    void delayOnNetworkDown()
    {
        import kameloso.thread : interruptibleSleep;
        import std.algorithm.comparison : min;
        import core.time : seconds;

        enum pattern = "Network down? Retrying in <i>%d</> seconds.";
        logger.logf(pattern, incrementedRetryDelay);
        interruptibleSleep(incrementedRetryDelay.seconds, instance.abort);
        if (*instance.abort) return;

        enum delayCap = 10*60;  // seconds
        incrementedRetryDelay = cast(uint)(incrementedRetryDelay * incrementMultiplier);
        incrementedRetryDelay = min(incrementedRetryDelay, delayCap);
    }

    foreach (const attempt; resolver)
    {
        import std.algorithm.searching : startsWith;

        if (*instance.abort) return Next.returnFailure;

        enum getaddrinfoErrorString = "getaddrinfo error: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.startsWith(getaddrinfoErrorString) ?
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
            enum pattern = "Could not resolve server address: <l>%s</> <t>(%d)";
            logger.warningf(pattern, errorString, attempt.errno);
            delayOnNetworkDown();
            if (*instance.abort) return Next.returnFailure;
            continue;

        case error:
            enum pattern = "Could not resolve server address: <l>%s</> <t>(%d)";
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
    import kameloso.terminal : isTerminal, setTerminalTitle;

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
        setTerminalTitle();
    }
}


// setDefaultDirectories
/++
    Sets default directories in the passed [kameloso.pods.CoreSettings|CoreSettings].

    This is called during early execution.

    Params:
        settings = A reference to some [kameloso.pods.CoreSettings|CoreSettings].
 +/
void setDefaultDirectories(ref CoreSettings settings) @safe
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

        /*if (!instance.settings.prefix.length)
        {
            logger.error("No prefix configured!");
            return Next.returnFailure;
        }*/
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
        import std.string : indexOf;

        // Workaround for Issue 19247:
        // Segmentation fault when resolving address with std.socket.getAddress inside a Fiber
        // the workaround being never resolve addresses that don't contain at least one dot
        immutable addressIsResolvable =
            instance.settings.force ||
            instance.parser.server.address == "localhost" ||
            (instance.parser.server.address.indexOf('.') != -1) ||
            (instance.parser.server.address.indexOf(':') != -1);
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
void resolvePaths(ref Kameloso instance) @safe
{
    import kameloso.platform : rbd = resourceBaseDirectory;
    import std.file : exists;
    import std.path : absolutePath, buildNormalizedPath, dirName, expandTilde, isAbsolute;
    import std.range : only;

    immutable defaultResourceHomeDir = buildNormalizedPath(rbd, "kameloso");

    version(Posix)
    {
        instance.settings.resourceDirectory = instance.settings.resourceDirectory.expandTilde();
    }

    // Resolve and create the resource directory
    // Assume nothing has been entered if it is the default resource dir sans server etc
    if (instance.settings.resourceDirectory == defaultResourceHomeDir)
    {
        version(Windows)
        {
            import std.string : replace;
            instance.settings.resourceDirectory = buildNormalizedPath(
                defaultResourceHomeDir,
                "server",
                instance.parser.server.address.replace(':', '_'));
        }
        else version(Posix)
        {
            instance.settings.resourceDirectory = buildNormalizedPath(
                defaultResourceHomeDir,
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
        import kameloso.string : doublyBackslashed;
        import std.file : mkdirRecurse;

        mkdirRecurse(instance.settings.resourceDirectory);
        enum pattern = "Created resource directory <i>%s";
        logger.logf(pattern, instance.settings.resourceDirectory.doublyBackslashed);
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
        attempt = out-reference [AttemptState] aggregate of state variables used when connecting.
 +/
void startBot(ref Kameloso instance, out AttemptState attempt)
{
    import kameloso.plugins.common.misc :
        IRCPluginInitialisationException,
        pluginNameOfFilename,
        pluginFileBaseName;
    import kameloso.constants : ShellReturnValue;
    import kameloso.string : doublyBackslashed;
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

            version(TwitchSupport)
            {
                import std.algorithm.searching : endsWith;
                immutable lastConnectAttemptFizzled =
                    instance.parser.server.address.endsWith(".twitch.tv") &&
                    !instance.flags.sawWelcome;
            }
            else
            {
                enum lastConnectAttemptFizzled = false;
            }

            if ((!lastConnectAttemptFizzled && instance.settings.reexecToReconnect) || instance.flags.askedToReexec)
            {
                import kameloso.platform : ExecException, execvp;
                import kameloso.terminal : isTerminal, resetTerminalTitle, setTerminalTitle;
                import std.process : ProcessException;

                if (!instance.settings.headless)
                {
                    if (instance.settings.exitSummary && instance.connectionHistory.length)
                    {
                        printSummary(instance);
                    }

                    version(GCStatsOnExit)
                    {
                        import kameloso.common : printGCStats;
                        printGCStats();
                    }

                    immutable message = instance.flags.askedToReexec ?
                        "Re-executing as requested." :
                        "Re-executing to reconnect as per settings.";
                    logger.info(message);

                    version(Windows)
                    {
                        // Don't writeln on Windows, leave room for "Forked into PID" message
                    }
                    else
                    {
                        import std.stdio : stdout, writeln;
                        writeln();
                        stdout.flush();
                    }
                }

                try
                {
                    import core.stdc.stdlib : exit;

                    // Clear the terminal title if we're in a terminal
                    if (isTerminal) resetTerminalTitle();

                    auto pid = execvp(instance.args);
                    // On Windows, if we're here, the call succeeded
                    // Posix should never be here; it will either exec or throw

                    enum pattern = "Forked into PID <l>%d</>.";
                    logger.infof(pattern, pid.processID);
                    //resetConsoleModeAndCodepage(); // Don't, it will be called via atexit
                    exit(0);
                }
                catch (ProcessException e)
                {
                    enum pattern = "Failed to spawn a new process: <t>%s</>.";
                    logger.errorf(pattern, e.msg);
                }
                catch (ExecException e)
                {
                    enum pattern = "Failed to <l>execvp</> with an error value of <l>%d</>.";
                    logger.errorf(pattern, e.retval);
                }
                catch (Exception e)
                {
                    enum pattern = "Unexpected exception: <t>%s";
                    logger.errorf(pattern, e.msg);
                    version(PrintStacktraces) logger.trace(e);
                }

                // Reset the terminal title after a failed execvp/fork
                if (isTerminal) setTerminalTitle();
            }

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
                if (lastConnectAttemptFizzled || instance.flags.askedToReconnect)
                {
                    import core.time : msecs;

                    /+
                        We either saw an instant disconnect before even getting
                        to RPL_WELCOME, or we're reconnecting.
                        Quickly attempt again.
                     +/
                    static immutable twitchRegistrationFailConnectionRetry =
                        Timeout.twitchRegistrationFailConnectionRetryMsecs.msecs;
                    gracePeriodBeforeReconnect = twitchRegistrationFailConnectionRetry;
                }
            }

            if (!lastConnectAttemptFizzled && !instance.flags.askedToReconnect)
            {
                logger.log("One moment...");
            }

            interruptibleSleep(gracePeriodBeforeReconnect, instance.abort);
            if (*instance.abort) break outerloop;

            try
            {
                // Re-instantiate plugins here so it isn't done on the first connect attempt
                instance.instantiatePlugins();
            }
            catch (Exception e)
            {
                enum pattern = "An unexpected error occurred while instantiating plugins: " ~
                    "<t>%s</> (at <l>%s</>:<l>%d</>)";
                logger.errorf(
                    pattern,
                    e.msg,
                    e.file.doublyBackslashed,
                    e.line);

                version(PrintStacktraces) logger.trace(e.info);
                attempt.retval = ShellReturnValue.pluginInitialisationException;
                break outerloop;
            }

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

            // Reset transient state flags
            instance.flags = typeof(instance.flags).init;
        }

        scope(exit)
        {
            // Always teardown when exiting this loop (for any reason)
            instance.teardownPlugins();
        }

        // May as well check once here, in case something in instantiatePlugins aborted or so.
        if (*instance.abort) break outerloop;

        instance.conn.reset();

        // reset() sets the receive timeout to the enum default, so make sure to
        // update it to any custom value after each reset() call.
        instance.conn.receiveTimeout = instance.connSettings.receiveTimeout;

        /+
            Resolve.
         +/
        immutable actionAfterResolve = tryResolve(
            instance,
            cast(Flag!"firstConnect")(attempt.firstConnect));
        if (*instance.abort) break outerloop;  // tryResolve interruptibleSleep can abort

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case returnFailure:
            // No need to teardown; the scopeguard does it for us.
            attempt.retval = ShellReturnValue.resolutionFailure;
            break outerloop;

        case returnSuccess:
            // Ditto
            attempt.retval = ShellReturnValue.success;
            break outerloop;

        case retry:  // should never happen
        case crash:  // ditto
            import lu.conv : Enum;
            import std.conv : text;
            assert(0, text("`tryResolve` returned `", Enum!Next.toString(actionAfterResolve), "`"));
        }

        /+
            Initialise all plugins' resources.

            Ensure initialised resources after resolve so we know we have a
            valid server to create a directory for.
         +/
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
                    "<t>%s</> is malformed. (at <l>%s</>:<l>%d</>)%s";
                logger.errorf(
                    pattern,
                    e.pluginName,
                    e.malformedFilename.doublyBackslashed,
                    e.file.pluginFileBaseName.doublyBackslashed,
                    e.line,
                    bell);
            }
            else
            {
                enum pattern = "The <l>%s</> plugin failed to load its resources; " ~
                    "<t>%s</> (at <l>%s</>:<l>%d</>)%s";
                logger.errorf(
                    pattern,
                    e.pluginName,
                    e.msg,
                    e.file.pluginFileBaseName.doublyBackslashed,
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
                "plugin resources: <t>%s</> (at <t>%s</>:<l>%d</>)%s";
            logger.errorf(
                pattern,
                e.msg,
                e.file.pluginFileBaseName.doublyBackslashed,
                e.line,
                bell);

            version(PrintStacktraces) logger.trace(e);
            attempt.retval = ShellReturnValue.pluginResourceLoadException;
            break outerloop;
        }

        /+
            Connect.
         +/
        immutable actionAfterConnect = tryConnect(instance);
        if (*instance.abort) break outerloop;  // tryConnect interruptibleSleep can abort

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnFailure:
            // No need to saveOnExit, the scopeguard takes care of that
            attempt.retval = ShellReturnValue.connectionFailure;
            break outerloop;

        case returnSuccess:  // should never happen
        case retry:  // ditto
        case crash:  // ditto
            import lu.conv : Enum;
            import std.conv : text;
            assert(0, text("`tryConnect` returned `", Enum!Next.toString(actionAfterConnect), "`"));
        }

        // Reinit with its own server.
        instance.parser = IRCParser(backupClient, instance.parser.server);

        /+
            Set up all plugins.
         +/
        try
        {
            instance.setupPlugins();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            enum pattern = "The <l>%s</> plugin failed to set up; " ~
                "<t>%s</> (at <l>%s</>:<l>%d</>)%s";
            logger.errorf(
                pattern,
                e.pluginName,
                e.msg,
                e.file.pluginFileBaseName.doublyBackslashed,
                e.line,
                bell);

            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = ShellReturnValue.pluginSetupFailure;
            break outerloop;
        }
        catch (Exception e)
        {
            enum pattern = "An unexpected error occurred while setting up the <l>%s</> plugin: " ~
                "<t>%s</> (at <l>%s</>:<l>%d</>)%s";
            logger.errorf(
                pattern,
                e.file.pluginNameOfFilename.doublyBackslashed,
                e.msg,
                e.file.doublyBackslashed,
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
                import std.algorithm.searching : startsWith;
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
                instance.callgrindRunning = !result.output.startsWith("Error: Callgrind task with PID");
            }

            if (instance.callgrindRunning)
            {
                // Dump now and on scope exit
                dumpCallgrind();
            }

            scope(exit) if (instance.callgrindRunning) dumpCallgrind();
        }

        // Start the main loop
        instance.flags.askedToReconnect = false;
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
    static import kameloso.common;

    if (kameloso.common.globalHeadless || !raw.length) return;

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
        if (event.tags.length)
        {
            enum pattern = `Offending line: "<t>%s</>"`;
            logger.warningf(pattern, raw);
        }
        else
        {
            enum pattern = `Offending line: "<l>@%s %s</>"`;
            logger.warningf(pattern, event.tags, raw);
        }
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
void printSummary(const ref Kameloso instance) @safe
{
    import kameloso.time : timeSince;
    import core.time : Duration;

    Duration totalTime;
    ulong totalBytesReceived;
    uint i;

    logger.info("== Connection summary ==");

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
    /++
        Enum denoting what we should do next loop in an execution attempt.
     +/
    Next next;

    /++
        Bool whether this is the first connection attempt or if we have
        connected at least once already.
     +/
    bool firstConnect = true;

    /++
        Whether or not "Exiting..." should be printed at program exit.
     +/
    bool silentExit;

    /++
        Shell return value to exit with.
     +/
    int retval;
}


// syncGuestChannels
/++
    Syncs currently joined channels with [IRCBot.guestChannels|guestChannels],
    adding entries in the latter where the former is missing.

    We can't just check the first plugin at `instance.plugins[0]` since there's
    no way to be certain it mixes in [kameloso.plugins.common.awareness.ChannelAwareness|ChannelAwareness].

    Used when saving to configuration file, to ensure the current state is saved.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void syncGuestChannels(ref Kameloso instance) pure @safe nothrow
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


// echoQuitMessage
/++
    Echos the quit message to the local terminal, to fake it being sent verbosely
    to the server. It is sent, but later, bypassing the message Fiber which would
    otherwise do the echoing.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        reason = Quit reason.
 +/
void echoQuitMessage(ref Kameloso instance, const string reason) @safe
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


// propagateWhoisTimestamp
/++
    Propagates a single update to the the [kameloso.kameloso.Kameloso.previousWhoisTimestamps]
    associative array to all plugins.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        nickname = Nickname whose WHOIS timestamp to propagate.
        nowInUnix = UNIX WHOIS timestamp.
 +/
void propagateWhoisTimestamp(
    ref Kameloso instance,
    const string nickname,
    const long nowInUnix) pure @safe nothrow
{
    instance.previousWhoisTimestamps[nickname] = nowInUnix;

    foreach (plugin; instance.plugins)
    {
        plugin.state.previousWhoisTimestamps[nickname] = nowInUnix;
    }
}


// propagateWhoisTimestamps
/++
    Propagates the [kameloso.kameloso.Kameloso.previousWhoisTimestamps]
    associative array to all plugins.

    Makes a copy of it before passing it onwards; this way, plugins cannot
    modify the original.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
 +/
void propagateWhoisTimestamps(ref Kameloso instance) pure @safe
{
    auto copy = instance.previousWhoisTimestamps.dup;  // mutable

    foreach (plugin; instance.plugins)
    {
        plugin.state.previousWhoisTimestamps = copy;
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
    import kameloso.plugins.common.misc : IRCPluginInitialisationException, IRCPluginSettingsException;
    import kameloso.constants : ShellReturnValue;
    import kameloso.logger : KamelosoLogger;
    import kameloso.string : doublyBackslashed, replaceTokens;
    import std.algorithm.comparison : among;
    import std.conv : ConvException;
    import std.exception : ErrnoException;
    static import kameloso.common;

    // Set up the Kameloso instance.
    auto instance = Kameloso(args);
    postInstanceSetup(instance);

    scope(exit)
    {
        import kameloso.terminal : isTerminal, resetTerminalTitle;
        if (isTerminal) resetTerminalTitle();
        resetSignals();
    }

    // Set pointers.
    kameloso.common.settings = &instance.settings;
    instance.abort = &kameloso.common.globalAbort;

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

        *instance.abort = Yes.abort;
    }

    immutable actionAfterGetopt = tryGetopt(instance);
    kameloso.common.globalHeadless = cast(Flag!"headless")instance.settings.headless;

    with (Next)
    final switch (actionAfterGetopt)
    {
    case continue_:
        break;

    case returnSuccess:
        return ShellReturnValue.success;

    case returnFailure:
        return ShellReturnValue.getoptFailure;

    case retry:  // should never happen
    case crash:  // ditto
        import lu.conv : Enum;
        import std.conv : text;
        assert(0, text("`tryGetopt` returned `", Enum!Next.toString(actionAfterGetopt), "`"));
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
            import std.stdio : stdout;
            if (instance.settings.flush) stdout.flush();
        }
    }

    // Apply some defaults to empty members, as stored in `kameloso.constants`.
    // It's done before in tryGetopt but do it again to ensure we don't have an empty nick etc
    // Skip if --force was passed.
    if (!instance.settings.force)
    {
        import kameloso.config : applyDefaults;
        applyDefaults(instance);
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
        import std.stdio : stdout, writeln;

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
    immutable actionAfterVerification = verifySettings(instance);

    with (Next)
    final switch (actionAfterVerification)
    {
    case continue_:
        break;

    case returnFailure:
        return ShellReturnValue.settingsVerificationFailure;

    case retry:  // should never happen
    case returnSuccess:  // ditto
    case crash:  // ditto
        import lu.conv : Enum;
        import std.conv : text;
        assert(0, text("`verifySettings` returned `", Enum!Next.toString(actionAfterVerification), "`"));
    }

    // Resolve resource and private key/certificate paths.
    resolvePaths(instance);
    instance.conn.certFile = instance.connSettings.certFile;
    instance.conn.privateKeyFile = instance.connSettings.privateKeyFile;

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    scope(exit)
    {
        // Tear down plugins outside the loop too, to cover errors during initialisation
        // It does nothing if the plugins array is empty
        instance.teardownPlugins();
    }

    // Initialise plugins outside the loop once, for the error messages
    try
    {
        import std.file : exists;

        instance.instantiatePlugins();

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
    catch (Exception e)
    {
        enum pattern = "An unexpected error occurred while instantiating plugins: " ~
            "<t>%s</> (at <l>%s</>:<l>%d</>)";
        logger.errorf(
            pattern,
            e.msg,
            e.file.doublyBackslashed,
            e.line);

        version(PrintStacktraces) logger.trace(e);
        if (!instance.settings.force) return ShellReturnValue.pluginInstantiationException;
    }

    // Save the original nickname *once*, outside the connection loop.
    // It will change later and knowing this is useful when authenticating
    instance.parser.client.origNickname = instance.parser.client.nickname;

    // Plugins were instantiated but not initialised, so do that here
    try
    {
        instance.initialisePlugins();
    }
    catch (IRCPluginInitialisationException e)
    {
        import kameloso.plugins.common.misc : pluginFileBaseName;

        enum pattern = "The <l>%s</> plugin failed to initialise: " ~
            "<t>%s</> (at <l>%s</>:<l>%d</>)";
        logger.errorf(
            pattern,
            e.pluginName,
            e.msg,
            e.file.pluginFileBaseName.doublyBackslashed,
            e.line);

        version(PrintStacktraces) logger.trace(e.info);
        return ShellReturnValue.pluginInitialisationFailure;
    }
    catch (Exception e)
    {
        enum pattern = "An unexpected error occurred while initialising plugins: " ~
            "<t>%s</> (at <l>%s</>:<l>%d</>)";
        logger.errorf(
            pattern,
            e.msg,
            e.file.doublyBackslashed,
            e.line);

        version(PrintStacktraces) logger.trace(e);
        return ShellReturnValue.pluginInitialisationException;
    }

    if (*instance.abort) return ShellReturnValue.failure;

    // Check for concurrency messages in case any were sent during plugin initialisation
    while (true)
    {
        import kameloso.thread : ThreadMessage;
        import std.concurrency : receiveTimeout;
        import std.variant : Variant;
        import core.time : Duration;

        bool halt;

        void onThreadMessage(ThreadMessage message) scope
        {
            with (ThreadMessage.Type)
            switch (message.type)
            {
            case popCustomSetting:
                size_t[] toRemove;

                foreach (immutable i, immutable line; instance.customSettings)
                {
                    import lu.string : advancePast;

                    string slice = line;  // mutable
                    immutable setting = slice.advancePast('=', Yes.inherit);
                    if (setting == message.content) toRemove ~= i;
                }

                foreach_reverse (immutable i; toRemove)
                {
                    import std.algorithm.mutation : SwapStrategy, remove;
                    instance.customSettings = instance.customSettings
                        .remove!(SwapStrategy.unstable)(i);
                }

                toRemove = null;
                break;

            case save:
                import kameloso.config : writeConfigurationFile;
                writeConfigurationFile(instance, instance.settings.configFile);
                break;

            default:
                import std.stdio : stdout;

                enum pattern = "onThreadMessage received unexpected message type: <t>%s";
                logger.errorf(pattern, message.type);
                if (instance.settings.flush) stdout.flush();
                halt = true;
                break;
            }
        }

        if (halt) return ShellReturnValue.pluginInitialisationFailure;

        immutable receivedSomething = receiveTimeout(Duration.zero,
            &onThreadMessage,
            (Variant v) scope
            {
                // Caught an unhandled message
                enum pattern = "run received unknown Variant: <l>%s";
                logger.warningf(pattern, v.type);
            }
        );

        if (!receivedSomething) break;
    }

    // Go!
    startBot(instance, attempt);

    // If we're here, we should exit. The only question is in what way.

    if (instance.conn.connected && !instance.flags.quitMessageSent)
    {
        // If not already sent, send a proper QUIT, optionally verbosely
        string reason;  // mutable

        if (
            !*instance.abort &&
            !instance.settings.headless &&
            !instance.settings.hideOutgoing)
        {
            import kameloso.thread : exhaustMessages;

            immutable quitMessage = exhaustMessages();
            reason = quitMessage.length ?
                quitMessage :
                instance.bot.quitReason;
            reason = reason.replaceTokens(instance.parser.client);
            echoQuitMessage(instance, reason);
        }
        else
        {
            reason = instance.bot.quitReason
                .replaceTokens(instance.parser.client);
        }

        instance.conn.sendline("QUIT :" ~ reason);
    }

    // Save if we're exiting and configuration says we should.
    if (instance.settings.saveOnExit)
    {
        try
        {
            import kameloso.config : writeConfigurationFile;
            syncGuestChannels(instance);
            writeConfigurationFile(instance, instance.settings.configFile);
        }
        catch (Exception e)
        {
            import kameloso.string : doublyBackslashed;

            enum pattern = "Caught Exception when saving settings: " ~
                "<t>%s</> (at <l>%s</>:<l>%d</>)";
            logger.warningf(
                pattern,
                e.msg,
                e.file.doublyBackslashed,
                e.line);

            version(PrintStacktraces) logger.trace(e);
        }
    }

    // Print connection summary
    if (!instance.settings.headless)
    {
        if (instance.settings.exitSummary && instance.connectionHistory.length)
        {
            printSummary(instance);
        }

        version(GCStatsOnExit)
        {
            import kameloso.common : printGCStats;
            printGCStats();
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

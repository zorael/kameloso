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

debug version = Debug;

private:

import kameloso.common : logger;
import kameloso.constants : ShellReturnValue;
import kameloso.kameloso : Kameloso;
import kameloso.net : ListenAttempt;
import kameloso.plugins.common : IRCPlugin;
import kameloso.pods : CoreSettings;
import dialect.defs;

version(DigitalMars)
{
    version(D_Optimized)
    {
        enum optimisedMessage1 = "Warning: optimised (release) builds are prone " ~
            "to memory corruption and crashes when compiled with dmd.";
        enum optimisedMessage2 = "Please use ldc instead for optimised builds.";
        pragma(msg, optimisedMessage1);
        pragma(msg, optimisedMessage2);
    }
}


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

    version(ConcurrentGC)
    {
        sink.put("fork:1 ");
    }

    // Tweak these numbers as we see fit
    // https://forum.dlang.org/post/uqqabgqnoqdqbwbglthg@forum.dlang.org
    sink.put("initReserve:8 minPoolSize:8 heapSizeFactor:1.002"); // incPoolSize:16
    return sink[].assumeUnique();
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

    Sets the [kameloso.common.globalAbort|globalAbort] global to `true`
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

    if (sig < signalNames.length)
    {
        if (!kameloso.common.globalAbort)
        {
            printf("...caught signal SIG%s!\n", signalNames[sig].ptr);
        }
        else if (sig == 2)
        {
            enum pattern = "...caught another signal SIG%s! " ~
                "(press Enter if nothing happens, or Ctrl+C again)\n";
            printf(pattern, signalNames[sig].ptr);
        }
    }
    else
    {
        // Can signals even be > 31?
        printf("...caught signal %d!\n", sig);
    }

    if (kameloso.common.globalAbort) resetSignals();
    else kameloso.common.globalAbort = true;

    version(Posix)
    {
        signalRaised = sig;
    }
}


// processMessages
/++
    Processes messages and performs action based on them.

    The return value signals to the caller whether the received action means the
    bot should exit or not.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        A [lu.common.Next|Next] value, signaling to the caller whether the bot
        should exit or not.
 +/
auto processMessages(Kameloso instance)
{
    import kameloso.common : OutgoingLine;
    import kameloso.constants : Timeout;
    import kameloso.messaging : Message;
    import kameloso.tables : trueThenFalse;
    import kameloso.thread : ThreadMessage;
    import lu.common : Next;
    import core.time : MonoTime, msecs;

    auto next = Next.continue_;

    /++
        Handle [kameloso.thread.ThreadMessage]s based on their
        [kameloso.thread.ThreadMessage.MessageType|MessageType]s.
     +/
    void onThreadMessage(ThreadMessage message)
    {
        with (ThreadMessage.MessageType)
        final switch (message.type)
        {
        case pong:
            /+
                PONGs literally always have the same content, so micro-optimise
                this a bit by only allocating the string once and keeping it
                if the contents don't change.
             +/
            enum pongHeader = "PONG :";

            if (!instance.transient.pongline.length ||
                (instance.transient.pongline[pongHeader.length..$] != message.content))
            {
                instance.transient.pongline = pongHeader ~ message.content;
            }

            instance.priorityBuffer.put(OutgoingLine(instance.transient.pongline, quiet: true));
            break;

        case ping:
            // No need to micro-optimise here, PINGs should be very rare
            immutable pingline = "PING :" ~ message.content;
            instance.priorityBuffer.put(OutgoingLine(pingline, quiet: true));
            break;

        case shortenReceiveTimeout:
            instance.transient.wantReceiveTimeoutShortened = true;
            break;

        case busMessage:
            foreach (plugin; instance.plugins)
            {
                plugin.onBusMessage(message.content, cast()message.payload);
            }
            break;

        case quit:
            import kameloso.string : replaceTokens;

            // This will automatically close the connection.
            immutable reason = message.content.length ?
                message.content :
                instance.bot.quitReason;
            immutable quitMessage = "QUIT :" ~ reason.replaceTokens(instance.parser.client);

            instance.priorityBuffer.put(OutgoingLine(
                quitMessage,
                quiet: message.quiet));

            instance.transient.quitMessageSent = true;
            next = Next.returnSuccess;
            break;

        case reconnect:
            import kameloso.thread : Boxed;

            if (auto boxedReexecFlag = cast(Boxed!bool)message.payload)
            {
                // Re-exec explicitly requested
                instance.transient.askedToReexec = boxedReexecFlag.payload;
            }
            else
            {
                // Normal reconnect
                instance.transient.askedToReconnect = true;
            }

            immutable quitMessage = message.content.length ?
                message.content :
                "Reconnecting.";

            instance.priorityBuffer.put(OutgoingLine(
                "QUIT :" ~ quitMessage,
                quiet: true));

            instance.transient.quitMessageSent = true;
            next = Next.retry;
            break;

        case wantLiveSummary:
            instance.transient.wantLiveSummary = true;
            break;

        case abort:
            *instance.abort = true;
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
            writeConfigurationFile(instance, instance.settings.configFile);
            break;

        case popCustomSetting:
            size_t[] toRemove;

            foreach (immutable i, immutable line; instance.customSettings)
            {
                import lu.string : advancePast;

                string slice = line;  // mutable
                immutable setting = slice.advancePast('=', inherit: true);
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
            import std.datetime.systime : Clock;

            auto boxedUser = cast(Boxed!IRCUser)message.payload;
            assert(boxedUser, "Incorrectly cast message payload: " ~ typeof(boxedUser).stringof);

            auto user = boxedUser.payload;
            user.updated = Clock.currTime.toUnixTime();

            foreach (plugin; instance.plugins)
            {
                plugin.putUser(user, message.content);
            }
            break;

        case askToTrace:
            logger.trace(message.content);
            break;

        case askToLog:
            logger.log(message.content);
            break;

        case askToInfo:
            logger.info(message.content);
            break;

        case askToWarn:
            logger.warning(message.content);
            break;

        case askToError:
            logger.error(message.content);
            break;

        case askToCritical:
            logger.critical(message.content);
            break;

        case askToFatal:
            logger.fatal(message.content);
            break;

        case askToWriteln:
            import kameloso.logger : LogLevel;
            import kameloso.terminal.colours.tags : expandTags;
            import std.stdio : stdout, writeln;

            writeln(message.content.expandTags(LogLevel.off));
            if (instance.settings.flush) stdout.flush();
            break;

        case fakeEvent:
            version(Debug)
            {
                import std.datetime.systime : Clock;
                processLineFromServer(instance, message.content, Clock.currTime.toUnixTime());
            }
            break;

        case teardown:
            import lu.conv : toString;
            enum pattern = "onThreadMessage received unexpected message type: <l>%s";
            logger.errorf(pattern, message.type.toString());
            break;
        }
    }

    /++
        Reverse-formats an event and sends it to the server.
     +/
    void onEventMessage(Message m)
    {
        import lu.string : splitLineAtPosition;
        import std.conv : text;

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
        immutable quiet = (instance.settings.hideOutgoing || (m.properties & Message.Property.quiet));
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
            /*enum pattern = "PRIVMSG %s :";
            prelude = pattern.format(m.event.channel);*/
            prelude = text("PRIVMSG ", m.event.channel, " :");
            lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
            break;

        case QUERY:
            version(TwitchSupport)
            {
                if (instance.parser.server.daemon == IRCServer.Daemon.twitch)
                {
                    enum message = "Tried to send a Twitch whisper " ~
                        "but Twitch now requires them to be made through API calls.";
                    enum pattern = "--> [<l>%s</>] %s";
                    logger.error(message);
                    logger.errorf(pattern, m.event.target.nickname, m.event.content);
                    return;
                }
            }

            /*enum pattern = "PRIVMSG %s :";
            prelude = pattern.format(m.event.target.nickname);*/
            prelude = text("PRIVMSG ", m.event.target.nickname, " :");
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
                    /*enum pattern = "PRIVMSG %s :/me ";
                    prelude = pattern.format(emoteTarget);*/
                    prelude = text("PRIVMSG ", emoteTarget, " :/me ");
                    lines = m.event.content.splitLineAtPosition(' ', maxIRCLineLength-prelude.length);
                }
            }

            if (!prelude.length)
            {
                import dialect.common : IRCControlCharacter;
                /*enum pattern = "PRIVMSG %s :%cACTION %s%2$c";
                line = pattern.format(emoteTarget, cast(char)IRCControlCharacter.ctcp, m.event.content);*/
                immutable c = cast(char)IRCControlCharacter.ctcp;
                line = text( "PRIVMSG ", emoteTarget, " :", c, "ACTION ", m.event.content, c);
            }
            break;

        case MODE:
            import lu.string : strippedRight;
            /*enum pattern = "MODE %s %s %s";
            line = pattern.format(m.event.channel, m.event.aux[0], m.event.content.strippedRight);*/
            line = text("MODE ", m.event.channel, ' ', m.event.aux[0], ' ', m.event.content.strippedRight);
            break;

        case TOPIC:
            /*enum pattern = "TOPIC %s :%s";
            line = pattern.format(m.event.channel, m.event.content);*/
            line = text("TOPIC ", m.event.channel, " :", m.event.content);
            break;

        case INVITE:
            /*enum pattern = "INVITE %s %s";
            line = pattern.format(m.event.channel, m.event.target.nickname);*/
            line = text("INVITE ", m.event.channel, ' ', m.event.target.nickname);
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
            /*enum pattern = "KICK %s %s%s";
            line = pattern.format(m.event.channel, m.event.target.nickname, reason);*/
            line = text("KICK ", m.event.channel, ' ', m.event.target.nickname, reason);
            break;

        case PART:
            if (m.event.content.length)
            {
                import kameloso.string : replaceTokens;

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

                    enum pattern = "[TraceWhois] processMessages caught request to " ~
                        "WHOIS \"%s\" from %s (quiet:%s, background:%s)";
                    writef(
                        pattern,
                        m.event.target.nickname,
                        m.caller,
                        quiet,
                        background);
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
            import kameloso.string : replaceTokens;

            immutable rawReason = m.event.content.length ?
                m.event.content :
                instance.bot.quitReason;
            immutable reason = rawReason.replaceTokens(instance.parser.client);
            line = "QUIT :" ~ reason;

            instance.transient.quitMessageSent = true;
            next = Next.returnSuccess;
            break;

        case UNSET:
            line = m.event.content;
            break;

        default:
            import lu.conv : toString;
            // Using Enum here is not necessary but lowers compilation memory usage
            logger.error("<l>processMessages</>.<l>eventToServer</> missing case " ~
                "for outgoing event type <l>", m.event.type.toString());
            break;
        }

        void appropriateline(const string finalLine)
        {
            if (immediate)
            {
                return instance.immediateBuffer.put(OutgoingLine(finalLine, quiet: quiet));
            }

            version(TwitchSupport)
            {
                if (/*(instance.parser.server.daemon == IRCServer.Daemon.twitch) &&*/ fast)
                {
                    // Send a line via the fastbuffer, faster than normal sends.
                    return instance.fastbuffer.put(OutgoingLine(finalLine, quiet: quiet));
                }
            }

            if (priority)
            {
                instance.priorityBuffer.put(OutgoingLine(finalLine, quiet: quiet));
            }
            else if (background)
            {
                // Send a line via the low-priority background buffer.
                instance.backgroundBuffer.put(OutgoingLine(finalLine, quiet: quiet));
            }
            else if (quiet)
            {
                instance.outbuffer.put(OutgoingLine(finalLine, quiet: true));
            }
            else
            {
                instance.outbuffer.put(OutgoingLine(finalLine, quiet: instance.settings.hideOutgoing));
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
                lines[i] = string.init;
            }
        }
        else if (line.length)
        {
            if (m.event.tags.length) line = text('@', m.event.tags, ' ', line);
            appropriateline(line);
        }

        lines = null;
    }

    /+
        Timestamp of when the loop started.
     +/
    immutable loopStartTime = MonoTime.currTime;
    static immutable maxReceiveTime = Timeout.messageReadMsecs.msecs;

    /+
        Still time enough to act on messages?
     +/
    auto isStillOnTime()
    {
        immutable onTime = ((MonoTime.currTime - loopStartTime) <= maxReceiveTime);
        //version(Debug) if (!onTime) logger.warning("Messenger loop ran out of time");
        return onTime;
    }

    /+
        Whether or not to continue the loop.
     +/
    auto shouldStillContinue()
    {
        immutable shouldContinue = ((next == Next.continue_) && !*instance.abort);
        //version(Debug) if (!shouldContinue) logger.warning("Messenger loop shouldn't continue");
        return shouldContinue;
    }

    /+
        Messages. Process all priority ones over all plugins before processing
        normal ones.
     +/
    foreach (immutable isPriority; trueThenFalse[])
    {
        foreach (plugin; instance.plugins)
        {
            auto box = isPriority ?
                &plugin.state.priorityMessages :
                &plugin.state.messages;

            if (!(*box)[].length) continue;

            messageLoop:
            for (size_t i; i<(*box)[].length; ++i)
            {
                if ((*box)[][i].exhausted) continue messageLoop;

                onThreadMessage((*box)[][i]);
                (*box)[][i].exhausted = true;

                if (!shouldStillContinue)
                {
                    // Something triggered an abort
                    return next;
                }
                else if (!isPriority && !isStillOnTime)
                {
                    // Ran out of time processing a non-priority message
                    return next;
                }
            }

            box.clear();
        }
    }

    if (!shouldStillContinue || !isStillOnTime)
    {
        return next;
    }

    /+
        Outgoing messages.
     +/
    outgoingMessageTop:
    foreach (plugin; instance.plugins)
    {
        if (!plugin.state.outgoingMessages[].length || !plugin.isEnabled) continue outgoingMessageTop;

        // No need to iterate with a for loop since the length shouldn't change in the middle of it
        outgoingMessageInner:
        foreach (immutable i, ref message; plugin.state.outgoingMessages[])
        {
            if (message.exhausted) continue outgoingMessageInner;

            onEventMessage(message);
            message.exhausted = true;

            if (!shouldStillContinue || !isStillOnTime)
            {
                // Ran out of time or something triggered an abort
                return next;
            }
        }

        // if we're here, we've exhausted all outgoing messages for this plugin
        plugin.state.outgoingMessages.clear();
    }

    /+
        If a plugin wants to be able to send concurrency messages to the
        main loop, to output messages to the screen and/or send messages to
        the server, declare version `WantConcurrencyMessageLoop` to enable
        this block.
     +/
    version(WantConcurrencyMessageLoop)
    {
        if (!shouldStillContinue || !isStillOnTime)
        {
            return next;
        }

        /++
            On compilers 2.092 or later, this prevents a closure from being
            allocated each time this function is called. On 2.091 and earlier it
            doesn't, which is unfortunate.
         +/
        scope onThreadMessageDg = &onThreadMessage;
        scope onEventMessageDg = &onEventMessage;

        /+
            Concurrency messages, dead last.
         +/
        readloop:
        while (true)
        {
            bool receivedSomething;

            try
            {
                import std.concurrency : receiveTimeout;
                import core.time : Duration;

                receivedSomething = receiveTimeout(Duration.zero,
                    onThreadMessageDg,
                    onEventMessageDg,
                );
            }
            catch (Exception e)
            {
                logger.error("processMessages caught exception: <l>", e.msg);
                version(PrintStacktraces) logger.trace(e);
            }

            if (!receivedSomething || !shouldStillContinue || !isStillOnTime) break readloop;
        }
    }

    return next;
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        [lu.common.Next.returnFailure|Next.returnFailure] if circumstances mean
        the bot should exit with a non-zero exit code,
        [lu.common.Next.returnSuccess|Next.returnSuccess] if it should exit by
        returning `0`,
        [lu.common.Next.retry|Next.retry] if the bot should reconnect to the server.
        [lu.common.Next.continue_|Next.continue_] is never returned.
 +/
auto mainLoop(Kameloso instance)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ListenAttempt, SocketSendException, listenFiber;
    import lu.common : Next;
    import std.concurrency : Generator;
    import std.datetime.systime : Clock, SysTime;
    import core.thread.fiber : Fiber;

    // Instantiate a Generator to read from the socket and yield lines
    auto listener = new Generator!ListenAttempt(() =>
        listenFiber(
            instance.conn,
            instance.abort,
            Timeout.connectionLost));

    scope(exit)
    {
        destroy(listener);
        listener = null;
    }

    /++
        Processes messages in a try-catch.
     +/
    auto processMessages()
    {
        try
        {
            return .processMessages(instance);
        }
        catch (Exception e)
        {
            import kameloso.string : doublyBackslashed;

            enum pattern = "Unhandled exception processing messages: " ~
                "<t>%s</> (at <l>%s</>:<l>%d</>)";
            logger.warningf(pattern, e.msg, e.file.doublyBackslashed, e.line);
            version(PrintStacktraces) logger.trace(e);
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
            immutable untilNextSeconds = sendLines(instance);
            if (untilNextSeconds > 0.0)
            {
                timeoutFromMessages = cast(uint)(untilNextSeconds * 1000);
            }
        }
    }

    /// Variable denoting what we should do next loop.
    auto next = processMessages();  // Immediately check for messages, in case starting plugins left some
    if (next != Next.continue_) return next;
    else if (*instance.abort) return Next.returnFailure;

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

        if (!instance.settings.headless && instance.transient.wantLiveSummary)
        {
            // Live connection summary requested.
            printSummary(instance);
            instance.transient.wantLiveSummary = false;
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

            if (plugin.state.deferredActions[].length)
            {
                try
                {
                    processDeferredActions(instance, plugin);
                }
                catch (Exception e)
                {
                    logPluginActionException(
                        e,
                        plugin,
                        IRCEvent.init,
                        "deferredActions");
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
            next = processMessages();
            if (next != Next.continue_) return next;
            else if (*instance.abort) return Next.returnFailure;

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

        // Walk it and process the yielded lines
        listenerloop:
        while (true)
        {
            listener.call();
            if (*instance.abort) return Next.returnFailure;
            immutable attempt = listener.front;
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

            case noop:
                // Do nothing and retry
                continue listenerloop;

            case returnSuccess:  // should never happen
            case unset:  // ditto
            case crash:  // ...
                import lu.conv : toString;
                import std.conv : text;

                immutable message = text(
                    "`listenAttemptToNext` returned `",
                    actionAfterListen.toString(),
                    "`");
                assert(0, message);
            }
        }

        // Check messages to see if we should exit
        next = processMessages();
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

        if (instance.transient.wantReceiveTimeoutShortened)
        {
            // Set the timestamp and unset the bool
            instance.transient.wantReceiveTimeoutShortened = false;
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        A `double` of how many seconds until the next message in the buffers should be sent.
        If `0.0`, the buffer was emptied.
 +/
auto sendLines(Kameloso instance)
{
    if (!instance.immediateBuffer.empty)
    {
        cast(void)instance.throttleline(
            instance.immediateBuffer,
            dryRun: false,
            sendFaster: false,
            immediate: true);
    }

    if (!instance.priorityBuffer.empty)
    {
        immutable untilNextSeconds = instance.throttleline(instance.priorityBuffer);
        if (untilNextSeconds > 0.0) return untilNextSeconds;
    }

    version(TwitchSupport)
    {
        if (!instance.fastbuffer.empty)
        {
            immutable untilNextSeconds = instance.throttleline(
                instance.fastbuffer,
                dryRun: false,
                sendFaster: true);
            if (untilNextSeconds > 0.0) return untilNextSeconds;
        }
    }

    if (!instance.outbuffer.empty)
    {
        immutable untilNextSeconds = instance.throttleline(instance.outbuffer);
        if (untilNextSeconds > 0.0) return untilNextSeconds;
    }

    if (!instance.backgroundBuffer.empty)
    {
        immutable untilNextSeconds = instance.throttleline(instance.backgroundBuffer);
        if (untilNextSeconds > 0.0) return untilNextSeconds;
    }

    return 0.0;
}


// listenAttemptToNext
/++
    Translates the [kameloso.net.ListenAttempt.State|ListenAttempt.State]
    received from a [std.concurrency.Generator|Generator] into a [lu.common.Next|Next],
    while also providing warnings and error messages.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        attempt = The [kameloso.net.ListenAttempt|ListenAttempt] to map the `.state` value of.

    Returns:
        A [lu.common.Next|Next] describing what action [mainLoop] should take next.
 +/
auto listenAttemptToNext(Kameloso instance, const ListenAttempt attempt)
{
    import lu.common : Next;

    // Handle the attempt; switch on its state
    with (ListenAttempt.ListenState)
    final switch (attempt.state)
    {
    case isEmpty:
        // Empty line yielded means nothing received; break foreach and try again
        return Next.retry;

    case hasString:
        // hasString means we should drop down and continue processing
        return Next.continue_;

    case noop:
        // Do nothing
        return Next.noop;

    case warning:
        // Benign socket error; break foreach and try again
        import kameloso.constants : Timeout;
        import kameloso.thread : interruptibleSleep;
        import core.time : msecs;

        version(Posix)
        {
            import kameloso.tables : errnoMap;
            enum pattern = "Connection error! (<l>%s</>) <t>(%s)";
            logger.warningf(pattern, attempt.error, errnoMap[attempt.errno]);
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
                import kameloso.tables : errnoMap;
                enum pattern = "Connection error: invalid server response! (<l>%s</>) <t>(%s)";
                logger.errorf(pattern, attempt.error, errnoMap[attempt.errno]);
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

    case unset:  // should never happen
    case prelisten:  // ditto
        import lu.conv : toString;
        import std.conv : text;

        immutable message = text("listener yielded `", attempt.state.toString(), "` state");
        assert(0, message);
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
        enum pattern = `AdvanceException %s.%s: tried to advance past "<t>%s</>" with "<l>%s</>" <t>(%s:%d)`;
        logger.warningf(pattern, plugin.name, fun, e.haystack, e.needle, e.file, e.line);
        if (event.raw.length) printEventDebugDetails(event, event.raw);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else if (auto e = cast(UTFException)base)
    {
        enum pattern = "UTFException %s.%s: <t>%s (%s:%d)";
        logger.warningf(pattern, plugin.name, fun, e.msg, e.file, e.line);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else if (auto e = cast(UnicodeException)base)
    {
        enum pattern = "UnicodeException %s.%s: <t>%s (%s:%d)";
        logger.warningf(pattern, plugin.name, fun, e.msg, e.file, e.line);
        version(PrintStacktraces) logger.trace(e.info);
    }
    else
    {
        enum pattern = "Exception %s.%s: <t>%s (%s:%d)";
        logger.warningf(pattern, plugin.name, fun, base.msg, base.file, base.line);
        if (event.raw.length) printEventDebugDetails(event, event.raw);
        version(PrintStacktraces) logger.trace(base);
    }
}


// processLineFromServer
/++
    Processes a line read from the server, constructing an
    [dialect.defs.IRCEvent|IRCEvent] and dispatches it to all plugins.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance instance.
        raw = A raw line as read from the server.
        nowInUnix = Current timestamp in UNIX time.
 +/
void processLineFromServer(
    Kameloso instance,
    const string raw,
    const long nowInUnix)
{
    import kameloso.string : doublyBackslashed;
    import dialect.common : IRCParseException;
    import lu.string : AdvanceException;
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
            import std.string : representation;

            // Something asserted
            logger.error("scopeguard tripped.");
            printEventDebugDetails(event, raw, eventWasInitialised: eventWasInitialised);

            immutable rawRepresentation = raw.representation;

            // Print the raw line char by char if it contains non-printables
            if (rawRepresentation.canFind!((c) => c < ' '))
            {
                import std.stdio : writefln;
                import std.string : representation;

                foreach (immutable c; rawRepresentation)
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
                instance.transient.sawWelcome = true;
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
                    instance.throttleline(instance.fastbuffer, dryRun: true, sendFaster: true);
                }
                else
                {
                    instance.throttleline(instance.outbuffer, dryRun: true);
                }
            }
            else
            {
                instance.throttleline(instance.outbuffer, dryRun: true);
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
    [kameloso.plugins.common.IRCPlugin|IRCPlugin].

    Does not remove delegates after calling them. They are expected to remove
    themselves after finishing if they aren't awaiting any further events.

    Params:
        plugin = The [kameloso.plugins.common.IRCPlugin|IRCPlugin] whose
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
            if (!dg) continue;

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
    [kameloso.plugins.common.IRCPlugin|IRCPlugin].

    Don't delete [core.thread.fiber.Fiber|Fiber]s, as they can be reset and reused.

    Params:
        plugin = The [kameloso.plugins.common.IRCPlugin|IRCPlugin] whose
            [dialect.defs.IRCEvent.Type|IRCEvent.Type]-awaiting
            [core.thread.fiber.Fiber|Fiber]s to iterate and process.
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
 +/
void processAwaitingFibers(IRCPlugin plugin, const ref IRCEvent event)
{
    import core.thread.fiber : Fiber;

    Fiber[] expiredFibers;

    /++
        Handle awaiting fibers of a specified type.
     +/
    void processAwaitingFibersImpl(Fiber[] fibersForType)
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
                        version(TraceFibersAndDelegates)
                        {
                            import lu.conv : toString;

                            enum pattern =
                                "<l>%s</>.awaitingFibers[%d] " ~
                                "event type <l>%s</> " ~
                                "creator <l>%s</> " ~
                                "call <l>%d";

                            logger.tracef(
                                pattern,
                                plugin.name,
                                i,
                                event.type.toString(),
                                carryingFiber.creator,
                                carryingFiber.called+1);
                        }

                        carryingFiber.call(event);

                        // We need to reset the payload so that we can differentiate
                        // between whether the fiber was called due to an incoming
                        // (awaited) event or due to a timer. delegates will have
                        // to cache the event if they don't want it to get reset.
                        carryingFiber.resetPayload();
                    }
                    else
                    {
                        version(TraceFibersAndDelegates)
                        {
                            import lu.conv : toString;

                            enum pattern =
                                "<l>%s</>.awaitingFibers[%d] " ~
                                "event type <l>%s</> " ~
                                "plain fiber";

                            logger.tracef(
                                pattern,
                                plugin.name,
                                i,
                                event.type.toString());
                        }

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

    if (plugin.state.awaitingFibers[event.type].length)
    {
        processAwaitingFibersImpl(plugin.state.awaitingFibers[event.type]);
    }

    if (plugin.state.awaitingFibers[IRCEvent.Type.ANY].length)
    {
        processAwaitingFibersImpl(plugin.state.awaitingFibers[IRCEvent.Type.ANY]);
    }

    // Clean up processed fibers
    foreach (ref expiredFiber; expiredFibers)
    {
        import kameloso.thread : CarryingFiber;

        // Detect duplicates that were already destroyed and skip
        if (!expiredFiber) continue;

        foreach (ref fibersByType; plugin.state.awaitingFibers)
        {
            foreach_reverse (immutable i, /*ref*/ fiber; fibersByType)
            {
                import std.algorithm.mutation : SwapStrategy, remove;

                if (fiber !is expiredFiber) continue;

                version(TraceFibersAndDelegates)
                {
                    if (auto carryingFiber = cast(CarryingFiber!IRCEvent)fiber)
                    {
                        import lu.conv : toString;

                        enum pattern = "<l>%s</>.expiredFibers[%d] " ~
                            "event type <l>%s</> " ~
                            "creator <l>%s</> " ~
                            "DELETED";

                        logger.tracef(
                            pattern,
                            plugin.name,
                            i,
                            carryingFiber.payload.type.toString(),
                            carryingFiber.creator);
                    }
                    else
                    {
                        enum pattern = "<l>%s</>.expiredFibers[%d] " ~
                            "plain fiber " ~
                            "DELETED";

                        logger.tracef(
                            pattern,
                            plugin.name,
                            i);
                    }
                }

                fibersByType = fibersByType.remove!(SwapStrategy.unstable)(i);
            }
        }

        if (auto carryingFiber = cast(CarryingFiber!IRCEvent)expiredFiber)
        {
            if (carryingFiber.state == Fiber.State.TERM)
            {
                carryingFiber.reset();
            }
        }

        expiredFiber = null;  // needs ref
    }

    expiredFibers = null;
}


// processScheduledDelegates
/++
    Processes the queued [kameloso.thread.ScheduledDelegate|ScheduledDelegate]s of an
    [kameloso.plugins.common.IRCPlugin|IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.IRCPlugin|IRCPlugin] whose
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
            version(TraceFibersAndDelegates)
            {
                enum pattern = "<l>%s</>.scheduledDelegates[%d] " ~
                    "creator <l>%s";

                logger.tracef(
                    pattern,
                    plugin.name,
                    i,
                    scheduledDg.creator);
            }

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
    [kameloso.plugins.common.IRCPlugin|IRCPlugin].

    Params:
        plugin = The [kameloso.plugins.common.IRCPlugin|IRCPlugin] whose
            queued [kameloso.thread.ScheduledFiber|ScheduledFiber]s to iterate
            and process.
        nowInHnsecs = Current timestamp to compare the
            [kameloso.thread.ScheduledFiber|ScheduledFiber]'s timestamp with.
 +/
void processScheduledFibers(IRCPlugin plugin, const long nowInHnsecs)
in ((nowInHnsecs > 0), "Tried to process queued `ScheduledFiber`s with an unset timestamp")
{
    import kameloso.thread : CarryingFiber;
    import std.algorithm.iteration : uniq;
    import std.algorithm.sorting : sort;
    import std.range : chain;
    import core.thread.fiber : Fiber;

    size_t[] toRemove;
    size_t[] toReset;

    /+
        Walk through the scheduled fibers and call them if their timestamp is up.
        Expired fibers will be cleaned up below.
     +/
    foreach (immutable i, ref scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.timestamp > nowInHnsecs) continue;

        try
        {
            version(TraceFibersAndDelegates)
            {
                if (auto carryingFiber = cast(CarryingFiber!IRCEvent)scheduledFiber.fiber)
                {
                    enum pattern = "<l>%s</>.scheduledFibers[%d] " ~
                        "creator <l>%s";

                    logger.tracef(
                        pattern,
                        plugin.name,
                        i,
                        carryingFiber.creator);
                }
                else
                {
                    enum pattern = "<l>%s</>.scheduledFibers[%d] " ~
                        "(probably) plain fiber";

                    logger.tracef(
                        pattern,
                        plugin.name,
                        i);
                }
            }

            if (auto carryingFiber = cast(CarryingFiber!IRCEvent)scheduledFiber.fiber)
            {
                if (carryingFiber.state == Fiber.State.HOLD)
                {
                    carryingFiber.call();
                }
            }
            else
            {
                if (scheduledFiber.fiber &&
                    (scheduledFiber.fiber.state == Fiber.State.HOLD))
                {
                    scheduledFiber.fiber.call();
                }
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
            /+
                Always remove a scheduled fiber after processing, regardless of its state.
                Don't necessarily reset it though, as it may be referenced to
                elsewhere too. Evaluate that below.
             +/
            toRemove ~= i;
        }
    }

    /+
        Collect expired CarryingFibers and store their indices in toReset.
        Don't reset normal fibers, as they may be referenced to elsewhere too
        and we have no way of telling.
     +/
    foreach (immutable i, /*ref*/ scheduledFiber; plugin.state.scheduledFibers)
    {
        if (auto carryingFiber = cast(CarryingFiber!IRCEvent)scheduledFiber.fiber)
        {
            if (carryingFiber.state == Fiber.State.TERM)
            {
                toReset ~= i;
            }
        }
    }

    // No need to continue if there's nothing to do
    if (!toRemove.length && !toReset.length) return;

    /+
        Sort the indices so we can walk them in reverse order.
     +/
    auto indexRange = chain(toRemove, toReset)
        .sort!((a, b) => a < b)
        .uniq;

    /+
        Finally, remove the expired fibers, additionally resetting those that
        were terminated.
     +/
    foreach_reverse (immutable i; indexRange)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : canFind;

        if (toReset.canFind(i))
        {
            if (auto carryingFiber = cast(CarryingFiber!IRCEvent)plugin.state.scheduledFibers[i].fiber)
            {
                carryingFiber.reset();
            }
        }

        plugin.state.scheduledFibers[i].fiber = null;
        plugin.state.scheduledFibers = plugin.state.scheduledFibers
            .remove!(SwapStrategy.unstable)(i);
    }
}


// processReadyReplays
/++
    Handles the queue of ready-to-replay objects, re-postprocessing events from the
    current (main loop) context, outside of any plugin.

    Params:
        instance = The current bot instance.
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
 +/
void processReadyReplays(Kameloso instance, IRCPlugin plugin)
{
    import core.thread.fiber : Fiber;

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
    Takes a queue of pending [kameloso.plugins.common.Replay|Replay]
    objects and issues WHOIS queries for each one, unless it has already been done
    recently (within [kameloso.constants.Timeout.whoisRetry|Timeout.whoisRetry] seconds).

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        plugin = The relevant [kameloso.plugins.common.IRCPlugin|IRCPlugin].
 +/
void processPendingReplays(Kameloso instance, IRCPlugin plugin)
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
                quiet: instance.settings.hideOutgoing));
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


/+
    These versions must be placed at the top level. They are used to determine
    if one or more plugins request a specific feature, and if so, whether they
    should be supported in [processDeferredActions].

 +/
version(WithAdminPlugin)
{
    version = WantGetSettingHandler;
    version = WantSetSettingHandler;
    version = WantSelftestHandler;
}

version(WithHelpPlugin)
{
    version = WantPeekCommandsHandler;
}

version(WithCounterPlugin)
{
    version = WantPeekCommandsHandler;
}

version(WithOnelinerPlugin)
{
    version = WantPeekCommandsHandler;
}

// processDeferredActions
/++
    Iterates through a plugin's array of [kameloso.plugins.common.DeferredAction|DeferredAction]s.
    Depending on what their [kameloso.plugins.common.DeferredAction.fiber|fiber] member
    (which is in actually a [kameloso.thread.CarryingFiber|CarryingFiber]) can be
    cast to, it prepares a payload, assigns it to the
    [kameloso.thread.CarryingFiber|CarryingFiber], and calls it.

    If plugins need support for new types of requests, they must be defined and
    hardcoded here. There's no way to let plugins process the requests themselves
    without letting them peek into [kameloso.kameloso.Kameloso|the Kameloso instance].

    The array is always cleared after iteration, so requests that yield must
    first re-queue themselves.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        plugin = The relevant [kameloso.plugins.common.IRCPlugin|IRCPlugin].
 +/
void processDeferredActions(Kameloso instance, IRCPlugin plugin)
{
    import kameloso.thread : CarryingFiber;
    import std.typecons : Tuple;
    import core.thread.fiber : Fiber;

    scope(exit) plugin.state.deferredActions.clear();

    top:
    for (size_t i = 0; i<plugin.state.deferredActions[].length; ++i)
    {
        scope(exit)
        {
            if (plugin.state.deferredActions[][i].fiber.state == Fiber.State.TERM)
            {
                // Clean up
                destroy(plugin.state.deferredActions[][i].fiber);
                //request.fiber = null;  // fiber is an accessor, cannot null it here
            }

            destroy(plugin.state.deferredActions[][i]);
            plugin.state.deferredActions[][i] = null;
        }

        auto action = plugin.state.deferredActions[][i];

        version(WantPeekCommandsHandler)
        {
            alias PeekCommandsPayload = Tuple!
                (IRCPlugin.CommandMetadata[string][string],
                IRCPlugin.CommandMetadata[string][string]);

            if (auto fiber = cast(CarryingFiber!(PeekCommandsPayload))(action.fiber))
            {
                immutable channelName = action.context;

                IRCPlugin.CommandMetadata[string][string] globalCommandAA;
                IRCPlugin.CommandMetadata[string][string] channelCommandAA;

                foreach (thisPlugin; instance.plugins)
                {
                    globalCommandAA[thisPlugin.name] = thisPlugin.commands;
                }

                if (channelName.length)
                {
                    foreach (thisPlugin; instance.plugins)
                    {
                        channelCommandAA[thisPlugin.name] = thisPlugin.channelSpecificCommands(channelName);
                    }
                }

                fiber.payload[0] = globalCommandAA;
                fiber.payload[1] = channelCommandAA;
                fiber.call(action.creator);
                continue top;
            }
        }

        version(WantGetSettingHandler)
        {
            alias GetSettingPayload = Tuple!(string, string, string);

            if (auto fiber = cast(CarryingFiber!(GetSettingPayload))(action.fiber))
            {
                import lu.string : advancePast;
                import std.algorithm.iteration : splitter;
                import std.algorithm.searching : startsWith;
                import std.array : Appender;

                immutable expression = action.context;
                string slice = expression;  // mutable
                immutable pluginName = slice.advancePast('.', inherit: true);
                alias setting = slice;

                Appender!(char[]) sink;
                sink.reserve(256);  // guesstimate

                void apply()
                {
                    if (setting.length)
                    {
                        import lu.string : strippedLeft;

                        foreach (const line; sink[].splitter('\n'))
                        {
                            string lineslice = cast(string)line;  // need a string for advancePast and strippedLeft...
                            if (lineslice.startsWith('#')) lineslice = lineslice[1..$];
                            const thisSetting = lineslice.advancePast(' ', inherit: true);

                            if (thisSetting != setting) continue;

                            const value = lineslice.strippedLeft;
                            fiber.payload[0] = pluginName;
                            fiber.payload[1] = setting;
                            fiber.payload[2] = value;
                            fiber.call(action.creator);
                            return;
                        }
                    }
                    else
                    {
                        import std.conv : to;

                        string[] allSettings;

                        foreach (const line; sink[].splitter('\n'))
                        {
                            string lineslice = cast(string)line;  // need a string for advancePast and strippedLeft...
                            if (!lineslice.startsWith('[')) allSettings ~= lineslice.advancePast(' ', inherit: true);
                        }

                        fiber.payload[0] = pluginName;
                        //fiber.payload[1] = string.init;
                        fiber.payload[2] = allSettings.to!string;
                        fiber.call(action.creator);
                        allSettings = null;
                        return;
                    }

                    // If we're here, no such setting was found
                    fiber.payload[0] = pluginName;
                    //fiber.payload[1] = string.init;
                    //fiber.payload[2] = string.init;
                    fiber.call(action.creator);
                    return;
                }

                switch (pluginName)
                {
                case "core":
                    import lu.serialisation : serialise;
                    sink.serialise(*instance.settings);
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
                    fiber.call(action.creator);
                    break;
                }
                continue top;
            }
        }

        version(WantSetSettingHandler)
        {
            alias SetSettingPayload = Tuple!(bool);

            if (auto fiber = cast(CarryingFiber!(SetSettingPayload))(action.fiber))
            {
                import kameloso.plugins.common.misc : applyCustomSettings;

                immutable expression = action.context;

                // Borrow settings from the first plugin. It's taken by value
                immutable success = applyCustomSettings(
                    instance.plugins,
                    [ expression ]);

                fiber.payload[0] = success;
                fiber.call(action.creator);
                continue top;
            }
        }

        version(Selftests)
        version(WantSelftestHandler)
        {
            import kameloso.plugins.common : Selftester;
            import std.typecons : Ternary;

            alias SelftestPayload = Tuple!(string[], Ternary delegate()[]);

            if (auto fiber = cast(CarryingFiber!(SelftestPayload))(action.fiber))
            {
                import kameloso.constants : BufferSize;

                void selftestDg()
                {
                    import lu.string : advancePast;
                    import std.algorithm.searching : canFind;
                    import std.array : split;

                    Selftester tester;
                    tester.channelName = action.context;

                    string slice = action.subcontext;  // mutable
                    tester.targetNickname = slice.advancePast(' ', inherit: true);
                    immutable pluginNames = slice.split(' ');

                    foreach (thisPlugin; instance.plugins)
                    {
                        if (!thisPlugin.isEnabled ||
                            (pluginNames.length && !pluginNames.canFind(thisPlugin.name)))
                        {
                            continue;
                        }

                        Ternary pluginSelftestDg(IRCPlugin plugin)
                        {
                            import kameloso.plugins.common.scheduling : await, unawait;

                            auto dgFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
                            assert(dgFiber, "Incorrectly cast fiber: " ~ typeof(dgFiber).stringof);
                            tester.fiber = dgFiber;

                            await(plugin, dgFiber, IRCEvent.Type.CHAN);
                            scope(exit) unawait(plugin, dgFiber, IRCEvent.Type.CHAN);

                            return plugin.selftest(tester);
                        }

                        // https://forum.dlang.org/post/dxnhgxehdrcqdolbnfuy@forum.dlang.org
                        fiber.payload[0] ~= thisPlugin.name;
                        fiber.payload[1] ~= (plugin => () => pluginSelftestDg(plugin))(thisPlugin);
                    }

                    fiber.call(action.creator);
                }

                auto selftestFiber = new CarryingFiber!IRCEvent(&selftestDg, BufferSize.fiberStack);
                selftestFiber.call(action.creator);
                continue top;
            }
        }

        /+
            If we're here, nothing matched.
            Don't output an error though; it might just mean that the corresponding
            plugins were not compiled in.
         +/
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        [lu.common.Next|Next].* depending on what action the calling site should take.
 +/
auto tryGetopt(Kameloso instance)
{
    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import kameloso.config : handleGetopt;
    import kameloso.configreader : ConfigurationFileReadFailureException;
    import kameloso.string : doublyBackslashed;
    import lu.common : FileTypeMismatchException, Next;
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        [lu.common.Next.continue_|Next.continue_] if connection succeeded,
        [lu.common.Next.returnFailure|Next.returnFailure] if connection failed
        and the program should exit.
 +/
auto tryConnect(Kameloso instance)
{
    import kameloso.constants :
        ConnectionDefaultFloats,
        ConnectionDefaultIntegers,
        Timeout;
    import kameloso.net : ConnectionAttempt, connectFiber;
    import kameloso.thread : interruptibleSleep;
    import lu.common : Next;
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

    uint incrementedRetryDelay = Timeout.connectionRetry;
    enum transientSSLFailureTolerance = 10;
    uint numTransientSSLFailures;

    while (true)
    {
        import std.algorithm.searching : startsWith;
        import core.time : seconds;

        connector.call();
        if (*instance.abort) return Next.returnFailure;
        const attempt = connector.front;
        immutable isLastRetry = (attempt.retryNum+1 == ConnectionDefaultIntegers.retries);

        auto errorString()
        {
            enum unableToConnectString = "Unable to connect socket: ";
            return attempt.error.length ?
                (attempt.error.startsWith(unableToConnectString) ?
                    attempt.error[unableToConnectString.length..$] :
                    attempt.error) :
                string.init;
        }

        void verboselyDelay()
        {
            import std.algorithm.comparison : min;

            enum pattern = "Retrying in <i>%d</> seconds...";
            logger.logf(pattern, incrementedRetryDelay);
            interruptibleSleep(incrementedRetryDelay.seconds, instance.abort);

            incrementedRetryDelay = cast(uint)(incrementedRetryDelay *
                ConnectionDefaultFloats.delayIncrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay, Timeout.connectionDelayCap);
        }

        void verboselyDelayToNextIP()
        {
            enum pattern = "Failed to connect to IP. Trying next IP in <i>%d</> seconds.";
            logger.logf(pattern, cast(uint)Timeout.connectionRetry);
            incrementedRetryDelay = Timeout.connectionRetry;
            interruptibleSleep(Timeout.connectionRetry.seconds, instance.abort);
        }

        with (ConnectionAttempt.ConnectState)
        final switch (attempt.state)
        {
        case unset:  // should never happen
            assert(0, "connector yielded `unset` state");

        case noop:
            // Do nothing and retry
            continue;

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
            immutable sslText = instance.conn.ssl ? "(SSL) " : string.init;
            immutable address = (!resolvedHost.length ||
                (instance.parser.server.address == resolvedHost) ||
                (sharedDomains(instance.parser.server.address, resolvedHost) < 2)) ?
                    attempt.ip.toAddrString :
                    resolvedHost;

            logger.logf(rtPattern, address, attempt.ip.toPortString, sslText);
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
                    import kameloso.tables : errnoMap;
                    enum pattern = "Connection failed with <l>%s</>: <t>%s";
                    logger.warningf(pattern, errnoMap[attempt.errno], errorString);
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

            if (!isLastRetry) verboselyDelay();
            numTransientSSLFailures = 0;
            continue;

        case delayThenNextIP:
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
                import kameloso.tables : errnoMap;
                enum pattern = "IPv6 connection failed with <l>%s</>: <t>%s";
                logger.warningf(pattern, errnoMap[attempt.errno], errorString);
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

            if (!isLastRetry) goto case delayThenNextIP;
            numTransientSSLFailures = 0;
            continue;

        case transientSSLFailure:
            import std.string : indexOf;

            // "Failed to establish SSL connection after successful connect (system lib)"
            // "Failed to establish SSL connection after successful connect" --> attempted SSL on non-SSL server
            enum pattern = "Failed to connect: <l>%s</> <t>(%d)";
            logger.errorf(pattern, attempt.error, attempt.errno);
            if (*instance.abort) return Next.returnFailure;

            if ((numTransientSSLFailures++ < transientSSLFailureTolerance) &&
                (attempt.error.indexOf("(system lib)") != -1))
            {
                // Random failure, just reconnect immediately
                // but only `transientSSLFailureTolerance` times
            }
            else
            {
                if (!isLastRetry) verboselyDelay();
            }
            continue;

        case fatalSSLFailure:
            import kameloso.constants : MagicErrorStrings;

            /+
                We can only detect SSL context creation failure based on the string
                in the generic Exception thrown, sadly.
             +/
            if (attempt.error == MagicErrorStrings.sslLibraryNotFoundRewritten)
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
                enum pattern = "Failed to connect due to SSL errors: <l>%s";
                logger.errorf(pattern, attempt.error);
            }
            return Next.returnFailure;

        case exception:
            enum pattern = "Connection error: <l>%s";
            logger.errorf(pattern, attempt.error);
            //continue;  // safe to continue?
            return Next.returnFailure;

        case invalidConnectionError:
        case error:
            version(Posix)
            {
                import kameloso.tables : errnoMap;
                enum pattern = "Connection failed with <l>%s</>: <t>%s";
                logger.warningf(pattern, errnoMap[attempt.errno], errorString);
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        firstConnect = Whether or not this is the first time we're attempting a connection.

    Returns:
        [lu.common.Next.continue_|Next.continue_] if resolution succeeded,
        [lu.common.Next.returnFailure|Next.returnFailure] if it failed and the
        program should exit.
 +/
auto tryResolve(Kameloso instance, const bool firstConnect)
{
    import kameloso.constants : Timeout;
    import kameloso.net : ResolveAttempt, resolveFiber;
    import lu.common : Next;
    import std.concurrency : Generator;

    auto resolver = new Generator!ResolveAttempt(() =>
        resolveFiber(
            instance.conn,
            instance.parser.server.address,
            instance.parser.server.port,
            useIPv6: instance.connSettings.ipv6,
            abort: instance.abort));

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

    while (true)
    {
        import std.algorithm.searching : startsWith;

        resolver.call();
        immutable attempt = resolver.front;
        if (*instance.abort) return Next.returnFailure;

        enum getaddrinfoErrorString = "getaddrinfo error: ";
        immutable errorString = attempt.error.length ?
            (attempt.error.startsWith(getaddrinfoErrorString) ?
                attempt.error[getaddrinfoErrorString.length..$] :
                attempt.error) :
            string.init;

        with (ResolveAttempt.ResolveState)
        final switch (attempt.state)
        {
        case unset:
            // Should never happen
            assert(0, "resolver yielded `unset` state");

        case noop:
            // Do nothing and retry
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
}


// postInstanceSetup
/++
    Sets up the program (terminal) environment.

    Depending on your platform it may set any of thread name, terminal title and
    console codepages.

    This is called very early during execution.
 +/
void postInstanceSetup()
{
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        [lu.common.Next.returnFailure|Next.returnFailure] if the program should exit,
        [lu.common.Next.continue_|Next.continue_] otherwise.
 +/
auto verifySettings(Kameloso instance)
{
    import lu.common : Next;

    if (!instance.settings.force)
    {
        import dialect.common : isValidNickname;

        IRCServer conservativeServer;
        conservativeServer.maxNickLength = 25;  // Twitch max, should be enough

        if (!instance.parser.client.nickname.isValidNickname(conservativeServer))
        {
            // No need to print the nickname, visible from prettyprint previously
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void resolvePaths(Kameloso instance) @safe
{
    import kameloso.platform : rbd = resourceBaseDirectory;
    import std.file : exists;
    import std.path : buildNormalizedPath, dirName;

    immutable defaultResourceHomeDir = buildNormalizedPath(rbd, "kameloso");

    version(Posix)
    {
        import std.path : expandTilde;
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

    string*[3] filenames =
    [
        &instance.connSettings.caBundleFile,
        &instance.connSettings.privateKeyFile,
        &instance.connSettings.certFile,
    ];

    foreach (/*const*/ filenamePtr; filenames[])
    {
        import std.path : absolutePath, buildNormalizedPath, expandTilde, isAbsolute;

        if (!filenamePtr.length) continue;

        *filenamePtr = (*filenamePtr).expandTilde();
        immutable filename = *filenamePtr;

        if (!filename.isAbsolute && !filename.exists)
        {
            immutable fullPath = instance.settings.configDirectory.isAbsolute ?
                absolutePath(filename, instance.settings.configDirectory) :
                buildNormalizedPath(instance.settings.configDirectory, filename);

            if (fullPath.exists)
            {
                *filenamePtr = fullPath;
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        A [RunState] aggregate of state variables derived from a program run.
 +/
auto startBot(Kameloso instance)
{
    import kameloso.plugins.common.misc :
        IRCPluginInitialisationException,
        pluginNameOfFilename,
        pluginFileBaseName;
    import kameloso.constants : ShellReturnValue;
    import kameloso.string : doublyBackslashed;
    import kameloso.terminal : TerminalToken, isTerminal;
    import dialect.parsing : IRCParser;
    import lu.common : Next;
    import std.algorithm.comparison : among;

    // Save a backup snapshot of the client, for restoring upon reconnections
    IRCClient backupClient = instance.parser.client;

    // Persistent state variables
    RunState attempt;

    enum bellString = "" ~ cast(char)(TerminalToken.bell);
    immutable bell = isTerminal ? bellString : string.init;

    while (true)
    {
        instance.generateNewConnectionID();
        attempt.silentExit = true;

        if (!attempt.firstConnect)
        {
            import kameloso.constants : Timeout;
            import kameloso.thread : getQuitMessage, interruptibleSleep;
            import core.time : seconds;

            version(TwitchSupport)
            {
                import std.algorithm.searching : endsWith;
                immutable lastConnectAttemptFizzled =
                    instance.parser.server.address.endsWith(".twitch.tv") &&
                    !instance.transient.sawWelcome;
            }
            else
            {
                enum lastConnectAttemptFizzled = false;
            }

            if ((!lastConnectAttemptFizzled && instance.settings.reexecToReconnect) || instance.transient.askedToReexec)
            {
                import kameloso.platform : exec;
                import kameloso.terminal : isTerminal, resetTerminalTitle, setTerminalTitle;
                import lu.common : ReturnValueException;
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

                    immutable message = instance.transient.askedToReexec ?
                        "Re-executing as requested." :
                        "Re-executing to reconnect as per settings.";
                    logger.info(message);
                }

                // Clear the terminal title if we're in a terminal
                if (isTerminal) resetTerminalTitle();

                try
                {
                    const pid = exec(instance.args.dup, instance.transient.numReexecs, instance.bot.channelOverride);
                    // On Windows, if we're here, the call succeeded
                    // Posix should never be here; it will either exec or throw

                    version(Posix)
                    {
                        assert(0, "resumed after exec");
                    }
                    else
                    {
                        import core.stdc.stdlib : exit;

                        enum pattern = "Forked into PID <l>%d</>.";
                        logger.infof(pattern, pid.processID);
                        //resetConsoleModeAndCodepage(); // Don't, it will be called via atexit
                        exit(0);
                    }
                }
                catch (ProcessException e)
                {
                    enum pattern = "Failed to spawn a new process: <t>%s</>.";
                    logger.errorf(pattern, e.msg);
                }
                catch (ReturnValueException e)
                {
                    enum pattern = "Failed to <l>exec</> with an error value of <l>%d</>.";
                    logger.errorf(pattern, e.retval);
                }
                catch (Exception e)
                {
                    enum pattern = "Unexpected exception: <t>%s";
                    logger.errorf(pattern, e.msg);
                    version(PrintStacktraces) logger.trace(e);
                }

                // Reset the terminal title after a failed exec/fork
                if (isTerminal) setTerminalTitle();
            }

            // Carry some values but otherwise restore the pristine client backup
            backupClient.nickname = instance.parser.client.nickname;
            //instance.parser = IRCParser(backupClient, instance.parser.server);  // done below

            // Exhaust leftover queued messages
            getQuitMessage(instance.plugins);

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
                if (lastConnectAttemptFizzled || instance.transient.askedToReconnect)
                {
                    import core.time : msecs;

                    /+
                        We either saw an instant disconnect before even getting
                        to RPL_WELCOME, or we're reconnecting.
                        Quickly attempt again.
                     +/
                    gracePeriodBeforeReconnect = Timeout.twitchRegistrationFailConnectionRetryMsecs.msecs;
                }
            }

            if (!lastConnectAttemptFizzled && !instance.transient.askedToReconnect)
            {
                logger.log("One moment...");
            }

            interruptibleSleep(gracePeriodBeforeReconnect, instance.abort);
            if (*instance.abort) return attempt;

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
            instance.transient = typeof(instance.transient).init;

            scope(exit)
            {
                if (*instance.abort || (attempt.retval != ShellReturnValue.success))
                {
                    // Something seems to have failed, so teardown plugins
                    instance.teardownPlugins();
                }
            }

            /+
                Reinstantiate plugins.
             +/
            try
            {
                assert(!instance.plugins.length, "Tried to reinstantiate with existing plugins");
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
                attempt.retval = ShellReturnValue.pluginInstantiationException;
                return attempt;
            }

            /+
                Reinitialise them.
             +/
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
                attempt.retval = ShellReturnValue.pluginInitialisationFailure;
                return attempt;
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

                version(PrintStacktraces) logger.trace(e.info);
                attempt.retval = ShellReturnValue.pluginInitialisationException;
                return attempt;
            }

            if (*instance.abort) return attempt;

            // Check for messages in case any were sent during plugin initialisation
            ShellReturnValue initRetval;
            immutable proceed = checkInitialisationMessages(instance, initRetval);

            if (!proceed)
            {
                attempt.retval = initRetval;
                return attempt;
            }
        }

        scope(exit)
        {
            // Always teardown when exiting this loop (for any reason)
            instance.teardownPlugins();
        }

        // May as well check once here, in case something in instantiatePlugins aborted or so.
        if (*instance.abort) return attempt;

        instance.conn.reset();

        // reset() sets the receive timeout to the enum default, so make sure to
        // update it to any custom value after each reset() call.
        instance.conn.receiveTimeout = instance.connSettings.receiveTimeout;

        /+
            Resolve.
         +/
        immutable actionAfterResolve = tryResolve(
            instance,
            firstConnect: attempt.firstConnect);
        if (*instance.abort) return attempt;  // tryResolve interruptibleSleep can abort

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case returnFailure:
            // No need to teardown; the scopeguard does it for us.
            attempt.retval = ShellReturnValue.resolutionFailure;
            return attempt;

        case returnSuccess:
            // Ditto
            attempt.retval = ShellReturnValue.success;
            return attempt;

        case unset:  // should never happen
        case noop:   // ditto
        case retry:  // ...
        case crash:  // ...
            import lu.conv : toString;
            import std.conv : text;
            assert(0, text("`tryResolve` returned `", actionAfterResolve.toString(), "`"));
        }

        /+
            Initialise all plugins' resources.

            Ensure initialised resources after resolve so we know we have a
            valid server to create a directory for.
         +/
        try
        {
            instance.initPluginResources();
            if (*instance.abort) return attempt;
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
            return attempt;
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
            return attempt;
        }

        /+
            Connect.
         +/
        immutable actionAfterConnect = tryConnect(instance);
        if (*instance.abort) return attempt;  // tryConnect interruptibleSleep can abort

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnFailure:
            // No need to saveOnExit, the scopeguard takes care of that
            attempt.retval = ShellReturnValue.connectionFailure;
            return attempt;

        case returnSuccess:  // should never happen
        case unset:  // ditto
        case noop:   // ...
        case retry:  // ...
        case crash:  // ...
            import lu.conv : toString;
            import std.conv : text;
            assert(0, text("`tryConnect` returned `", actionAfterConnect.toString(), "`"));
        }

        // Reinit with its own server.
        instance.parser = IRCParser(backupClient, instance.parser.server);

        /+
            Set up all plugins.
         +/
        try
        {
            instance.setupPlugins();
            if (*instance.abort) return attempt;
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
            return attempt;
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
            return attempt;
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
                import std.stdio : stdout, writeln;
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
                if (instance.settings.flush) stdout.flush();
                instance.callgrindRunning = !result.output.startsWith("Error: Callgrind task with PID");
            }

            if (instance.callgrindRunning)
            {
                // Dump now and on scope exit
                dumpCallgrind();
            }

            scope(exit) if (instance.callgrindRunning) dumpCallgrind();
        }

        version(WantConcurrencyMessageLoop)
        {
            import std.concurrency : thisTid;

            /+
                If version `WantConcurrencyMessageLoop` is declared, the message
                fiber will try to receive concurrency messages (after first
                prioritising other messages). To have the program not assert at
                the first read, we have to either spawn a new thread using
                std.concurrency.spawn, *or* call thisTid at some point prior.
                So just call it and discard the value.
             +/
            cast(void)thisTid;
        }

        // Start the main loop
        instance.transient.askedToReconnect = false;
        attempt.next = mainLoop(instance);
        instance.bot.channelOverride = instance.collectChannels();  // snapshot channels
        attempt.firstConnect = false;

        if (*instance.abort || !attempt.next.among!(Next.continue_, Next.retry))
        {
            // Break and return
            return attempt;
        }
    }

    assert(0, "Unreachable");
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
    const bool eventWasInitialised = true)
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
            import kameloso.prettyprint : prettyprint;
            import std.typecons : Flag, No, Yes;

            // Offending line included in event, in raw
            prettyprint!(Yes.all)(event);

            if (event.sender != IRCUser.init)
            {
                logger.trace("sender:");
                prettyprint(event.sender);
            }

            if (event.target != IRCUser.init)
            {
                logger.trace("target:");
                prettyprint(event.target);
            }
        }
    }
}


// printSummary
/++
    Prints a summary of the connection(s) made and events parsed this execution.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void printSummary(const Kameloso instance) @safe
{
    import kameloso.time : timeSince;
    import core.time : Duration;

    Duration totalTime;
    ulong totalBytesReceived;
    uint i;

    if (instance.transient.numReexecs > 0)
    {
        enum summaryPattern = "== Connection summary == <t>(reexecs: </>%d<t>)";
        logger.infof(summaryPattern, instance.transient.numReexecs);
    }
    else
    {
        logger.info("== Connection summary ==");
    }

    foreach (const entry; instance.connectionHistory)
    {
        import std.datetime.systime : SysTime;
        import std.format : format;
        import std.stdio : writefln;

        if (!entry.bytesReceived) continue;

        enum onlyTimePattern = "%02d:%02d:%02d";
        enum fullDatePattern = "%d-%02d-%02d " ~ onlyTimePattern;

        auto start = SysTime.fromUnixTime(entry.startTime);
        immutable startString = fullDatePattern.format(
            start.year,
            cast(uint)start.month,
            start.day,
            start.hour,
            start.minute,
            start.second);

        auto stop = SysTime.fromUnixTime(entry.stopTime);
        immutable sameDay =
            (start.year == stop.year) &&
            (start.dayOfGregorianCal == stop.dayOfGregorianCal);
        immutable stopString = sameDay ?
            onlyTimePattern.format(
                stop.hour,
                stop.minute,
                stop.second) :
            fullDatePattern.format(
                stop.year,
                cast(uint)stop.month,
                stop.day,
                stop.hour,
                stop.minute,
                stop.second);

        start.fracSecs = Duration.zero;
        stop.fracSecs = Duration.zero;
        immutable duration = (stop - start);
        totalTime += duration;
        totalBytesReceived += entry.bytesReceived;

        enum pattern = "%2d: %s, %d events parsed in %,d bytes (%s to %s)";
        writefln(
            pattern,
            ++i,
            duration.timeSince!(7, 0)(abbreviate: true),
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


// RunState
/++
    Aggregate of state values used in an execution of the program.
 +/
struct RunState
{
private:
    import lu.common : Next;

public:
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


// echoQuitMessage
/++
    Echos the quit message to the local terminal, to fake it being sent verbosely
    to the server. It is sent, but later, bypassing the message fiber which would
    otherwise do the echoing.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        reason = Quit reason.
 +/
void echoQuitMessage(Kameloso instance, const string reason) @safe
{
    bool printed;

    version(Colours)
    {
        if (instance.settings.colours)
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        nickname = Nickname whose WHOIS timestamp to propagate.
        nowInUnix = UNIX WHOIS timestamp.
 +/
void propagateWhoisTimestamp(
    Kameloso instance,
    const string nickname,
    const long nowInUnix) @system
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
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void propagateWhoisTimestamps(Kameloso instance) @system
{
    auto copy = instance.previousWhoisTimestamps.dup;  // mutable

    foreach (plugin; instance.plugins)
    {
        plugin.state.previousWhoisTimestamps = copy;
    }
}


// prettyPrintStartScreen
/++
    Prints a pretty start screen.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        arg0 = The name of the program, as passed on the command line.
 +/
void prettyPrintStartScreen(const Kameloso instance, const string arg0)
{
    import kameloso.common : printVersionInfo;
    import kameloso.prettyprint : prettyprint;
    import kameloso.string : replaceTokens;
    import std.stdio : stdout, writeln;

    printVersionInfo();
    writeln();
    if (instance.settings.flush) stdout.flush();

    // Print the current settings to show what's going on.
    IRCClient prettyClient = instance.parser.client;
    prettyClient.realName = replaceTokens(prettyClient.realName);
    prettyprint(prettyClient, instance.bot, instance.parser.server);

    if (!instance.bot.homeChannels.length && !instance.bot.admins.length)
    {
        import kameloso.config : giveBrightTerminalHint, notifyAboutIncompleteConfiguration;

        giveBrightTerminalHint();
        logger.trace();
        notifyAboutIncompleteConfiguration(instance.settings.configFile, arg0);
    }
}



// checkInitialisationMessages
/++
    Checks for any initialisation messages that may have been sent by plugins
    during their initialisation.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        retval = out-reference to the [kameloso.constants.ShellReturnValue|ShellReturnValue]
            to return from [run].

    Returns:
        `true` if nothing fatal happened and the calling function should proceed,
        `false` otherwise.
 +/
auto checkInitialisationMessages(
    Kameloso instance,
    out ShellReturnValue retval)
{
    import kameloso.tables : trueThenFalse;
    import kameloso.thread : ThreadMessage;

    bool success = true;

    void onThreadMessage(ThreadMessage message)
    {
        with (ThreadMessage.MessageType)
        switch (message.type)
        {
        case popCustomSetting:
            size_t[] toRemove;

            foreach (immutable i, immutable line; instance.customSettings)
            {
                import lu.string : advancePast;

                string slice = line;  // mutable
                immutable setting = slice.advancePast('=', inherit: true);
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
            import lu.conv : toString;
            import std.stdio : stdout;

            enum pattern = "checkInitialisationMessages.onThreadMessage " ~
                "received unexpected message type: <t>%s";
            logger.errorf(
                pattern,
                message.type.toString());
            success = false;
            break;
        }
    }

    foreach (immutable isPriority; trueThenFalse[])
    {
        foreach (plugin; instance.plugins)
        {
            auto box = isPriority ?
                &plugin.state.priorityMessages :
                &plugin.state.messages;

            if (!(*box)[].length) continue;

            for (size_t i; i<(*box)[].length; ++i)
            {
                onThreadMessage((*box)[][i]);
            }

            box.clear();
        }
    }

    if (!success) retval = ShellReturnValue.pluginInitialisationFailure;
    return success;
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
    import lu.common : Next;
    import std.algorithm.comparison : among;
    import std.conv : ConvException;
    import std.exception : ErrnoException;
    static import kameloso.common;

    version(Windows)
    {
        /+
            Work around not being able to have arguments carry over re-executions
            with Powershell if they contain double quotes and/or octothorpes,
            by replacing such with KamelosoDefaultChars.doublequotePlaceholder and
            KamelosoDefaultChars.octothorpePlaceholder before forking
            (and now back before getopt).

            See comments in kameloso.platform.exec for more information.
         +/
        if (args.length > 1)
        {
            // skip args[0]
            foreach (immutable i; 1..args.length)
            {
                import kameloso.constants : KamelosoDefaultChars;
                import std.array : replace;

                args[i] = args[i]
                    .replace(cast(char)KamelosoDefaultChars.doublequotePlaceholder, '"')
                    .replace(cast(char)KamelosoDefaultChars.octothorpePlaceholder, '#');
            }
        }
    }

    // Set up the Kameloso instance.
    auto instance = new Kameloso(args);
    postInstanceSetup();

    scope(exit)
    {
        import kameloso.terminal : isTerminal, resetTerminalTitle;
        if (isTerminal) resetTerminalTitle();
        resetSignals();
    }

    // Set the abort pointer.
    instance.abort = &kameloso.common.globalAbort;

    // Set up default directories in the settings.
    setDefaultDirectories(*instance.settings);

    // Initialise the logger immediately so it's always available.
    // handleGetopt re-inits later when we know the settings for colours and headless
    kameloso.common.logger = new KamelosoLogger(*instance.settings);

    // Set up signal handling so that we can gracefully catch Ctrl+C.
    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken, isTerminal;

        if (!instance.settings.headless)
        {
            enum bellString = TerminalToken.bell ~ "";
            immutable bell = isTerminal ? bellString : string.init;
            logger.error("We just crashed!", bell);
        }

        *instance.abort = true;
    }

    // Handle command-line arguments.
    immutable actionAfterGetopt = tryGetopt(instance);
    kameloso.common.globalHeadless = instance.settings.headless;

    with (Next)
    final switch (actionAfterGetopt)
    {
    case continue_:
        break;

    case returnSuccess:
        return ShellReturnValue.success;

    case returnFailure:
        return ShellReturnValue.getoptFailure;

    case unset:  // should never happen
    case noop:   // ditto
    case retry:  // ...
    case crash:  // ...
        import lu.conv : toString;
        import std.conv : text;
        assert(0, text("`tryGetopt` returned `", actionAfterGetopt.toString(), "`"));
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

    if (!instance.settings.headless && !instance.transient.numReexecs)
    {
        prettyPrintStartScreen(instance, args[0]);
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

    case returnSuccess:  // should never happen
    case unset:  // ditto
    case noop:   // ...
    case retry:  // ...
    case crash:  // ...
        import lu.conv : toString;
        import std.conv : text;
        assert(0, text("`verifySettings` returned `", actionAfterVerification.toString(), "`"));
    }

    // Resolve resource and private key/certificate paths.
    resolvePaths(instance);

    version(Windows)
    {
        import std.file : exists, isDir;

        bool shouldWarnAboutMissingCaBundle;

        if (!instance.connSettings.caBundleFile.length)
        {
            import std.path : buildNormalizedPath, dirName;

            /+
                If no CA bundle file was specified *and* one exists either next
                to the configuration file or next to the binary, assume that filename.
             +/
            immutable string[2] fallbackCaBundleFileDirs =
            [
                instance.settings.configDirectory,
                args[0].dirName,
            ];

            foreach (immutable fallbackDir; fallbackCaBundleFileDirs[])
            {
                immutable fullPath = buildNormalizedPath(
                    fallbackDir,
                    "cacert.pem");

                if (fullPath.exists && !fullPath.isDir)
                {
                    instance.connSettings.caBundleFile = fullPath;
                    break;
                }
            }
        }

        if (
            (!instance.settings.headless &&
            !instance.transient.numReexecs) &&
            (!instance.connSettings.caBundleFile.exists ||
            instance.connSettings.caBundleFile.isDir))
        {
            shouldWarnAboutMissingCaBundle = true;
        }
    }

    // Sync settings and connSettings.
    instance.conn.certFile = instance.connSettings.certFile;
    instance.conn.privateKeyFile = instance.connSettings.privateKeyFile;

    // Save the original nickname *once*, outside the connection loop and before
    // initialising plugins (who will make a copy of it). Knowing this is useful
    // when authenticating.
    instance.parser.client.origNickname = instance.parser.client.nickname;

    scope(success)
    {
        // Tearing down tears down plugins too
        instance.teardown();
        destroy(instance);
        instance = null;
    }

    // Initialise plugins outside the loop once, for the error messages
    try
    {
        import std.file : exists;

        instance.instantiatePlugins();

        if (!instance.settings.headless &&
            !instance.transient.numReexecs &&
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

    version(Windows)
    {
        if (shouldWarnAboutMissingCaBundle)
        {
            import kameloso.constants : MagicErrorStrings;

            /+
                A cacert.pem was specified (at the command line or in the
                configuration file) but it doesn't exist. Warn.
             +/
            enum caBundleMessage1 = "No SSL certificate authority bundle file found.";
            enum caBundleMessage2 = cast(string)MagicErrorStrings.visitWikiOneliner;
            enum caBundleMessage3 = "Run the program with <l>--get-cacert</> to download one, " ~
                "or specify an existing file with <l>--cacert=";  // no dot at end on purpose
            enum caBundleMessage4 = "Expect some plugins to break.";

            logger.warning(caBundleMessage1);
            logger.warning(caBundleMessage2);
            logger.warning(caBundleMessage3);
            logger.warning(caBundleMessage4);
            logger.trace();
        }
    }

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

    // Check for messages in case any were sent during plugin initialisation
    ShellReturnValue initRetval;
    immutable proceed = checkInitialisationMessages(instance, initRetval);
    if (!proceed) return initRetval;

    // Go!
    auto attempt = startBot(instance);  // mustn't be const

    // If we're here, we should exit. The only question is in what way.

    if (instance.conn.connected && !instance.transient.quitMessageSent)
    {
        // If not already sent, send a proper QUIT, optionally verbosely
        string reason;  // mutable

        if (!*instance.abort &&
            !instance.settings.headless &&
            !instance.settings.hideOutgoing)
        {
            import kameloso.thread : getQuitMessage;

            immutable quitMessage = getQuitMessage(instance.plugins);
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

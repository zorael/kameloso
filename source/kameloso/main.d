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
        extern(C)
        public __gshared string[] rt_options =
        [
            "gcopt=profile:1 gc:precise",
            "scanDataSeg=precise",
        ];
    }
    else
    {
        extern(C)
        public __gshared string[] rt_options =
        [
            "gcopt=profile:1",
        ];
    }
}

public __gshared bool rawAbort;

version(Posix)
{
    private int signalRaised;
}

extern (C)
void signalHandler(int sig) nothrow @nogc @system {}

void messageFiber(ref Kameloso instance)
{
    import kameloso.common : OutgoingLine, replaceTokens;
    import kameloso.messaging : Message;
    import kameloso.thread : Sendable, ThreadMessage;
    import std.concurrency : yield;

    yield(Next.init);

    assert(0, "`while (true)` loop break in `messageFiber`");
}

Next mainLoop(ref Kameloso instance)
{
    return Next.init;
}

double sendLines(ref Kameloso instance)
{
    return 0.0;
}

import kameloso.net : ListenAttempt;

Next listenAttemptToNext(ref Kameloso instance, const ListenAttempt attempt)
{
    return Next.init;
}

void processScheduledFibers(IRCPlugin plugin, const long nowInHnsecs)
in ((nowInHnsecs > 0), "Tried to process queued `ScheduledFiber`s with an unset timestamp")
{}

void processRepeats(ref Kameloso instance, IRCPlugin plugin) {}

void processReplays(ref Kameloso instance, IRCPlugin plugin) {}

void setupSignals() nothrow @nogc {}

void resetSignals() nothrow @nogc {}

Next tryGetopt(ref Kameloso instance, string[] args, out string[] customSettings)
{
    return Next.returnFailure;
}

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
            logger.logf("Retrying in %s%d%s seconds...",
                Tint.info, incrementedRetryDelay, Tint.log);
            interruptibleSleep(incrementedRetryDelay.seconds, *instance.abort);

            import std.algorithm.comparison : min;
            incrementedRetryDelay = cast(uint)(incrementedRetryDelay *
                ConnectionDefaultFloats.delayIncrementMultiplier);
            incrementedRetryDelay = min(incrementedRetryDelay, Timeout.connectionDelayCap);
        }

        void verboselyDelayToNextIP()
        {
            logger.logf("Failed to connect to IP. Trying next IP in %s%d%s seconds.",
                Tint.info, Timeout.connectionRetry, Tint.log);
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
                catch (AddressException e) {}

                if (*instance.abort) return Next.returnFailure;
            }

            immutable pattern = !resolvedHost.length &&
                (attempt.ip.addressFamily == AddressFamily.INET6) ?
                "Connecting to [%s%s%s]:%1$s%4$s%3$s %5$s..." :
                "Connecting to %s%s%s:%1$s%4$s%3$s %5$s...";

            immutable ssl = instance.conn.ssl ? "(SSL) " : string.init;

            immutable address = (!resolvedHost.length ||
                (instance.parser.server.address == resolvedHost) ||
                (sharedDomains(instance.parser.server.address, resolvedHost) < 2)) ?
                attempt.ip.toAddrString : resolvedHost;

            logger.logf(pattern, Tint.info, address, Tint.log, attempt.ip.toPortString, ssl);
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
                    logger.warningf("Connection failed with %s%s%s: %1$s%4$s",
                        Tint.log, errnoStrings[attempt.errno], Tint.warning, errorString);
                }
                else version(Windows)
                {
                    logger.warningf("Connection failed with error %s%d%s: %1$s%4$s",
                        Tint.log, attempt.errno, Tint.warning, errorString);
                }
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) verboselyDelay();
            continue;

        case delayThenNextIP:

            if (*instance.abort) return Next.returnFailure;
            verboselyDelayToNextIP();
            if (*instance.abort) return Next.returnFailure;
            continue;

        case ipv6Failure:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                logger.warningf("IPv6 connection failed with %s%s%s: %1$s%4$s",
                    Tint.log, errnoStrings[attempt.errno], Tint.warning, errorString);
            }
            else version(Windows)
            {
                logger.warningf("IPv6 connection failed with error %s%d%s: %1$s%4$s",
                    Tint.log, attempt.errno, Tint.warning, errorString);
            }
            else
            {
                logger.warning("IPv6 connection failed. Disabling IPv6.");
            }

            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) goto case delayThenNextIP;
            continue;

        case sslFailure:
            logger.error("Failed to connect: ", Tint.log, attempt.error);
            if (*instance.abort) return Next.returnFailure;
            if (!lastRetry) verboselyDelay();
            continue;

        case invalidConnectionError:
        case error:
            version(Posix)
            {
                import kameloso.common : errnoStrings;
                logger.errorf("Failed to connect: %s%s%s (%1$s%4$s%3$s)",
                    Tint.log, errorString, Tint.error, errnoStrings[attempt.errno]);
            }
            else version(Windows)
            {
                logger.errorf("Failed to connect: %s%s%s (%1$s%4$d%3$s)",
                    Tint.log, errorString, Tint.error, attempt.errno);
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

Next tryResolve(ref Kameloso instance, const Flag!"firstConnect" firstConnect)
{
    return Next.returnFailure;
}

void postInstanceSetup(ref Kameloso instance) {}

void expandPaths(ref CoreSettings settings) {}

Next verifySettings(ref Kameloso instance)
{
    return Next.continue_;
}

void resolveResourceDirectory(ref Kameloso instance) {}

void startBot(ref Kameloso instance, ref AttemptState attempt)
{
    import kameloso.terminal : TerminalToken, isTTY;
    import std.algorithm.comparison : among;

    IRCClient backupClient = instance.parser.client;

    enum bellString = ("" ~ cast(char)(TerminalToken.bell));
    immutable bell = isTTY ? bellString : string.init;

    outerloop:
    do
    {
        attempt.silentExit = true;

        if (!attempt.firstConnect)
        {
            import kameloso.constants : Timeout;
            import kameloso.thread : exhaustMessages, interruptibleSleep;
            import core.time : seconds;

            backupClient.nickname = instance.parser.client.nickname;
            exhaustMessages();

            instance.outbuffer.clear();
            instance.backgroundBuffer.clear();
            instance.priorityBuffer.clear();
            instance.immediateBuffer.clear();

            version(TwitchSupport)
            {
                instance.fastbuffer.clear();
            }

            logger.log("One moment...");
            interruptibleSleep(Timeout.connectionRetry.seconds, *instance.abort);
            if (*instance.abort) break outerloop;

            instance.initPlugins(attempt.customSettings);

            instance.throttle = typeof(instance.throttle).init;
            instance.previousWhoisTimestamps = typeof(instance.previousWhoisTimestamps).init;
            immutable addressSnapshot = instance.parser.server.address;
            immutable portSnapshot = instance.parser.server.port;
            instance.parser.server = typeof(instance.parser.server).init;
            instance.parser.server.address = addressSnapshot;
            instance.parser.server.port = portSnapshot;
        }

        scope(exit)
        {
            instance.teardownPlugins();
        }

        if (*instance.abort) break outerloop;

        instance.conn.reset();

        instance.conn.receiveTimeout = instance.connSettings.receiveTimeout;

        immutable actionAfterResolve = tryResolve(instance, cast(Flag!"firstConnect")(attempt.firstConnect));
        if (*instance.abort) break outerloop;

        with (Next)
        final switch (actionAfterResolve)
        {
        case continue_:
            break;

        case retry:
            assert(0, "`tryResolve` returned `Next.retry`");

        case returnFailure:

            attempt.retval = 1;
            break outerloop;

        case returnSuccess:

            attempt.retval = 0;
            break outerloop;

        case crash:
            assert(0, "`tryResolve` returned `Next.crash`");
        }

        immutable actionAfterConnect = tryConnect(instance);
        if (*instance.abort) break outerloop;

        with (Next)
        final switch (actionAfterConnect)
        {
        case continue_:
            break;

        case returnSuccess:
            assert(0, "`tryConnect` returned `Next.returnSuccess`");

        case retry:
            assert(0, "`tryConnect` returned `Next.retry`");

        case returnFailure:

            attempt.retval = 1;
            break outerloop;

        case crash:
            assert(0, "`tryConnect` returned `Next.crash`");
        }

        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
        import std.path : baseName;

        try
        {
            instance.initPluginResources();
            if (*instance.abort) break outerloop;
        }
        catch (IRCPluginInitialisationException e)
        {
            import kameloso.terminal : TerminalToken;

            logger.warningf("The %s%s%s plugin failed to load its resources: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s",
                Tint.log, e.file.baseName[0..$-2], Tint.warning, e.msg,
                e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = 1;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;

            logger.warningf("An error occurred while initialising the %s%s%s " ~
                "plugin's resources: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s",
                Tint.log, e.file.baseName[0..$-2], Tint.warning, e.msg,
                e.file, e.line, bell);
            version(PrintStacktraces) logger.trace(e);
            attempt.retval = 1;
            break outerloop;
        }

        import dialect.parsing : IRCParser;

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
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s",
                Tint.log, e.file.baseName[0..$-2], Tint.warning, e.msg,
                e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e.info);
            attempt.retval = 1;
            break outerloop;
        }
        catch (Exception e)
        {
            import kameloso.terminal : TerminalToken;

            logger.warningf("An error occurred while starting up the %s%s%s plugin: %1$s%4$s%3$s " ~
                "(at %1$s%5$s%3$s:%1$s%6$d%3$s)%7$s",
                Tint.log, e.file.baseName[0..$-2], Tint.warning, e.msg,
                e.file.baseName, e.line, bell);
            version(PrintStacktraces) logger.trace(e);
            attempt.retval = 1;
            break outerloop;
        }

        attempt.silentExit = false;
        attempt.next = instance.mainLoop();
        attempt.firstConnect = false;
    }
    while (!*instance.abort && attempt.next.among!(Next.continue_, Next.retry, Next.returnFailure));
}

void printEventDebugDetails(const ref IRCEvent event,
    const string raw,
    const bool eventWasInitialised = true)
{}

void printSummary(const ref Kameloso instance)
{
    import kameloso.common : timeSince;
    import core.time : Duration;

    Duration totalTime;
    long totalBytesReceived;

    logger.info("-- Connection summary --");

    foreach (immutable i, const entry; instance.connectionHistory)
    {
        import std.datetime.systime : SysTime;
        import std.format : format;
        import std.stdio : writefln;
        import core.time : hnsecs;

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

        writefln("%2d: %s, %d events parsed in %,d bytes (%s to %s)",
            i+1, duration.timeSince!(7, 0)(Yes.abbreviate), entry.numEvents,
            entry.bytesReceived, startString, stopString);
    }

    logger.info("Total time connected: ", Tint.log, totalTime.timeSince!(7, 1));
    logger.infof("Total received: %s%,d%s bytes", Tint.log, totalBytesReceived, Tint.info);
}

struct AttemptState
{
    Next next;
    string[] customSettings;
    bool firstConnect = true;
    bool silentExit;
    int retval;
}

public:

int initBot(string[] args)
{
    static import kameloso.common;
    import kameloso.common : initLogger;
    import std.exception : ErrnoException;
    import core.stdc.errno : errno;

    Kameloso instance;
    postInstanceSetup(instance);

    kameloso.common.settings = &instance.settings;
    instance.abort = &rawAbort;

    AttemptState attempt;

    expandPaths(instance.settings);
    initLogger(cast(Flag!"monochrome")instance.settings.monochrome,
        cast(Flag!"brightTerminal")instance.settings.brightTerminal);

    setupSignals();

    scope(failure)
    {
        import kameloso.terminal : TerminalToken, isTTY;

        enum bellString = ("" ~ cast(char)(TerminalToken.bell));
        immutable bell = isTTY ? bellString : string.init;

        logger.error("We just crashed!", bell);
        *instance.abort = true;
        resetSignals();
    }

    immutable actionAfterGetopt = instance.tryGetopt(args, attempt.customSettings);

    with (Next)
    final switch (actionAfterGetopt)
    {
    case continue_:
        break;

    case retry:
        assert(0, "`tryGetopt` returned `Next.retry`");

    case returnSuccess:
        return 0;

    case returnFailure:
        return 1;

    case crash:
        assert(0, "`tryGetopt` returned `Next.crash`");
    }

    try
    {
        import kameloso.terminal : ensureAppropriateBuffering;
        ensureAppropriateBuffering(cast(Flag!"override_")instance.settings.flush);
    }
    catch (ErrnoException e)
    {
        import std.stdio : writeln;
        writeln("Failed to set stdout buffer mode/size! errno:", errno);
        if (!instance.settings.force) return 1;
    }
    catch (Exception e)
    {
        import std.stdio : writeln;
        writeln("Failed to set stdout buffer mode/size!");
        writeln(e);
        if (!instance.settings.force) return 1;
    }

    if (!instance.settings.force)
    {
        import kameloso.config : applyDefaults;
        applyDefaults(instance.parser.client, instance.parser.server, instance.bot);
    }

    import std.algorithm.comparison : among;

    instance.conn.certFile = instance.connSettings.certFile;
    instance.conn.privateKeyFile = instance.connSettings.privateKeyFile;
    instance.conn.ssl = instance.connSettings.ssl;

    if (!instance.conn.ssl && !instance.settings.force &&
        instance.parser.server.port.among(6697, 7000, 7001, 7029, 7070, 9999, 443))
    {
        instance.connSettings.ssl = true;
        instance.conn.ssl = true;
    }

    import kameloso.common : replaceTokens, printVersionInfo;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    printVersionInfo();
    writeln();

    IRCClient prettyClient = instance.parser.client;
    prettyClient.realName = replaceTokens(prettyClient.realName);
    printObjects(prettyClient, instance.bot, instance.parser.server);

    if (!instance.bot.homeChannels.length && !instance.bot.admins.length)
    {
        import kameloso.config : notifyAboutIncompleteConfiguration;
        notifyAboutIncompleteConfiguration(instance.settings.configFile, args[0]);
    }

    immutable actionAfterVerification = instance.verifySettings();

    with (Next)
    final switch (actionAfterVerification)
    {
    case continue_:
        break;

    case retry:
        assert(0, "`verifySettings` returned `Next.retry`");

    case returnSuccess:
        return 0;

    case returnFailure:
        return 1;

    case crash:
        assert(0, "`verifySettings` returned `Next.crash`");
    }

    instance.resolveResourceDirectory();

    instance.parser.client.origNickname = instance.parser.client.nickname;

    import kameloso.plugins.common.misc : IRCPluginSettingsException;
    import std.conv : ConvException;

    try
    {
        import std.file : exists;

        string[][string] missingEntries;
        string[][string] invalidEntries;

        instance.initPlugins(attempt.customSettings, missingEntries, invalidEntries);

        if (missingEntries.length && instance.settings.configFile.exists)
        {
            import kameloso.config : notifyAboutMissingSettings;
            notifyAboutMissingSettings(missingEntries, args[0], instance.settings.configFile);
        }
    }
    catch (ConvException e)
    {
        logger.error(e.msg);
        if (!instance.settings.force) return 1;
    }
    catch (IRCPluginSettingsException e)
    {

        logger.error(e.msg);
        if (!instance.settings.force) return 1;
    }

    instance.parser.client.origNickname = instance.parser.client.nickname;

    instance.startBot(attempt);

    if (*instance.abort && instance.conn.connected)
    {
        import kameloso.thread : ThreadMessage;
        import std.concurrency : receiveTimeout;
        import std.variant : Variant;
        import core.time : seconds;

        string reason = instance.bot.quitReason;
        bool quiet;
        bool notEmpty;

        do
        {
            notEmpty = receiveTimeout((-1).seconds,
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

    if (instance.settings.saveOnExit)
    {
        try
        {
            import kameloso.config : writeConfigurationFile;
            instance.writeConfigurationFile(instance.settings.configFile);
        }
        catch (Exception e)
        {
            logger.warningf("Caught Exception when saving settings: " ~
                "%s%s%s (at %1$s%4$s%3$s:%1$s%5$d%3$s)",
                Tint.log, e.msg, Tint.warning, e.file, e.line);
            version(PrintStacktraces) logger.trace(e);
        }
    }

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
            logger.infof("Allocated in current thread: %s%,d%s bytes",
                Tint.log, allocated, Tint.info);
        }

        logger.infof("Memory used: %s%,d%s bytes, free: %1$s%4$,d%3$s bytes",
            Tint.log, stats.usedSize, Tint.info, stats.freeSize);
    }

    if (*instance.abort)
    {
        logger.error("Aborting...");

        version(Posix)
        {
            attempt.retval = (signalRaised > 0) ? (128 + signalRaised) : 1;
        }
        else
        {
            attempt.retval = 1;
        }
    }
    else if (!attempt.silentExit)
    {
        logger.info("Exiting...");
    }

    return attempt.retval;
}

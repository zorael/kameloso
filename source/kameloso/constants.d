/++
    A collection of constants used throughout the program.

    This acts as a compile-time configuration file to reduce ad-hoc magic numbers.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.constants;

private:

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;

version(DigitalMars)
{
    /++
        String of the compiler that was used to compile this binary with. Here: `dmd`.
     +/
    enum compiler = "dmd";
}
else version(LDC)
{
    /++
        String of the compiler that was used to compile this binary with. Here: `ldc`.
     +/
    enum compiler = "ldc";
}
else version(GNU)
{
    /++
        String of the compiler that was used to compile this binary with. Here: `gdc`.
     +/
    enum compiler = "gdc";
}
else
{
    /++
        String of the compiler that was used to compile this binary with. Here: no idea.
     +/
    enum compiler = "<unknown>";
}


// buildCompilerVersionString
/++
    Replaces the following expression and lowers compilation memory by avoiding
    use of compile-time [std.format.format|format].

    ---
    import std.compiler;
    enum compilerVersion = format("%d.%03d", version_major, version_minor);
    ---

    Returns:
        The compiler version as a string in the format of `{MAJOR}.{MINOR}` (eg. `2.100`).
 +/
auto buildCompilerVersionString()
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;
    import std.exception : assumeUnique;

    enum major = cast(uint) (__VERSION__ / 1000);
    enum minor = cast(uint) (__VERSION__ % 1000);

    Appender!(char[]) sink;
    sink.reserve(5);  // "2.123"

    major.toAlphaInto(sink);
    sink.put('.');
    minor.toAlphaInto!(3, 3)(sink);

    return sink[].assumeUnique();
}


// buildVersionString
/++
    Replaces the following expression and lowers compilation memory by avoiding
    use of compile-time [std.format.format|format].

    ---
    enum version_ = "%d.%d.%d%s%s"
        .format(
            KamelosoSemVer.major,
            KamelosoSemVer.minor,
            KamelosoSemVer.patch,
            KamelosoSemVerPrerelease.length ? "-" : string.init,
            KamelosoSemVerPrerelease);
    ---

    Returns:
        The program version as a string in the format of
        `{MAJOR}.{MINOR}.{PATCH}{-PRERELEASE}` (eg. `3.2.0-alpha.1`).
        `{-PRERELEASE}` is optional.
 +/
auto buildVersionString()
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;
    import std.exception : assumeUnique;

    Appender!(char[]) sink;
    sink.reserve(16);  // 10.10.10-alpha.1

    with (KamelosoSemVer)
    {
        major.toAlphaInto(sink);
        sink.put('.');
        minor.toAlphaInto(sink);
        sink.put('.');
        patch.toAlphaInto(sink);

        if (KamelosoSemVerPrerelease.length)
        {
            sink.put('-');
            sink.put(cast(string) KamelosoSemVerPrerelease);
        }
    }

    return sink[].assumeUnique();
}


public:


// KamelosoInfo
/++
    Meta-information about the program.
 +/
enum KamelosoInfo
{
    /++
        Version as a string.
     +/
    version_ = .buildVersionString(),

    /++
        Timestamp of when the binary was built.
     +/
    built = __TIMESTAMP__,

    /++
        Compiler used to build this binary.
     +/
    compiler = .compiler,

    /++
        Compiler version used to build this binary.
     +/
    compilerVersion = .buildCompilerVersionString(),

    /++
        GitHub source link.
     +/
    source = "https://github.com/zorael/kameloso",
}


// KamelosoDefaults
/++
    Kameloso defaults, strings version.
 +/
enum KamelosoDefaults
{
    /++
        Default user to use when logging onto a server (the USER command).
        Additionally becomes the bot's IDENT identifier (prepended with a '~'),
        if a separate `identd` server is not being run.
     +/
    user = "kameloso",

    /++
        Default server address.
     +/
    serverAddress = "irc.libera.chat",

    /++
        The default GEOC/"real name" string.
     +/
    realName = "kameloso IRC bot v$version",

    /++
        The default quit reason, when the bot exits. Supports some string replacements.
     +/
    quitReason = "kameloso IRC bot v$version @ $source",

    /++
        The default part reason, when the bot is asked to part a channel.
     +/
    partReason = quitReason,

    /++
        When a nickname was already taken during registration, append this followed
        by some random numbers to it to generate a new one.

        A separator of "|" and a taken nickname of "guest" thus gives nicknames like "guest|1".
        A separator of "^" gives nicknames like "guest^2".
     +/
    altNickSeparator = "|",

    /++
        The default prefix to use for commands.
     +/
    prefix = "!",
}


// KamelosoDefaultIntegers
/++
    Kameloso defaults, integers version.
 +/
enum KamelosoDefaultIntegers
{
    /++
        Default server port.
     +/
    port = 6667,
}


// KamelosoDefaultChars
/++
    Kameloso defaults, character version.
 +/
enum KamelosoDefaultChars
{
    /++
        Placeholder for quote characters, used when re-executing on Windows.
     +/
    doublequotePlaceholder = '\1',

    /++
        Placeholder for octothorpe characters, used when re-executing on Windows.
     +/
    octothorpePlaceholder = '\2',
}


// KamelosoFilenames
/++
    Kameloso filenames.
 +/
enum KamelosoFilenames
{
    /++
        The main configuration file.
     +/
    configuration = "kameloso.conf",

    /++
        The file containing user account classifiers, specifying which accounts
        are whitelisted, operators and/or blacklisted.
     +/
    users = "users.json",

    /++
        The file containing user "account" hostmasks, mapping what we still
        consider accounts to hostmasks, on servers that don't employ services.
     +/
    hostmasks = "hostmasks.json",
}


// ConnectionDefaultIntegers
/++
    Connection defaults, integers version.
 +/
enum ConnectionDefaultIntegers
{
    /++
        How many times to attempt to connect to an IP before moving on to the next one.
     +/
    connectionRetries = 4,

    /++
        How many querier workers to spawn. This is the number of threads that
        will be used to send messages to the server in parallel.
     +/
    numWorkers = 6,
}


// Timeout
/++
    Various timeout values used throughout the program.
 +/
struct Timeout
{
private:
    import core.time : hnsecs, msecs, seconds;

    alias CDF = ConnectionDefaultFloats;

public:
    // ConnectionDefaultIntegers
    /++
        Connection defaults, integers version.
     +/
    enum Integers
    {
        /++
            The receive attempt timeout as set as a [std.socket.SocketOption|SocketOption].
         +/
        receiveMsecs = 1000,

        /++
            The receive attempt timeout when it's shortened to provide better
            responsiveness, in milliseconds.
         +/
        receiveShortenedMsecs = cast(int) (receiveMsecs * CDF.receiveShorteningMultiplier),

        /++
            The amount of time to spend with a shortened receive timeout.
            After this, it reverts to [Timeout.receiveMsecs].
         +/
        maxShortenDurationHnsecs = 2_000 * 10_000,

        /++
            The send attempt timeout as set as a [std.socket.SocketOption|SocketOption].
         +/
        sendMsecs = 15_000,

        /++
            How long to wait before allowing to re-issue a WHOIS query for a user.

            This is merely to stop us from spamming queries for the same person
            without hysteresis.
         +/
        whoisRetrySeconds = 30,

        /++
            The length of the window in which replays may be queued before the timer
            towards [Timeout.whoisRetry] kicks in.
         +/
        whoisGracePeriodSeconds = 3,

        /++
            How long a replayable event is expected to be relevant. Before this
            it will be replayed, after this it will be discarded.

            Note: WHOIS-replays will break if the ping toward the server reaches this value.
         +/
        whoisDiscardSeconds = 10,

        /++
            The amount of seconds to wait before retrying after a failed
            connection attempt.
         +/
        connectionRetrySeconds = 5,

        /++
            The maximum amount of time to wait between connection attempts.
         +/
        connectionDelayCapSeconds = 300,

        /++
            How long to keep trying to read from the sever when not receiving
            anything at all before the connection is considered lost.
         +/
        connectionLostSeconds = 600,

        /++
            How long to wait before retrying a connection attempt after a network
            down error.
         +/
        networkDownDelayCapSeconds = 600,

        /++
            Timeout for HTTP GET requests.
         +/
        httpGETSeconds = 10,

        /++
            How long to wait after encountering an error when reading from the
            server, before trying anew.

            Not having a small delay could cause it to spam the screen with errors
            as fast as it can.
         +/
        readErrorGracePeriodMsecs = 100,

        /++
            The amount of seconds to wait before retrying to connect after an
            instant failure to register on Twitch.
         +/
        twitchRegistrationFailConnectionRetryMsecs = 500,

        /++
            How long to wait after issuing an HTTP request before checking
            whether a response has been received.
         +/
        httpQueryInitialWaitMsecs = 200,

        /++
            How long to wait between checks for a response after the initial
            wait period.
         +/
        httpQueryWaitBetweenChecksMsecs = 100,
    }

    /++
        The receive attempt timeout as set as a [std.socket.SocketOption|SocketOption].
     +/
    static immutable receive = Integers.receiveMsecs.msecs;

    /++
        The send attempt timeout as set as a [std.socket.SocketOption|SocketOption].
     +/
    static immutable send = Integers.sendMsecs.msecs;

    /++
        The amount of time to spend with a shortened receive timeout.
        After this, it reverts to [Timeout.receive].
     +/
    static immutable maxShortenDuration = Integers.maxShortenDurationHnsecs.hnsecs;

    /++
        The maximum amount of time to wait between connection attempts.
     +/
    static immutable connectionDelayCap = Integers.connectionDelayCapSeconds.seconds;

    /++
        The amount of seconds to wait before retrying after a failed connection attempt.
     +/
    static immutable connectionRetry = Integers.connectionRetrySeconds.seconds;

    /++
        The amount of seconds to wait before retrying to connect after an instant
        failure to register on Twitch.
     +/
    static immutable twitchRegistrationFailConnectionRetry =
        Integers.twitchRegistrationFailConnectionRetryMsecs.msecs;

    /++
        How long to wait before allowing to re-issue a WHOIS query for a user.

        This is merely to stop us from spamming queries for the same person
        without hysteresis.
     +/
    static immutable whoisRetry = Integers.whoisRetrySeconds.seconds;

    /++
        How long a replayable event is expected to be relevant. Before this it
        will be replayed, after this it will be discarded.

        Note: WHOIS-replays will break if the ping toward the server reaches this value.
     +/
    static immutable whoisDiscard = Integers.whoisDiscardSeconds.seconds;

    /++
        The length of the window in which replays may be queued before the timer
        towards [Timeout.whoisRetry] kicks in.
     +/
    static immutable whoisGracePeriod = Integers.whoisGracePeriodSeconds.seconds;

    /++
        How long to wait after encountering an error when reading from the server,
        before trying anew.

        Not having a small delay could cause it to spam the screen with errors
        as fast as it can.
     +/
    static immutable readErrorGracePeriod = Integers.readErrorGracePeriodMsecs.msecs;

    /++
        How long to keep trying to read from the sever when not receiving anything
        at all before the connection is considered lost.
     +/
    static immutable connectionLost = Integers.connectionLostSeconds.seconds;

    /++
        Timeout for HTTP GET requests.
     +/
    static immutable httpGET = Integers.httpGETSeconds.seconds;

    /++
        How long to wait after issuing an HTTP request before checking whether a
        response has been received.
     +/
    static immutable httpQueryInitialWait = Integers.httpQueryInitialWaitMsecs.msecs;

    /++
        How long to wait between checks for a response after the initial wait period.
     +/
    static immutable httpQueryWaitBetweenChecks = Integers.httpQueryWaitBetweenChecksMsecs.msecs;
}


// ConnectionDefaultFloats
/++
    Connection defaults, floating point version.
 +/
enum ConnectionDefaultFloats : double
{
    /++
        By what to multiply the connect timeout after failing an attempt.
     +/
    delayIncrementMultiplier = 1.5,

    /++
        By what to multiply [Timeout.receiveMsecs] with to shorten reads.
     +/
    receiveShorteningMultiplier = 0.25,

    /++
        How many messages to send per second, maximum.
     +/
    messageRate = 1.2,

    /++
        How many messages to immediately send in one go, before throttling kicks in.
     +/
    messageBurst = 3.0,

    /++
        How many messages to send per second, maximum. For *fast* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageRateTwitchFast = 2.0,

    /++
        How many messages to immediately send in one go, before throttling kicks in.
        For *fast* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageBurstTwitchFast = 3.0,

    /++
        How many messages to send per second, maximum. For *slow* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageRateTwitchSlow = 0.5,

    /++
        How many messages to immediately send in one go, before throttling kicks in.
        For *slow* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageBurstTwitchSlow = 0.5,
}


// BufferSize
/++
    Buffer sizes in bytes.
 +/
enum BufferSize
{
    /++
        The receive buffer size as set as a [std.socket.SocketOption|SocketOption].
     +/
    socketOptionReceive = 8192,

    /++
        The send buffer size as set as a [std.socket.SocketOption|SocketOption].
     +/
    socketOptionSend = 8192,

    /++
        The actual buffer array size used when reading from the socket.
     +/
    socketReceive = 8192,

    /++
        The maximum number of queued outgoing lines to buffer. Anything above
        this will crash the program with a buffer overrun. It can be arbitrarily big.
     +/
    outbuffer = 512,

    /++
        The maximum number of queued priority lines to buffer. These are rare.
     +/
    priorityBuffer = 64,

    /++
        How many bytes to preallocate a buffer for when printing objects to
        screen with the [kameloso.prettyprint] templates. This value times the
        number of objects to print.
     +/
    prettyprintBufferPerObject = 1024,

    /++
        How many bytes to allocate for the stdout buffer, when we need to do so explicitly.
     +/
    vbufStdout = 32_768,

    /++
        How large to make [core.thread.fiber.Fiber|Fiber] stacks, so they don't
        overflow (which they seem to have a knack for doing).
     +/
    fiberStack = 32_768,
}


// ShellReturnValue
/++
    Magic number shell exit codes.
 +/
enum ShellReturnValue
{
    /++
        Success. No error encountered.
     +/
    success = 0,

    /++
        Generic error.
     +/
    failure = 1,

    /++
        Failure encountered during `getopt`.
     +/
    getoptFailure = 2,

    /++
        Failure encountered when setting up terminal buffering.
     +/
    terminalSetupFailure = 3,

    /++
        Settings verification failed.
     +/
    settingsVerificationFailure = 4,

    /++
        `--set` argument syntax error.
     +/
    customConfigSyntaxFailure = 5,

    /++
        `--set` other failure.
     +/
    customConfigFailure = 6,

    /++
        Failure encountered during host address resolution.
     +/
    resolutionFailure = 21,

    /++
        Failure encountered during connection attempt.
     +/
    connectionFailure = 22,

    /++
        Failure encountered when a plugin tried to load resources.
     +/
    pluginResourceLoadFailure = 31,

    /++
        Generic exception was thrown when a plugin tried to load resources.
     +/
    pluginResourceLoadException = 32,

    /++
        Failure encountered during plugin setup.
     +/
    pluginSetupFailure = 33,

    /++
        Generic exception was thrown when a plugin tried to setup.
     +/
    pluginSetupException = 34,

    /++
        Failure encountered during plugin start.
     +/
    pluginStartFailure = 35,

    /++
        Generic exception was thrown when a plugin tried to start.
     +/
    pluginStartException = 36,

    /++
        Failure encountered during plugin init.
     +/
    pluginInitialisationFailure = 37,

    /++
        Generic exception was thrown when a plugin tried to initialise.
     +/
    pluginInitialisationException = 38,

    /++
        Failure encountered during plugin init.
     +/
    pluginInstantiationFailure = 39,

    /++
        Generic exception was thrown when a plugin tried to initialise.
     +/
    pluginInstantiationException = 40,
}


// MagicErrorStrings
/++
    Hardcoded error strings.
 +/
enum MagicErrorStrings
{
    /++
        Failed to set up an SSL context, original library line ([requests]).
     +/
    sslContextCreationFailure = "can't complete call to TLS_method",

    /++
        Could not initialise SSL libraries, rewritten line.
     +/
    sslLibraryNotFoundRewritten = "SSL libraries not found",

    /++
        Wiki link oneliner, tagged.
     +/
    visitWikiOneliner = "Visit <l>https://github.com/zorael/kameloso/wiki/OpenSSL</> for more information.",

    /++
        `--get-openssl` suggestion hint oneliner, tagged.
     +/
    getOpenSSLSuggestion = "Run the program with <l>--get-openssl</> to download " ~
        "and run the installer for <l>OpenSSL for Windows</>.",
}


// MagicStrings
/++
    Hardcoded non-error strings.
 +/
enum MagicStrings
{
    /++
        When used as the first and only element in an array, signifies that is
        should be considered empty. Used internally.
     +/
    emptyArrayMarker = "__empty",
}


// DefaultColours
/++
    Default colours gathered in one struct namespace.

    This makes it easier to compile-time customise colours to your liking.
 +/
version(Colours)
struct DefaultColours
{
private:
    import kameloso.logger : LogLevel;
    import kameloso.terminal.colours.defs : TerminalForeground;

    alias TF = TerminalForeground;

public:
    /++
        Colours for timestamps, shared between event-printing and logging.
     +/
    enum TimestampColour : TerminalForeground
    {
        /++
            For dark terminal backgrounds. Was
            [kameloso.terminal.colours.defs.TerminalForeground.white_|TerminalForeground.white_].
         +/
        dark = TF.default_,

        /++
            For bright terminal backgrounds. Was
            [kameloso.terminal.colours.defs.TerminalForeground.black_|TerminalForeground.black_].
         +/
        bright = TF.default_,
    }

    /++
        Logger colours to use with a dark terminal background.
     +/
    static immutable TerminalForeground[256] logcoloursDark  =
    [
        LogLevel.all      : TF.white,        /// LogLevel.all, or just `log`
        LogLevel.trace    : TF.default_,     /// `trace`
        LogLevel.info     : TF.lightgreen,   /// `info`
        LogLevel.warning  : TF.lightred,     /// `warning`
        LogLevel.error    : TF.red,          /// `error`
        LogLevel.critical : TF.red,          /// `critical`
        LogLevel.fatal    : TF.red,          /// `fatal`
        LogLevel.off      : TF.default_,     /// `off`
    ];

    /++
        Logger colours to use with a bright terminal background.
     +/
    static immutable TerminalForeground[256] logcoloursBright  =
    [
        LogLevel.all      : TF.black,        /// LogLevel.all, or just `log`
        LogLevel.trace    : TF.default_,     /// `trace`
        LogLevel.info     : TF.green,        /// `info`
        LogLevel.warning  : TF.red,          /// `warning`
        LogLevel.error    : TF.red,          /// `error`
        LogLevel.critical : TF.red,          /// `critical`
        LogLevel.fatal    : TF.red,          /// `fatal`
        LogLevel.off      : TF.default_,     /// `off`
    ];
}

/++
    A collection of constants used throughout the program.

    This acts as a compile-time configuration file.
 +/
module kameloso.constants;

private:

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;
import std.format : format;


version(DigitalMars)
{
    /// String of the compiler that was used to compile this binary with. Here: `dmd`.
    enum compiler = "dmd";
}
else version(LDC)
{
    /// String of the compiler that was used to compile this binary with. Here: `ldc`.
    enum compiler = "ldc";
}
else version(GNU)
{
    /// String of the compiler that was used to compile this binary with. Here: `gdc`.
    enum compiler = "gdc";
}
else
{
    /// String of the compiler that was used to compile this binary with. Here: no idea.
    enum compiler = "<unknown>";
}


// buildCompilerVersionString
/++
    Replaces the following expression and lowers compilation memory by avoiding
    use of compile-time [std.format.format|format].

    ---
    enum compilerVersion = format("%d.%03d", (__VERSION__ / 1000), (__VERSION__ % 1000));
    ---
 +/
auto buildCompilerVersionString()
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(5);  // 2.098

    (__VERSION__ / 1000).toAlphaInto(sink);
    sink.put('.');
    (__VERSION__ % 1000).toAlphaInto!(3,3)(sink);

    return sink.data.idup;
}


// buildVersionString
/++
    Replaces the following expression and lowers compilation memory by avoiding
    use of compile-time [std.format.format|format].

    ---
    enum version_ = "%d.%d.%d%s%s"
        .format(
            KamelosoSemVer.majorVersion,
            KamelosoSemVer.minorVersion,
            KamelosoSemVer.patchVersion,
            KamelosoSemVerPrerelease.length ? "-" : string.init,
            KamelosoSemVerPrerelease);
    ---
 +/
auto buildVersionString()
{
    import lu.conv : toAlphaInto;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(16);  // 10.10.10-alpha.1

    with (KamelosoSemVer)
    {
        majorVersion.toAlphaInto(sink);
        sink.put('.');
        minorVersion.toAlphaInto(sink);
        sink.put('.');
        patchVersion.toAlphaInto(sink);

        if (KamelosoSemVerPrerelease.length)
        {
            sink.put('-');
            sink.put(cast(string)KamelosoSemVerPrerelease);
        }
    }

    return sink.data.idup;
}


public:


// KamelosoInfo
/++
    Meta-information about the program.
 +/
enum KamelosoInfo
{
    version_ = .buildVersionString(), /// Version as a string.
    built = __TIMESTAMP__, /// Timestamp of when the binary was built.
    compiler = .compiler,  /// Compiler used to build this binary.
    compilerVersion = .buildCompilerVersionString(),  /// Compiler version used to build this binary.
    source = "https://github.com/zorael/kameloso",  /// GitHub source link.
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

    /// Default server address.
    serverAddress = "irc.libera.chat",

    /// The default GEOC/"real name" string.
    realName = "kameloso IRC bot v$version",

    /// The default quit reason, when the bot exits. Supports some string replacements.
    quitReason = "kameloso IRC bot v$version @ $source",

    /// The default part reason, when the bot is asked to part a channel.
    partReason = quitReason,

    /++
        When a nickname was already taken during registration, append this followed
        by some random numbers to it to generate a new one.

        A separator of "|" and a taken nickname of "guest" thus gives nicknames like "guest|1".
        A separator of "^" gives nicknames like "guest^2".
     +/
    altNickSeparator = "|",
}


// KamelosoDefaultIntegers
/++
    Kameloso defaults, integers version.
 +/
enum KamelosoDefaultIntegers
{
    /// Default server port.
    port = 6667,
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
    /// How many times to attempt to connect to an IP before moving on to the next one.
    retries = 4,
}


// ConnectionDefaultFloats
/++
    Connection defaults, floating point version.
 +/
enum ConnectionDefaultFloats : double
{
    /// By what to multiply the connect timeout after failing an attempt.
    delayIncrementMultiplier = 1.5,

    /// By what to multiply [Timeout.receiveMsecs] with to shorten reads.
    receiveShorteningMultiplier = 0.25,

    /// How many messages to send per second, maximum.
    messageRate = 1.2,

    /// How many messages to immediately send in one go, before throttling kicks in.
    messageBurst = 3.0,

    /++
        How many messages to send per second, maximum. For *fast* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageRateTwitchFast = 3.0,

    /++
        How many messages to immediately send in one go, before throttling kicks in.
        For *fast* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageBurstTwitchFast = 10.0,

    /++
        How many messages to send per second, maximum. For *slow* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageRateTwitchSlow = 1.0,

    /++
        How many messages to immediately send in one go, before throttling kicks in.
        For *slow* sends on Twitch servers.

        FIXME: Tweak value.
     +/
    messageBurstTwitchSlow = 1.0,
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
    socketOptionReceive = 2048,

    /++
        The send buffer size as set as a [std.socket.SocketOption|SocketOption].
     +/
    socketOptionSend = 1024,

    /++
        The actual buffer array size used when reading from the socket.
     +/
    socketReceive = 2048,

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
        screen with the [kameloso.printing] templates. This value times the
        number of objects to print.
     +/
    printObjectBufferPerObject = 1024,

    /++
        How many bytes to allocate for the stdout buffer, when we need to do so explicitly.
     +/
    vbufStdout = 16_384,

    /++
        How large to make [core.thread.fiber.Fiber|Fiber] stacks, so they don't
        overflow (which they seem to have a knack for doing).
     +/
    fiberStack = 32_768,
}


// Timeout
/++
    Various timeouts, in seconds unless specified otherwise.
 +/
enum Timeout
{
    /++
        The send attempt timeout as set as a [std.socket.SocketOption|SocketOption],
        in milliseconds.
     +/
    sendMsecs = 15_000,

    /++
        The receive attempt timeout as set as a [std.socket.SocketOption|SocketOption],
        in milliseconds.
     +/
    receiveMsecs = 1000,

    /++
        The amount of time to spend with a shortened receive timeout, in milliseconds.
        After this, it reverts from [receiveShortenedMsecs] to [receiveMsecs].
     +/
    maxShortenDurationMsecs = 2000,

    /++
        The maximum amount of time to wait between connection attempts.
     +/
    connectionDelayCap = 600,

    /++
        The amount of seconds to wait before retrying after a failed connection attempt.
     +/
    connectionRetry = 10,

    /++
        The amount of seconds to wait before retrying to connect after an instant
        failure to register on Twitch.
     +/
    twitchRegistrationFailConnectionRetryMsecs = 500,

    /++
        How long to wait before allowing to re-issue a WHOIS query for a user.

        This is merely to stop us from spamming queries for the same person
        without hysteresis.
     +/
    whoisRetry = 30,

    /++
        How long a replayable event is expected to be relevant. Before this it
        will be replayed, after this it will be discarded.

        Note: WHOIS-replays will break if the ping toward the server reaches this value.
     +/
    whoisDiscard = 10,

    /++
        The length of the window in which replays may be queued before the timer
        towards [whoisRetry] kicks in.
     +/
    whoisGracePeriod = 3,

    /++
        How long to wait after encountering an error when reading from the server,
        before trying anew.

        Not having a small delay could cause it to spam the screen with errors
        as fast as it can.
     +/
    readErrorGracePeriodMsecs = 100,

    /++
        How long to keep trying to read from the sever when not receiving anything
        at all before the connection is considered lost.
     +/
    connectionLost = 600,

    /++
        Timeout for HTTP GET requests.
     +/
    httpGET = 10,
}


// Periodicals
/++
    Timings and timeouts of various periodical events.
 +/
enum Periodicals
{
    /++
        How often to rehash plugins' `users` associative arrays for more efficient lookups.
     +/
    userAARehashMinutes = 60,
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
        Failure encountered during plugin startup.
     +/
    pluginStartFailure = 33,

    /++
        Generic exception was thrown when a plugin tried to start up.
     +/
    pluginStartException = 34,
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
    import kameloso.terminal.colours : TerminalForeground;
    import std.experimental.logger : LogLevel;

    alias TF = TerminalForeground;

public:
    /++
        Colours for timestamps, shared between event-printing and logging.
     +/
    enum TimestampColour : TerminalForeground
    {
        /++
            For dark terminal backgrounds. Was
            [kameloso.terminal.TerminalForeground.white_|TerminalForeground.white_].
         +/
        dark = TF.default_,

        /++
            For bright terminal backgrounds. Was
            [kameloso.terminal.TerminalForeground.black_|TerminalForeground.black_].
         +/
        bright = TF.default_,
    }

    /// Logger colours to use with a dark terminal background.
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

    /// Logger colours to use with a bright terminal background.
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

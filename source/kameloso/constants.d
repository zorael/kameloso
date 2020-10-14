/++
    A collection of constants used throughout the program.

    This acts as a compile-time configuration file.
 +/
module kameloso.constants;

private:

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;
import std.format : format;

public:


// KamelosoInfo
/++
    Meta-information about the program.
 +/
enum KamelosoInfo
{
    version_ = "%d.%d.%d%s%s"
        .format(
            KamelosoSemVer.majorVersion,
            KamelosoSemVer.minorVersion,
            KamelosoSemVer.patchVersion,
            KamelosoSemVerPrerelease.length ? "-" : string.init,
            KamelosoSemVerPrerelease),  /// Version as a string.
    built = __TIMESTAMP__, /// Timestamp of when the binary was built.
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
    serverAddress = "irc.freenode.net",

    /// The default GEOC/"real name" string.
    realName = "kameloso IRC bot v$version",

    /// The default quit reason, when the bot exits. Supports some string replacements.
    quitReason = "kameloso IRC bot v$version @ $source",

    /// The default part reason, when the bot is asked to part a channel.
    partReason = quitReason,

    /// When a nickname is taken, first append this to get a new name before trying random numbers.
    altNickSign = "^",
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
}


// BufferSize
/++
    Buffer sizes in bytes.
 +/
enum BufferSize
{
    /++
        The receive buffer size as set as a `std.socket.SocketOption`.
     +/
    socketOptionReceive = 2048,

    /++
        The send buffer size as set as a `std.socket.SocketOption`.
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
        screen with the `kameloso.printing` templates. This value times the
        number of objects to print.
     +/
    printObjectBufferPerObject = 1024,

    /++
        How many bytes to allocate for the stdout buffer, when we need to do so explicitly.
     +/
    vbufStdout = 16_384,

    /++
        How large to make `core.thread.fiber.Fiber` stacks, so they don't overflow
        (which they seem to have a knack for doing).
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
        The send attempt timeout as set as a `std.socket.SocketOption`, in milliseconds.
     +/
    sendMsecs = 5000,

    /++
        The receive attempt timeout as set as a `std.socket.SocketOption`, in milliseconds.
     +/
    receiveMsecs = 1000,

    /++
        The maximum amount of time to wait between connection attempts.
     +/
    delayCap = 600,

    /++
        The amount of seconds to wait before retrying after a failed connection attempt.
     +/
    retry = 10,

    /++
        How long to wait before allowing to re-issue a WHOIS query for a user.

        This is merely to stop us from spamming queries for the same person
        without hysteresis.
     +/
    whoisRetry = 300,

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


// DefaultColours
/++
    Default colours gathered in one struct namespace.

    This makes it easier to compile-time customise colours to your liking.
 +/
version(Colours)
struct DefaultColours
{
private:
    import kameloso.terminal : TerminalForeground;
    import std.experimental.logger : LogLevel;

    alias TF = TerminalForeground;

public:
    /++
        Colours for timestamps, shared between event-printing and logging.
     +/
    enum TimestampColour : TerminalForeground
    {
        /// For dark terminal backgrounds. Was `kameloso.terminal.TerminalForeground.white_`.
        dark = TF.default_,

        /// For bright terminal backgrounds. Was `kameloso.terminal.TerminalForeground.black_`.
        bright = TF.default_,
    }

    /// Logger colours to use with a dark terminal background.
    static immutable TerminalForeground[193] logcoloursDark  =
    [
        LogLevel.all     : TF.white,        /// LogLevel.all, or just `log`
        LogLevel.trace   : TF.default_,     /// `trace`
        LogLevel.info    : TF.lightgreen,   /// `info`
        LogLevel.warning : TF.lightred,     /// `warning`
        LogLevel.error   : TF.red,          /// `error`
        LogLevel.fatal   : TF.red,          /// `fatal`
    ];

    /// Logger colours to use with a bright terminal background.
    static immutable TerminalForeground[193] logcoloursBright  =
    [
        LogLevel.all     : TF.black,        /// LogLevel.all, or just `log`
        LogLevel.trace   : TF.default_,     /// `trace`
        LogLevel.info    : TF.green,        /// `info`
        LogLevel.warning : TF.red,          /// `warning`
        LogLevel.error   : TF.red,          /// `error`
        LogLevel.fatal   : TF.red,          /// `fatal`
    ];
}

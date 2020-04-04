/++
 +  A collection of constants used throughout the program.
 +
 +  This acts as a compile-time configuration file.
 +/
module kameloso.constants;

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;
import std.format : format;


/// Meta-information about the program.
enum KamelosoInfo
{
    version_ = "%d.%d.%d%s"
        .format(KamelosoSemVer.majorVersion,
            KamelosoSemVer.minorVersion,
            KamelosoSemVer.patchVersion,
            KamelosoSemVerPrerelease),  /// Version as a string.
    built = __TIMESTAMP__, /// Timestamp of when the binary was built.
    source = "https://github.com/zorael/kameloso",  /// GitHub source link.
}

/++
 +  Kameloso defaults, strings version.
 +/
enum KamelosoDefaultStrings
{
    /// Default user to use when logging onto a server (the USER command).
    user = "kameloso",
    /// Default IDENT identifier.
    ident = "NaN",
    /// Default server address.
    serverAddress = "irc.freenode.net",
    /// The default GEOC/"real name" string.
    realName = "kameloso IRC bot",
    /// The default quit reason, when the bot exits normally (not through Ctrl+C).
    quitReason = "kameloso IRC bot @ https://github.com/zorael/kameloso",
    /// When a nickname is taken, append this to get a new name.
    altNickSign = "^",
}

/++
 +  Kameloso defaults, integers version.
 +/
enum KamelosoDefaultIntegers
{
    /// Default server port.
    port = 6667,
}

/++
 +  Connection defaults, integers version.
 +/
enum ConnectionDefaultIntegers
{
    /// How many times to attempt to connect to an IP before moving on to the next one.
    retries = 4,
    /// The maximum amount of time to wait between connection attempts.
    delayCap = 10*60,  // seconds
}

/++
 +  Connection defaults, floating point version.
 +/
enum ConnectionDefaultFloats : double
{
    /// By what to multiply the connect timeout after failing an attempt.
    delayIncrementMultiplier = 1.5,
}

/// Buffer sizes in bytes.
enum BufferSize
{
    titleLookup = 8192,
    outbuffer = 512,
    priorityBuffer = 64,
}

/// Various timeouts in seconds.
enum Timeout
{
    retry = 10,
    whoisRetry = 300,
    titleCache = 600,
    initialPeriodical = 3600,
    readErrorGracePeriod = 1,
}


// DefaultColours
/++
 +  Default colours gathered in one struct namespace.
 +
 +  This makes it easier to compile-time customise colours to your liking.
 +/
version(Colours)
struct DefaultColours
{
    import kameloso.terminal : TerminalForeground;
    import std.experimental.logger : LogLevel;

    alias TF = TerminalForeground;

    /++
     +  Colours for timestamps, shared between event-printing and logging.
     +/
    enum TimestampColour : TerminalForeground
    {
        dark = TF.default_,   // TF.white_,
        bright = TF.default_, // TF.black_,
    }

    /// Default colours for printing events on a dark terminal background.
    enum EventPrintingDark : TerminalForeground
    {
        type    = TF.lightblue,
        error   = TF.lightred,
        sender  = TF.lightgreen,
        target  = TF.cyan,
        channel = TF.yellow,
        content = TF.default_,
        aux     = TF.white,
        count   = TF.green,
        altcount = TF.lightgreen,
        num     = TF.darkgrey,
        badge   = TF.white,
        emote   = TF.cyan,
        highlight = TF.white,
        query   = TF.lightgreen,
    }

    /// Default colours for printing events on a bright terminal background.
    enum EventPrintingBright : TerminalForeground
    {
        type    = TF.blue,
        error   = TF.red,
        sender  = TF.green,
        target  = TF.cyan,
        channel = TF.yellow,
        content = TF.default_,
        aux     = TF.black,
        count   = TF.lightgreen,
        altcount = TF.green,
        num     = TF.lightgrey,
        badge   = TF.black,
        emote   = TF.lightcyan,
        highlight = TF.black,
        query   = TF.green,
    }

    /// Logger colours to use with a dark terminal background.
    static immutable TerminalForeground[193] logcoloursDark  =
    [
        LogLevel.all     : TF.white,
        LogLevel.trace   : TF.default_,
        LogLevel.info    : TF.lightgreen,
        LogLevel.warning : TF.lightred,
        LogLevel.error   : TF.red,
        LogLevel.fatal   : TF.red,
    ];

    /// Logger colours to use with a bright terminal background.
    static immutable TerminalForeground[193] logcoloursBright  =
    [
        LogLevel.all     : TF.black,
        LogLevel.trace   : TF.default_,
        LogLevel.info    : TF.green,
        LogLevel.warning : TF.red,
        LogLevel.error   : TF.red,
        LogLevel.fatal   : TF.red,
    ];
}

/++
 +  A collection of constants used throughout the program.
 +
 +  This acts as a compile-time configuration file.
 +/
module kameloso.constants;

private:

import kameloso.semver : KamelosoSemVer, KamelosoSemVerPrerelease;
import std.format : format;

public:


/++
 +  Meta-information about the program.
 +/
enum KamelosoInfo
{
    version_ = "%d.%d.%d%s"
        .format(
            KamelosoSemVer.majorVersion,
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
    /++
     +  Default user to use when logging onto a server (the USER command).
     +  Additionally becomes the bot's IDENT identifier (prepended with a '~'),
     +  if a separate `identd` server is not being run.
     +/
    user = "kameloso",

    /// Default server address.
    serverAddress = "irc.freenode.net",

    /// The default GEOC/"real name" string.
    realName = "kameloso IRC bot v$version",

    /// The default quit reason, when the bot exits.
    quitReason = "kameloso IRC bot v$version @ $source",

    /// The default part reason, when the bot is asked to part a channel.
    partReason = quitReason,

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
 +  Kameloso filenames.
 +/
enum KamelosoFilenames
{
    /++
     +  The main configuration file.
     +/
    configuration = "kameloso.conf",

    /++
     +  The file containing user account classifiers, specifying which accounts
     +  are whitelisted, operators and/or blacklisted.
     +/
    users = "users.json",

    /++
     +  The file containing user "account" hostmasks, mapping what we still
     +  consider accounts to hostmasks, on servers that don't employ services.
     +/
    hostmasks = "hostmasks.json",
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

/++
 +  Buffer sizes in bytes.
 +/
enum BufferSize
{
    /++
     +  How long a Webtitles title lookup lasts before it is considered to
     +  have expired, and should be looked up anew.
     +/
    titleLookup = 8192,

    /++
     +  The maximum number of queued outgoing lines to buffer. Anything above
     +  this will crash the program with a buffer overrun. It can be arbitrarily big.
     +/
    outbuffer = 512,

    /++
     +  The maximum number of queued priority lines to buffer. These are rare.
     +/
    priorityBuffer = 64,
}

/++
 +  Various timeouts in seconds.
 +/
enum Timeout
{
    /++
     +  The amount of seconds to wait before retrying after a failed connection attempt.
     +/
    retry = 10,

    /++
     +  How long to wait before allowing to re-issue a WHOIS query for a user.
     +
     +  This is merely to stop us from spamming queries for the same person
     +  without hysteresis.
     +/
    whoisRetry = 300,

    /++
     +  How long to wait before calling plugins' `periodical` for the first time.
     +
     +  Since it is meant for maintenance and cleanup tasks we can hold on a while
     +  before calling it the first time.
     +/
    initialPeriodical = 3600,

    /++
     +  How long to wait after encountering an error when reading from the server,
     +  before trying anew.
     +
     +  Not having a small delay could cause it to spam the screen with errors
     +  as fast as it can.
     +/
    readErrorGracePeriod = 1,

    /++
     +  How long to keep trying to read from the sever when not receiving anything
     +  at all before the connection is considered lost.
     +/
    connectionLost = 600,
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
        dark = TF.default_,   /// For dark terminal backgrounds. Was `TerminalForeground.white_`.
        bright = TF.default_, /// For bright terminal backgrounds. Was `TerminalForeground.black_`.
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

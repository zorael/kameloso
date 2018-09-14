/++
 +  Contains the custom `KamelosoLogger` class, used to print timestamped and
 +  (optionally) coloured logging messages.
 +/
module kameloso.logger;

import std.experimental.logger : Logger;

@safe:


// KamelosoLogger
/++
 +  Modified `Logger` to print timestamped and coloured logging messages.
 +
 +  It is thread-local so instantiate more if you're threading.
 +
 +  See the documentation for `std.experimental.logger.Logger`.
 +/
final class KamelosoLogger : Logger
{
    @safe:

    import kameloso.bash : BashForeground, BashFormat, BashReset;
    import std.concurrency : Tid;
    import std.datetime.systime : SysTime;
    import std.experimental.logger : LogLevel;
    import std.stdio : stdout;

    version(Colours)
    {
        import kameloso.bash : colour;
    }

    /// Logger colours to use with a dark terminal.
    static immutable BashForeground[193] logcoloursDark  =
    [
        LogLevel.all     : BashForeground.white,
        LogLevel.trace   : BashForeground.default_,
        LogLevel.info    : BashForeground.lightgreen,
        LogLevel.warning : BashForeground.lightred,
        LogLevel.error   : BashForeground.red,
        LogLevel.fatal   : BashForeground.red,
    ];

    /// Logger colours to use with a bright terminal.
    static immutable BashForeground[193] logcoloursBright  =
    [
        LogLevel.all     : BashForeground.black,
        LogLevel.trace   : BashForeground.default_,
        LogLevel.info    : BashForeground.green,
        LogLevel.warning : BashForeground.red,
        LogLevel.error   : BashForeground.red,
        LogLevel.fatal   : BashForeground.red,
    ];

    bool monochrome;  /// Whether to use colours or not in logger output.
    bool brightTerminal;   /// Whether to use colours for a bright background.

    /// Create a new `KamelosoLogger` with the passed settings.
    this(LogLevel lv = LogLevel.all, bool monochrome = false,
        bool brightTerminal = false)
    {
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
        super(lv);
    }

    // tint
    /++
     +  Returns the corresponding `BashForeground` for the supplied `LogLevel`,
     +  taking into account whether the terminal is said to be bright or not.
     +
     +  This is merely a convenient wrapping for `logcoloursBright` and
     +  `logcoloursDark`.
     +
     +  Example:
     +  ---
     +  BashForeground errtint = KamelosoLogger.tint(LogLevel.error, false);  // false means dark terminal
     +  immutable errtintString = errtint.colour;
     +  ---
     +
     +  Params:
     +      level = The `LogLevel` of the colour we want to scry.
     +      bright = Whether the colour should be for a bright terminal
     +          background or a dark one.
     +
     +  Returns:
     +      A `BashForeground` of the right colour. Use with
     +      `kameloso.bash.colour` to get a string.
     +/
    version(Colours)
    static BashForeground tint(const LogLevel level, const bool bright)
    {
        return bright ? logcoloursBright[level] : logcoloursDark[level];
    }

    ///
    version(Colours)
    unittest
    {
        import std.range : only;

        foreach (immutable logLevel; only(LogLevel.all, LogLevel.info, LogLevel.warning, LogLevel.fatal))
        {
            import std.format : format;

            immutable tintBright = tint(logLevel, true);
            immutable tintBrightTable = logcoloursBright[logLevel];
            assert((tintBright == tintBrightTable), "%s != %s".format(tintBright, tintBrightTable));

            immutable tintDark = tint(logLevel, false);
            immutable tintDarkTable = logcoloursDark[logLevel];
            assert((tintDark == tintDarkTable), "%s != %s".format(tintDark, tintDarkTable));
        }
    }

    /// This override is needed or it won't compile.
    override void writeLogMsg(ref LogEntry payload) pure nothrow const {}

    /// Outputs the head of a logger message.
    protected void beginLogMsg(Sink)(auto ref Sink sink,
        string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) const
    {
        import std.datetime : DateTime;

        version(Colours)
        {
            if (!monochrome)
            {
                sink.colour(brightTerminal ? BashForeground.black : BashForeground.white);
            }
        }

        sink.put('[');
        sink.put((cast(DateTime)timestamp).timeOfDay.toString());
        sink.put("] ");

        if (monochrome) return;

        version(Colours)
        {
            sink.colour(brightTerminal ? logcoloursBright[logLevel] : logcoloursDark[logLevel]);
        }
    }

    /// ditto
    override protected void beginLogMsg(string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @trusted const
    {
        return beginLogMsg(stdout.lockingTextWriter, file, line, funcName,
            prettyFuncName, moduleName, logLevel, threadId, timestamp, logger);
    }

    /// Outputs the message part of a logger message; the content.
    protected void logMsgPart(Sink)(auto ref Sink sink, const(char)[] msg) const
    {
        sink.put(msg);
    }

    /// ditto
    override protected void logMsgPart(scope const(char)[] msg) @trusted const
    {
        if (!msg.length) return;

        return logMsgPart(stdout.lockingTextWriter, msg);
    }

    /// Outputs the tail of a logger message.
    protected void finishLogMsg(Sink)(auto ref Sink sink) const
    {
        version(Colours)
        {
            if (!monochrome)
            {
                // Reset.blink in case a fatal message was thrown
                sink.colour(BashForeground.default_, BashReset.blink);
            }
        }

        static if (__traits(hasMember, Sink, "data"))
        {
            writeln(sink.data);
            sink.clear();
        }
        else
        {
            sink.put('\n');
        }
    }

    /// ditto
    override protected void finishLogMsg() @trusted const
    {
        finishLogMsg(stdout.lockingTextWriter);
        version(Cygwin_) stdout.flush();
    }
}


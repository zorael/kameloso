/++
 +  Contains the custom `KamelosoLogger` class, used to print timestamped and
 +  (optionally) coloured logging messages.
 +/
module kameloso.logger;

import std.experimental.logger : Logger;

@safe:

/+
    Build tint colours at compile time, saving the need to compute them during
    runtime. It's a trade-off.
 +/
version = CtTints;


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
    import std.concurrency : Tid;
    import std.datetime.systime : SysTime;
    import std.experimental.logger : LogLevel;
    import std.stdio : stdout;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground, TerminalReset, colour;
        import kameloso.constants : DefaultColours;

        alias logcoloursBright = DefaultColours.logcoloursBright;
        alias logcoloursDark = DefaultColours.logcoloursDark;
    }

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
     +  Returns the corresponding `TerminalForeground` for the supplied `LogLevel`,
     +  taking into account whether the terminal is said to be bright or not.
     +
     +  This is merely a convenient wrapping for `logcoloursBright` and
     +  `logcoloursDark`.
     +
     +  Example:
     +  ---
     +  TerminalForeground errtint = KamelosoLogger.tint(LogLevel.error, false);  // false means dark terminal
     +  immutable errtintString = errtint.colour;
     +  ---
     +
     +  Params:
     +      level = The `LogLevel` of the colour we want to scry.
     +      bright = Whether the colour should be for a bright terminal
     +          background or a dark one.
     +
     +  Returns:
     +      A `TerminalForeground` of the right colour. Use with
     +      `kameloso.terminal.colour` to get a string.
     +/
    version(Colours)
    static TerminalForeground tint(const LogLevel level, const bool bright)
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

    // tintImpl
    /++
     +  Template for returning tints based on the settings of the `this`
     +  `KamelosoLogger`.
     +
     +  This saves us having to pass the brightness setting, and allows for
     +  making easy aliases for the log level.
     +
     +  Params:
     +      level = Compile-time `LogLevel`.
     +
     +  Returns:
     +      A tint string.
     +/
    version(Colours)
    private string tintImpl(LogLevel level)() const @property
    {
        version(CtTints)
        {
            if (brightTerminal)
            {
                enum ctTint = tint(level, true).colour;
                return ctTint;
            }
            else
            {
                enum ctTint = tint(level, false).colour;
                return ctTint;
            }
        }
        else
        {
            return tint(level, brightTerminal).colour;
        }
    }

    pragma(inline)
    version(Colours)
    {
        /// Provides easy way to get a log tint.
        string logtint() const @property { return tintImpl!(LogLevel.all); }

        /// Provides easy way to get an info tint.
        string infotint() const @property { return tintImpl!(LogLevel.info); }

        /// Provides easy way to get a warning tint.
        string warningtint() const @property { return tintImpl!(LogLevel.warning); }

        /// Provides easy way to get an error tint.
        string errortint() const @property { return tintImpl!(LogLevel.error); }

        /// Provides easy way to get a fatal tint.
        string fataltint() const @property { return tintImpl!(LogLevel.fatal); }
    }

    /++
     +  This override is needed or it won't compile.
     +
     +  Params:
     +      payload = Message payload to write.
     +/
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
                sink.colour(brightTerminal ? TerminalForeground.black : TerminalForeground.white);
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
                sink.colour(TerminalForeground.default_, TerminalReset.blink);
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
        version(FlushStdout) stdout.flush();
    }
}

///
unittest
{
    import std.experimental.logger : LogLevel;

    Logger log_ = new KamelosoLogger(LogLevel.all, true, false);

    log_.log("log: log");
    log_.info("log: info");
    log_.warning("log: warning");
    log_.error("log: error");
    // log_.fatal("log: FATAL");  // crashes the program
    log_.trace("log: trace");

    version(Colours)
    {
        log_ = new KamelosoLogger(LogLevel.all, false, true);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");

        log_ = new KamelosoLogger(LogLevel.all, false, false);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");
    }
}

/++
 +  Contains the custom `KamelosoLogger` class, used to print timestamped and
 +  (optionally) coloured logging messages.
 +
 +  This is merely a subclass of `std.experimental.logger.Logger` that formats
 +  its arguments differently, implying the log level by way of colours.
 +
 +  Example:
 +  ---
 +  Logger logger = new KamelosoLogger;
 +
 +  logger.log("This is LogLevel.log");
 +  logger.info("LogLevel.info");
 +  logger.warn(".warn");
 +  logger.error(".error");
 +  logger.trace(".trace");
 +  //logger.fatal("This will crash the program.");
 +  ---
 +/
module kameloso.logger;

private:

import std.experimental.logger.core : Logger;
import std.range.primitives : isOutputRange;

public:

@safe:

/+
    Build tint colours at compile time, saving the need to compute them during
    runtime. It's a trade-off.
 +/
version = CtTints;


// KamelosoLogger
/++
 +  Modified `std.experimental.logger.Logger` to print timestamped and coloured logging messages.
 +
 +  It is thread-local so instantiate more if you're threading. Even so there
 +  may be race conditions.
 +
 +  See_Also:
 +      std.experimental.logger.Logger.
 +/
final class KamelosoLogger : Logger
{
@safe:
    import std.concurrency : Tid;
    import std.datetime.systime : SysTime;
    import std.experimental.logger : LogLevel;
    import std.stdio : stdout;
    import std.typecons : Flag, No, Yes;

    version(Colours)
    {
        import kameloso.constants : DefaultColours;
        import kameloso.terminal : TerminalForeground, TerminalReset, colourWith, colour;

        alias logcoloursBright = DefaultColours.logcoloursBright;
        alias logcoloursDark = DefaultColours.logcoloursDark;
    }

    bool monochrome;  /// Whether to use colours or not in logger output.
    bool brightTerminal;   /// Whether or not to use colours for a bright background.
    bool flush;  /// Whether or not we should flush stdout after finishing writing to it.

    /// Create a new `KamelosoLogger` with the passed settings.
    this(LogLevel lv,
        const Flag!"monochrome" monochrome,
        const Flag!"brightTerminal" brightTerminal,
        const Flag!"flush" flush)
    {
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
        this.flush = flush;
        super(lv);
    }

    /// Create a new `KamelosoLogger` with the passed settings.
    deprecated("Use the constructor that takes `Flag` parameters instead")
    this(LogLevel lv = LogLevel.all, bool monochrome = false,
        bool brightTerminal = false, bool flush = false)
    {
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
        this.flush = flush;
        super(lv);
    }

    // tint
    /++
     +  Returns the corresponding `kameloso.terminal.TerminalForeground` for the
     +  supplied `std.experimental.logger.LogLevel`,
     +  taking into account whether the terminal is said to be bright or not.
     +
     +  This is merely a convenient wrapping for `logcoloursBright` and
     +  `logcoloursDark`.
     +
     +  Example:
     +  ---
     +  TerminalForeground errtint = KamelosoLogger.tint(LogLevel.error, No.brightTerminal);
     +  immutable errtintString = errtint.colour;
     +  ---
     +
     +  Params:
     +      level = The `std.experimental.logger.LogLevel` of the colour we want to scry.
     +      bright = Whether the colour should be for a bright terminal
     +          background or a dark one.
     +
     +  Returns:
     +      A `kameloso.terminal.TerminalForeground` of the right colour. Use with
     +      `kameloso.terminal.colour` to get a string.
     +/
    pragma(inline)
    version(Colours)
    static auto tint(const LogLevel level, const Flag!"brightTerminal" bright)
    {
        return bright ? logcoloursBright[level] : logcoloursDark[level];
    }

    ///
    version(Colours)
    unittest
    {
        import std.range : only;

        foreach (immutable logLevel; only(LogLevel.all, LogLevel.info,
            LogLevel.warning, LogLevel.fatal))
        {
            import std.format : format;

            immutable tintBright = tint(logLevel, Yes.brightTerminal);
            immutable tintBrightTable = logcoloursBright[logLevel];
            assert((tintBright == tintBrightTable), "%s != %s"
                .format(tintBright, tintBrightTable));

            immutable tintDark = tint(logLevel, No.brightTerminal);
            immutable tintDarkTable = logcoloursDark[logLevel];
            assert((tintDark == tintDarkTable), "%s != %s"
                .format(tintDark, tintDarkTable));
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
     +      level = Compile-time `std.experimental.logger.LogLevel`.
     +
     +  Returns:
     +      A tint string.
     +/
    pragma(inline)
    version(Colours)
    private string tintImpl(LogLevel level)() const @property
    {
        version(CtTints)
        {
            if (brightTerminal)
            {
                enum ctTintBright = tint(level, Yes.brightTerminal).colour.idup;
                return ctTintBright;
            }
            else
            {
                enum ctTintDark = tint(level, No.brightTerminal).colour.idup;
                return ctTintDark;
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
        auto tracetint() const @property @nogc { return tintImpl!(LogLevel.trace); }

        /// Convenience alias to `tracetint`.
        alias resettint = tracetint;

        /// Provides easy way to get a log tint.
        auto logtint() const @property @nogc { return tintImpl!(LogLevel.all); }

        /// Provides easy way to get an info tint.
        auto infotint() const @property @nogc { return tintImpl!(LogLevel.info); }

        /// Provides easy way to get a warning tint.
        auto warningtint() const @property @nogc { return tintImpl!(LogLevel.warning); }

        /// Provides easy way to get an error tint.
        auto errortint() const @property @nogc { return tintImpl!(LogLevel.error); }

        /// Provides easy way to get a fatal tint.
        auto fataltint() const @property @nogc { return tintImpl!(LogLevel.fatal); }
    }

    /++
     +  This override is needed or it won't compile.
     +
     +  Params:
     +      payload = Message payload to write.
     +/
    override void writeLogMsg(ref LogEntry payload) pure nothrow const @nogc {}

    /++
     +  Outputs the header of a logger message.
     +
     +  Overload that takes an output range sink.
     +/
    pragma(inline)
    protected void beginLogMsg(Sink)(auto ref Sink sink,
        string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) const
    if (isOutputRange!(Sink, char[]))
    {
        import std.datetime : DateTime;

        version(Colours)
        {
            if (!monochrome)
            {
                alias Timestamp = DefaultColours.TimestampColour;
                sink.colourWith(brightTerminal ? Timestamp.bright : Timestamp.dark);
            }
        }

        sink.put('[');
        (cast(DateTime)timestamp).timeOfDay.toString(sink);
        sink.put("] ");

        if (monochrome) return;

        version(Colours)
        {
            sink.colourWith(brightTerminal ?
                logcoloursBright[logLevel] :
                logcoloursDark[logLevel]);
        }
    }

    /++
     +  Outputs the header of a logger message.
     +
     +  Overload that passes a `std.stdio.stdout.lockingTextWriter` to
     +  the other `beginLogMsg`.
     +/
    override protected void beginLogMsg(string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @trusted const
    {
        return beginLogMsg(stdout.lockingTextWriter, file, line, funcName,
            prettyFuncName, moduleName, logLevel, threadId, timestamp, logger);
    }

    /++
     +  Outputs the message part of a logger message; the content.
     +
     +  Overload that takes an output range sink.
     +/
    pragma(inline)
    protected void logMsgPart(Sink)(auto ref Sink sink, const(char)[] msg) const
    if (isOutputRange!(Sink, char[]))
    {
        sink.put(msg);
    }

    /++
     +  Outputs the message part of a logger message; the content.
     +
     +  Overload that passes a `std.stdio.stdout.lockingTextWriter` to
     +  the other `logMsgPart`.
     +/
    override protected void logMsgPart(scope const(char)[] msg) @trusted const
    {
        if (!msg.length) return;

        return logMsgPart(stdout.lockingTextWriter, msg);
    }

    /++
     +  Outputs the tail of a logger message.
     +
     +  Overload that takes an output range sink.
     +/
    pragma(inline)
    version(Colours)
    protected void finishLogMsg(Sink)(auto ref Sink sink) const
    if (isOutputRange!(Sink, char[]))
    {
        if (!monochrome)
        {
            // Reset.blink in case a fatal message was thrown
            sink.colourWith(TerminalForeground.default_, TerminalReset.blink);
        }
    }

    /++
     +  Outputs the tail of a logger message.
     +
     +  Overload that passes a `std.stdio.stdout.lockingTextWriter` to
     +  the other `finishLogMsg`.
     +/
    override protected void finishLogMsg() @trusted const
    {
        version(Colours)
        {
            finishLogMsg(stdout.lockingTextWriter);
        }

        stdout.lockingTextWriter.put('\n');
        if (flush) stdout.flush();
    }
}

///
unittest
{
    import std.experimental.logger : LogLevel;
    import std.typecons : Flag, No, Yes;

    Logger log_ = new KamelosoLogger(LogLevel.all, Yes.monochrome, No.brightTerminal);

    log_.log("log: log");
    log_.info("log: info");
    log_.warning("log: warning");
    log_.error("log: error");
    // log_.fatal("log: FATAL");  // crashes the program
    log_.trace("log: trace");

    version(Colours)
    {
        log_ = new KamelosoLogger(LogLevel.all, No.monochrome, Yes.brightTerminal);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");

        log_ = new KamelosoLogger(LogLevel.all, No.monochrome, No.brightTerminal);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");
    }
}

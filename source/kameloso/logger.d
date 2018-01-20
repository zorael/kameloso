/++
 +  Contains the custom `KamelosoLogger` class, used to print timestamped and
 +  (optionally) coloured logging messages.
 +/
module kameloso.logger;

import kameloso.common : settings;
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
    import std.format : formattedWrite;
    import std.stdio : stdout;

    version(Colours)
    {
        import kameloso.bash : colour;
    }

    /// Logger colours to use with a dark terminal
    static immutable BashForeground[193] logcoloursDark  =
    [
        LogLevel.all     : BashForeground.white,
        LogLevel.trace   : BashForeground.default_,
        LogLevel.info    : BashForeground.lightgreen,
        LogLevel.warning : BashForeground.lightred,
        LogLevel.error   : BashForeground.red,
        LogLevel.fatal   : BashForeground.red,
    ];

    /// Logger colours to use with a bright terminal
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

    this(LogLevel lv = LogLevel.all, bool monochrome = false,
        bool brightTerminal = false)
    {
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
        super(lv);
    }

    /// This override is needed or it won't compile
    override void writeLogMsg(ref LogEntry payload) pure nothrow const {}

    /// Outputs the head of a logger message
    protected void beginLogMsg(Sink)(auto ref Sink sink,
        string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) const
    {
        import std.datetime : DateTime;

        sink.put(brightTerminal);

        version(Colours)
        {
            if (!monochrome)
            {
                sink.colour(brightTerminal ? BashForeground.black :
                    BashForeground.white);
            }
        }

        sink.put('[');
        sink.put((cast(DateTime)timestamp).timeOfDay.toString());
        sink.put("] ");

        if (monochrome) return;

        version(Colours)
        {
            sink.colour(brightTerminal ? logcoloursBright[logLevel] :
                logcoloursDark[logLevel]);
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

    /// Outputs the message part of a logger message; the content
    protected void logMsgPart(Sink)(auto ref Sink sink, const(char)[] msg) const
    {
        sink.put(msg);
    }

    /// ditto
    override protected void logMsgPart(const(char)[] msg) @trusted const
    {
        if (!msg.length) return;

        return logMsgPart(stdout.lockingTextWriter, msg);
    }

    /// Outputs the tail of a logger message
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

    version (Colours)
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

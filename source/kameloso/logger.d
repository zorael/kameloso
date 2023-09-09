/++
    Contains the custom [KamelosoLogger] class, used to print timestamped and
    (optionally) coloured logging messages.

    Example:
    ---
    auto logger = new KamelosoLogger(
        No.monochrome,
        No.brightTerminal,
        No.headless,
        No.flush);

    logger.log("This is LogLevel.all");
    logger.info("LogLevel.info");
    logger.warn(".warn");
    logger.error(".error");
    logger.trace(".trace");
    //logger.fatal("This will crash the program.");
    ---

    See_Also:
        [kameloso.terminal.colours]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.logger;

private:

import std.typecons : Flag, No, Yes;

public:


// LogLevel
/++
    Logging levels; copied straight from [std.logger], to save us an import.

    There are eight usable logging level. These level are $(I all), $(I trace),
    $(I info), $(I warning), $(I error), $(I critical), $(I fatal), and $(I off).
    If a log function with `LogLevel.fatal` is called the shutdown handler of
    that logger is called.
 +/
enum LogLevel : ubyte
{
    /++
        Lowest possible assignable `LogLevel`.
     +/
    all = 1,

    /++
        `LogLevel` for tracing the execution of the program.
     +/
    trace = 32,

    /++
        This level is used to display information about the program.
     +/
    info = 64,

    /++
        warnings about the program should be displayed with this level.
     +/
    warning = 96,

    /++
        Information about errors should be logged with this level.
     +/
    error = 128,

    /++
        Messages that inform about critical errors should be logged with this level.
     +/
    critical = 160,

    /++
        Log messages that describe fatal errors should use this level.
     +/
    fatal = 192,

    /++
        Highest possible `LogLevel`.
     +/
    off = ubyte.max
}


// KamelosoLogger
/++
    Logger class, used to print timestamped and coloured logging messages.

    It is thread-local so instantiate more if you're threading.
 +/
final class KamelosoLogger
{
private:
    import kameloso.pods : CoreSettings;
    import kameloso.terminal.colours.tags : expandTags;
    import lu.conv : Enum;
    import std.array : Appender;
    import std.format : format;
    import std.traits : EnumMembers;

    version(Colours)
    {
        import kameloso.constants : DefaultColours;
        import kameloso.terminal.colours.defs : TerminalForeground, TerminalReset;
        import kameloso.terminal.colours : applyANSI, asANSI;

        /++
            Convenience alias.
         +/
        alias logcoloursBright = DefaultColours.logcoloursBright;

        /// ditto
        alias logcoloursDark = DefaultColours.logcoloursDark;
    }

    /++
        Buffer to compose a line in before printing it to screen in one go.
     +/
    Appender!(char[]) linebuffer;

    /++
        Sub-buffer to compose the message in.
     +/
    Appender!(char[]) messagebuffer;

    /++
        The initial size to allocate for buffers. It will grow if needed.
     +/
    enum bufferInitialSize = 4096;

    /++
        Whether to use colours or not in logger output.
     +/
    bool monochrome;

    /++
        Whether or not to use colours for a bright background.
     +/
    bool brightTerminal;

    /++
        Whether or not to disable all terminal output.
     +/
    bool headless;

    /++
        Whether or not to flush standard out after writing to it.
     +/
    bool flush;

public:
    /++
        Creates a new [KamelosoLogger] with the passed settings.

        Params:
            monochrome = Whether or not to print colours.
            brightTerminal = Bright terminal setting.
            headless = Headless setting.
            flush = Flush setting.
     +/
    this(
        const Flag!"monochrome" monochrome,
        const Flag!"brightTerminal" brightTerminal,
        const Flag!"headless" headless,
        const Flag!"flush" flush) pure nothrow @safe
    {
        linebuffer.reserve(bufferInitialSize);
        messagebuffer.reserve(bufferInitialSize);
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
        this.headless = headless;
        this.flush = flush;
    }

    /++
        Creates a new [KamelosoLogger] with settings divined from the passed
        [kameloso.pods.CoreSettings|CoreSettings] struct.

        Params:
            settings = [kameloso.pods.CoreSettings|CoreSettings] whose
                values to inherit.
     +/
    this(const CoreSettings settings) pure nothrow @safe
    {
        this(
            cast(Flag!"monochrome")settings.monochrome,
            cast(Flag!"brightTerminal")settings.brightTerminal,
            cast(Flag!"headless")settings.headless,
            cast(Flag!"flush")settings.flush);
    }

    version(Colours)
    {
        // tint
        /++
            Returns the corresponding
            [kameloso.terminal.colours.defs.TerminalForeground|TerminalForeground] for the [LogLevel],
            taking into account whether the terminal is said to be bright or not.

            This is merely a convenient wrapping for [logcoloursBright] and
            [logcoloursDark].

            Example:
            ---
            TerminalForeground errtint = KamelosoLogger.tint(LogLevel.error, No.brightTerminal);
            immutable errtintString = errtint.asANSI;
            ---

            Params:
                level = The [LogLevel] of the colour we want to scry.
                bright = Whether the colour should be for a bright terminal
                    background or a dark one.

            Returns:
                A [kameloso.terminal.colours.defs.TerminalForeground|TerminalForeground] of
                the right colour. Use with [kameloso.terminal.colours.asANSI|asANSI]
                to get a string.
         +/
        static uint tint(const LogLevel level, const Flag!"brightTerminal" bright) pure nothrow @nogc @safe
        {
            return bright ? logcoloursBright[level] : logcoloursDark[level];
        }

        ///
        unittest
        {
            import std.range : only;

            auto range = only(
                LogLevel.all,
                LogLevel.info,
                LogLevel.warning,
                LogLevel.fatal);

            foreach (immutable logLevel; range)
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
            Template for returning tints based on the settings of the `this`
            [KamelosoLogger].

            This saves us having to pass the brightness setting, and allows for
            making easy aliases for the log level.

            Params:
                level = Compile-time [LogLevel].

            Returns:
                A tint string.
         +/
        private auto tintImpl(LogLevel level)() const pure @safe nothrow @nogc
        {
            if (headless || monochrome)
            {
                return string.init;
            }
            else if (brightTerminal)
            {
                enum ctTintBright = tint(level, Yes.brightTerminal).asANSI.idup;
                return ctTintBright;
            }
            else
            {
                enum ctTintDark = tint(level, No.brightTerminal).asANSI.idup;
                return ctTintDark;
            }
        }


        /+
            Generate *tint functions for each [LogLevel].
         +/
        static foreach (const lv; EnumMembers!LogLevel)
        {
            mixin(
"auto " ~ Enum!LogLevel.toString(lv) ~ "tint() const pure @safe nothrow @nogc
{
    return tintImpl!(LogLevel." ~ Enum!LogLevel.toString(lv) ~ ");
}");
        }

        /++
            Synonymous alias to `alltint`, as a workaround for [LogLevel.all]
            not being named `LogLevel.log`.
         +/
        alias logtint = alltint;
    }
    else
    {
        // offtint
        /++
            Dummy function returning an empty string, since there can be no tints
            on non-version `Colours` builds.

            Returns:
                An empty string.
         +/
        public static auto offtint() pure nothrow @nogc @safe
        {
            return string.init;
        }

        /+
            Generate dummy *tint functions for each [LogLevel] by aliasing them
            to [offtint].
         +/
        static foreach (const lv; EnumMembers!LogLevel)
        {
            static if (lv != LogLevel.off)
            {
                mixin("alias " ~ Enum!LogLevel.toString(lv) ~ "tint = offtint;");
            }
        }

        /++
            Synonymous alias to `alltint`, as a workaround for [LogLevel.all]
            not being named `LogLevel.log`.
         +/
        alias logtint = alltint;
    }


    /++
        Outputs the header of a logger message.

        Params:
            logLevel = The [LogLevel] to treat this message as being of.
     +/
    private void beginLogMsg(const LogLevel logLevel) @safe
    {
        import std.datetime : DateTime;
        import std.datetime.systime : Clock;

        version(Colours)
        {
            if (!monochrome)
            {
                alias Timestamp = DefaultColours.TimestampColour;
                //linebuffer.applyANSI(brightTerminal ? Timestamp.bright : Timestamp.dark);
                linebuffer.applyANSI(TerminalReset.all);
            }
        }

        linebuffer.put('[');
        (cast(DateTime)Clock.currTime).timeOfDay.toString(linebuffer);
        linebuffer.put("] ");

        version(Colours)
        {
            if (!monochrome)
            {
                linebuffer.applyANSI(brightTerminal ?
                    logcoloursBright[logLevel] :
                    logcoloursDark[logLevel]);
            }
        }
    }


    /++
        Outputs the tail of a logger message.
     +/
    private void finishLogMsg() @safe
    {
        import std.stdio : stdout, writeln;

        version(Colours)
        {
            if (!monochrome)
            {
                import kameloso.terminal.colours : applyANSI;
                // Reset.blink in case a fatal message was thrown
                linebuffer.applyANSI(TerminalReset.all);
            }
        }

        writeln(linebuffer.data);

        () @trusted
        {
            // writeln trusts stdout.flush, so we should be able to too
            if (flush) stdout.flush();
        }();
    }


    // printImpl
    /++
        Prints a timestamped log message to screen. Implementation function.

        Prints the arguments as they are if possible (if they are some variant of
        `char` or `char[]`), and otherwise tries to coerce them by using
        [std.conv.to].

        Params:
            logLevel = The [LogLevel] to treat this message as being of.
            args = Variadic arguments to compose the output message with.
     +/
    private void printImpl(Args...)(const LogLevel logLevel, auto ref Args args)
    {
        import lu.traits : UnqualArray;
        import std.traits : isAggregateType;

        scope(exit)
        {
            linebuffer.clear();
            messagebuffer.clear();
        }

        beginLogMsg(logLevel);

        foreach (ref arg; args)
        {
            alias T = typeof(arg);

            static if (is(UnqualArray!T : char[]) || is(T : char))
            {
                messagebuffer.put(arg);
            }
            else static if (is(T == enum))
            {
                import lu.conv : Enum;
                messagebuffer.put(Enum!T.toString(arg));
            }
            else static if (isAggregateType!T && is(typeof(T.toString)))
            {
                import std.traits : isSomeFunction;

                static if (isSomeFunction!(T.toString) || __traits(isTemplate, T.toString))
                {
                    static if (__traits(compiles, arg.toString(messagebuffer)))
                    {
                        // Output range sink overload (accepts an Appender)
                        arg.toString(messagebuffer);
                    }
                    else static if (__traits(compiles,
                        arg.toString((const(char)[] text) => messagebuffer.put(text))))
                    {
                        // Output delegate sink overload
                        arg.toString((const(char)[] text) => messagebuffer.put(text));
                    }
                    else static if (__traits(compiles, messagebuffer.put(arg.toString)))
                    {
                        // Plain string-returning function or template
                        messagebuffer.put(arg.toString);
                    }
                    else
                    {
                        import std.conv : to;
                        // std.conv.to fallback
                        messagebuffer.put(arg.to!string);
                    }
                }
                else static if (is(typeof(T.toString)) &&
                    is(UnqualArray!(typeof(T.toString)) : char[]))
                {
                    // toString string/char[] literal
                    messagebuffer.put(arg.toString);
                }
                else
                {
                    import std.conv : to;
                    // std.conv.to fallback
                    messagebuffer.put(arg.to!string);
                }
            }
            else
            {
                import std.conv : to;
                // std.conv.to fallback
                messagebuffer.put(arg.to!string);
            }
        }

        linebuffer.put(messagebuffer.data.expandTags(logLevel, cast(Flag!"strip")monochrome));
        finishLogMsg();
    }


    // printfImpl
    /++
        Prints a timestamped log message to screen as per the passed runtime pattern,
        in `printf` style. Implementation function.

        Uses [std.format.formattedWrite|formattedWrite] to coerce the passed
        arguments as the format pattern dictates.

        Params:
            logLevel = The [LogLevel] to treat this message as being of.
            pattern = Runtime pattern to format the output with.
            args = Variadic arguments to compose the output message with.
     +/
    private void printfImpl(Args...)
        (const LogLevel logLevel,
        const string pattern,
        auto ref Args args)
    {
        import std.format : formattedWrite;

        scope(exit)
        {
            linebuffer.clear();
            messagebuffer.clear();
        }

        beginLogMsg(logLevel);
        messagebuffer.formattedWrite(pattern, args);
        linebuffer.put(messagebuffer.data.expandTags(logLevel, cast(Flag!"strip")monochrome));
        finishLogMsg();
    }


    // printfImpl
    /++
        Prints a timestamped log message to screen as per the passed compile-time
        pattern, in `printf` style. Implementation function.

        Uses [std.format.formattedWrite|formattedWrite] to coerce the passed
        arguments as the format pattern dictates.

        Params:
            pattern = Compile-time pattern to validate the arguments and format
                the output with.
            logLevel = The [LogLevel] to treat this message as being of.
            args = Variadic arguments to compose the output message with.
     +/
    private void printfImpl(string pattern, Args...)(const LogLevel logLevel, auto ref Args args)
    {
        import std.format : formattedWrite;

        scope(exit)
        {
            linebuffer.clear();
            messagebuffer.clear();
        }

        beginLogMsg(logLevel);
        messagebuffer.formattedWrite!pattern(args);
        linebuffer.put(messagebuffer.data.expandTags(logLevel, cast(Flag!"strip")monochrome));
        finishLogMsg();
    }


    /++
        Mixin to error out on `fatal` calls.
     +/
    private enum fatalErrorMixin =
`throw new Error("A fatal error message was logged");`;

    /+
        Generate `trace`, `tracef`, `log`, `logf` and similar Logger-esque functions.

        Mixes in [fatalExitMixin] on `fatal` to have it exit the program on those.
     +/
    static foreach (const lv; EnumMembers!LogLevel)
    {
        mixin(
"void " ~ Enum!LogLevel.toString(lv) ~ "(Args...)(auto ref Args args)
{
    if (!headless) printImpl(LogLevel." ~ Enum!LogLevel.toString(lv) ~ ", args);
    " ~ ((lv == LogLevel.fatal) ? fatalErrorMixin : string.init) ~ "
}

void " ~ Enum!LogLevel.toString(lv) ~ "f(Args...)(const string pattern, auto ref Args args)
{
    if (!headless) printfImpl(LogLevel." ~ Enum!LogLevel.toString(lv) ~ ", pattern, args);
    " ~ ((lv == LogLevel.fatal) ? fatalErrorMixin : string.init) ~ "
}

void " ~ Enum!LogLevel.toString(lv) ~ "f(string pattern, Args...)(auto ref Args args)
{
    if (!headless) printfImpl!pattern(LogLevel." ~ Enum!LogLevel.toString(lv) ~ ", args);
    " ~ ((lv == LogLevel.fatal) ? fatalErrorMixin : string.init) ~ "
}");
    }

    /++
        Synonymous alias to [KamelosoLogger.all], as a workaround for
        [LogLevel.all] not being named `LogLevel.log`.
     +/
    alias log = all;

    /++
        Synonymous alias to [KamelosoLogger.allf], as a workaround for
        [LogLevel.all] not being named `LogLevel.log`.
     +/
    alias logf = allf;
}

///
unittest
{
    struct S1
    {
        void toString(Sink)(auto ref Sink sink) const
        {
            sink.put("sink toString");
        }
    }

    struct S2
    {
        void toString(scope void delegate(const(char)[]) dg) const
        {
            dg("delegate toString");
        }

        @disable this(this);
    }

    struct S3
    {
        string s = "no toString";
    }

    struct S4
    {
        string toString = "toString literal";
    }

    struct S5
    {
        string toString()() const
        {
            return "template toString";
        }
    }

    class C
    {
        override string toString() const
        {
            return "plain toString";
        }
    }

    auto log_ = new KamelosoLogger(Yes.monochrome, No.brightTerminal, No.headless, Yes.flush);

    log_.logf!"log: %s"("log");
    log_.infof!"log: %s"("info");
    log_.warningf!"log: %s"("warning");
    log_.errorf!"log: %s"("error");
    log_.criticalf!"log: %s"("critical");
    // log_.fatalf!"log: %s"("FATAL");
    log_.tracef!"log: %s"("trace");
    log_.offf!"log: %s"("off");

    version(Colours)
    {
        log_ = new KamelosoLogger(No.monochrome, Yes.brightTerminal, No.headless, Yes.flush);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        log_.critical("log: critical");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");
        log_.off("log: off");

        log_ = new KamelosoLogger(No.monochrome, No.brightTerminal, No.headless, Yes.flush);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");
        log_.off("log: off");
    }

    log_.log("log <i>info</> log <w>warning</> log <e>error</> log <t>trace</> log <o>off</> log");

    S1 s1;
    S2 s2;
    S3 s3;
    S4 s4;
    S5 s5;
    C c = new C;

    log_.trace();

    log_.log(s1);
    log_.info(s2);
    log_.warning(s3);
    log_.critical(s4);
    log_.error(s5);
    log_.trace(c);

    log_.headless = true;
    log_.error("THIS SHOULD NEVER BE SEEN");
}

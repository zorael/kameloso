/++
    Contains the custom `KamelosoLogger` class, used to print timestamped and
    (optionally) coloured logging messages.

    Example:
    ---
    auto logger = new KamelosoLogger(No.monochrome, No.brigtTerminal, Yes.flush);

    logger.log("This is LogLevel.log");
    logger.info("LogLevel.info");
    logger.warn(".warn");
    logger.error(".error");
    logger.trace(".trace");
    //logger.fatal("This will crash the program.");
    ---
 +/
module kameloso.logger;

private:

import std.range.primitives : isOutputRange;

public:

/+
    Build tint colours at compile time, saving the need to compute them during
    runtime. It's a trade-off.
 +/
version = CtTints;


// KamelosoLogger
/++
    Logger class, used to print timestamped and coloured logging messages.

    It is thread-local so instantiate more if you're threading.
 +/
final class KamelosoLogger
{
private:
    import std.array : Appender;
    import std.experimental.logger : LogLevel;
    import std.format : format;
    import std.traits : EnumMembers;
    import std.typecons : Flag, No, Yes;

    version(Colours)
    {
        import kameloso.constants : DefaultColours;
        import kameloso.terminal : TerminalForeground, TerminalReset, colourWith, colour;

        alias logcoloursBright = DefaultColours.logcoloursBright;
        alias logcoloursDark = DefaultColours.logcoloursDark;
    }

    /// Buffer to compose a line in before printing it to screen in one go.
    Appender!(char[]) linebuffer;

    /// The initial size to allocate for `linebuffer`. It will grow if needed.
    enum linebufferInitialSize = 4096;

    bool monochrome;  /// Whether to use colours or not in logger output.
    bool brightTerminal;   /// Whether or not to use colours for a bright background.

public:
    /++
        Create a new `KamelosoLogger` with the passed settings.

        Params:
            monochrome = Whether or not to print colours.
            brightTerminal = Bright terminal setting.
     +/
    this(const Flag!"monochrome" monochrome,
        const Flag!"brightTerminal" brightTerminal) @safe
    {
        linebuffer.reserve(linebufferInitialSize);
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
    }


    // tint
    /++
        Returns the corresponding `kameloso.terminal.TerminalForeground` for the
        supplied `std.experimental.logger.LogLevel`,
        taking into account whether the terminal is said to be bright or not.

        This is merely a convenient wrapping for `logcoloursBright` and
        `logcoloursDark`.

        Example:
        ---
        TerminalForeground errtint = KamelosoLogger.tint(LogLevel.error, No.brightTerminal);
        immutable errtintString = errtint.colour;
        ---

        Params:
            level = The `std.experimental.logger.LogLevel` of the colour we want to scry.
            bright = Whether the colour should be for a bright terminal
                background or a dark one.

        Returns:
            A `kameloso.terminal.TerminalForeground` of the right colour. Use with
            `kameloso.terminal.colour` to get a string.
     +/
    pragma(inline, true)
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
        Template for returning tints based on the settings of the `this`
        `KamelosoLogger`.

        This saves us having to pass the brightness setting, and allows for
        making easy aliases for the log level.

        Params:
            level = Compile-time `std.experimental.logger.LogLevel`.

        Returns:
            A tint string.
     +/
    pragma(inline, true)
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
            return tint(level, brightTerminal ? Yes.brightTerminal : No.brightTerminal).colour;
        }
    }

    pragma(inline, true)
    version(Colours)
    {
        /// Provides easy way to get a log tint.
        auto tracetint() const @property { return tintImpl!(LogLevel.trace); }

        /// Synonymous alias to `tracetint`.
        alias resettint = tracetint;

        /// Provides easy way to get a log tint.
        auto logtint() const @property { return tintImpl!(LogLevel.all); }

        /// Provides easy way to get an info tint.
        auto infotint() const @property { return tintImpl!(LogLevel.info); }

        /// Provides easy way to get a warning tint.
        auto warningtint() const @property { return tintImpl!(LogLevel.warning); }

        /// Provides easy way to get an error tint.
        auto errortint() const @property { return tintImpl!(LogLevel.error); }

        /// Provides easy way to get a fatal tint.
        auto fataltint() const @property { return tintImpl!(LogLevel.fatal); }
    }


    /++
        Outputs the header of a logger message.

        Params:
            logLevel = The `std.experimental.logger.LogLevel` to treat this
                message as being of.
     +/
    protected void beginLogMsg(const LogLevel logLevel) @safe
    {
        import std.datetime : DateTime;
        import std.datetime.systime : Clock;

        version(Colours)
        {
            if (!monochrome)
            {
                alias Timestamp = DefaultColours.TimestampColour;
                linebuffer.colourWith(brightTerminal ? Timestamp.bright : Timestamp.dark);
            }
        }

        linebuffer.put('[');
        (cast(DateTime)Clock.currTime).timeOfDay.toString(linebuffer);
        linebuffer.put("] ");

        if (monochrome) return;

        version(Colours)
        {
            linebuffer.colourWith(brightTerminal ?
                logcoloursBright[logLevel] :
                logcoloursDark[logLevel]);
        }
    }


    /++
        Outputs the tail of a logger message.
     +/
    private void finishLogMsg() @safe
    {
        import std.stdio : writeln;

        version(Colours)
        {
            if (!monochrome)
            {
                // Reset.blink in case a fatal message was thrown
                linebuffer.colourWith(TerminalForeground.default_, TerminalReset.blink);
            }
        }

        writeln(linebuffer.data);
        linebuffer.clear();
    }


    // printImpl
    /++
        Prints a timestamped log message to screen. Implementation function.

        Prints the arguments as they are if possible (if they are some variant of
        `char` or `char[]`), and otherwise tries to coerce them by using
        `std.conv.to`.

        Params:
            logLevel = The `std.experimental.logger.LogLevel` to treat this
                message as being of.
            args = Variadic arguments to compose the output message with.
     +/
    private void printImpl(Args...)(const LogLevel logLevel, Args args)
    {
        beginLogMsg(logLevel);

        foreach (arg; args)
        {
            alias T = typeof(arg);

            static if (is(T : string) || is(T : char[]) || is(T : char))
            {
                linebuffer.put(arg);
            }
            else static if (is(T == enum))
            {
                import lu.conv : Enum;
                linebuffer.put(Enum!T.toString(arg));
            }
            else static if ((is(T == struct) || is(T == class) || is(T == interface)) &&
                is(typeof(T.toString)))
            {
                import std.traits : isSomeFunction;

                static if (isSomeFunction!(T.toString) || __traits(isTemplate, T.toString))
                {
                    static if (__traits(compiles, arg.toString(linebuffer)))
                    {
                        // Output range sink overload (accepts an Appender)
                        arg.toString(linebuffer);
                    }
                    else static if (__traits(compiles,
                        arg.toString((const(char)[] text) => linebuffer.put(text))))
                    {
                        // Output delegate sink overload
                        arg.toString((const(char)[] text) => linebuffer.put(text));
                    }
                    else static if (__traits(compiles, linebuffer.put(arg.toString)))
                    {
                        // Plain string-returning function or template
                        linebuffer.put(arg.toString);
                    }
                    else
                    {
                        import std.conv : to;
                        // std.conv.to fallback
                        linebuffer.put(arg.to!string);
                    }
                }
                else static if (is(typeof(T.toString)) &&
                    (is(typeof(T.toString) : string) || is(typeof(T.toString) : char[])))
                {
                    // toString string/char[] literal
                    linebuffer.put(arg.toString);
                }
                else
                {
                    import std.conv : to;
                    // std.conv.to fallback
                    linebuffer.put(arg.to!string);
                }
            }
            else
            {
                import std.conv : to;
                // std.conv.to fallback
                linebuffer.put(arg.to!string);
            }
        }

        finishLogMsg();
    }


    // printfImpl
    /++
        Prints a timestamped log message to screen as per the passed runtime pattern,
        in `printf` style. Implementation function.

        Uses `std.format.formattedWrite` to coerce the passed arguments as
        the format pattern dictates.

        Params:
            logLevel = The `std.experimental.logger.LogLevel` to treat this
                message as being of.
            pattern = Runtime pattern to format the output with.
            args = Variadic arguments to compose the output message with.
     +/
    private void printfImpl(Args...)(const LogLevel logLevel, const string pattern, Args args)
    {
        import std.format : formattedWrite;

        beginLogMsg(logLevel);
        linebuffer.formattedWrite(pattern, args);
        finishLogMsg();
    }


    // printfImpl
    /++
        Prints a timestamped log message to screen as per the passed compile-time pattern,
        in `printf` style. Implementation function.

        Uses `std.format.formattedWrite` to coerce the passed arguments as
        the format pattern dictates.

        If on D version 2.074 or later, passes the pattern as a compile-time
        parameter to it, to validate that the pattern matches the arguments.
        If earlier it passes execution to the other, runtime-pattern `printfImpl` overload.

        Params:
            pattern = Compile-time pattern to validate the arguments and format the output with.
            logLevel = The `std.experimental.logger.LogLevel` to treat this
                message as being of.
            args = Variadic arguments to compose the output message with.
     +/
    private void printfImpl(string pattern, Args...)(const LogLevel logLevel, Args args)
    {
        import std.format : formattedWrite;

        beginLogMsg(logLevel);
        linebuffer.formattedWrite!pattern(args);
        finishLogMsg();
    }


    /+
        Generate `trace`, `tracef`, `log`, `logf` and similar Logger-esque functions.
     +/
    static foreach (const lv; [ EnumMembers!LogLevel ])
    {
        mixin(
q{void %1$s(Args...)(Args args)
{
    printImpl(LogLevel.%1$s, args);
}

void %1$sf(Args...)(const string pattern, Args args)
{
    printfImpl(LogLevel.%1$s, pattern, args);
}

void %sf(string pattern, Args...)(Args args)
{
    printfImpl!pattern(LogLevel.%1$s, args);
}}.format(lv));
    }

    /// Alias to `KamelosoLogger.all`.
    alias log = all;

    /// Alias to `KamelosoLogger.allf`.
    alias logf = allf;
}

///
unittest
{
    import std.experimental.logger : LogLevel;
    import std.typecons : Flag, No, Yes;

    struct S1
    {
        void toString(Sink)(auto ref Sink sink)
        {
            sink.put("sink toString");
        }
    }

    struct S2
    {
        void toString(scope void delegate(const(char)[]) dg)
        {
            dg("delegate toString");
        }
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
        string toString()()
        {
            return "template toString";
        }
    }

    class C
    {
        override string toString()
        {
            return "plain toString";
        }
    }

    auto log_ = new KamelosoLogger(Yes.monochrome, No.brightTerminal, Yes.flush);

    log_.logf!"log: %s"("log");
    log_.infof!"log: %s"("info");
    log_.warningf!"log: %s"("warning");
    log_.errorf!"log: %s"("error");
    // log_.fatalf!"log: %s"("FATAL");
    log_.tracef("log: %s", "trace");

    version(Colours)
    {
        log_ = new KamelosoLogger(No.monochrome, Yes.brightTerminal, Yes.flush);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");

        log_ = new KamelosoLogger(No.monochrome, No.brightTerminal, Yes.flush);

        log_.log("log: log");
        log_.info("log: info");
        log_.warning("log: warning");
        log_.error("log: error");
        // log_.fatal("log: FATAL");
        log_.trace("log: trace");
    }

    S1 s1;
    S2 s2;
    S3 s3;
    S4 s4;
    S5 s5;
    C c = new C;

    log_.trace("---");

    log_.log(s1);
    log_.info(s2);
    log_.warning(s3);
    log_.error(s4);
    log_.trace(s5);
    log_.log(c);
}


module kameloso.logger;

public:




pragma(msg, "DustMiteNoRemoveStart");
 class KamelosoLogger
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

    
    Appender!(char[]) linebuffer;

    
    enum linebufferInitialSize = 4096;

    bool monochrome;  
    bool brightTerminal;   

public:
    
    this(const Flag!"monochrome" monochrome,
        const Flag!"brightTerminal" brightTerminal) pure nothrow @safe
    {
        linebuffer.reserve(linebufferInitialSize);
        this.monochrome = monochrome;
        this.brightTerminal = brightTerminal;
    }


    pragma(inline, true)
    version(Colours)
    {
        
        
        static auto tint(const LogLevel level, const Flag!"brightTerminal" bright) pure nothrow @nogc @safe
        {
            return bright ? logcoloursBright[level] : logcoloursDark[level];
        }

        
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


        
        
        private string tintImpl(LogLevel level)() const @property pure nothrow @nogc @safe
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


        
        static foreach (const lv; EnumMembers!LogLevel)
        {
            mixin(
q{
auto %1$stint() const @property pure nothrow @nogc @safe { return tintImpl!(LogLevel.%1$s); }
            }.format(lv));
        }

        
        alias logtint = alltint;
    }


    
    private void beginLogMsg(const LogLevel logLevel) @safe
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

        version(Colours)
        {
            if (!monochrome)
            {
                linebuffer.colourWith(brightTerminal ?
                    logcoloursBright[logLevel] :
                    logcoloursDark[logLevel]);
            }
        }
    }


    
    private void finishLogMsg() @safe
    {
        import std.stdio : writeln;

        version(Colours)
        {
            if (!monochrome)
            {
                
                linebuffer.colourWith(TerminalForeground.default_, TerminalReset.blink);
            }
        }

        writeln(linebuffer.data);
        linebuffer.clear();
    }


    
    
    private void printImpl(Args...)(const LogLevel logLevel, auto ref Args args)
    {
        import std.traits : isAggregateType;

        beginLogMsg(logLevel);

        foreach (ref arg; args)
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
            else static if (isAggregateType!T && is(typeof(T.toString)))
            {
                import std.traits : isSomeFunction;

                static if (isSomeFunction!(T.toString) || __traits(isTemplate, T.toString))
                {
                    static if (__traits(compiles, arg.toString(linebuffer)))
                    {
                        
                        arg.toString(linebuffer);
                    }
                    else static if (__traits(compiles,
                        arg.toString((const(char)[] text) => linebuffer.put(text))))
                    {
                        
                        arg.toString((const(char)[] text) => linebuffer.put(text));
                    }
                    else static if (__traits(compiles, linebuffer.put(arg.toString)))
                    {
                        
                        linebuffer.put(arg.toString);
                    }
                    else
                    {
                        import std.conv : to;
                        
                        linebuffer.put(arg.to!string);
                    }
                }
                else static if (is(typeof(T.toString)) &&
                    (is(typeof(T.toString) : string) || is(typeof(T.toString) : char[])))
                {
                    
                    linebuffer.put(arg.toString);
                }
                else
                {
                    import std.conv : to;
                    
                    linebuffer.put(arg.to!string);
                }
            }
            else
            {
                import std.conv : to;
                
                linebuffer.put(arg.to!string);
            }
        }

        finishLogMsg();
    }


    
    
    private void printfImpl(Args...)
        (const LogLevel logLevel,
        const string pattern,
        auto ref Args args)
    {
        import std.format : formattedWrite;

        beginLogMsg(logLevel);
        linebuffer.formattedWrite(pattern, args);
        finishLogMsg();
    }


    
    
    private void printfImpl(string pattern, Args...)(const LogLevel logLevel, auto ref Args args)
    {
        import std.format : formattedWrite;

        beginLogMsg(logLevel);
        linebuffer.formattedWrite!pattern(args);
        finishLogMsg();
    }


    
    private enum fatalErrorMixin =
`throw new Error("A fatal error message was logged");`;

    
    static foreach (const lv; [ EnumMembers!LogLevel ])
    {
        mixin(
q{
void %1$s(Args...)(auto ref Args args)
{
    printImpl(LogLevel.%1$s, args);
    %2$s
}


void %1$sf(Args...)(const string pattern, auto ref Args args)
{
    printfImpl(LogLevel.%1$s, pattern, args);
    %2$s
}


void %1$sf(string pattern, Args...)(auto ref Args args)
{
    printfImpl!pattern(LogLevel.%1$s, args);
    %2$s
}}.format(lv, (lv == LogLevel.fatal) ? fatalErrorMixin : string.init));
    }

    
    alias log = all;

    
    alias logf = allf;
}
pragma(msg, "DustMiteNoRemoveStop");



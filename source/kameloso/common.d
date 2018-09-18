/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

import kameloso.bash : BashForeground;
import kameloso.uda;

import core.time : Duration;

import std.experimental.logger : Logger;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

@safe:

version(unittest)
shared static this()
{
    import kameloso.logger : KamelosoLogger;

    // This is technically before settings have been read...
    logger = new KamelosoLogger;
}


// logger
/++
 +  Instance of a `kameloso.logger.KamelosoLogger`, providing timestamped and
 +  coloured logging.
 +
 +  The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
 +  and `fatal`. It is not global, so instantiate a thread-local `Logger` if
 +  threading.
 +
 +  Having this here is unfortunate; ideally plugins should not use variables
 +  from other modules, but unsure of any way to fix this other than to have
 +  each plugin keep their own `Logger`.
 +/
Logger logger;


// initLogger
/++
 +  Initialises the `kameloso.logger.KamelosoLogger` logger for use in this
 +  thread.
 +
 +  It needs to be separately instantiated per thread.
 +
 +  Example:
 +  ---
 +  initLogger(settings.monochrome, settings.brightTerminal);
 +  ---
 +
 +  Params:
 +      monochrome = Whether the terminal is set to monochrome or not.
 +      bright = Whether the terminal has a bright background or not.
 +/
void initLogger(const bool monochrome = settings.monochrome,
    const bool bright = settings.brightTerminal)
{
    import kameloso.logger : KamelosoLogger;
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome, bright);
}


// settings
/++
 +  A `CoreSettings` struct global, housing certain runtime settings.
 +
 +  This will be accessed from other parts of the program, via
 +  `kameloso.common.settings`, so they know to use monochrome output or not. It
 +  is a problem that needs solving.
 +/
__gshared CoreSettings settings;


// ThreadMessage
/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate concurrency-receiving delegates for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server `PONG` event.
    struct Pong {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to immediately send a message.
    struct Immediateline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}

    /// Concurrency message type asking to have plugins' configuration saved.
    struct Save {}

    /++
     +  Concurrency message asking for a reference to the arrays of
     +  `kameloso.plugins.common.IRCPlugin`s in the current `Client`.
     +/
    struct PeekPlugins {}

    /// Concurrency message asking plugins to "reload".
    struct Reload {}

    /// Concurrency message asking to disconnect and reconnect to the server.
    struct Reconnect {}

    /// Concurrency message meant to be sent between plugins.
    struct BusMessage {}

    /// Concurrency messages for writing text to the terminal.
    enum TerminalOutput
    {
        writeln,
        trace,
        log,
        info,
        warning,
        error,
    }
}


// CoreSettings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +/
struct CoreSettings
{
    version(Colours)
    {
        bool monochrome = false;  /// Logger monochrome setting.
    }
    else
    {
        bool monochrome = true;  /// Mainly version Windows.
    }

    /// Flag denoting whether the program should reconnect after disconnect.
    bool reconnectOnFailure = true;

    /// Flag denoting that the terminal has a bright background.
    bool brightTerminal = false;

    /// Whether to connect to IPv6 addresses or not.
    bool ipv6 = true;

    /// Whether to print outgoing messages or not.
    bool hideOutgoing = false;

    /// Flag denoting that we should save to file on exit.
    bool saveOnExit = false;

    /// Character(s) that prefix a bot chat command.
    string prefix = "!";

    @Unconfigurable
    @Hidden
    {
        string configFile;  /// Main configuration file.
        string resourceDirectory;  /// Path to resource directory.
        string configDirectory;  /// Path to configuration directory.
    }
}


// printObjects
/++
 +  Prints out struct objects, with all their printable members with all their
 +  printable values.
 +
 +  This is not only convenient for debugging but also usable to print out
 +  current settings and state, where such is kept in structs.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      int foo;
 +      string bar;
 +      float f;
 +      double d;
 +  }
 +
 +  Foo foo, bar;
 +  printObjects(foo, bar);
 +  ---
 +
 +  Params:
 +      widthArg = The width with which to pad output columns.
 +      things = Variadic list of struct objects to enumerate.
 +/
void printObjects(Flag!"printAll" printAll = No.printAll, uint widthArg = 0, Things...)(Things things) @trusted
{
    import std.stdio : stdout;

    // writeln trusts `lockingTextWriter` so we will too.

    bool printed;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            formatObjects!(printAll, Yes.coloured, widthArg)(stdout.lockingTextWriter, things);
            printed = true;
        }
    }

    if (!printed)
    {
        formatObjects!(printAll, No.coloured, widthArg)(stdout.lockingTextWriter, things);
    }

    version(Cygwin_) stdout.flush();
}

alias printObject = printObjects;


// formatObjects
/++
 +  Formats a struct object, with all its printable members with all their
 +  printable values.
 +
 +  This is an implementation template and should not be called directly;
 +  instead use `printObject` and `printObjects`.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      int foo = 42;
 +      string bar = "arr matey";
 +      float f = 3.14f;
 +      double d = 9.99;
 +  }
 +
 +  Foo foo, bar;
 +  Appender!string sink;
 +
 +  sink.formatObjects!(Yes.coloured)(foo);
 +  sink.formatObjects!(No.coloured)(bar);
 +  writeln(sink.data);
 +  ---
 +
 +  Params:
 +      coloured = Whether to display in colours or not.
 +      widthArg = The width with which to pad output columns.
 +      sink = Output range to write to.
 +      things = Variadic list of structs to enumerate and format.
 +/
void formatObjects(Flag!"printAll" printAll = No.printAll,
    Flag!"coloured" coloured = Yes.coloured, uint widthArg = 0, Sink, Things...)
    (auto ref Sink sink, Things things) @trusted
if (isOutputRange!(Sink, char[]))
{
    import kameloso.traits;
    import std.algorithm.comparison : max;

    static if (coloured)
    {
        import kameloso.bash : colour;
    }

    static if (__VERSION__ < 2076L)
    {
        // workaround formattedWrite taking sink by value pre 2.076
        sink.put(string.init);
    }

    enum minimumTypeWidth = 9;  // Current sweet spot, accomodates well for `string[]`
    enum minimumNameWidth = 20;

    static if (printAll)
    {
        enum typewidth = max(minimumTypeWidth, (longestUnconfigurableMemberTypeName!Things.length + 1));
        enum initialWidth = !widthArg ? longestUnconfigurableMemberName!Things.length : widthArg;
    }
    else
    {
        enum typewidth = max(minimumTypeWidth, (longestMemberTypeName!Things.length + 1));
        enum initialWidth = !widthArg ? longestMemberName!Things.length : widthArg;
    }

    enum compensatedWidth = (typewidth > minimumTypeWidth) ?
        (initialWidth - typewidth + minimumTypeWidth) : initialWidth;
    enum namewidth = max(minimumNameWidth, compensatedWidth);

    immutable bright = .settings.brightTerminal;

    with (BashForeground)
    foreach (immutable n, thing; things)
    {
        import kameloso.string : stripSuffix;
        import std.format : formattedWrite;
        import std.traits : Unqual;

        alias Thing = Unqual!(typeof(thing));

        static if (coloured)
        {
            immutable titleColour = bright ? black : white;
            sink.formattedWrite("%s-- %s\n", titleColour.colour, Thing.stringof.stripSuffix("Settings"));
        }
        else
        {
            sink.formattedWrite("-- %s\n", Thing.stringof.stripSuffix("Settings"));
        }

        foreach (immutable i, member; thing.tupleof)
        {
            import std.traits : hasUDA, isAssociativeArray, isType;

            enum shouldNormallyBePrinted = !isType!member &&
                isConfigurableVariable!member &&
                !hasUDA!(thing.tupleof[i], Hidden) &&
                !hasUDA!(thing.tupleof[i], Unconfigurable);

            enum shouldMaybeBePrinted = printAll && !hasUDA!(thing.tupleof[i], Hidden);

            static if (shouldNormallyBePrinted || shouldMaybeBePrinted)
            {
                import std.traits : isArray, isSomeString;

                alias T = Unqual!(typeof(member));

                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (isTrulyString!T)
                {
                    static if (coloured)
                    {
                        enum stringPattern = `%s%*s %s%-*s %s"%s"%s(%d)` ~ '\n';
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;
                        immutable lengthColour = bright ? lightgrey : darkgrey;

                        sink.formattedWrite(stringPattern,
                            cyan.colour, typewidth, T.stringof,
                            memberColour.colour, (namewidth + 2), memberstring,
                            valueColour.colour, member,
                            lengthColour.colour, member.length);
                    }
                    else
                    {
                        enum stringPattern = `%*s %-*s "%s"(%d)` ~ '\n';
                        sink.formattedWrite(stringPattern, typewidth, T.stringof,
                            (namewidth + 2), memberstring,
                            member, member.length);
                    }
                }
                else static if (isArray!T || isAssociativeArray!T)
                {
                    import std.range.primitives : ElementEncodingType;

                    alias ElemType = Unqual!(ElementEncodingType!T);
                    enum elemIsCharacter = is(ElemType == char) || is(ElemType == dchar) || is(ElemType == wchar);

                    immutable thisWidth = member.length ? (namewidth + 2) : (namewidth + 4);

                    static if (coloured)
                    {
                        static if (elemIsCharacter)
                        {
                            enum arrayPattern = "%s%*s %s%-*s%s[%(%s, %)]%s(%d)\n";
                        }
                        else
                        {
                            enum arrayPattern = "%s%*s %s%-*s%s%s%s(%d)\n";
                        }

                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;
                        immutable lengthColour = bright ? lightgrey : darkgrey;

                        sink.formattedWrite(arrayPattern,
                            cyan.colour, typewidth, UnqualArray!T.stringof,
                            memberColour.colour, thisWidth, memberstring,
                            valueColour.colour, member,
                            lengthColour.colour, member.length);
                    }
                    else
                    {
                        static if (elemIsCharacter)
                        {
                            enum arrayPattern = "%*s %-*s[%(%s, %)](%d)\n";
                        }
                        else
                        {
                            enum arrayPattern = "%*s %-*s%s(%d)\n";
                        }

                        sink.formattedWrite(arrayPattern,
                            typewidth, UnqualArray!T.stringof,
                            thisWidth, memberstring,
                            member,
                            member.length);
                    }
                }
                else static if (is(T == struct) || is(T == class))
                {
                    enum classOrStruct = is(T == struct) ? "struct" : "class";

                    immutable initText = (thing.tupleof[i] == Thing.init.tupleof[i]) ? " (init)" : string.init;

                    static if (coloured)
                    {
                        enum normalPattern = "%s%*s %s%-*s %s<%s>%s\n";
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;

                        sink.formattedWrite(normalPattern,
                            cyan.colour, typewidth, T.stringof,
                            memberColour.colour, (namewidth + 2), memberstring,
                            valueColour.colour, classOrStruct, initText);
                    }
                    else
                    {
                        enum normalPattern = "%*s %-*s <%s>%s\n";
                        sink.formattedWrite(normalPattern, typewidth, T.stringof,
                            (namewidth + 2), memberstring, classOrStruct, initText);
                    }
                }
                else
                {
                    static if (coloured)
                    {
                        enum normalPattern = "%s%*s %s%-*s  %s%s\n";
                        immutable memberColour = bright ? black : white;
                        immutable valueColour = bright ? green : lightgreen;

                        sink.formattedWrite(normalPattern,
                            cyan.colour, typewidth, T.stringof,
                            memberColour.colour, (namewidth + 2), memberstring,
                            valueColour.colour, member);
                    }
                    else
                    {
                        enum normalPattern = "%*s %-*s  %s\n";
                        sink.formattedWrite(normalPattern, typewidth, T.stringof,
                            (namewidth + 2), memberstring, member);
                    }
                }
            }
        }

        static if (coloured)
        {
            sink.put(default_.colour);
        }

        static if ((n+1 < things.length) || !__traits(hasMember, Sink, "data"))
        {
            // Not an Appender, make sure it has a final linebreak to be consistent
            // with Appender writeln
            sink.put('\n');
        }
    }
}

///
@system unittest
{
    import kameloso.string : contains;
    import std.array : Appender;

    struct Struct
    {
        string members;
        int asdf;
    }

    // Monochrome

    struct StructName
    {
        Struct struct_;
        int i = 12_345;
        string s = "foo";
        bool b = true;
        float f = 3.14f;
        double d = 99.9;
        const(char)[] c = [ 'a', 'b', 'c' ];
        const(char)[] emptyC;
        string[] dynA = [ "foo", "bar", "baz" ];
        int[] iA = [ 1, 2, 3, 4 ];
        const(char)[char] cC;
    }

    StructName s;
    s.cC = [ 'a':'a', 'b':'b' ];
    assert('a' in s.cC);
    assert('b' in s.cC);
    Appender!(char[]) sink;

    sink.reserve(512);  // ~323
    sink.formatObjects!(No.printAll, No.coloured)(s);

    enum structNameSerialised =
`-- StructName
     Struct struct_                <struct> (init)
        int i                       12345
     string s                      "foo"(3)
       bool b                       true
      float f                       3.14
     double d                       99.9
     char[] c                     ['a', 'b', 'c'](3)
     char[] emptyC                  [](0)
   string[] dynA                  ["foo", "bar", "baz"](3)
      int[] iA                    [1, 2, 3, 4](4)
 char[char] cC                    ['b':'b', 'a':'a'](2)
`;
    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Adding Settings does nothing
    alias StructNameSettings = StructName;
    StructNameSettings so = s;
    sink.clear();
    sink.formatObjects!(No.printAll, No.coloured)(so);

    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Two at a time
    struct Struct1
    {
        string members;
        int asdf;
    }

    struct Struct2
    {
        string mumburs;
        int fdsa;
    }

    Struct1 st1;
    Struct2 st2;

    st1.members = "harbl";
    st1.asdf = 42;
    st2.mumburs = "hirrs";
    st2.fdsa = -1;

    sink.clear();
    sink.formatObjects!(No.printAll, No.coloured)(st1, st2);
    enum st1st2Formatted =
`-- Struct1
   string members                "harbl"(5)
      int asdf                    42

-- Struct2
   string mumburs                "hirrs"(5)
      int fdsa                    -1
`;
    assert((sink.data == st1st2Formatted), '\n' ~ sink.data);

    // Colour
    struct StructName2
    {
        int int_ = 12_345;
        string string_ = "foo";
        bool bool_ = true;
        float float_ = 3.14f;
        double double_ = 99.9;
    }

    version(Colours)
    {
        StructName2 s2;

        sink.clear();
        sink.reserve(256);  // ~239
        sink.formatObjects!(No.printAll, Yes.coloured)(s2);

        assert((sink.data.length > 12), "Empty sink after coloured fill");

        assert(sink.data.contains("-- StructName"));
        assert(sink.data.contains("int_"));
        assert(sink.data.contains("12345"));

        assert(sink.data.contains("string_"));
        assert(sink.data.contains(`"foo"`));

        assert(sink.data.contains("bool_"));
        assert(sink.data.contains("true"));

        assert(sink.data.contains("float_"));
        assert(sink.data.contains("3.14"));

        assert(sink.data.contains("double_"));
        assert(sink.data.contains("99.9"));

        // Adding Settings does nothing
        alias StructName2Settings = StructName2;
        immutable sinkCopy = sink.data.idup;
        StructName2Settings s2o;

        sink.clear();
        sink.formatObjects!(No.printAll, Yes.coloured)(s2o);
        assert((sink.data == sinkCopy), sink.data);
    }
}


// formatObjects
/++
 +  A `string`-returning variant of `formatObjects` that doesn't take an
 +  input range.
 +
 +  This is useful when you just want the object(s) formatted without having to
 +  pass it a sink.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      int foo = 42;
 +      string bar = "arr matey";
 +      float f = 3.14f;
 +      double d = 9.99;
 +  }
 +
 +  Foo foo, bar;
 +
 +  writeln(formatObjects!(Yes.coloured)(foo));
 +  writeln(formatObjects!(No.coloured)(bar));
 +  ---
 +
 +  Params:
 +      coloured = Whether to display in colours or not.
 +      widthArg = The width with which to pad output columns.
 +      things = Variadic list of structs to enumerate and format.
 +/
string formatObjects(Flag!"printAll" printAll = No.printAll,
    Flag!"coloured" coloured = Yes.coloured, uint widthArg = 0, Things...)
    (Things things) @trusted
if ((Things.length > 0) && !isOutputRange!(Things[0], char[]))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(1024);

    sink.formatObjects!(printAll, coloured, widthArg)(things);
    return sink.data;
}

///
unittest
{
    // Rely on the main unittests of the output range version of formatObjects

    struct Struct
    {
        string members;
        int asdf;
    }

    Struct s;
    s.members = "foo";
    s.asdf = 42;

    immutable formatted = formatObjects!(No.printAll, No.coloured)(s);
    assert((formatted ==
`-- Struct
   string members                "foo"(3)
      int asdf                    42
`), '\n' ~ formatted);
}


// scopeguard
/++
 +  Generates a string mixin of *scopeguards*.
 +
 +  This is a convenience function to automate basic
 +  `scope(exit|success|failure)` messages, as well as a custom "entry" message.
 +  Which scope to guard is passed by ORing the states.
 +
 +  Example:
 +  ---
 +  mixin(scopeguard(entry|exit));
 +  ---
 +
 +  Params:
 +      states = Bitmask of which states to guard.
 +      scopeName = Optional scope name to print. If none is supplied, the
 +          current function name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
string scopeguard(const ubyte states = exit, const string scopeName = string.init)
{
    import std.array : Appender;

    Appender!string app;

    string scopeString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    logger.infof("[%2$s] %3$s");
                }
            }.format(state.toLower, state, scopeName);
        }
        else
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    import std.string : indexOf;
                    enum __%2$sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%2$sfunName = __FUNCTION__[(__%2$sdotPos+1)..$];
                    logger.infof("[%%s] %2$s", __%2$sfunName);
                }
            }.format(state.toLower, state);
        }
    }

    string entryString(const string state)
    {
        import std.string : format, toLower;

        if (scopeName.length)
        {
            return
            q{
                logger.infof("[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                import std.string : indexOf;
                enum __%1$sdotPos  = __FUNCTION__.indexOf('.');
                enum __%1$sfunName = __FUNCTION__[(__%1$sdotPos+1)..$];
                logger.infof("[%%s] %1$s", __%1$sfunName);
            }.format(state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}

/++
 +  Bitflags used in combination with the `scopeguard` function, to generate
 +  *scopeguard* mixins.
 +/
enum : ubyte
{
    entry   = 1 << 0,  /// On entry of function.
    exit    = 1 << 1,  /// On exit of function.
    success = 1 << 2,  /// On successful exit of function.
    failure = 1 << 3,  /// On thrown exception or error in function.
}


// getMultipleOf
/++
 +  Given a number, calculate the largest multiple of `n` needed to reach that
 +  number.
 +
 +  It rounds up, and if supplied `Yes.alwaysOneUp` it will always overshoot.
 +  This is good for when calculating format pattern widths.
 +
 +  Example:
 +  ---
 +  immutable width = 16.getMultipleOf(4);
 +  assert(width == 16);
 +  immutable width2 = 16.getMultipleOf!(Yes.oneUp)(4);
 +  assert(width2 == 20);
 +  ---
 +
 +  Params:
 +      oneUp = Whether to always overshoot.
 +      num = Number to reach.
 +      n = Base value to find a multiplier for.
 +
 +  Returns:
 +      The multiple of `n` that reaches and possibly overshoots `num`.
 +/
uint getMultipleOf(Flag!"alwaysOneUp" oneUp = No.alwaysOneUp, Number)
    (const Number num, const int n)
{
    assert((n > 0), "Cannot get multiple of 0 or negatives");
    assert((num >= 0), "Cannot get multiples for a negative number");

    if (num == 0) return 0;

    if (num == n)
    {
        static if (oneUp) return (n * 2);
        else
        {
            return n;
        }
    }

    immutable frac = (num / double(n));
    immutable floor_ = cast(uint)frac;

    static if (oneUp)
    {
        immutable mod = (floor_ + 1);
    }
    else
    {
        immutable mod = (floor_ == frac) ? floor_ : (floor_ + 1);
    }

    return (mod * n);
}

///
unittest
{
    import std.conv : text;

    immutable n1 = 15.getMultipleOf(4);
    assert((n1 == 16), n1.text);

    immutable n2 = 16.getMultipleOf!(Yes.alwaysOneUp)(4);
    assert((n2 == 20), n2.text);

    immutable n3 = 16.getMultipleOf(4);
    assert((n3 == 16), n3.text);
    immutable n4 = 0.getMultipleOf(5);
    assert((n4 == 0), n4.text);

    immutable n5 = 1.getMultipleOf(1);
    assert((n5 == 1), n5.text);

    immutable n6 = 1.getMultipleOf!(Yes.alwaysOneUp)(1);
    assert((n6 == 2), n6.text);
}


@system:


// interruptibleSleep
/++
 +  Sleep in small periods, checking the passed `abort` bool inbetween to see
 +  if we should break and return.
 +
 +  This is useful when a different signal handler has been set up, as triggeing
 +  it won't break sleeps. This way it does, assuming the `abort` bool is the
 +  signal handler one.
 +
 +  Example:
 +  ---
 +  interruptibleSleep(1.seconds, abort);
 +  ---
 +
 +  Params:
 +      dur = Duration to sleep for.
 +      abort = Reference to the bool flag which, if set, means we should
 +          interrupt and return early.
 +/
void interruptibleSleep(const Duration dur, const ref bool abort)
{
    import core.thread : Thread, msecs, seconds;
    import std.algorithm.comparison : min;

    static immutable step = 250.msecs;

    Duration left = dur;

    static immutable nothing = 0.seconds;

    while (left > nothing)
    {
        if (abort) return;

        immutable nextStep = min((left-step), step);

        if (nextStep <= nothing) break;

        Thread.sleep(nextStep);
        left -= step;
    }
}


// Client
/++
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct Client
{
    import kameloso.connection : Connection;
    import kameloso.ircdefs : IRCBot;
    import kameloso.irc : IRCParser;
    import kameloso.plugins.common : IRCPlugin;

    import std.datetime.systime : SysTime;

    // ThrottleValues
    /++
     +  Aggregate of values and state needed to throttle messages without
     +  polluting namespace too much.
     +/
    struct ThrottleValues
    {
        /// Graph constant modifier (inclination, MUST be negative).
        enum k = -1.2;

        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        double increment = 1.0;

        /++
         +  Burst limit; how many messages*increment can be sent initially
         +  before throttling kicks in.
         +/
        double burst = 3.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);
    }

    /// The socket we use to connect to the server.
    Connection conn;

    /++
     +  A runtime array of all plugins. We iterate these when we have finished
     +  parsing an `kameloso.ircdefs.IRCEvent`, and call the relevant event
     +  handlers of each.
     +/
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    long[string] whoisCalls;

    /// Parser instance.
    IRCParser parser;

    /// Values and state needed to throttle sending messages.
    ThrottleValues throttling;

    /++
     +  When this is set by signal handlers, the program should exit. Other
     +  parts of the program will be monitoring it.
     +/
    __gshared bool* abort;

    /// Never copy this.
    @disable this(this);


    // initPlugins
    /++
     +  Resets and *minimally* initialises all plugins.
     +
     +  It only initialises them to the point where they're aware of their
     +  settings, and not far enough to have loaded any resources.
     +
     +  Params:
     +      customSettings = String array of custom settings to apply to plugins
     +          in addition to those read from the configuration file.
     +/
    string[][string] initPlugins(string[] customSettings)
    {
        import kameloso.plugins;
        import kameloso.plugins.common : IRCPluginState;
        import std.concurrency : thisTid;
        import std.datetime.systime : Clock;

        teardownPlugins();

        IRCPluginState state;
        state.bot = parser.bot;
        state.settings = settings;
        state.mainThread = thisTid;
        immutable now = Clock.currTime.toUnixTime;

        plugins.reserve(EnabledPlugins.length + 4);

        // Instantiate all plugin types in the `EnabledPlugins` `AliasSeq` in
        // `kameloso.plugins.package`
        foreach (Plugin; EnabledPlugins)
        {
            plugins ~= new Plugin(state);
        }

        version(Web)
        {
            foreach (WebPlugin; EnabledWebPlugins)
            {
                plugins ~= new WebPlugin(state);
            }
        }

        version(Posix)
        {
            foreach (PosixPlugin; EnabledPosixPlugins)
            {
                plugins ~= new PosixPlugin(state);
            }
        }

        string[][string] allInvalidEntries;

        foreach (plugin; plugins)
        {
            auto theseInvalidEntries = plugin.deserialiseConfigFrom(state.settings.configFile);

            if (theseInvalidEntries.length)
            {
                import kameloso.meld : meldInto;
                theseInvalidEntries.meldInto(allInvalidEntries);
            }

            if (plugin.state.nextPeriodical == 0)
            {
                // Schedule first periodical in an hour for plugins that don't
                // set a timestamp themselves in `initialise`
                plugin.state.nextPeriodical = now + 3600;
            }
        }

        plugins.applyCustomSettings(customSettings);

        return allInvalidEntries;
    }


    // initPluginResources
    /++
     +  Initialises all plugins' resource files.
     +
     +  This merely calls `IRCPlugin.initResources()` on each plugin.
     +/
    void initPluginResources()
    {
        foreach (plugin; plugins)
        {
            plugin.initResources();
        }
    }


    // teardownPlugins
    /++
    +  Tears down all plugins, deinitialising them and having them save their
    +  settings for a clean shutdown.
    +
    +  Think of it as a plugin destructor.
    +/
    void teardownPlugins()
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;

            try
            {
                plugin.teardown();
            }
            catch (ErrnoException e)
            {
                import core.stdc.errno : ENOENT;
                import std.file : exists;
                import std.path : dirName;

                if ((e.errno == ENOENT) && !settings.resourceDirectory.dirName.exists)
                {
                    // The resource directory hasn't been created, don't panic
                }
                else
                {
                    logger.warningf("ErrnoException when tearing down %s: %s",
                        plugin.name, e.msg);
                }
            }
            catch (const Exception e)
            {
                logger.warningf("Exception when tearing down %s: %s", plugin.name, e.msg);
            }
        }

        // Zero out old plugins array
        plugins.length = 0;
    }


    // startPlugins
    /++
    +  *start* all plugins, loading any resources they may want.
    +
    +  This has to happen after `initPlugins` or there will not be any plugins
    +  in the `plugins` array to start.
    +/
    void startPlugins()
    {
        foreach (plugin; plugins)
        {
            plugin.start();
            auto pluginBot = plugin.state.bot;

            if (pluginBot.updated)
            {
                // start changed the bot; propagate
                parser.bot = pluginBot;
                propagateBot(parser.bot);
            }
        }
    }


    // propagateBot
    /++
    +  Takes a bot and passes it out to all plugins.
    +
    +  This is called when a change to the bot has occured and we want to update
    +  all plugins to have an updated copy of it.
    +
    +  Params:
    +      bot = `kameloso.ircdefs.IRCBot` to propagate to all plugins.
    +/
    void propagateBot(IRCBot bot) pure nothrow @nogc @safe
    {
        foreach (plugin; plugins)
        {
            plugin.state.bot = bot;
        }
    }
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, with the
 +  passed colouring.
 +
 +  Example:
 +  ---
 +  printVersionInfo(BashForeground.white);
 +  ---
 +
 +  Params:
 +      colourCode = Bash foreground colour to display the text in.
 +/
void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : writefln, stdout;

    string pre;
    string post;

    version(Colours)
    {
        import kameloso.bash : colour;
        pre = colourCode.colour;
        post = BashForeground.default_.colour;
    }

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);

    version(Cygwin_) stdout.flush();
}


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Example:
 +  ---
 +  Client client;
 +  client.writeConfigurationFile(client.settings.configFile);
 +  ---
 +
 +  Params:
 +      client = Refrence to the current `Client`, with all its settings.
 +      filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref Client client, const string filename)
{
    import kameloso.config : justifiedConfigurationText, serialise, writeToDisk;
    import kameloso.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(1536);  // ~1097

    with (client)
    with (client.parser)
    {
        if (bot.authPassword.length && !bot.authPassword.beginsWith("base64:"))
        {
            bot.authPassword = "base64:" ~ encode64(bot.authPassword);
        }

        sink.serialise(bot, bot.server, settings);

        foreach (plugin; plugins)
        {
            plugin.serialiseConfigInto(sink);
        }

        immutable justified = sink.data.justifiedConfigurationText;
        writeToDisk!(Yes.addBanner)(filename, justified);
    }
}


// Labeled
/++
 +  Labels an item by wrapping it in a struct with an `id` field.
 +
 +  Access to the `thing` is passed on by use of `std.typecons.Proxy`, so this
 +  will transparently act like the original `thing` in most cases. The original
 +  object can be accessed via the `thing` member when it doesn't.
 +/
struct Labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
{
public:
    import std.typecons : Proxy;

    /// The wrapped item.
    Thing thing;

    /// The label applied to the wrapped item.
    Label id;

    /// Create a new `Labeled` struct with the passed `id` identifier.
    this(Thing thing, Label id) pure nothrow @nogc @safe
    {
        this.thing = thing;
        this.id = id;
    }

    static if (disableThis)
    {
        /// Never copy this.
        @disable this(this);
    }

    /// Tranparently proxy all `Thing`-related calls to `thing`.
    alias thing this;
}

///
unittest
{
    struct Foo
    {
        bool b = true;

        bool wefpok() @property
        {
            return false;
        }
    }

    Foo foo;
    Foo bar;

    Labeled!(Foo,int)[] arr;

    arr ~= labeled(foo, 1);
    arr ~= labeled(bar, 2);

    assert(arr[0].id == 1);
    assert(arr[1].id == 2);

    assert(arr[0].b);
    assert(!arr[1].wefpok);
}


// labeled
/++
 +  Convenience function to create a `Labeled` struct while inferring the
 +  template parameters from the runtime arguments.
 +
 +  Example:
 +  ---
 +  Foo foo;
 +  auto namedFoo = labeled(foo, "hello world");
 +
 +  Foo bar;
 +  auto numberedBar = labeled(bar, 42);
 +  ---
 +
 +  Params:
 +      thing = Object to wrap.
 +      label = Label ID to apply to the wrapped item.
 +
 +  Returns:
 +      The passed object, wrapped and labeled with the supplied ID.
 +/
auto labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
    (Thing thing, Label label) pure nothrow @nogc @safe
{
    import std.traits : Unqual;
    return Labeled!(Unqual!Thing, Unqual!Label, disableThis)(thing, label);
}

///
unittest
{
    auto foo = labeled("FOO", "foo");
    assert(is(typeof(foo) == Labeled!(string, string)));

    assert(foo.thing == "FOO");
    assert(foo.id == "foo");
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English)
 +  language.
 +
 +  Write the result to a passed output range `sink`.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = sink.timeSince(duration);
 +  ---
 +
 +  Params:
 +      sink = Output buffer sink to write to.
 +      duration = A period of time.
 +/
void timeSince(Flag!"abbreviate" abbreviate = No.abbreviate, Sink)
    (auto ref Sink sink, const Duration duration) pure
if (isOutputRange!(Sink, string))
{
    import kameloso.string : plurality;
    import std.format : formattedWrite;

    int days, hours, minutes, seconds;
    duration.split!("days", "hours", "minutes", "seconds")(days, hours, minutes, seconds);

    if (days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%dd", days);
        }
        else
        {
            sink.formattedWrite("%d %s", days, days.plurality("day", "days"));
        }
    }

    if (hours)
    {
        static if (abbreviate)
        {
            if (days) sink.put(' ');
            sink.formattedWrite("%dh", hours);
        }
        else
        {
            if (days)
            {
                if (minutes) sink.put(", ");
                else sink.put("and ");
            }
            sink.formattedWrite("%d %s", hours, hours.plurality("hour", "hours"));
        }
    }

    if (minutes)
    {
        static if (abbreviate)
        {
            if (hours) sink.put(' ');
            sink.formattedWrite("%dm", minutes);
        }
        else
        {
            if (hours) sink.put(" and ");
            sink.formattedWrite("%d %s", minutes, minutes.plurality("minute", "minutes"));
        }
    }

    if (!minutes && !hours && !days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%ds", seconds);
        }
        else
        {
            sink.formattedWrite("%d %s", seconds, seconds.plurality("second", "seconds"));
        }
    }
}

///
unittest
{
    import core.time : msecs, seconds;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for formattedWrite < 2.076

    {
        immutable dur = 0.seconds;
        sink.timeSince(dur);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3_141_519_265.msecs;
        sink.timeSince(dur);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3599.seconds;
        sink.timeSince(dur);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English)
 +  language.
 +
 +  Returns the result as a string.
 +
 +  Example:
 +  ---
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = timeSince(duration);
 +  ---
 +
 +  Params:
 +      duration = A period of time.
 +
 +  Returns:
 +      The passed duration expressed in natural English language.
 +/
string timeSince(Flag!"abbreviate" abbreviate = No.abbreviate)(const Duration duration)
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(50);
    sink.timeSince!abbreviate(duration);
    return sink.data;
}

///
unittest
{
    import core.time : msecs, seconds;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }

    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }

    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }

    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
}


// complainAboutInvalidConfigurationEntries
/++
 +  Prints some information about invalid configugration enries to the local
 +  terminal.
 +
 +  Params:
 +      invalidEntries = A `string[][string]` associative array of dynamic
 +          `string[]` arrays, keyed by strings. These contain invalid settings.
 +/
void complainAboutInvalidConfigurationEntries(const string[][string] invalidEntries)
{
    if (!invalidEntries.length) return;

    logger.log("Found invalid configuration entries:");

    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    foreach (immutable section, const sectionEntries; invalidEntries)
    {
        logger.logf(`...under [%s%s%s]: %s%-("%s"%|, %)`,
            infotint, section, logtint, infotint, sectionEntries);
    }

    logger.logf("They are either malformed or no longer in use. " ~
        "Use %s--writeconfig%s to update your configuration file. [%1$s%3$s%2$s]",
        infotint, logtint, settings.configFile);
}


// complainAboutMissingConfiguration
/++
 +  Displays an error if the configuration is *incomplete*, e.g. missing crucial
 +  information.
 +
 +  It assumes such information is missing, and that the check has been done at
 +  the calling site.
 +
 +  Params:
 +      bot = The current `kameloso.ircdefs.IRCBot`.
 +      args = The command-line arguments passed to the program at start.
 +
 +  Returns:
 +      `true` if configuration is complete and nothing needs doing, `false` if
 +      incomplete and the program should exit.
 +/
import kameloso.irc : IRCBot;
void complainAboutMissingConfiguration(const IRCBot bot, const string[] args)
{
    import std.file : exists;
    import std.path : baseName;

    logger.error("No administrators nor channels configured!");

    immutable configFileExists = settings.configFile.exists;
    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    if (configFileExists)
    {
        logger.logf("Edit %s%s%s and make sure it has at least one of the following:",
            infotint, settings.configFile, logtint);
        complainAboutIncompleteConfiguration();
    }
    else
    {
        logger.logf("Use %s%s --writeconfig%s to generate a configuration file.",
            infotint, args[0].baseName, logtint);
    }
}


// complainAboutIncompleteConfiguration
/++
 +  Displays an error on how to complete a minimal configuration file.
 +
 +  It assumes that the bot's `admins` and `homes` are both empty.
 +/
void complainAboutIncompleteConfiguration()
{
    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : colour;
            import kameloso.logger : KamelosoLogger;
            import std.experimental.logger : LogLevel;

            infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
            logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
        }
    }

    logger.logf("...one or more %sadmins%s who get administrative control over the bot.", infotint, logtint);
    logger.logf("...one or more %shomes%s in which to operate.", infotint, logtint);
}


// Next
/++
 +  Enum of flags carrying the meaning of "what to do next".
 +/
enum Next
{
    continue_,     /// Keep doing whatever is being done.
    retry,         /// Halt what's being done and give it another attempt.
    returnSuccess, /// Exit or abort with a positive return value.
    returnFailure, /// Exit or abort with a negative return value.
}


/++
 +  A version identifier that catches non-OSX Posix platforms.
 +
 +  We need it to version code for freedesktop.org-aware environments.
 +/
version(linux)
{
    version = XDG;
}
else version(FreeBSD)
{
    version = XDG;
}


// defaultConfigurationPrefix
/++
 +  Divines the default configuration file directory, depending on what platform
 +  we're currently running.
 +
 +  On Linux it defaults to `$XDG_CONFIG_HOME/kameloso` and falls back to
 +  `~/.config/kameloso` if no `$XDG_CONFIG_HOME` environment variable present.
 +
 +  On MacOS it defaults to `$HOME/Library/Application Support/kameloso`.
 +
 +  On Windows it defaults to `%LOCALAPPDATA%\\Local\\kameloso`.
 +
 +  Returns:
 +      A string path to the default configuration file.
 +/
string defaultConfigurationPrefix() @property
{
    import std.path : buildNormalizedPath;
    import std.process : environment;

    version(XDG)
    {
        import std.path : expandTilde;
        enum defaultDir = "~/.config";
        return buildNormalizedPath(environment.get("XDG_CONFIG_HOME", defaultDir),
            "kameloso").expandTilde;
    }
    else version(OSX)
    {
        return buildNormalizedPath(environment["HOME"], "Library",
            "Application Support", "kameloso");
    }
    else version(Windows)
    {
        // Blindly assume %LOCALAPPDATA% is defined
        return buildNormalizedPath(environment["LOCALAPPDATA"], "kameloso");
    }
    else
    {
        pragma(msg, "Unsupported platform? Cannot divine default config file path.");
        pragma(msg, "Configuration file will be placed in the working directory.");
        return "kameloso.conf";
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    immutable df = defaultConfigurationPrefix;

    version(XDG)
    {
        import std.process : environment;

        environment["XDG_CONFIG_HOME"] = "/tmp";
        immutable dfTmp = defaultConfigurationPrefix;
        assert((dfTmp == "/tmp/kameloso"), dfTmp);

        environment.remove("XDG_CONFIG_HOME");
        immutable dfWithout = defaultConfigurationPrefix;
        assert(dfWithout.endsWith("/.config/kameloso"), dfWithout);
    }
    else version(OSX)
    {
        assert(df.endsWith("Library/Application Support/kameloso"), df);
    }
    else version(Windows)
    {
        assert(df.endsWith("\\Local\\kameloso"), df);
    }
}


// defaultResourcePrefix
/++
 +  Divines the default resource base directory, depending on what platform
 +  we're currently running.
 +
 +  On Posix it defaults to `$XDG_DATA_HOME/kameloso` and falls back to
 +  `~/.local/share/kameloso` if no `XDG_DATA_HOME` environment variable
 +  present.
 +
 +  On Windows it defaults to `%LOCALAPPDATA%\\Local\\kameloso`.
 +
 +  Returns:
 +      A string path to the default resource directory.
 +/
string defaultResourcePrefix() @property
{
    import std.path : buildNormalizedPath;
    import std.process : environment;

    version(XDG)
    {
        import std.path : expandTilde;
        enum defaultDir = "~/.local/share";
        return buildNormalizedPath(environment.get("XDG_DATA_HOME", defaultDir),
            "kameloso").expandTilde;
    }
    else version(OSX)
    {
        return buildNormalizedPath(environment["HOME"], "Library",
            "Application Support", "kameloso");
    }
    else version(Windows)
    {
        // Blindly assume %LOCALAPPDATA% is defined
        return buildNormalizedPath(environment["LOCALAPPDATA"], "kameloso");
    }
    else
    {
        pragma(msg, "Unsupported platform? Cannot divine default resource prefix.");
        pragma(msg, "Resource files will be placed in the working directory.");
        return ".";
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    version(XDG)
    {
        import kameloso.string : beginsWith;
        import std.process : environment;

        environment["XDG_DATA_HOME"] = "/tmp";
        string df = defaultResourcePrefix;
        assert((df == "/tmp/kameloso"), df);

        environment.remove("XDG_DATA_HOME");
        df = defaultResourcePrefix;
        assert(df.beginsWith("/home/") && df.endsWith("/.local/share/kameloso"));
    }
    else version (OSX)
    {
        immutable df = defaultResourcePrefix;
        assert(df.endsWith("Library/Application Support/kameloso"), df);
    }
    else version(Windows)
    {
        immutable df = defaultResourcePrefix;
        assert(df.endsWith("\\Local\\kameloso"), df);
    }
}

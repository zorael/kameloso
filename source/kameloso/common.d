module kameloso.common;

import kameloso.bash : BashForeground;
import kameloso.constants;

import std.datetime.systime : SysTime;
import std.experimental.logger;
import std.meta : allSatisfy;
import std.traits : isType, isArray;
import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;

import std.stdio;

@safe:

version(unittest)
shared static this()
{
    // This is technically before settings have been read...
    logger = new KamelosoLogger;
}


// logger
/++
 +  Instance of a `KamelosoLogger`, providing timestamped and coloured logging.
 +
 +  The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
 +  and `fatal`. It is not thread-safe, so instantiate a thread-local Logger
 +  if threading.
 +/
Logger logger;

/// A local copy of the CoreSettings struct, housing certain runtime settings
CoreSettings settings;

deprecated("Use CoreSettings instead of BaseSettings. " ~
    "This alias will eventually be removed.")
alias BaseSettings = CoreSettings;


// ThreadMessage
/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate functions for each.
 +
 +  ------------
 +  struct ThreadMessage
 +  {
 +      struct Pong {}
 +      struct Sendline {}
 +      struct Quietline {}
 +      struct Quit {}
 +      struct Teardown {}
 +  }
 +  ------------
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server `PONG` event.
    struct Pong {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to verbosely send throttled messages.
    struct Throttleline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}
}


/// UDA conveying that a field is not to be saved in configuration files
struct Unconfigurable {}

/// UDA conveying that a string is an array with this token as separator
struct Separator
{
    /// Separator, can be more than one character
    string token = ",";
}

/// UDA conveying that this member contains sensitive information and should not
/// be printed in clear text; e.g. passwords
struct Hidden {}


// CoreSettings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +
 +  ------------
 +  struct CoreSettings
 +  {
 +      bool monochrome = true;
 +      bool reconnectOnFailure = true;
 +      string configFile = "kameloso.conf";
 +  }
 +  ------------
 +/
struct CoreSettings
{
    version(Windows)
    {
        bool monochrome = true;  /// Logger monochrome setting
    }
    else version(Colours)
    {
        bool monochrome = false;  /// Ditto
    }
    else
    {
        bool monochrome = true;  /// Ditto
    }

    /// Flag denoting whether the program should reconnect after disconnect
    bool reconnectOnFailure = true;

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";  /// Main configuration file
    }
}


// isConfigurableVariable
/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in `kameloso.config` or not.
 +
 +  Currently it does not support static arrays.
 +
 +  Params:
 +      var = alias of variable to examine.
 +/
template isConfigurableVariable(alias var)
{
    static if (!isType!var)
    {
        import std.traits : isSomeFunction;

        alias T = typeof(var);

        enum isConfigurableVariable =
            !isSomeFunction!T &&
            !__traits(isTemplate, T) &&
            !__traits(isAssociativeArray, T) &&
            !__traits(isStaticArray, T);
    }
    else
    {
        enum isConfigurableVariable = false;
    }
}

///
unittest
{
    int i;
    char[] c;
    char[8] c2;
    struct S {}
    class C {}
    enum E { foo }
    E e;

    static assert(isConfigurableVariable!i);
    static assert(isConfigurableVariable!c);
    static assert(!isConfigurableVariable!c2); // should static arrays pass?
    static assert(!isConfigurableVariable!S);
    static assert(!isConfigurableVariable!C);
    static assert(!isConfigurableVariable!E);
    static assert(isConfigurableVariable!e);
}


// printObjects
/++
 +  Prints out struct objects, with all their printable members with all their
 +  printable values.
 +
 +  This is not only convenient for debugging but also usable to print out
 +  current settings and state, where such is kept in structs.
 +
 +  Params:
 +      things = The struct objects to enumerate.
 +
 +  ------------
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
 +  ------------
 +/
void printObjects(uint widthArg = 0, Things...)(Things things) @trusted
{
    // writeln trusts `lockingTextWriter` so we will too.

    version(Colours)
    {
        if (settings.monochrome)
        {
            formatObjectsImpl!(No.coloured, widthArg)
                (stdout.lockingTextWriter, things);
        }
        else
        {
            formatObjectsImpl!(Yes.coloured, widthArg)
                (stdout.lockingTextWriter, things);
        }
    }
    else
    {
        formatObjectsImpl!(No.coloured, widthArg)
            (stdout.lockingTextWriter, things);
    }
}


// printObject
/++
 +  Single-object `printObjects`.
 +
 +  An alias for when there is only one object to print.
 +
 +  Params:
 +      widthArgs = manually specified with of first column in the output
 +      thing = the struct object to enumerate.
 +
 +  ------------
 +  struct Foo
 +  {
 +      int foo;
 +      string bar;
 +      float f;
 +      double d;
 +  }
 +
 +  Foo foo;
 +  printObject(foo);
 +  ------------
 +/
void printObject(uint widthArg = 0, Thing)(Thing thing)
{
    printObjects!widthArg(thing);
}


// formatObjectsColoured
/++
 +  Formats a struct object, with all its printable members with all their
 +  printable values.
 +
 +  This is an implementation template and should not be called directly;
 +  instead use `printObjects(Things...)`.
 +
 +  Params:
 +      coloured = whether to display in colours or not
 +      sink = output range to write to
 +      things = one or more structs to enumerate and format.
 +
 +  ------------
 +  struct Foo
 +  {
 +      int foo;
 +      string bar;
 +      float f;
 +      double d;
 +  }
 +
 +  Foo foo, bar;
 +  Appender!string sink;
 +
 +  sink.formatObjectsColoured!(Yes.coloured)(foo);
 +  sink.formatObjectsColoured!(No.coloured)(bar);
 +  ------------
 +/
void formatObjectsImpl(Flag!"coloured" coloured = Yes.coloured,
    uint widthArg = 0, Sink, Things...)
    (auto ref Sink sink, Things things) @system
{
    import kameloso.bash : BashForeground, colour;
    import kameloso.string : stripSuffix;
    import std.format : format, formattedWrite;
    import std.traits : hasUDA, isSomeFunction;
    import std.typecons : Unqual;

    // workaround formattedWrite taking Appender by value
    version(LDC) sink.put(string.init);

    enum width = !widthArg ? longestMemberName!Things.length : widthArg;

    with (BashForeground)
    foreach (thing; things)
    {
        alias Thing = typeof(thing);
        static if (coloured)
        {
            sink.formattedWrite("%s-- %s\n", white.colour, Unqual!Thing
                .stringof
                .stripSuffix("Settings"));
        }
        else
        {
            sink.formattedWrite("-- %s\n", Unqual!Thing
                .stringof
                .stripSuffix("Settings"));
        }

        foreach (immutable i, member; thing.tupleof)
        {
            static if (!isType!member &&
                       isConfigurableVariable!member &&
                       !hasUDA!(thing.tupleof[i], Hidden) &&
                       !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                import std.traits : isArray, isSomeString;

                alias T = Unqual!(typeof(member));
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (isSomeString!T)
                {
                    static if (coloured)
                    {
                        enum stringPattern = `%s%9s %s%-*s %s"%s"%s(%d)` ~ '\n';
                        sink.formattedWrite(stringPattern,
                            cyan.colour, T.stringof,
                            white.colour, (width + 2), memberstring,
                            lightgreen.colour, member,
                            darkgrey.colour, member.length);
                    }
                    else
                    {
                        //enum stringPattern = "%9s %-*s \"%s\"(%d)\n";
                        enum stringPattern = `%9s %-*s "%s"(%d)` ~ '\n';
                        sink.formattedWrite(stringPattern, T.stringof,
                            (width + 2), memberstring,
                            member, member.length);
                    }
                }
                else static if (isArray!T)
                {
                    static if (coloured)
                    {
                        immutable thisWidth = member.length ?
                            (width + 2) : (width + 4);

                        enum arrayPattern = "%s%9s %s%-*s%s%s%s(%d)\n";
                        sink.formattedWrite(arrayPattern,
                            cyan.colour, T.stringof,
                            white.colour, thisWidth, memberstring,
                            lightgreen.colour, member,
                            darkgrey.colour, member.length);
                    }
                    else
                    {
                        immutable thisWidth = member.length ?
                            (width + 2) : (width + 4);

                        enum arrayPattern = "%9s %-*s%s(%d)\n";
                        sink.formattedWrite(arrayPattern,
                            T.stringof,
                            thisWidth, memberstring,
                            member,
                            member.length);
                    }
                }
                else
                {
                    static if (coloured)
                    {
                        enum normalPattern = "%s%9s %s%-*s  %s%s\n";
                        sink.formattedWrite(normalPattern,
                            cyan.colour, T.stringof,
                            white.colour, (width + 2), memberstring,
                            lightgreen.colour, member);
                    }
                    else
                    {
                        enum normalPattern = "%9s %-*s  %s\n";
                        sink.formattedWrite(normalPattern, T.stringof,
                            (width + 2), memberstring, member);
                    }
                }
            }
        }

        static if (coloured)
        {
            sink.put(default_.colour);
        }

        sink.put('\n');
    }
}

///
@system unittest
{
    import std.array : Appender;

    // Monochrome

    struct StructName
    {
        int i = 12_345;
        string s = "foo";
        bool b = true;
        float f = 3.14f;
        double d = 99.9;
    }

    StructName s;
    Appender!(char[]) sink;

    sink.reserve(128);  // ~119
    sink.formatObjectsImpl!(No.coloured)(s);

    enum structNameSerialised =
`-- StructName
      int i    12345
   string s   "foo"(3)
     bool b    true
    float f    3.14
   double d    99.9

`;
    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Adding Settings does nothing
    alias StructNameSettings = StructName;
    StructNameSettings so;
    sink.clear();
    sink.formatObjectsImpl!(No.coloured)(so);

    assert((sink.data == structNameSerialised), "\n" ~ sink.data);


    // Colour
    import std.string : indexOf;

    struct StructName2
    {
        int int_ = 12_345;
        string string_ = "foo";
        bool bool_ = true;
        float float_ = 3.14f;
        double double_ = 99.9;
    }

    StructName2 s2;

    sink.clear();
    sink.reserve(256);  // ~239
    sink.formatObjectsImpl!(Yes.coloured)(s2);

    assert((sink.data.length > 12), "Empty sink after coloured fill");

    assert(sink.data.indexOf("-- StructName") != -1);
    assert(sink.data.indexOf("int_") != -1);
    assert(sink.data.indexOf("12345") != -1);

    assert(sink.data.indexOf("string_") != -1);
    assert(sink.data.indexOf(`"foo"`) != -1);

    assert(sink.data.indexOf("bool_") != -1);
    assert(sink.data.indexOf("true") != -1);

    assert(sink.data.indexOf("float_") != -1);
    assert(sink.data.indexOf("3.14") != -1);

    assert(sink.data.indexOf("double_") != -1);
    assert(sink.data.indexOf("99.9") != -1);

    // Adding Settings does nothing
    alias StructName2Settings = StructName2;
    immutable sinkCopy = sink.data.idup;
    StructName2Settings s2o;

    sink.clear();
    sink.formatObjectsImpl!(Yes.coloured)(s2o);
    assert((sink.data == sinkCopy), sink.data);
}



// longestMemberName
/++
 +  Gets the name of the longest member in one or more struct/class objects.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Params:
 +      Things = the types to examine and count name lengths
 +/
template longestMemberName(Things...)
if (Things.length > 0)
{
    enum longestMemberName = ()
    {
        import std.traits : hasUDA;

        string longest;

        foreach (T; Things)
        {
            foreach (name; __traits(allMembers, T))
            {
                static if (!isType!(__traits(getMember, T, name)) &&
                    isConfigurableVariable!(__traits(getMember, T, name)) &&
                    !hasUDA!(__traits(getMember, T, name), Hidden) &&
                    !hasUDA!(__traits(getMember, T, name), Unconfigurable))
                {
                    if (name.length > longest.length)
                    {
                        longest = name;
                    }
                }
            }
        }

        return longest;
    }();
}

///
unittest
{
    struct Foo
    {
        string veryLongName;
        int i;
        @Unconfigurable string veryVeryVeryLongNameThatIsInvalid;
        @Hidden float likewiseWayLongerButInvalid;
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unconfigurable
        @Hidden
        long looooooooooooooooooooooong;
    }

    static assert(longestMemberName!Foo == "veryLongName");
    static assert(longestMemberName!Bar == "evenLongerName");
    static assert(longestMemberName!(Foo, Bar) == "evenLongerName");
}


// isOfAssignableType
/++
 +  Eponymous template bool of whether a variable is "assignable"; if it is
 +  an lvalue that isn't protected from being written to.
 +/
template isOfAssignableType(T)
if (isType!T)
{
    import std.traits : isSomeFunction;

    enum isOfAssignableType = isType!T &&
        !isSomeFunction!T &&
        !is(T == const) &&
        !is(T == immutable);
}


/// Ditto
enum isOfAssignableType(alias symbol) = isType!symbol && is(symbol == enum);

///
unittest
{
    struct Foo
    {
        string bar, baz;
    }

    class Bar
    {
        int i;
    }

    void boo(int i) {}

    enum Baz { abc, def, ghi }
    Baz baz;

    assert(isOfAssignableType!int);
    assert(!isOfAssignableType!(const int));
    assert(!isOfAssignableType!(immutable int));
    assert(isOfAssignableType!(string[]));
    assert(isOfAssignableType!Foo);
    assert(isOfAssignableType!Bar);
    assert(!isOfAssignableType!boo);  // room for improvement: @property
    assert(isOfAssignableType!Baz);
    assert(!isOfAssignableType!baz);
    assert(isOfAssignableType!string);
}


// meldInto
/++
 +  Takes two structs and melds them together, making the members a union of
 +  the two.
 +
 +  It only overwrites members that are `typeof(member).init`, so only unset
 +  members get their values overwritten by the melding struct. Supply a
 +  template parameter `Yes.overwrite` to make it overwrite if the melding
 +  struct's member is not `typeof(member).init`.
 +
 +  Params:
 +      overwrite = flag denoting whether the second object should overwrite
 +                  set values in the receiving object.
 +      meldThis = struct to meld (origin).
 +      intoThis = struct to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = No.overwrite, Thing)
    (Thing meldThis, ref Thing intoThis)
if (is(Thing == struct) || is(Thing == class) && !is(intoThis == const) &&
    !is(intoThis == immutable))
{
    if (meldThis == Thing.init)
    {
        // We're merging an .init with something; just return, should be faster
        return;
    }

    foreach (immutable i, ref member; intoThis.tupleof)
    {
        static if (!isType!member)
        {
            alias T = typeof(member);

            static if (is(T == struct) || is(T == class))
            {
                // Recurse
                meldThis.tupleof[i].meldInto(member);
            }
            else static if (isOfAssignableType!T)
            {
                static if (overwrite)
                {
                    static if (is(T == float))
                    {
                        import std.math : isNaN;

                        if (!meldThis.tupleof[i].isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else static if (is(T == bool))
                    {
                        member = meldThis.tupleof[i];
                    }
                    else
                    {
                        if (meldThis.tupleof[i] != T.init)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
                else
                {
                    static if (is(T == float))
                    {
                        import std.math : isNaN;

                        if (member.isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else
                    {
                        /+  This is tricksy for bools. A value of false could be
                            false, or merely unset. If we're not overwriting,
                            let whichever side is true win out? +/

                        if ((member == T.init) ||
                            (member == Thing.init.tupleof[i]))
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
            }
            else
            {
                pragma(msg, T.stringof ~ " is not meldable!");
            }
        }
    }
}

///
unittest
{
    import std.conv : to;

    struct Foo
    {
        string abc;
        string def;
        int i;
        float f;
    }

    Foo f1; // = new Foo;
    f1.abc = "ABC";
    f1.def = "DEF";

    Foo f2; // = new Foo;
    f2.abc = "this won't get copied";
    f2.def = "neither will this";
    f2.i = 42;
    f2.f = 3.14f;

    f2.meldInto(f1);

    with (f1)
    {
        assert((abc == "ABC"), abc);
        assert((def == "DEF"), def);
        assert((i == 42), i.to!string);
        assert((f == 3.14f), f.to!string);
    }

    Foo f3; // new Foo;
    f3.abc = "abc";
    f3.def = "def";
    f3.i = 100_135;
    f3.f = 99.9f;

    Foo f4; // new Foo;
    f4.abc = "OVERWRITTEN";
    f4.def = "OVERWRITTEN TOO";
    f4.i = 0;
    f4.f = 0.1f;

    f4.meldInto!(Yes.overwrite)(f3);

    with (f3)
    {
        assert((abc == "OVERWRITTEN"), abc);
        assert((def == "OVERWRITTEN TOO"), def);
        assert((i == 100_135), i.to!string); // 0 is int.init
        assert((f == 0.1f), f.to!string);
    }

    struct User
    {
        string nickname;
        string alias_;
        string ident;
        string address;
        string login;
        bool special;
    }

    User one;
    with (one)
    {
        nickname = "kameloso";
        ident = "NaN";
        address = "herpderp.net";
        special = false;
    }

    User two;
    with (two)
    {
        nickname = "kameloso^";
        alias_ = "Kameloso";
        address = "asdf.org";
        login = "kamelusu";
        special = true;
    }

    User twoCopy = two;

    one.meldInto!(No.overwrite)(two);
    with (two)
    {
        assert((nickname == "kameloso^"), nickname);
        assert((alias_ == "Kameloso"), alias_);
        assert((ident == "NaN"), ident);
        assert((address == "asdf.org"), address);
        assert((login == "kamelusu"), login);
        assert(special);
    }

    one.meldInto!(Yes.overwrite)(twoCopy);
    with (twoCopy)
    {
        assert((nickname == "kameloso"), nickname);
        assert((alias_ == "Kameloso"), alias_);
        assert((ident == "NaN"), ident);
        assert((address == "herpderp.net"), address);
        assert((login == "kamelusu"), login);
        assert(!special);
    }

    struct EnumThing
    {
        enum Enum { unset, one, two, three }
        Enum enum_;
    }

    EnumThing e1;
    EnumThing e2;
    e2.enum_ = EnumThing.Enum.three;
    assert((e1.enum_ == EnumThing.Enum.init), e1.enum_.to!string);
    e2.meldInto(e1);
    assert((e1.enum_ == EnumThing.Enum.three), e1.enum_.to!string);
}


// meldInto (array)
/++
 +  Takes two arrays and melds them together, making a union of the two.
 +
 +  It only overwrites members that are `T.init`, so only unset
 +  fields get their values overwritten by the melding array. Supply a
 +  template parameter `Yes.overwrite` to make it overwrite if the melding
 +  array's field is not `T.init`.
 +
 +  Params:
 +      overwrite = flag denoting whether the second array should overwrite
 +                  set values in the receiving array.
 +      meldThis = array to meld (origin).
 +      intoThis = array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, Array1, Array2)
    (Array1 meldThis, ref Array2 intoThis)
if (isArray!Array1 && isArray!Array2 && !is(Array2 == const)
    && !is(Array2 == immutable))
{
    assert((intoThis.length >= meldThis.length),
        "Can't meld a larger array into a smaller one");

    foreach (immutable i, val; meldThis)
    {
        if (val == typeof(val).init) continue;

        static if (overwrite)
        {
            intoThis[i] = val;
        }
        else
        {
            if ((val != typeof(val).init) && (intoThis[i] == typeof(intoThis[i]).init))
            {
                intoThis[i] = val;
            }
        }
    }
}

///
unittest
{
    import std.conv : to;
    import std.typecons : Yes, No;

    auto arr1 = [ 123, 0, 789, 0, 456, 0 ];
    auto arr2 = [ 0, 456, 0, 123, 0, 789 ];
    arr1.meldInto!(No.overwrite)(arr2);
    assert((arr2 == [ 123, 456, 789, 123, 456, 789 ]), arr2.to!string);

    auto yarr1 = [ 'Z', char.init, 'Z', char.init, 'Z' ];
    auto yarr2 = [ 'A', 'B', 'C', 'D', 'E', 'F' ];
    yarr1.meldInto!(Yes.overwrite)(yarr2);
    assert((yarr2 == [ 'Z', 'B', 'Z', 'D', 'Z', 'F' ]), yarr2.to!string);
}


// scopeguard
/++
 +  Generates a string mixin of scopeguards.
 +
 +  This is a convenience function to automate basic
 +  `scope(exit|success|failure)` messages, as well as an optional entry
 +  message. Which scope to guard is passed by ORing the states.
 +
 +  Params:
 +      states = Bitmask of which states to guard, see the enum in
 +               `kameloso.constants`.
 +      scopeName = Optional scope name to print. Otherwise the current function
 +                  name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
string scopeguard(ubyte states = exit, string scopeName = string.init)
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
                    logger.info("[%2$s] %3$s");
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
                logger.info("[%s] %s");
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


// KamelosoLogger
/++
 +  Modified `Logger` to print timestamped and coloured logging messages.
 +
 +  It is not thread-safe so instantiate more if you're threading.
 +/
final class KamelosoLogger : Logger
{
    import kameloso.bash : BashForeground, BashFormat, BashReset, colour;
    import std.concurrency : Tid;
    import std.format : formattedWrite;
    import std.array : Appender;

    bool monochrome;  /// Whether to use colours or not in logger output

    /// KamelosoLogger-specific constructor
    this(LogLevel lv = LogLevel.all, bool monochrome = false)
    {
        this.monochrome = monochrome;
        super(lv);
    }

    /// This override is needed or it won't compile
    override void writeLogMsg(ref LogEntry payload) const {}

    /// Outputs the head of a logger message
    protected void beginLogMsg(Sink)(auto ref Sink sink,
        string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @safe
    {
        import std.datetime : DateTime;

        version(Colours)
        {
            if (!monochrome)
            {
                sink.colour(BashForeground.white);
            }
        }

        sink.formattedWrite("[%s] ", (cast(DateTime)timestamp)
            .timeOfDay
            .toString());

        if (monochrome) return;

        version(Colours)
        with (LogLevel)
        with (BashForeground)
        switch (logLevel)
        {
        case trace:
            sink.colour(default_);
            break;

        case info:
            sink.colour(lightgreen);
            break;

        case warning:
            sink.colour(lightred);
            break;

        case error:
            sink.colour(red);
            break;

        case fatal:
            sink.colour(red, BashFormat.blink);
            break;

        default:
            sink.colour(white);
            break;
        }
    }

    /// ditto
    override protected void beginLogMsg(string file, int line, string funcName,
        string prettyFuncName, string moduleName, LogLevel logLevel,
        Tid threadId, SysTime timestamp, Logger logger) @trusted
    {
        return beginLogMsg(stdout.lockingTextWriter, file, line, funcName,
            prettyFuncName, moduleName, logLevel, threadId, timestamp, logger);
    }

    /// Outputs the message part of a logger message; the content
    protected void logMsgPart(Sink)(auto ref Sink sink, const(char)[] msg) @safe
    {
        sink.put(msg);
    }

    /// ditto
    override protected void logMsgPart(const(char)[] msg) @trusted
    {
        if (!msg.length) return;

        return logMsgPart(stdout.lockingTextWriter, msg);
    }

    /// Outputs the tail of a logger message
    protected void finishLogMsg(Sink)(auto ref Sink sink) @safe
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
    override protected void finishLogMsg() @trusted
    {
        finishLogMsg(stdout.lockingTextWriter);

        version(Cygwin)
        {
            stdout.flush();
        }
    }
}

///
unittest
{
    Logger log_ = new KamelosoLogger(LogLevel.all, true);

    log_.log("log: log");
    log_.info("log: info");
    log_.warning("log: warning");
    log_.error("log: error");
    // log_.fatal("log: FATAL");  // crashes the program
    log_.trace("log: trace");

    log_ = new KamelosoLogger(LogLevel.all, false);

    log_.log("log: log");
    log_.info("log: info");
    log_.warning("log: warning");
    log_.error("log: error");
    // log_.fatal("log: FATAL");
    log_.trace("log: trace");
}


// getMultipleOf
/++
 +  Given a number, calculates the largest multiple of `n` needed to reach that
 +  number.
 +
 +  It rounds up, and if supplied `Yes.alwaysOneUp` it will always overshoot.
 +  This is good for when calculating format pattern widths.
 +
 +  Params:
 +      num = the number to reach
 +      n = the value to find a multiplier for
 +/
size_t getMultipleOf(Flag!"alwaysOneUp" oneUp = No.alwaysOneUp, Number)
    (Number num, ptrdiff_t n)
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

    const frac = (num / double(n));
    const floor_ = cast(uint)frac;

    static if (oneUp)
    {
        const mod = (floor_ + 1);
    }
    else
    {
        const mod = (floor_ == frac) ? floor_ : (floor_ + 1);
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


// interruptibleSleep
/++
 +  Sleep in small periods, checking the passed `abort` bool inbetween to see
 +  if we should break and return.
 +
 +  This is useful when a different signal handler has been set up, as triggeing
 +  it won't break sleeps. This way it does, assuming the `abort` bool is the
 +  signal handler one.
 +
 +  Params:
 +      dur = duration to sleep for
 +      abort = bool flag if we should interrupt and return early
 +
 +  ------------
 +  interruptibleSleep(1.seconds, abort);
 +  ------------
 +/
void interruptibleSleep(D)(const D dur, ref bool abort) @system
{
    import core.thread : Thread, msecs, seconds;

    const step = 250.msecs;

    D left = dur;

    while (left > 0.seconds)
    {
        if (abort) return;

        if ((left - step) < 0.seconds)
        {
            Thread.sleep(left);
            break;
        }
        else
        {
            Thread.sleep(step);
            left -= step;
        }
    }
}


// invert
/++
 +  Bash-inverts the colours of a piece of text in a string.
 +/
string invert(Flag!"elaborateBoundary" elaborate = Yes.elaborateBoundary)
    (const string line, const string toInvert)
{
    import kameloso.constants : TerminalToken;
    import kameloso.bash : BashEffect, BashReset;
    import kameloso.string : escaped;
    import std.format : format;
    import std.regex : matchAll, regex, replaceAll;

    immutable inverted = "%c[%dm%s%c[%dm"
        .format(TerminalToken.bashFormat, BashEffect.reverse,
            toInvert, TerminalToken.bashFormat, BashReset.invert);

    static if (elaborate)
    {
        auto engine = toInvert.escaped.format!`\b%s(\b|\W|$)`.regex;
    }
    else
    {
        auto engine = toInvert.escaped.format!`\b%s\b`.regex;
    }

    string replaced = line;

    foreach (hit; line.matchAll(engine))
    {
        replaced = replaced.replaceAll(engine, inverted ~ hit[1]);
    }

    return replaced;
}

///
unittest
{
    immutable inverted1 = "foo kameloso bar".invert("kameloso");
    assert((inverted1 == "foo \033[7mkameloso\033[27m bar"), inverted1);

    immutable inverted2 = "fookameloso bar".invert("kameloso");
    assert((inverted2 == "fookameloso bar"), inverted2);

    immutable inverted3 = "foo kamelosobar".invert("kameloso");
    assert((inverted3 == "foo kamelosobar"), inverted3);

    immutable inverted4 = "foo(kameloso)bar".invert("kameloso");
    assert((inverted4 == "foo(\033[7mkameloso\033[27m)bar"), inverted4);

    immutable inverted5 = "kameloso: 8ball".invert("kameloso");
    assert((inverted5 == "\033[7mkameloso\033[27m: 8ball"), inverted5);

    immutable inverted6 = "Welcome to the freenode Internet Relay Chat Network kameloso^"
        .invert("kameloso^");
    assert((inverted6 == "Welcome to the freenode Internet Relay Chat Network \033[7mkameloso^\033[27m"),
        inverted6);

    immutable inverted7 = "kameloso^: wfwef".invert("kameloso^");
    assert((inverted7 == "\033[7mkameloso^\033[27m: wfwef"), inverted7);

    immutable inverted8 = "[kameloso^]".invert("kameloso^");
    assert((inverted8 == "[\033[7mkameloso^\033[27m]"), inverted8);

    immutable inverted9 = `"kameloso^"`.invert("kameloso^");
    assert((inverted9 == "\"\033[7mkameloso^\033[27m\""), inverted9);
}

@system:


// Kameloso
/++
 +  State needed for the `kameloso` bot, aggregated in a struct for easier
 +  passing by ref.
 +
 +  ------------
 +  struct Kameloso
 +  {
 +      IRCBot bot;
 +      CoreSettings settings;
 +      Connection conn;
 +      IRCPlugin[] plugins;
 +      SysTime[string] whoisCalls;
 +      IRCParser parser;
 +      ubyte today;
 +      ThrottleValues throttling;
 +      __gshared bool abort;
 +
 +      void initPlugins();
 +      void teardownPlugins();
 +      void startPlugins();
 +      void propagateBot(IRCBot);
 +  }
 +  ------------
 +/
struct Kameloso
{
    import kameloso.connection : Connection;
    import kameloso.ircdefs : IRCBot;
    import kameloso.irc : IRCParser;
    import kameloso.plugins.common : IRCPlugin;

    /// Nickname and other IRC variables for the bot.
    IRCBot bot;

    /// Runtime settings for bot behaviour.
    CoreSettings settings;

    /// The socket we use to connect to the server.
    Connection conn;

    /// A runtime array of all plugins. We iterate this when we have an `IRCEvent`
    /// to react to.
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    SysTime[string] whoisCalls;

    /// Parser instance.
    IRCParser parser;

    /// Curent day of the month, so we can track changes in day
    ubyte today;

    /// Values and state needed to throttle sending messages.
    ThrottleValues throttling;

    /// When this is set by signal handlers, the program should exit. Other parts of
    /// the program will be monitoring it.
    __gshared bool abort;

    /// Never copy this.
    @disable this(this);

    // initPlugins
    /++
     +  Resets and *minimally* initialises all plugins.
     +
     +  It only initialises them to the point where they're aware of their settings,
     +  and not far enough to have loaded any resources.
     +/
    void initPlugins()
    {
        import kameloso.plugins;
        import std.concurrency : thisTid;
        import std.datetime.systime : Clock;

        teardownPlugins();

        IRCPluginState state;
        state.bot = bot;
        state.settings = settings;
        state.mainThread = thisTid;
        today = Clock.currTime.day;

        // Zero out old plugins array and allocate room for new ones
        plugins.length = 0;
        plugins.reserve(EnabledPlugins.length + 3);

        // Instantiate all plugin types in the `EnabledPlugins` `AliasSeq` in
        // `kameloso.plugins.package`
        foreach (Plugin; EnabledPlugins)
        {
            plugins ~= new Plugin(state);
        }

        // Add `webtitles` if possible. If it's not being publically imported in
        // `kameloso.plugins.package`, it's not there to instantiate, which is the
        // case when we're not compiling the version `Webtitles`.
        static if (__traits(compiles, new WebtitlesPlugin(IRCPluginState.init)))
        {
            plugins ~= new WebtitlesPlugin(state);
        }

        // Likewise with `pipeline`, except it depends on whether we're on a Posix
        // system or not.
        static if (__traits(compiles, new PipelinePlugin(IRCPluginState.init)))
        {
            plugins ~= new PipelinePlugin(state);
        }

        // `bashquotes` needs `dlang-requests` just like `webtitles` does.
        static if (__traits(compiles, new BashQuotesPlugin(IRCPluginState.init)))
        {
            plugins ~= new BashQuotesPlugin(state);
        }

        foreach (plugin; plugins)
        {
            plugin.loadConfig(state.settings.configFile);
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

        logger.info("Deinitialising plugins");

        foreach (plugin; plugins)
        {
            try plugin.teardown();
            catch (const Exception e)
            {
                logger.error(e.msg);
            }
        }
    }

    // startPlugins
    /++
    +  *start* all plugins, loading any resources they may want.
    +
    +  This has to happen after `initPlugins` or there will not be any plugins in
    +  the `plugin` array to start.
    +/
    void startPlugins()
    {
        if (!plugins.length) return;

        logger.info("Starting plugins");
        foreach (plugin; plugins)
        {
            plugin.start();
            auto yieldedBot = plugin.yieldBot();

            if (yieldedBot != bot)
            {
                // start changed the bot; propagate
                bot = yieldedBot;
                parser.bot = bot;
                propagateBot(bot);
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
    +      bot = IRCBot to propagate.
    +/
    void propagateBot(IRCBot bot)
    {
        foreach (plugin; plugins)
        {
            plugin.newBot(bot);
        }
    }
}


// ThrottleValues
/++
 +  Aggregate of values and state needed to throttle messages without polluting
 +  namespace too much.
 +
 +  ------------
 +  struct ThrottleValues
 +  {
 +      enum k;
 +      SysTime t0;
 +      double m;
 +      double increment;
 +      double burst;
 +  }
 +  ------------
 +/
struct ThrottleValues
{
    /// Graph constant modifier (inclination, MUST be negative)
    enum k = -1.2;

    /// Origo of x-axis (last sent message)
    SysTime t0;

    /// y at t0 (ergo y at x = 0, weight at last sent message)
    double m = 0.0;

    /// Increment to y on sent message
    double increment = 1.0;

    /// Burst limit; how many messages*increment can be sent initially before
    /// throttling kicks in
    double burst = 3.0;

    /// Don't copy this, just keep one instance
    @disable this(this);
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and github URL, with the
 +  passed colouring.
 +
 +  Params:
 +      colourCode = the Bash foreground colour to display the text in.
 +
 +  ------------
 +  printVersionInfo(BashForeground.white);
 +  ------------
 +/
void printVersionInfo(BashForeground colourCode = BashForeground.default_)
{
    import kameloso.bash : colour;
    import kameloso.constants : KamelosoInfo;

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        colourCode.colour,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        BashForeground.default_.colour);
}


// initLogger
/++
 +  Initialises the `KamelosoLogger` logger for use in the whole program.
 +
 +  We pass the `monochrome` setting bool here to control if the logger should
 +  be coloured or not.
 +/
void initLogger(bool monochrome = settings.monochrome)
{
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome);
}

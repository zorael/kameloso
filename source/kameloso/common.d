module kameloso.common;

import kameloso.constants;
import std.typecons : Flag, Yes, No;

/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use string literals
 +  to differentiate between messages and then have big switches inside the catching function,
 +  but with these you can actually have separate functions for each.
 +/
struct ThreadMessage
{
    /// Concurrency message type asking for a to-server PONG event.
    struct Pong {}

    /// Concurrency message type asking for a to-server PING event.
    struct Ping {}

    /// Concurrency message type asking to verbosely send a line to the server.
    struct Sendline {}

    /// Concurrency message type asking to quietly send a line to the server.
    struct Quietline {}

    /// Concurrency message type asking to quit the server and the program.
    struct Quit {}

    /// Concurrency message type asking for WHOIS information on a user.
    struct Whois {}

    /// Concurrency message type asking for a plugin to shut down cleanly.
    struct Teardown {}

    /// Concurrency message type asking for current settings to be saved to disk.
    struct WriteConfig {}
}


/// UDA used for conveying "this field is not to be saved in configuration files"
struct Unconfigurable {}

/// UDA used for conveying "this string is an array with this token as separator"
struct Separator
{
    string token = ",";
}

/// UDA used to convey "this member should not be printed in clear text"
struct Hidden {}


/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct they're nicely gathered and easy to pass around.
 +/
struct Settings
{
    bool joinOnInvite = true;
    bool monochrome = false;
    bool randomNickColours = true;

    string notesFile = "notes.json";
    string quotesFile = "quotes.json";

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";
    }
}


/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in kameloso.config.
 +
 +  Currently it does not support static arrays.
 +/
template isConfigurableVariable(alias var)
{
    import std.traits : isSomeFunction;

    static if (is(typeof(var)))
    {
        alias T = typeof(var);

        enum isConfigurableVariable = !isSomeFunction!T &&
            !__traits(isTemplate, T) &&
            !__traits(isAssociativeArray, T) &&
            !__traits(isStaticArray, T);
    }
    else
    {
        enum isConfigurableVariable = false;
    }
}
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


/++
 +  Prints out a struct object, with all its printable members with all their printable values.
 +  This is not only convenient for deubgging but also usable to print out current settings
 +  and state, where such is kept in structs.
 +
 +  Params:
 +      thing = The struct object to enumerate.
 +/
void printObjects(Things...)(Things things)
{
    version (Colours)
    {
        printObjectsColoured(things);
    }
    else
    {
        printObjectsMonochrome(things);
    }
}


void printObjectsColoured(Things...)(Things things)
{
    import kameloso.config : longestMemberName;

    import std.format : format;
    import std.traits : isSomeFunction, hasUDA;
    import std.typecons : Unqual;

    enum entryPadding = longestMemberName!Things.length;
    enum stringPattern = `%%s%%9s %%s%%-%ds %%s"%%s"%%s(%%d)%%s`.format(entryPadding+2);
    enum normalPattern = `%%s%%9s %%s%%-%ds  %%s%%s%%s`.format(entryPadding+2);

    foreach (thing; things)
    {
        writeln(Foreground.white, "-- ", Unqual!(typeof(thing)).stringof);

        foreach (immutable i, member; thing.tupleof)
        {
            static if (is(typeof(member)) &&
                       isConfigurableVariable!member &&
                       !hasUDA!(thing.tupleof[i], Hidden) &&
                       !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                alias MemberType = Unqual!(typeof(member));
                enum typestring = MemberType.stringof;
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (is(typeof(value) : string))
                {
                    writefln(stringPattern,
                        colourise(Foreground.cyan), typestring,
                        colourise(Foreground.white), memberstring,
                        colourise(Foreground.lightgreen), member,
                        colourise(Foreground.darkgrey), member.length,
                        colourise(Foreground.default_));
                }
                else
                {
                    writefln(normalPattern,
                        colourise(Foreground.cyan), typestring,
                        colourise(Foreground.white), memberstring,
                        colourise(Foreground.lightgreen), member,
                        colourise(Foreground.default_));
                }
            }
        }

        writeln();
    }
}


void printObjectsMonochrome(Things...)(Things things)
{
    import kameloso.config : longestMemberName;

    import std.format : format;
    import std.traits : isSomeFunction, hasUDA;
    import std.typecons : Unqual;
    import std.stdio : realWritefln = writefln, realWriteln = writeln;

    enum entryPadding = longestMemberName!Things.length;
    enum stringPattern = `%%9s %%-%ds "%%s"(%%d)`.format(entryPadding+2);
    enum normalPattern = `%%9s %%-%ds  %%s`.format(entryPadding+2);

    foreach (thing; things)
    {
        realWriteln("-- ", Unqual!(typeof(thing)).stringof);

        foreach (immutable i, member; thing.tupleof)
        {
            static if (is(typeof(member)) &&
                       isConfigurableVariable!member &&
                       !hasUDA!(thing.tupleof[i], Hidden) &&
                       !hasUDA!(thing.tupleof[i], Unconfigurable))
            {
                alias MemberType = Unqual!(typeof(member));
                enum typestring = MemberType.stringof;
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                static if (is(MemberType : string))
                {
                    realWritefln!stringPattern(typestring, memberstring, member, member.length);
                }
                else
                {
                    realWritefln!normalPattern(typestring, memberstring, member);
                }
            }
        }

        realWriteln();
    }
}


// longestMemberName
/++
 +  Gets the name of the longest member in a struct.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Params:
 +      T = the struct type to inspect for member name lengths.
 +/
template longestMemberName(Things...)
{
    enum longestMemberName = ()
    {
        import std.traits : hasUDA;

        string longest;

        foreach (T; Things)
        {
            foreach (name; __traits(allMembers, T))
            {
                static if (is(typeof(__traits(getMember, T, name))) &&
                           isConfigurableVariable!(__traits(getMember, T, name)) &&
                           !hasUDA!(__traits(getMember, T, name), Hidden))
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
unittest
{
    struct Foo
    {
        string veryLongName;
        int i;
    }

    struct Bar
    {
        string evenLongerName;
        float f;
    }

    assert(longestMemberName!Foo == "veryLongName");
    assert(longestMemberName!Bar == "evenLongerName");
    assert(longestMemberName!(Foo, Bar) == "evenLongerName");
}


template isAssignableType(T)
if (!is(typeof(T)))
{
    import std.traits;

    enum bool isAssignableType = isType!T &&
        !isSomeFunction!T &&
        !is(T == const) &&
        !is(T == immutable);
}

template isAssignableType(alias symbol)
{
    import std.traits;

    enum bool isAssignableType = isType!symbol && is(symbol == enum);
}

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

    assert(isAssignableType!int);
    assert(!isAssignableType!(const int));
    assert(!isAssignableType!(immutable int));
    assert(isAssignableType!(string[]));
    assert(isAssignableType!Foo);
    assert(isAssignableType!Bar);
    assert(!isAssignableType!boo);  // room for improvement: @property
    assert(isAssignableType!Baz);
    assert(!isAssignableType!baz);
}


void meldInto(Flag!"overwrite" overwrite = No.overwrite, Thing)
    (Thing meldThis, ref Thing intoThis)
{
    foreach (immutable i, ref member; intoThis.tupleof)
    {
        static if (is(typeof(member)))
        {
            alias MemberType = typeof(member);

            static if (is(MemberType == struct) || is(MemberType == class))
            {
                // Recurse
                meldThis.tupleof[i].meldInto(member);
            }
            else static if (isAssignableType!MemberType)
            {
                static if (overwrite)
                {
                    static if (is(MemberType == float))
                    {
                        import std.math : isNaN;

                        if (!meldThis.tupleof[i].isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else
                    {
                        if (meldThis.tupleof[i] != MemberType.init)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
                else
                {
                    static if (is(MemberType == float))
                    {
                        import std.math : isNaN;

                        if (member.isNaN)
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                    else
                    {
                        if ((member == MemberType.init) || (member == Thing.init.tupleof[i]))
                        {
                            member = meldThis.tupleof[i];
                        }
                    }
                }
            }
        }
    }
}
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
}


// scopeguard
/++
 +  Generates a string mixin of scopeguards. This is a convenience function to automate
 +  basic scope(exit|success|failure) messages, as well as an optional entry message.
 +  Which scope to guard is passed by ORing the states.
 +
 +  Params:
 +      states = Bitmsask of which states to guard, see the enum in kameloso.constants.
 +      scopeName = Optional scope name to print. Otherwise the current function name
 +                  will be used.
 +/
string scopeguard(ubyte states = exit, string scopeName = string.init)
{
    import std.array : Appender;
    Appender!string app;

    string scopeString(const string state)
    {
        import std.string : toLower, format;

        if (scopeName.length)
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    // import std.stdio : writeln;
                    writeln(Foreground.white, "[%2$s] %3$s");
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
                    // import std.stdio  : writefln;
                    import std.string : indexOf;
                    enum __%2$sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%2$sfunName = __FUNCTION__[(__%2$sdotPos+1)..$];
                    writefln(Foreground.white, "[%%s] %2$s", __%2$sfunName);
                }
            }.format(state.toLower, state);
        }
    }

    string entryString(const string state)
    {
        import std.string : toLower, format;

        if (scopeName.length)
        {
            return
            q{
                // import std.stdio : writeln;
                writeln(Foreground.white, "[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                // import std.stdio  : writefln;
                import std.string : indexOf;
                enum __%1$sdotPos  = __FUNCTION__.indexOf('.');
                enum __%1$sfunName = __FUNCTION__[(__%1$sdotPos+1)..$];
                writefln(Foreground.white, "[%%s] %1$s", __%1$sfunName);
            }.format(state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}


enum bool isAColourCode(T) = is(T : Foreground) || is(T : Background) ||
                             is(T : Format) || is(T : Reset);

import std.meta : allSatisfy;

string colourise(Codes...)(Codes codes)
if ((Codes.length > 0) && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

    sink.colourise(codes);
    return sink.data;
}


string colourise(Sink, Codes...)(Sink sink, Codes codes)
if ((Codes.length > 0) && allSatisfy!(isAColourCode, Codes))
{
    sink.put(BashColourToken);
    sink.put('[');

    foreach (const code; codes)
    {
        if (sink.data.length > 2) sink.put(';');

        sink.put(cast(string)code);
    }

    sink.put('m');
    return sink.data;
}


mixin template ColouredWriteln(alias settings)
if (is(typeof(settings) : Settings))
{
    import std.stdio : realWrite = write, realWritefln = writefln, realWriteln = writeln;

    version (Colours)
    {
        pragma(msg, "Version: Colours");

        pragma(inline)
        void writeln(Code, Args...)(Code code, Args args)
        if (isAColourCode!Code)
        {
            if (settings.monochrome) realWriteln(args);
            else
            {
                realWriteln(colourise(code), args, colourise(typeof(code).default_));
            }
        }

        pragma(inline)
        void writeln(Args...)(Args args)
        if (!Args.length || !isAColourCode!(Args[0]))
        {
            realWriteln(args);
        }

        pragma(inline)
        void writefln(Code, Args...)(Code code, string pattern, Args args)
        if (isAColourCode!Code)
        {
            if (settings.monochrome) realWritefln(pattern, args);
            else
            {
                import std.conv : text;

                immutable newPattern = text(colourise(code), pattern, colourise(typeof(code).default_));
                realWritefln(newPattern, args);
            }
        }

        pragma(inline)
        void writefln(Args...)(string pattern, Args args)
        {
            realWritefln(pattern, args);
        }

        pragma(inline)
        void writefln()
        {
            realWriteln();
        }
    }
    else
    {
        pragma(inline)
        void writeln(Code, Args...)(Code code, Args args)
        if (isAColourCode!Code)
        {
            realWriteln(args);
        }

        pragma(inline)
        void writeln(Args...)(Args args)
        if (!Args.length || !isAColourCode!(Args[0]))
        {
            realWriteln(args);
        }

        pragma(inline)
        void writefln(Code, Args...)(Code code, string pattern, Args args)
        if (isAColourCode!Code)
        {
            realWritefln(pattern, args);
        }

        pragma(inline)
        void writefln(Args...)(string pattern, Args args)
        {
            realWritefln(pattern, args);
        }

        pragma(inline)
        void writefln()
        {
            realWriteln();
        }
    }
}

// FIXME: scope creep
mixin ColouredWriteln!(kameloso.main.settings);

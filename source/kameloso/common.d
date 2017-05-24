module kameloso.common;

import kameloso.constants;

import std.typecons : Flag;


/++
 +  Flag denoting whether the program should exit.
 +/
alias Quit = Flag!"quit";


/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use string literals
 +  to differentiate between messages and then have big switches inside the catching function,
 +  but with these you can actually have separate functions for each.
 +/
struct ThreadMessage
{
    struct Pong {}
    struct Ping {}
    struct Sendline {}
    struct Quietline {}
    struct Quit {}
    struct Whois {}
    struct Teardown {}
    struct Status {}
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

struct Settings
{
    bool joinOnInvite = true;
    bool monochrome = false;
    bool randomNickColours = true;
}

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

    static assert(isConfigurableVariable!i);
    static assert(isConfigurableVariable!c);
    static assert(!isConfigurableVariable!c2); // should static arrays pass?
    static assert(!isConfigurableVariable!S);
    static assert(!isConfigurableVariable!C);
}


/++
 +  Prints out a struct object, with all its printable members with all their printable values.
 +  This is not only convenient for deubgging but also usable to print out current settings
 +  and state, where such is kept in structs.
 +
 +  Params:
 +      thing = The struct object to enumerate.
 +      message = A compile-time optional message header to the printed list.
 +      file = source filename iff message provided, defaults to __FILE__.
 +      line = source file linenumber iff message provided, defaults to __LINE__.
 +/
void printObjects(Things...)(Things things)
{
    import kameloso.config : longestMemberName;

    import std.format : format;
    import std.traits : isSomeFunction, hasUDA;
    import std.typecons : Unqual;

    enum entryPadding = longestMemberName!Things.length;
    //enum stringPattern = `%%9s %%-%ds "%%s"(%%d)`.format(entryPadding+2);
    //enum normalPattern = `%%9s %%-%ds  %%s`.format(entryPadding+2);
    enum stringPattern = `%%s%%9s %%s%%-%ds %%s"%%s"%%s(%%d)%%s`.format(entryPadding+2);
    enum normalPattern = `%%s%%9s %%s%%-%ds  %%s%%s%%s`.format(entryPadding+2);

    foreach (thing; things)
    {
        alias T = typeof(thing);

        //writefln(Foreground.white, "-- [%s:%d] %s", __FILE__, __LINE__, T.stringof);
        writeln(Foreground.white, "-- ", Unqual!T.stringof);

        foreach (name; __traits(allMembers, T))
        {
            static if (is(typeof(__traits(getMember, T, name))) &&
                       isConfigurableVariable!(__traits(getMember, T, name)) &&
                       !hasUDA!(__traits(getMember, T, name), Hidden))
            {
                enum typestring = typeof(__traits(getMember, T, name)).stringof;
                const value = __traits(getMember, thing, name);

                static if (is(typeof(value) : string))
                {
                    writefln(stringPattern,
                        colourise(Foreground.cyan), typestring,
                        colourise(Foreground.white), name,
                        colourise(Foreground.lightgreen), value,
                        colourise(Foreground.darkgrey), value.length,
                        colourise(Foreground.default_));
                }
                else
                {
                    writefln(normalPattern,
                        colourise(Foreground.cyan), typestring,
                        colourise(Foreground.white), name,
                        colourise(Foreground.lightgreen), value,
                        colourise(Foreground.default_));
                }
            }
        }

        writeln();
    }
}

deprecated("Use printObjects instead")
alias printObject = printObjects;


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
                scope(%s)
                {
                    // import std.stdio : writeln;
                    writeln(Foreground.white, "[%s] %s");
                }
            }.format(state.toLower, state, scopeName);
        }
        else
        {
            return
            q{
                // scopeguard mixin
                scope(%s)
                {
                    // import std.stdio  : writefln;
                    import std.string : indexOf;
                    enum __%sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%sfunName = __FUNCTION__[(__%sdotPos+1)..$];
                    writefln(Foreground.white, "[%%s] %s", __%sfunName);
                }
            }.format(state.toLower, state, state, state, state, state);
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
                enum __%sdotPos  = __FUNCTION__.indexOf('.');
                enum __%sfunName = __FUNCTION__[(__%sdotPos+1)..$];
                writefln(Foreground.white, "[%%s] %s", __%sfunName);
            }.format(state, state, state, state, state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}


enum bool isAColourCode(T) = is(T : Foreground) || is(T : Background) || is(T : Format) || is(T : Reset);

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

    version(NoColours)
    {
        pragma(msg, "Version: No Colours");

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
    else
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
}

// FIXME: scope creep
mixin ColouredWriteln!(kameloso.main.settings);

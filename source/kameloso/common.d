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
}


/// UDA used for conveying "this field is not to be saved in configuration files"
struct Unconfigurable {}


/// UDA used for conveying "this string is an array with this token as separator"
struct Separator
{
	string token = ",";
}


/++
 +  Helper/syntactic sugar for static if constraints.
 +/
template memberSatisfies(string trait, T, string name) {
	import std.format : format;

	mixin(`enum memberSatisfies = __traits(%s, __traits(getMember, T, "%s"));`
          .format(trait, name));
}

/// Ditto
enum memberSatisfies(alias Template, T, string name) = Template!(__traits(getMember, T, name));

/// Ditto
enum memberIsType(T, string name) = !is(typeof(__traits(getMember, T, name)));


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
void printObject(T)(T thing, string message = string.init,
                    string file = __FILE__, int line = __LINE__)
{
	import std.stdio  : writefln;
    import std.traits : isSomeFunction;

    if (message.length)
    {
        // Optional header
	    writefln("---------- [%s:%d] %s", file, line, message);
    }

	foreach (name; __traits(allMembers, T))
    {
		static if (!memberIsType!(T,name) &&
                   !memberSatisfies!(isSomeFunction,T,name) &&
                   !memberSatisfies!("isTemplate",T,name) &&
                   !memberSatisfies!("isAssociativeArray",T,name) &&
                   !memberSatisfies!("isStaticArray",T,name))
		{
			enum typestring = typeof(__traits(getMember, T, name)).stringof;
			auto value = __traits(getMember, thing, name);

			static if (is(typeof(value) : string))
            {
				writefln(`%8s %-10s "%s"(%d)`, typestring, name, value, value.length);
			}
			else
            {
				writefln("%8s %-11s %s", typestring, name, value);
			}
		}
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
                scope(%s)
                {
                    import std.stdio : writeln;
                    writeln("[%s] %s");
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
                    import std.stdio  : writefln;
                    import std.string : indexOf;
                    enum __%sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%sfunName = __FUNCTION__[(__%sdotPos+1)..$];
                    writefln("[%%s] %s", __%sfunName);
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
                import std.stdio : writeln;
                writeln("[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                import std.stdio  : writefln;
                import std.string : indexOf;
                enum __%sdotPos  = __FUNCTION__.indexOf('.');
                enum __%sfunName = __FUNCTION__[(__%sdotPos+1)..$];
                writefln("[%%s] %s", __%sfunName);
            }.format(state, state, state, state, state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}


string colorise(Codes...)(Codes codes)
if (Codes.length > 0)
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

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

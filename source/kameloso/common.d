module kameloso.common;

import kameloso.constants;

import std.experimental.logger;
import std.meta : allSatisfy;
import std.stdio;
import std.traits : isType, isArray;
import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;

@safe:

Logger logger;

/// A local copy of the Settings struct, housing certain runtime options
Settings settings;

/// UDA used for conveying "this field is not to be saved in configuration files"
struct Unconfigurable {}

/// UDA used for conveying "this string is an array with this token as separator"
struct Separator
{
    string token = ",";
}

/// UDA used to convey "this member should not be printed in clear text"
struct Hidden {}


// Settings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +/
struct Settings
{
    version(Windows)
    {
        bool monochrome = true;
    }
    else version(Colours)
    {
        bool monochrome = false;
    }
    else
    {
        bool monochrome = true;
    }

    bool reconnectOnFailure = true;

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";
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
 +      var = variable to examine.
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


// printObjects
/++
 +  Prints out struct objects, with all their printable members with all their
 +  printable values.
 +
 +  This is not only convenient for deubgging but also usable to print out
 +  current settings and state, where such is kept in structs.
 +
 +  Params:
 +      things = The struct objects to enumerate.
 +/
void printObjects(Things...)(Things things) @trusted
{
    // writeln trusts `lockingTextWriter` so we will too.

    version(Colours)
    {
        if (settings.monochrome)
        {
            formatObjectsImpl!(No.coloured)(stdout.lockingTextWriter, things);
        }
        else
        {
            formatObjectsImpl!(Yes.coloured)(stdout.lockingTextWriter, things);
        }
    }
    else
    {
        formatObjectsImpl!(No.coloured)(stdout.lockingTextWriter, things);
    }
}


// printObject
/++
 +  Single-object `printObjects`.
 +/
void printObject(Thing)(Thing thing)
{
    printObjects(thing);
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
 +/
void formatObjectsImpl(Flag!"coloured" coloured = Yes.coloured, Sink, Things...)
    (auto ref Sink sink, Things things) @system
{
    import kameloso.stringutils : stripSuffix;

    import std.format : format, formattedWrite;
    import std.traits : hasUDA, isSomeFunction;
    import std.typecons : Unqual;

    // workaround formattedWrite taking Appender by value
    version(LDC) sink.put(string.init);

    enum entryPadding = longestMemberName!Things.length;

    with (BashForeground)
    foreach (thing; things)
    {
        alias Thing = typeof(thing);
        static if (coloured)
        {
            sink.formattedWrite("%s-- %s\n", white.colour, Unqual!Thing
                .stringof
                .stripSuffix("Options"));
        }
        else
        {
            sink.formattedWrite("-- %s\n", Unqual!Thing
                .stringof
                .stripSuffix("Options"));
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
                            white.colour, (entryPadding + 2), memberstring,
                            lightgreen.colour, member,
                            darkgrey.colour, member.length);
                    }
                    else
                    {
                        //enum stringPattern = "%9s %-*s \"%s\"(%d)\n";
                        enum stringPattern = `%9s %-*s "%s"(%d)` ~ '\n';
                        sink.formattedWrite(stringPattern, T.stringof,
                            (entryPadding + 2), memberstring,
                            member, member.length);
                    }
                }
                else static if (isArray!T)
                {
                    static if (coloured)
                    {
                        immutable width = member.length ?
                            (entryPadding + 2) : (entryPadding + 4);

                        enum arrayPattern = "%s%9s %s%-*s%s%s%s(%d)\n";
                        sink.formattedWrite(arrayPattern,
                            cyan.colour, T.stringof,
                            white.colour, width, memberstring,
                            lightgreen.colour, member,
                            darkgrey.colour, member.length);
                    }
                    else
                    {
                        immutable width = member.length ?
                            (entryPadding + 2) : (entryPadding + 4);

                        enum arrayPattern = "%9s %-*s%s(%d)\n";
                        sink.formattedWrite(arrayPattern,
                            T.stringof,
                            width, memberstring,
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
                            white.colour, (entryPadding + 2), memberstring,
                            lightgreen.colour, member);
                    }
                    else
                    {
                        enum normalPattern = "%9s %-*s  %s\n";
                        sink.formattedWrite(normalPattern, T.stringof,
                            (entryPadding + 2), memberstring, member);
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


// longestMemberName
/++
 +  Gets the name of the longest member in a struct.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Params:
 +      Things = the types to examine and count name lengths
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
                static if (!isType!(__traits(getMember, T, name)) &&
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


/// Bool of whether a type is a colour code enum
enum isAColourCode(T) = is(T : BashForeground) || is(T : BashBackground) ||
                        is(T : BashFormat) || is(T : BashReset);


// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset` and composes them into a colour code token.
 +
 +  This function creates an `Appender` and fills it with the return value of
 +  `colour(Sink, Codes...)`.
 +
 +  Params:
 +      codes = a variadic list of Bash format codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +/
version(Colours)
string colour(Codes...)(Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    if (settings.monochrome) return string.init;

    import std.array : Appender;

    Appender!string sink;
    sink.reserve(16);

    sink.colour(codes);
    return sink.data;
}
else
/// Dummy colour for when version != Colours
string colour(Codes...)(Codes codes)
{
    return string.init;
}


// colour
/++
 +  Takes a mix of a `BashForeground`, a `BashBackground`, a `BashFormat` and/or
 +  a `BashReset`` and composes them into a colour code token.
 +
 +  This is the composing function that fills its result into an output range.
 +
 +  Params:
 +      codes = a variadic list of Bash format codes.
 +
 +  Returns:
 +      A Bash code sequence of the passed codes.
 +/
version(Colours)
void colour(Sink, Codes...)(auto ref Sink sink, Codes codes)
if (isOutputRange!(Sink,string) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
    sink.put(TerminalToken.bashFormat);
    sink.put('[');

    uint numCodes;

    foreach (const code; codes)
    {
        import std.conv : to;

        if (++numCodes > 1) sink.put(';');

        sink.put((cast(size_t)code).to!string);
    }

    sink.put('m');
}

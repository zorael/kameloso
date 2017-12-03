module kameloso.common;

import kameloso.constants;

import std.experimental.logger;
import std.meta : allSatisfy;
import std.stdio;
import std.traits : isType, isArray;
import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;

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

/// A local copy of the Settings struct, housing certain runtime options
Settings settings;


// ThreadMessage
/++
 +  Aggregate of thread message types.
 +
 +  This is a way to make concurrency message passing easier. You could use
 +  string literals to differentiate between messages and then have big
 +  switches inside the catching function, but with these you can actually
 +  have separate functions for each.
 +/
struct ThreadMessage
{
    struct Sendline {}
    struct Quit {}
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
if (is(Thing == struct) || is(Thing == class) && !is(intoThis == const)
    && !is(intoThis == immutable))
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
version(none)
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


// scopeguard
/++
 +  Generates a string mixin of scopeguards. This is a convenience function
 +  to automate basic `scope(exit|success|failure)` messages, as well as an
 +  optional entry message. Which scope to guard is passed by ORing the states.
 +
 +  Params:
 +      states = Bitmask of which states to guard, see the enum in `kameloso.constants`.
 +      scopeName = Optional scope name to print. Otherwise the current function
 +                  name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
version(none)
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
/*version(Colours)
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
else*/
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
void colour(Sink, Codes...)(auto ref Sink sink, const Codes codes)
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

version(Colours)
string colour(Codes...)(const string text, const Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(text.length + 15);

    sink.colour(codes);
    sink.put(text);
    sink.colour(BashReset.all);
    return sink.data;
}


// normaliseColours
/++
 +  Takes a colour and, if it deems it is too dark to see on a black terminal
 +  background, makes it brighter.
 +
 +  Future improvements include reverse logic; making fonts darker to improve
 +  readability on bright background. The parameters are passed by `ref` and as
 +  such nothing is returned.
 +
 +  Params:
 +      r = red
 +      g = green
 +      b = blue
 +/
version(Colours)
void normaliseColours(ref uint r, ref uint g, ref uint b)
{
    enum pureBlackReplacement = 150;
    enum incrementWhenOnlyOneColour = 100;
    enum tooDarkValueThreshold = 75;
    enum highColourHighlight = 95;
    enum lowColourIncrement = 75;

    // Sanity check
    if (r > 255) r = 255;
    if (g > 255) g = 255;
    if (b > 255) b = 255;

    if ((r + g + b) == 0)
    {
        // Specialcase pure black, set to grey and return
        r = pureBlackReplacement;
        b = pureBlackReplacement;
        g = pureBlackReplacement;

        return;
    }

    if ((r + g + b) == 255)
    {
        // Precisely one colour is saturated with the rest at 0 (probably)
        // Make it more bland, can be difficult to see otherwise
        r += incrementWhenOnlyOneColour;
        b += incrementWhenOnlyOneColour;
        g += incrementWhenOnlyOneColour;

        // Sanity check
        if (r > 255) r = 255;
        if (g > 255) g = 255;
        if (b > 255) b = 255;

        return;
    }

    int rDark, gDark, bDark;

    rDark = (r < tooDarkValueThreshold);
    gDark = (g < tooDarkValueThreshold);
    bDark = (b < tooDarkValueThreshold);

    if ((rDark + gDark +bDark) > 1)
    {
        // At least two colours were below the threshold (75)

        // Highlight the colours above the threshold
        r += (rDark == 0) * highColourHighlight;
        b += (bDark == 0) * highColourHighlight;
        g += (gDark == 0) * highColourHighlight;

        // Raise all colours to make it brighter
        r += lowColourIncrement;
        b += lowColourIncrement;
        g += lowColourIncrement;

        // Sanity check
        if (r >= 255) r = 255;
        if (g >= 255) g = 255;
        if (b >= 255) b = 255;
    }
}


// truecolour
/++
 +  Produces a Bash colour token for the colour passed, expressed in terms of
 +  red, green and blue.
 +
 +  Params:
 +      normalise = normalise colours so that they aren't too dark.
 +      sink = output range to write the final code into
 +      r = red
 +      g = green
 +      b = blue
 +/
void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b)
if (isOutputRange!(Sink, string))
{
    // noop
}

// KamelosoLogger
/++
 +  Modified `Logger` to print timestamped and coloured logging messages.
 +/
final class KamelosoLogger : Logger
{
    import std.concurrency : Tid;
    import std.datetime;
    import std.format : formattedWrite;
    import std.array : Appender;

    bool monochrome;

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

    double frac = (num / double(n));
    uint floor_ = cast(uint)frac;

    static if (oneUp) uint mod = (floor_ + 1);
    else
    {
        uint mod = (floor_ == frac) ? floor_ : (floor_ + 1);
    }

    return (mod * n);
}

void interruptibleSleep(D)(const D dur, ref bool abort) @system
{
    import core.thread;

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

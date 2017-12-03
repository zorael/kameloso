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

Settings settings;

struct ThreadMessage
{
    struct Sendline {}
    struct Quit {}
}

struct Unconfigurable {}

struct Separator
{
    string token = ",";
}

struct Hidden {}

struct Settings
{
    bool monochrome = true;

    bool reconnectOnFailure = true;

    @Unconfigurable
    {
        @Hidden
        string configFile = "kameloso.conf";
    }
}

template isConfigurableVariable(alias var)
{
    enum isConfigurableVariable = false;
}

template longestMemberName(Things...)
{
    enum longestMemberName = ()
    {
        return "foo";
    }();
}

template isOfAssignableType(T)
if (isType!T)
{
    enum isOfAssignableType = false;
}


enum isOfAssignableType(alias symbol) = false;


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
        }
    }
}


/// Bool of whether a type is a colour code enum
enum isAColourCode(T) = is(T : BashForeground) || is(T : BashBackground) ||
                        is(T : BashFormat) || is(T : BashReset);

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


void truecolour(Flag!"normalise" normalise = Yes.normalise, Sink)
    (auto ref Sink sink, uint r, uint g, uint b)
if (isOutputRange!(Sink, string))
{
    // noop
}

alias KamelosoLogger = Logger;

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

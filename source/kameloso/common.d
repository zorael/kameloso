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


enum isAColourCode(T) = false;

string colour(Codes...)(Codes codes)
{
    return string.init;
}

version(Colours)
void colour(Sink, Codes...)(auto ref Sink sink, const Codes codes)
if (isOutputRange!(Sink,string) && Codes.length && allSatisfy!(isAColourCode, Codes))
{
}

version(Colours)
string colour(Codes...)(const string text, const Codes codes)
if (Codes.length && allSatisfy!(isAColourCode, Codes))
{
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
    return 1;
}

void interruptibleSleep(D)(const D dur, ref bool abort) @system
{
}

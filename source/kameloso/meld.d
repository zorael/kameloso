/++
 +  This module contains the `meldInto` functions; functions that take two
 +  structs and combines them, creating a resulting struct with values from both
 +  parent structs. Array and associative array variants exist too.
 +/
module kameloso.meld;

import std.typecons : Flag, No, Yes;
import std.traits : isArray, isAssociativeArray;

// meldInto
/++
 +  Takes two structs and melds them together, making the members a union of
 +  the two.
 +
 +  It only overwrites members in `intoThis` that are `typeof(member).init`, so
 +  only unset members get their values overwritten by the melding struct.
 +  Supply a template parameter `Yes.overwrite` to make it always overwrite,
    except if the melding struct's member is `typeof(member).init`.
 +
 +  Example:
 +  ------------
 +  struct Foo
 +  {
 +      string abc;
 +      int def;
 +  }
 +
 +  Foo foo, bar;
 +  foo.abc = "from foo"
 +  bar.def = 42;
 +  foo.meldInto(bar);
 +
 +  assert(bar.abc == "from foo");
 +  assert(bar.def == 42);
 +  ------------
 +
 +  Params:
 +      overwrite = Whether the source object should overwrite set (non-`init`)
 +          values in the receiving object.
 +      meldThis = Struct to meld (source).
 +      intoThis = Reference to struct to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = No.overwrite, Thing)
    (Thing meldThis, ref Thing intoThis) pure nothrow @nogc
if (is(Thing == struct) || is(Thing == class) && !is(intoThis == const) &&
    !is(intoThis == immutable))
{
    import kameloso.traits : isOfAssignableType;
    import std.traits : isType;

    if (meldThis == Thing.init)
    {
        // We're merging an .init with something

        static if (!overwrite)
        {
            // No value will get melded at all, so just return
            return;
        }
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
                    else static if (is(T == enum))
                    {
                        if (meldThis.tupleof[i] > member)
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
 +  Example:
 +  ------------
 +  int[] arr1 = [ 1, 2, 3, 0, 0, 0 ];
 +  int[] arr2 = [ 0, 0, 0, 4, 5, 6 ];
 +  arr1.meldInto!(No.overwrite)(arr2);
 +
 +  assert(arr2 == [ 1, 2, 3, 4, 5, 6 ]);
 +  ------------
 +
 +  Params:
 +      overwrite = Whether the source array should overwrite set (non-`init`)
 +          values in the receiving array.
 +      meldThis = Array to meld (source).
 +      intoThis = Reference to the array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, Array1, Array2)
    (Array1 meldThis, ref Array2 intoThis) pure nothrow @nogc
if (isArray!Array1 && isArray!Array2 && !is(Array2 == const)
    && !is(Array2 == immutable))
{
    assert((intoThis.length >= meldThis.length), "Can't meld a larger array into a smaller one");

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



// meldInto
/++
 +  Takes two associative arrays and melds them together, making a union of the
 +  two.
 +
 +  This is largely the same as the array-version `meldInto` but doesn't need
 +  the extensive template constraints it employs, so it might as well be kept
 +  separate.
 +
 +  Example:
 +  ------------
 +  int[string] aa1 = [ "abc" : 42, "def" : -1 ];
 +  int[string] aa2 = [ "ghi" : 10, "jkl" : 7 ];
 +  arr1.meldInto(arr2);
 +
 +  assert("abc" in aa2);
 +  assert("def" in aa2);
 +  assert("ghi" in aa2);
 +  assert("jkl" in aa2);
 +  ------------
 +
 +  Params:
 +      overwrite = Whether the source associative array should overwrite set
 +          (non-`init`) values in the receiving object.
 +      meldThis = Associative array to meld (source).
 +      intoThis = Reference to the associative array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, AA)
    (AA meldThis, ref AA intoThis) pure
if (isAssociativeArray!AA)
{
    foreach (key, val; meldThis)
    {
        static if (overwrite)
        {
            intoThis[key] = val;
        }
        else
        {
            if ((val != typeof(val).init) && (intoThis[key] == typeof(intoThis[i]).init))
            {
                intoThis[i] = val;
            }
        }
    }
}




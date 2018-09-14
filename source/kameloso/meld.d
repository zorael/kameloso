/++
 +  This module contains the `meldInto` functions; functions that take two
 +  structs and combines them, creating a resulting struct with values from both
 +  parent structs. Array and associative array variants exist too.
 +/
module kameloso.meld;

import std.typecons : Flag, No, Yes;
import std.traits : isArray, isAssociativeArray;


// MeldingStrategy
/++
 +  To what extent a source should overwrite a target when melding.
 +/
enum MeldingStrategy
{
    /++
     +  Takes care not to overwrite settings when either the source or the
     +  target is `.init`.
     +/
    conservative,

    /++
     +  Only considers the `init`-ness of the source, so as not to overwrite
     +  things with empty strings, but otherwise always considers the source to
     +  trump the target.
     +/
    aggressive,

    /++
     +  works like aggressive but also always overwrites bools, regardless o
     +  falseness.
     +/
    overwriting,
}


// meldInto
/++
 +  Takes two structs or classes of the same type and melds them together,
 +  making the members a union of the two.
 +
 +  In the case of classes it only overwrites members in `intoThis` that are
 +  `typeof(member).init`, so only unset members get their values overwritten by
 +  the melding class. It also does not work with static members.
 +
 +  In the case of structs it also overwrites members that still have their
 +  default values, in cases where such is applicable.
 +
 +  Supply a template parameter `Yes.overwrite` to make it always overwrite,
    except if the melding struct's member is `typeof(member).init`.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      string abc;
 +      int def;
 +      bool b = true;
 +  }
 +
 +  Foo foo, bar;
 +  foo.abc = "from foo"
 +  foo.b = false;
 +  bar.def = 42;
 +  foo.meldInto(bar);
 +
 +  assert(bar.abc == "from foo");
 +  assert(bar.def == 42);
 +  assert(!bar.b);  // false overwrote default value true
 +  ---
 +
 +  Params:
 +      strategy = To what extent the source object should overwrite set
 +          (non-`init`) values in the receiving object.
 +      meldThis = Struct to meld (source).
 +      intoThis = Reference to struct to meld (target).
 +/
void meldInto(MeldingStrategy strategy = MeldingStrategy.conservative, Thing)
    (Thing meldThis, ref Thing intoThis)
if (is(Thing == struct) || is(Thing == class) && !is(intoThis == const) &&
    !is(intoThis == immutable))
{
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
 +  ---
 +  int[] arr1 = [ 1, 2, 3, 0, 0, 0 ];
 +  int[] arr2 = [ 0, 0, 0, 4, 5, 6 ];
 +  arr1.meldInto!(No.overwrite)(arr2);
 +
 +  assert(arr2 == [ 1, 2, 3, 4, 5, 6 ]);
 +  ---
 +
 +  Params:
 +      overwrite = Whether the source array should overwrite set (non-`init`)
 +          values in the receiving array.
 +      meldThis = Array to meld (source).
 +      intoThis = Reference to the array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, Array1, Array2)
    (Array1 meldThis, ref Array2 intoThis) pure nothrow
if (isArray!Array1 && isArray!Array2 && !is(Array2 == const)
    && !is(Array2 == immutable))
{
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
 +  ---
 +  int[string] aa1 = [ "abc" : 42, "def" : -1 ];
 +  int[string] aa2 = [ "ghi" : 10, "jkl" : 7 ];
 +  arr1.meldInto(arr2);
 +
 +  assert("abc" in aa2);
 +  assert("def" in aa2);
 +  assert("ghi" in aa2);
 +  assert("jkl" in aa2);
 +  ---
 +
 +  Params:
 +      overwrite = Whether the source associative array should overwrite set
 +          (non-`init`) values in the receiving object.
 +      meldThis = Associative array to meld (source).
 +      intoThis = Reference to the associative array to meld (target).
 +/
void meldInto(Flag!"overwrite" overwrite = Yes.overwrite, AA)(AA meldThis, ref AA intoThis) pure
if (isAssociativeArray!AA)
{
}

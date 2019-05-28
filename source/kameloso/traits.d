/++
 +  Various compile-time traits used throughout the program.
 +/
module kameloso.traits;

import kameloso.uda;

import std.traits : Unqual, isArray, isAssociativeArray, isType;
import std.typecons : Flag, No, Yes;


// isConfigurableVariable
/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in `kameloso.config` or not.
 +
 +  Currently it does not support static arrays.
 +
 +  Params:
 +      var = Alias of variable to introspect.
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
            //!__traits(isAssociativeArray, T) &&
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


// longestMemberNameImpl
/++
 +  Gets the name of the longest member in one or more struct/class objects.
 +
 +  This is used for formatting terminal output of objects, so that columns line up.
 +
 +  Params:
 +      all = Flag of whether to display all members, or only those not hidden.
 +      Things = Types to introspect and count member name lengths of.
 +/
private template longestMemberNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberNameImpl = ()
    {
        import std.meta : Alias;
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            foreach (immutable name; __traits(allMembers, Thing))
            {
                alias member = Alias!(__traits(getMember, Thing, name));

                static if (!isType!member &&
                    isConfigurableVariable!member &&
                    !hasUDA!(member, Hidden) &&
                    (all || !hasUDA!(member, Unconfigurable)))
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


// longestMemberName
/++
 +  Gets the name of the longest configurable member in one or more structs.
 +
 +  This is used for formatting terminal output of configuration files, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to introspect and count member name lengths of.
 +/
alias longestMemberName(Things...) = longestMemberNameImpl!(No.all, Things);

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


// longestUnconfigurableMemberName
/++
 +  Gets the name of the longest member in one or more structs, including
 +  `kameloso.uda.Unconfigurable` ones.
 +
 +  This is used for formatting terminal output of objects, so that columns line up.
 +
 +  Params:
 +      Things = Types to introspect and count member name lengths of.
 +/
alias longestUnconfigurableMemberName(Things...) = longestMemberNameImpl!(Yes.all, Things);

///
unittest
{
    struct Foo
    {
        string veryLongName;
        int i;
        @Unconfigurable string veryVeryVeryLongNameThatIsValidNow;
        @Hidden float likewiseWayLongerButInvalidddddddddddddddddddddddddddddd;
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unconfigurable
        @Hidden
        long looooooooooooooooooooooong;
    }

    static assert(longestUnconfigurableMemberName!Foo == "veryVeryVeryLongNameThatIsValidNow");
    static assert(longestUnconfigurableMemberName!Bar == "evenLongerName");
    static assert(longestUnconfigurableMemberName!(Foo, Bar) == "veryVeryVeryLongNameThatIsValidNow");
}


// longestMemberTypeNameImpl
/++
 +  Gets the name of the longest type of a member in one or more structs.
 +
 +  This is used for formatting terminal output of objects, so that columns line up.
 +
 +  Params:
 +      all = Whether to consider all members or only those not hidden or unconfigurable.
 +      Things = Types to introspect and count member type name lengths of.
 +/
private template longestMemberTypeNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberTypeNameImpl = ()
    {
        import std.meta : Alias;
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            foreach (immutable i, immutable name; __traits(allMembers, Thing))
            {
                alias member = Alias!(__traits(getMember, Thing, name));

                static if (!isType!member &&
                    isConfigurableVariable!member &&
                    !hasUDA!(member, Hidden) &&
                    (all || !hasUDA!(member, Unconfigurable)))
                {
                    alias T = typeof(__traits(getMember, Thing, name));

                    static if (!isTrulyString!T && (isArray!T || isAssociativeArray!T))
                    {
                        enum typestring = UnqualArray!T.stringof;
                    }
                    else
                    {
                        enum typestring = Unqual!T.stringof;
                    }


                    if (typestring.length > longest.length)
                    {
                        longest = typestring;
                    }
                }
            }
        }

        return longest;
    }();
}


// longestMemberTypeName
/++
 +  Gets the name of the longest type of a member in one or more structs.
 +
 +  This is used for formatting terminal output of configuration files, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to introspect and count member type name lengths of.
 +/
alias longestMemberTypeName(Things...) = longestMemberTypeNameImpl!(No.all, Things);

///
unittest
{
    struct S1
    {
        string s;
        char[][string] css;
        @Unconfigurable string[][string] ss;
    }

    enum longestConfigurable = longestMemberTypeName!S1;
    assert((longestConfigurable == "char[][string]"), longestConfigurable);
}


// longestUnconfigurableMemberTypeName
/++
 +  Gets the name of the longest type of a member in one or more structs.
 +
 +  This is used for formatting terminal output of state objects, so that
 +  columns line up.
 +
 +  Params:
 +      Things = Types to introspect and count member type name lengths of.
 +/
alias longestUnconfigurableMemberTypeName(Things...) = longestMemberTypeNameImpl!(Yes.all, Things);

///
unittest
{
    struct S1
    {
        string s;
        char[][string] css;
        @Unconfigurable string[][string] ss;
    }

    enum longestUnconfigurable = longestUnconfigurableMemberTypeName!S1;
    assert((longestUnconfigurable == "string[][string]"), longestUnconfigurable);
}


// isOfAssignableType
/++
 +  Eponymous template bool of whether or not a variable is "assignable"; if it is
 +  an lvalue that isn't protected from being written to.
 +
 +  Params:
 +      T = Type to introspect.
 +/
template isOfAssignableType(T)
if (isType!T)
{
    import std.traits : isSomeFunction;

    enum isOfAssignableType = isType!T &&
        !isSomeFunction!T &&
        !__traits(isTemplate, T) &&
        !is(T == const) &&
        !is(T == immutable);
}


// isOfAssignableType
/++
 +  Eponymous template bool of whether or not a variable is "assignable"; if it is
 +  an lvalue that isn't protected from being written to.
 +
 +  Overload that takes an alias symbol instead of a normal template parameter.
 +
 +  Params:
 +      symbol = Symbol to introspect.
 +/
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


// isTrulyString
/++
 +  True if a type is `string`, `dstring` or `wstring`; otherwise false.
 +
 +  Does not consider e.g. `char[]` a string, as `std.traits.isSomeString` does.
 +
 +  Params:
 +      S = String type to introspect.
 +/
enum isTrulyString(S) = is(S == string) || is(S == dstring) || is(S == wstring);

///
unittest
{
    assert(isTrulyString!string);
    assert(isTrulyString!dstring);
    assert(isTrulyString!wstring);
    assert(!isTrulyString!(char[]));
    assert(!isTrulyString!(dchar[]));
    assert(!isTrulyString!(wchar[]));
}


// UnqualArray
/++
 +  Given an array of qualified elements, aliases itself to one such of
 +  unqualified elements.
 +
 +  Params:
 +      QualArray = Qualified array type.
 +      QualType = Qualified type, element of `QualArray`.
 +/
template UnqualArray(QualArray : QualType[], QualType)
if (!isAssociativeArray!QualType)
{
    alias UnqualArray = Unqual!QualType[];
}

///
unittest
{
    alias ConstStrings = const(string)[];
    alias UnqualStrings = UnqualArray!ConstStrings;
    static assert(is(UnqualStrings == string[]));

    alias ImmChars = string;
    alias UnqualChars = UnqualArray!ImmChars;
    static assert(is(UnqualChars == char[]));

    alias InoutBools = inout(bool)[];
    alias UnqualBools = UnqualArray!InoutBools;
    static assert(is(UnqualBools == bool[]));

    alias ConstChars = const(char)[];
    alias UnqualChars2 = UnqualArray!ConstChars;
    static assert(is(UnqualChars2 == char[]));
}


// UnqualArray
/++
 +  Given an associative array with elements that have a storage class, aliases
 +  itself to an associative array with elements without the storage classes.
 +
 +  Params:
 +      QualArray = Qualified associative array type.
 +      QualElem = Qualified type, element of `QualArray`.
 +      QualKey = Qualified type, key of `QualArray`.
 +/
template UnqualArray(QualArray : QualElem[QualKey], QualElem, QualKey)
if (!isArray!QualElem)
{
    alias UnqualArray = Unqual!QualElem[Unqual!QualKey];
}

///
unittest
{
    alias ConstStringAA = const(string)[int];
    alias UnqualStringAA = UnqualArray!ConstStringAA;
    static assert (is(UnqualStringAA == string[int]));

    alias ImmIntAA = immutable(int)[char];
    alias UnqualIntAA = UnqualArray!ImmIntAA;
    static assert(is(UnqualIntAA == int[char]));

    alias InoutBoolAA = inout(bool)[long];
    alias UnqualBoolAA = UnqualArray!InoutBoolAA;
    static assert(is(UnqualBoolAA == bool[long]));

    alias ConstCharAA = const(char)[string];
    alias UnqualCharAA = UnqualArray!ConstCharAA;
    static assert(is(UnqualCharAA == char[string]));
}


// UnqualArray
/++
 +  Given an associative array of arrays with a storage class, aliases itself to
 +  an associative array with array elements without the storage classes.
 +
 +  Params:
 +      QualArray = Qualified associative array type.
 +      QualElem = Qualified type, element of `QualArray`.
 +      QualKey = Qualified type, key of `QualArray`.
 +/
template UnqualArray(QualArray : QualElem[QualKey], QualElem, QualKey)
if (isArray!QualElem)
{
    static if (isTrulyString!(Unqual!QualElem))
    {
        alias UnqualArray = Unqual!QualElem[Unqual!QualKey];
    }
    else
    {
        alias UnqualArray = UnqualArray!QualElem[Unqual!QualKey];
    }
}

///
unittest
{
    alias ConstStringArrays = const(string[])[int];
    alias UnqualStringArrays = UnqualArray!ConstStringArrays;
    static assert (is(UnqualStringArrays == string[][int]));

    alias ImmIntArrays = immutable(int[])[char];
    alias UnqualIntArrays = UnqualArray!ImmIntArrays;
    static assert(is(UnqualIntArrays == int[][char]));

    alias InoutBoolArrays = inout(bool)[][long];
    alias UnqualBoolArrays = UnqualArray!InoutBoolArrays;
    static assert(is(UnqualBoolArrays == bool[][long]));

    alias ConstCharArrays = const(char)[][string];
    alias UnqualCharArrays = UnqualArray!ConstCharArrays;
    static assert(is(UnqualCharArrays == char[][string]));
}


// isStruct
/++
 +  Eponymous template that is true if the passed type is a struct.
 +
 +  Used with `std.meta.Filter`, which cannot take `is()` expressions.
 +
 +  Params:
 +      T = Type to introspect.
 +/
enum isStruct(T) = is(T == struct);


// hasElaborateInit
/++
 +  Eponymous template that is true if the passed type has default values to
 +  any of its fields.
 +
 +  Params:
 +      QualT = Qualified struct type to introspect for elaborate .init.
 +/
template hasElaborateInit(QualT)
if (is(QualT == struct))
{
    alias T = Unqual!QualT;

	enum hasElaborateInit = ()
    {
        bool match;

        foreach (immutable memberstring; __traits(allMembers, T))
        {
            import std.meta : Alias;
            import std.traits : isSomeFunction, isType;

            alias member = Alias!(__traits(getMember, T.init, memberstring));
            static if (!isType!member && !isSomeFunction!member && !__traits(isTemplate, member))
            {
                alias memberType = typeof(member);

                static if (is(memberType == float) || is(memberType == double))
                {
                    import std.math : isNaN;
                    match = !member.isNaN;
                }
                else static if (member != memberType.init)
                {
                    match = true;
                }

                if (match) break;
            }
        }

        return match;
    }();
}

///
unittest
{
    struct NoDefaultValues
    {
        string s;
        int i;
        bool b;
        float f;
    }

    struct HasDefaultValues
    {
        string s;
        int i = 42;
        bool b;
        float f;
    }

    struct HasDefaultValuesToo
    {
        string s;
        int i;
        bool b;
        float f = 3.14f;
    }

    struct HasDefaultValuesThree
    {
        string s;
        int i;
        bool b;
        double d = 99.9;
    }

    static assert(!hasElaborateInit!NoDefaultValues);
    static assert(hasElaborateInit!HasDefaultValues);
    static assert(hasElaborateInit!HasDefaultValuesToo);
    static assert(hasElaborateInit!HasDefaultValuesThree);
}


// TakesParams
/++
 +  Given a function and a tuple of types, evaluates whether that function could
 +  be called with that tuple as parameters. Qualifiers like `const` and
 +  `immutable` are skipped, which may make it a poor choice if dealing with
 +  functions that require such arguments.
 +
 +  It is merely syntactic sugar, using `std.meta` and `std.traits` behind the scenes.
 +
 +  Example:
 +  ---
 +  void noParams();
 +  bool boolParam(bool);
 +  string stringParam(string);
 +  float floatParam(float);
 +
 +  static assert(TakesParams!(noParams));
 +  static assert(TakesParams!(boolParam, bool));
 +  static assert(TakesParams!(stringParam, string));
 +  static assert(TakesParams!(floatParam, float));
 +  ---
 +
 +  Params:
 +      fun = Function to evaluate the parameters of.
 +      P = Variadic list of types to compare `fun`'s function parameters with.
 +/
template TakesParams(alias fun, P...)
{
    import std.meta : AliasSeq;
    import std.traits : Parameters, Unqual, staticMap;

    alias FunParams = staticMap!(Unqual, Parameters!fun);
    alias PassedParams = staticMap!(Unqual, P);

    static if (is(FunParams : PassedParams))
    {
        enum TakesParams = true;
    }
    else
    {
        enum TakesParams = false;
    }
}

///
unittest
{
    void foo();
    void foo1(string);
    void foo2(string, int);
    void foo3(bool, bool, bool);

    static assert(TakesParams!(foo));//, AliasSeq!()));
    static assert(TakesParams!(foo1, string));
    static assert(TakesParams!(foo2, string, int));
    static assert(TakesParams!(foo3, bool, bool, bool));

    static assert(!TakesParams!(foo, string));
    static assert(!TakesParams!(foo1, string, int));
    static assert(!TakesParams!(foo2, bool, bool, bool));
}

module kameloso.traits;

import kameloso.uda;

import std.traits : Unqual, isType;


// isConfigurableVariable
/++
 +  Eponymous template bool of whether a variable can be configured via the
 +  functions in `kameloso.config` or not.
 +
 +  Currently it does not support static arrays.
 +
 +  Params:
 +      var = alias of variable to examine.
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


// longestMemberName
/++
 +  Gets the name of the longest member in one or more struct/class objects.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Params:
 +      Things = the types to examine and count name lengths
 +/
template longestMemberName(Things...)
if (Things.length > 0)
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
                    !hasUDA!(__traits(getMember, T, name), Hidden) &&
                    !hasUDA!(__traits(getMember, T, name), Unconfigurable))
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


// UnqualArray
/++
 +  Given an array of qualified elements, aliases itself to one such of
 +  unqualified elements.
 +/
alias UnqualArray(QualArray : QualType[], QualType) = Unqual!QualType[];

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
}


// isStruct
/++
 +  Eponymous template that is true if the passed type is a struct.
 +
 +  Used with `std.meta.Filter`, which cannot take `is()` expressions.
 +/
enum isStruct(T) = is(T == struct);

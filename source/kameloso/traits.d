/++
    Various traits that are too kameloso-specific to be in `lu`.

    They generally deal with lengths of struct member names, used to format
    output and align columns for `kameloso.printing.printObject`.

    More of our homebrewn traits were deemed too generic to be in kameloso and
    were moved to `lu.traits` instead:
    - https://github.com/zorael/lu/blob/master/source/lu/traits.d
 +/
module kameloso.traits;

private:

import lu.traits : isStruct;
import std.meta : allSatisfy;
import std.typecons : Flag, No, Yes;

public:


// longestMemberNameImpl
/++
    Gets the name of the longest member in one or more struct objects.

    This is used for formatting terminal output of objects, so that columns line up.

    Params:
        all = Flag of whether to display all members, or only those not hidden.
        Things = Types to introspect and count member name lengths of.
 +/
private template longestMemberNameImpl(Flag!"all" all, Things...)
if ((Things.length > 0) && allSatisfy!(isStruct, Things))
{
    enum longestMemberNameImpl = ()
    {
        import lu.traits : isAnnotated, isSerialisable;
        import lu.uda : Hidden, Unserialisable;

        string longest;

        foreach (Thing; Things)
        {
            Thing thing;  // need a `this`

            foreach (immutable i, member; thing.tupleof)
            {
                static if (
                    !__traits(isDeprecated, thing.tupleof[i]) &&
                    isSerialisable!(thing.tupleof[i]) &&
                    !isAnnotated!(thing.tupleof[i], Hidden) &&
                    (all || !isAnnotated!(thing.tupleof[i], Unserialisable)))
                {
                    enum name = __traits(identifier, thing.tupleof[i]);

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
    Gets the name of the longest configurable member in one or more structs.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect and count member name lengths of.
 +/
alias longestMemberName(Things...) = longestMemberNameImpl!(No.all, Things);

///
unittest
{
    import lu.uda : Hidden, Unserialisable;

    struct Foo
    {
        string veryLongName;
        int i;
        @Unserialisable string veryVeryVeryLongNameThatIsInvalid;
        @Hidden float likewiseWayLongerButInvalid;
        deprecated bool alsoVeryLongButDeprecated;
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unserialisable
        @Hidden
        long looooooooooooooooooooooong;
    }

    static assert(longestMemberName!Foo == "veryLongName");
    static assert(longestMemberName!Bar == "evenLongerName");
    static assert(longestMemberName!(Foo, Bar) == "evenLongerName");
}


// longestUnserialisableMemberName
/++
    Gets the name of the longest member in one or more structs, including
    `lu.uda.Unserialisable` ones.

    This is used for formatting terminal output of objects, so that columns line up.

    Params:
        Things = Types to introspect and count member name lengths of.
 +/
alias longestUnserialisableMemberName(Things...) = longestMemberNameImpl!(Yes.all, Things);

///
unittest
{
    import lu.uda : Hidden, Unserialisable;

    struct Foo
    {
        string veryLongName;
        int i;
        @Unserialisable string veryVeryVeryLongNameThatIsValidNow;
        @Hidden float likewiseWayLongerButInvalidddddddddddddddddddddddddddddd;
        deprecated bool alsoVeryLongButDeprecated;
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unserialisable
        @Hidden
        long looooooooooooooooooooooong;
    }

    static assert(longestUnserialisableMemberName!Foo == "veryVeryVeryLongNameThatIsValidNow");
    static assert(longestUnserialisableMemberName!Bar == "evenLongerName");
    static assert(longestUnserialisableMemberName!(Foo, Bar) == "veryVeryVeryLongNameThatIsValidNow");
}


// longestMemberTypeNameImpl
/++
    Gets the name of the longest type of a configurable member in one or more structs.

    This is used for formatting terminal output of objects, so that columns line up.

    Params:
        all = Whether to consider all members or only those not hidden or Unserialisable.
        Things = Types to introspect and count member type name lengths of.
 +/
private template longestMemberTypeNameImpl(Flag!"all" all, Things...)
if ((Things.length > 0) && allSatisfy!(isStruct, Things))
{
    enum longestMemberTypeNameImpl = ()
    {
        import lu.traits : isAnnotated, isSerialisable;
        import lu.uda : Hidden, Unserialisable;

        string longest;

        foreach (Thing; Things)
        {
            Thing thing;  // need a `this`

            foreach (immutable i, member; thing.tupleof)
            {
                static if (
                    !__traits(isDeprecated, thing.tupleof[i]) &&
                    isSerialisable!(thing.tupleof[i]) &&
                    !isAnnotated!(thing.tupleof[i], Hidden) &&
                    (all || !isAnnotated!(thing.tupleof[i], Unserialisable)))
                {
                    import std.traits : isArray, isAssociativeArray;

                    alias T = typeof(thing.tupleof[i]);

                    import lu.traits : isTrulyString;

                    static if (!isTrulyString!T && (isArray!T || isAssociativeArray!T))
                    {
                        import lu.traits : UnqualArray;
                        enum typestring = UnqualArray!T.stringof;
                    }
                    else
                    {
                        import std.traits : Unqual;
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
    Gets the name of the longest type of a member in one or more structs.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect and count member type name lengths of.
 +/
alias longestMemberTypeName(Things...) = longestMemberTypeNameImpl!(No.all, Things);

///
unittest
{
    import lu.uda : Unserialisable;

    struct S1
    {
        string s;
        char[][string] css;
        @Unserialisable string[][string] ss;
    }

    enum longestConfigurable = longestMemberTypeName!S1;
    assert((longestConfigurable == "char[][string]"), longestConfigurable);
}


// longestUnserialisableMemberTypeName
/++
    Gets the name of the longest type of a member in one or more structs.

    This is used for formatting terminal output of state objects, so that
    columns line up.

    Params:
        Things = Types to introspect and count member type name lengths of.
 +/
alias longestUnserialisableMemberTypeName(Things...) = longestMemberTypeNameImpl!(Yes.all, Things);

///
unittest
{
    import lu.uda : Unserialisable;

    struct S1
    {
        string s;
        char[][string] css;
        @Unserialisable string[][string] ss;
    }

    enum longestUnserialisable = longestUnserialisableMemberTypeName!S1;
    assert((longestUnserialisable == "string[][string]"), longestUnserialisable);
}

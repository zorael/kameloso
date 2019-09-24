/++
 +  Various traits that are too kameloso-specific to be in `lu`.
 +
 +  They generally deal with lengths of struct/class member names, used to format
 +  output and align columns for `kameloso.printing.printObject`.
 +/
module kameloso.traits;

import lu.traits : isConfigurableVariable;
import lu.uda : Hidden, Unconfigurable;
import std.traits : isArray, isAssociativeArray, isType;
import std.typecons : Flag, No, Yes;


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
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            Thing thing;  // need a `this`

            foreach (immutable i, immutable member; thing.tupleof)
            {
                static if (!__traits(isDeprecated, thing.tupleof[i]) &&
                    !isType!(thing.tupleof[i]) &&
                    isConfigurableVariable!(thing.tupleof[i]) &&
                    !hasUDA!(thing.tupleof[i], Hidden) &&
                    (all || !hasUDA!(thing.tupleof[i], Unconfigurable)))
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
 +  `lu.uda.Unconfigurable` ones.
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
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            Thing thing;  // need a `this`

            foreach (immutable i, immutable member; thing.tupleof)
            {
                static if (!__traits(isDeprecated, thing.tupleof[i]) &&
                    !isType!(thing.tupleof[i]) &&
                    isConfigurableVariable!(thing.tupleof[i]) &&
                    !hasUDA!(thing.tupleof[i], Hidden) &&
                    (all || !hasUDA!(thing.tupleof[i], Unconfigurable)))
                {
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

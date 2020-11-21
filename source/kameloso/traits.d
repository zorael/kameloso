/++
    Various traits that are too kameloso-specific to be in $(REF lu).

    They generally deal with lengths of aggregate member names, used to format
    output and align columns for $(REF kameloso.printing.printObject).

    More of our homebrewn traits were deemed too generic to be in kameloso and
    were moved to $(REF lu.traits) instead.

    See_Also:
        https://github.com/zorael/lu/blob/master/source/lu/traits.d
 +/
module kameloso.traits;

private:

import std.typecons : Flag, No, Yes;

public:


// longestMemberNameImpl
/++
    Gets the name of the longest member in one or more aggregate objects.

    This is used for formatting terminal output of objects, so that columns line up.

    Params:
        all = Flag of whether to display all members, or only those not hidden.
        Things = Types to introspect and count member name lengths of.
 +/
private template longestMemberNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberNameImpl = ()
    {
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA, isAggregateType, isSomeFunction, isType;

        string longest;

        foreach (Thing; Things)
        {
            static if (isAggregateType!Thing)
            {
                foreach (immutable memberstring; __traits(derivedMembers, Thing))
                {
                    static if (
                        (memberstring != "this") &&
                        (memberstring != "__ctor") &&
                        (memberstring != "__dtor") &&
                        !__traits(isDeprecated, __traits(getMember, Thing, memberstring)) &&
                        !isType!(__traits(getMember, Thing, memberstring)) &&
                        !isSomeFunction!(__traits(getMember, Thing, memberstring)) &&
                        !__traits(isTemplate, __traits(getMember, Thing, memberstring)) &&
                        isSerialisable!(__traits(getMember, Thing, memberstring)) &&
                        !hasUDA!(__traits(getMember, Thing, memberstring), Hidden) &&
                        (all || !hasUDA!(__traits(getMember, Thing, memberstring), Unserialisable)))
                    {
                        enum name = __traits(identifier, __traits(getMember, Thing, memberstring));

                        if (name.length > longest.length)
                        {
                            longest = name;
                        }
                    }
                }
            }
            else
            {
                import std.format : format;
                static assert(0, "Non-aggregate type `%s` passed to `longestMemberNameImpl`"
                    .format(Thing.stringof));
            }
        }

        return longest;
    }();
}


// longestMemberName
/++
    Gets the name of the longest configurable member in one or more aggregate types.

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
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
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
    Gets the name of the longest member in one or more aggregate types, including
    $(REF lu.uda.Unserialisable) ones.

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
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
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
    Gets the name of the longest type of a configurable member in one or more aggregate types.

    This is used for formatting terminal output of objects, so that columns line up.

    Params:
        all = Whether to consider all members or only those not hidden or Unserialisable.
        Things = Types to introspect and count member type name lengths of.
 +/
private template longestMemberTypeNameImpl(Flag!"all" all, Things...)
if (Things.length > 0)
{
    enum longestMemberTypeNameImpl = ()
    {
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA, isAggregateType, isSomeFunction, isType;

        string longest;

        foreach (Thing; Things)
        {
            static if (isAggregateType!Thing)
            {
                foreach (immutable memberstring; __traits(derivedMembers, Thing))
                {
                    static if (
                        (memberstring != "this") &&
                        (memberstring != "__ctor") &&
                        (memberstring != "__dtor") &&
                        !__traits(isDeprecated, __traits(getMember, Thing, memberstring)) &&
                        !isType!(__traits(getMember, Thing, memberstring)) &&
                        !isSomeFunction!(__traits(getMember, Thing, memberstring)) &&
                        !__traits(isTemplate, __traits(getMember, Thing, memberstring)) &&
                        isSerialisable!(__traits(getMember, Thing, memberstring)) &&
                        !hasUDA!(__traits(getMember, Thing, memberstring), Hidden) &&
                        (all || !hasUDA!(__traits(getMember, Thing, memberstring), Unserialisable)))
                    {
                        import std.traits : isArray, isAssociativeArray;

                        alias T = typeof(__traits(getMember, Thing, memberstring));

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
            else
            {
                import std.format : format;
                static assert(0, "Non-aggregate type `%s` passed to `longestMemberTypeNameImpl`"
                    .format(Thing.stringof));
            }
        }

        return longest;
    }();
}


// longestMemberTypeName
/++
    Gets the name of the longest type of a member in one or more aggregate types.

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
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
        string foo(string,string,string,string,string,string,string,string);
    }

    enum longestConfigurable = longestMemberTypeName!S1;
    assert((longestConfigurable == "char[][string]"), longestConfigurable);
}


// longestUnserialisableMemberTypeName
/++
    Gets the name of the longest type of a member in one or more aggregate types.

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
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
        string foo(string,string,string,string,string,string,string,string);
    }

    enum longestUnserialisable = longestUnserialisableMemberTypeName!S1;
    assert((longestUnserialisable == "string[][string]"), longestUnserialisable);
}

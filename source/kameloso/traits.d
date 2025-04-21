/++
    Various traits that are too kameloso-specific to be in [lu].

    They generally deal with lengths of aggregate member names, used to format
    output and align columns for [kameloso.prettyprint.prettyprint].

    More of our homebrewn traits were deemed too generic to be in kameloso and
    were moved to [lu.traits] instead.

    See_Also:
        https://github.com/zorael/lu/blob/master/source/lu/traits.d

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.traits;

private:

import std.typecons : Flag, No, Yes;

public:


// memberstringIsThisCtorOrDtor
/++
    Returns whether or not the member name of an aggregate has the special name
    `this`, `__ctor` or `__dtor`.

    CTFEable.

    Params:
        memberstring = Aggregate member string to compare.

    Returns:
        `true` if the member string matches `this`, `__ctor` or `__dtor`;
        `false` if not.
 +/
auto memberstringIsThisCtorOrDtor(const string memberstring) pure @safe nothrow @nogc
{
    return
        (memberstring == "this") ||
        (memberstring == "__ctor") ||
        (memberstring == "__dtor");
}


// memberIsVisibleAndNotDeprecated
/++
    Eponymous template; aliases itself to `true` if the passed member of the
    passed aggregate `Thing` is not `private` and not `deprecated`.

    Params:
        Thing = Some aggregate.
        memberstring = String name of the member of `Thing` that we want to check
            the visibility and deprecationness of.
 +/
template memberIsVisibleAndNotDeprecated(Thing, string memberstring)
{
    import std.traits : isAggregateType, isType;

    static if (!isType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsVisibleAndNotDeprecated` was passed a non-type `%s`";
        enum message = pattern.format(typeof(Thing).stringof);
        static assert(0, message);
    }
    else static if (!isAggregateType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsVisibleAndNotDeprecated` was passed a non-aggregate type `%s`";
        enum message = pattern.format(Thing.stringof);
        static assert(0, message);
    }
    else static if (!memberstring.length)
    {
        import std.format : format;

        enum message = "`memberIsVisibleAndNotDeprecated` was passed an empty member string";
        static assert(0, message);
    }
    else
    {
        /+
            __traits(isDeprecated) before __traits(getVisibility) to gag
            deprecation warnings.

            source/kameloso/traits.d(104,14): Error: argument `char` has no visibility

            Tentatively test __traits(compiles, __traits(getVisibility, ...))
            first to avoid this.
         +/
        static if (
            !__traits(isDeprecated, __traits(getMember, Thing, memberstring)) &&
            __traits(compiles, __traits(getVisibility, __traits(getMember, Thing, memberstring))) &&
            ((__traits(getVisibility, __traits(getMember, Thing, memberstring)) != "private") &&
            (__traits(getVisibility, __traits(getMember, Thing, memberstring)) != "package")))
        {
            enum memberIsVisibleAndNotDeprecated = true;
        }
        else
        {
            enum memberIsVisibleAndNotDeprecated = false;
        }
    }
}

///
unittest
{
    struct Foo
    {
        public int i;
        private bool b;
        package string s;
        deprecated public int di;
    }

    class Bar
    {
        public int i;
        private bool b;
        package string s;
        deprecated public int di;
    }

    static assert( memberIsVisibleAndNotDeprecated!(Foo, "i"));
    static assert(!memberIsVisibleAndNotDeprecated!(Foo, "b"));
    static assert(!memberIsVisibleAndNotDeprecated!(Foo, "s"));
    static assert(!memberIsVisibleAndNotDeprecated!(Foo, "di"));

    static assert( memberIsVisibleAndNotDeprecated!(Bar, "i"));
    static assert(!memberIsVisibleAndNotDeprecated!(Bar, "b"));
    static assert(!memberIsVisibleAndNotDeprecated!(Bar, "s"));
    static assert(!memberIsVisibleAndNotDeprecated!(Bar, "di"));
}


// memberIsMutable
/++
    As the name suggests, aliases itself to `true` if the passed member of the
    passed aggregate `Thing` is mutable, which includes that it's not an enum.

    Params:
        Thing = Some aggregate.
        memberstring = String name of the member of `Thing` that we want to
            determine is a non-enum mutable.
 +/
template memberIsMutable(Thing, string memberstring)
{
    import std.traits : isAggregateType, isMutable, isType;

    static if (!isType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsMutable` was passed a non-type `%s`";
        enum message = pattern.format(typeof(Thing).stringof);
        static assert(0, message);
    }
    else static if (!isAggregateType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsMutable` was passed a non-aggregate type `%s`";
        enum message = pattern.format(Thing.stringof);
        static assert(0, message);
    }
    else static if (!memberstring.length)
    {
        import std.format : format;

        enum message = "`memberIsMutable` was passed an empty member string";
        static assert(0, message);
    }
    else
    {
        enum memberIsMutable =
            isMutable!(typeof(__traits(getMember, Thing, memberstring))) &&
            __traits(compiles, __traits(getMember, Thing, memberstring).offsetof);
    }
}

///
unittest
{
    struct Foo
    {
        int i;
        const bool b;
        immutable string s;
        enum float f = 3.14;
    }

    class Bar
    {
        int i;
        const bool b;
        immutable string s;
        enum float f = 3.14;
    }

    static assert( memberIsMutable!(Foo, "i"));
    static assert(!memberIsMutable!(Foo, "b"));
    static assert(!memberIsMutable!(Foo, "s"));
    static assert(!memberIsMutable!(Foo, "f"));

    static assert( memberIsMutable!(Bar, "i"));
    static assert(!memberIsMutable!(Bar, "b"));
    static assert(!memberIsMutable!(Bar, "s"));
    static assert(!memberIsMutable!(Bar, "f"));
}


// memberIsValue
/++
    Aliases itself to `true` if the passed member of the passed aggregate is a
    value and not a type, a function, a template or an enum.

    Params:
        Thing = Some aggregate.
        memberstring = String name of the member of `Thing` that we want to
            determine is a non-type non-function non-template non-enum value.
 +/
template memberIsValue(Thing, string memberstring)
{
    import std.traits : isAggregateType, isMutable, isSomeFunction, isType;

    static if (!isType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsValue` was passed a non-type `%s`";
        enum message = pattern.format(typeof(Thing).stringof);
        static assert(0, message);
    }
    else static if (!isAggregateType!Thing)
    {
        import std.format : format;

        enum pattern = "`memberIsValue` was passed a non-aggregate type `%s`";
        enum message = pattern.format(Thing.stringof);
        static assert(0, message);
    }
    else static if (!memberstring.length)
    {
        import std.format : format;

        enum message = "`memberIsValue` was passed an empty member string";
        static assert(0, message);
    }
    else
    {
        enum memberIsValue =
            !isType!(__traits(getMember, Thing, memberstring)) &&
            !isSomeFunction!(__traits(getMember, Thing, memberstring)) &&
            !__traits(isTemplate, __traits(getMember, Thing, memberstring)) &&
            !is(__traits(getMember, Thing, memberstring) == enum);
    }
}

///
unittest
{
    struct Foo
    {
        int i;
        void f() {}
        template t(T) {}
        enum E { abc, }
    }

    class Bar
    {
        int i;
        void f() {}
        template t(T) {}
        enum E { abc, }
    }

    static assert( memberIsValue!(Foo, "i"));
    static assert(!memberIsValue!(Foo, "f"));
    static assert(!memberIsValue!(Foo, "t"));
    static assert(!memberIsValue!(Foo, "E"));

    static assert( memberIsValue!(Bar, "i"));
    static assert(!memberIsValue!(Bar, "f"));
    static assert(!memberIsValue!(Bar, "t"));
    static assert(!memberIsValue!(Bar, "E"));
}


// longestMember
/++
    Introspects one or more aggregate types and determines the name of the
    longest member found between them, as well as the name of the longest type.
    Ignores [lu.uda.Unserialisable|Unserialisable] members.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect.
 +/
enum longestMember(Things...) = longestMemberImpl!(No.unserialisable, Things)();

///
unittest
{
    import lu.uda : Hidden, Unserialisable;

    struct Foo
    {
        string veryLongName;
        char[][string] css;
        @Unserialisable string[][string] veryVeryVeryLongNameThatIsInvalid;
        @Hidden float likewiseWayLongerButInvalid;
        deprecated bool alsoVeryLongButDeprecated;
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
        string foo(string,string,string,string,string,string,string,string);
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unserialisable short shoooooooooooooooort;

        @Unserialisable
        @Hidden
        long looooooooooooooooooooooong;
    }

    alias fooLongest = longestMember!Foo;
    static assert((fooLongest.member == "veryLongName"), fooLongest.member);
    static assert((fooLongest.type == "char[][string]"), fooLongest.type);

    alias barLongest = longestMember!Bar;
    static assert((barLongest.member == "evenLongerName"), barLongest.member);
    static assert((barLongest.type == "string"), barLongest.type);

    alias bothLongest = longestMember!(Foo, Bar);
    static assert((bothLongest.member == "evenLongerName"), bothLongest.member);
    static assert((bothLongest.type == "char[][string]"), bothLongest.type);
}


// longestUnserialisableMember
/++
    Introspects one or more aggregate types and determines the name of the
    longest member found between them, as well as the name of the longest type.
    Includes [lu.uda.Unserialisable|Unserialisable] members.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect.
 +/
enum longestUnserialisableMember(Things...) =
    longestMemberImpl!(Yes.unserialisable, Things)();

///
unittest
{
    import lu.uda : Hidden, Unserialisable;

    struct Foo
    {
        string veryLongName;
        char[][string] css;
        @Unserialisable string[][string] veryVeryVeryLongNameThatIsInvalid;
        @Hidden float likewiseWayLongerButInvalid;
        deprecated bool alsoVeryLongButDeprecated;
        void aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa();
        void bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb(T)();
        string foo(string,string,string,string,string,string,string,string);
    }

    struct Bar
    {
        string evenLongerName;
        float f;

        @Unserialisable short shoooooooooooooooort;

        @Unserialisable
        @Hidden
        long looooooooooooooooooooooong;
    }

    alias fooLongest = longestUnserialisableMember!Foo;
    static assert((fooLongest.member == "veryVeryVeryLongNameThatIsInvalid"), fooLongest.member);
    static assert((fooLongest.type == "string[][string]"), fooLongest.type);

    alias barLongest = longestUnserialisableMember!Bar;
    static assert((barLongest.member == "shoooooooooooooooort"), barLongest.member);
    static assert((barLongest.type == "string"), barLongest.type);

    alias bothLongest = longestUnserialisableMember!(Foo, Bar);
    static assert((bothLongest.member == "veryVeryVeryLongNameThatIsInvalid"), bothLongest.member);
    static assert((bothLongest.type == "string[][string]"), bothLongest.type);
}


// longestMemberImpl
/++
    Introspects one or more aggregate types and determines the name of the
    longest member found between them, as well as the name of the longest type.
    Only includes [lu.uda.Unserialisable|Unserialisable] members if `unserialisable`
    is set.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        unserialisable = Whether to consider all members or only those not
            [lu.uda.Unserialisable|Unserialisable].
        Things = Types to introspect.
 +/
private auto longestMemberImpl(Flag!"unserialisable" unserialisable, Things...)()
if (Things.length > 0)  // may as well be a constraint
{
    import std.traits : isAggregateType, isType;

    assert(__ctfe);

    static struct Results
    {
        string member;
        string type;
    }

    Results results;

    foreach (immutable i, Thing; Things)
    {
        static if (!isType!Thing)
        {
            import std.format : format;

            enum pattern = "`longestMemberImpl` was passed a non-type `%s` `%s`";
            enum message = pattern.format(
                typeof(Things[i]).stringof,
                __traits(identifier, Things[i]));
            static assert(0, message);
        }

        static if (!isAggregateType!Thing)
        {
            import std.format : format;

            enum pattern = "`longestNamesImpl` was passed a non-aggregate type `%s`";
            enum message = pattern.format(Things[i].stringof);
            static assert(0, message);
        }

        foreach (immutable memberstring; __traits(derivedMembers, Thing))
        {
            import lu.traits : isSerialisable, udaIndexOf;
            import lu.uda : Hidden, Unserialisable;

            static if (
                !memberstringIsThisCtorOrDtor(memberstring) &&
                memberIsVisibleAndNotDeprecated!(Thing, memberstring) &&
                memberIsValue!(Thing, memberstring) &&
                isSerialisable!(__traits(getMember, Thing, memberstring)) &&
                (udaIndexOf!(__traits(getMember, Thing, memberstring), Hidden) == -1) &&
                (unserialisable ||
                    udaIndexOf!(__traits(getMember, Thing, memberstring), Unserialisable) == -1))
            {
                import lu.traits : isTrulyString;
                import std.traits : isArray, isAssociativeArray;

                alias T = typeof(__traits(getMember, Thing, memberstring));

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

                if (typestring.length > results.type.length)
                {
                    results.type = typestring;
                }

                if (memberstring.length > results.member.length)
                {
                    results.member = memberstring;
                }
            }
        }
    }

    return results;
}

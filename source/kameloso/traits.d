/++
    Various traits that are too kameloso-specific to be in [lu].

    They generally deal with lengths of aggregate member names, used to format
    output and align columns for [kameloso.printing.printObject].

    More of our homebrewn traits were deemed too generic to be in kameloso and
    were moved to [lu.traits] instead.

    See_Also:
        https://github.com/zorael/lu/blob/master/source/lu/traits.d
 +/
module kameloso.traits;

private:

import std.traits : isAggregateType;
import std.typecons : Flag, No, Yes;

public:


// memberIsVisibleAndNotDeprecated
/++
    Eponymous template; aliases itself to `true` if the passed member of the
    passed aggregate `Thing` is not `private` and not `deprecated`.

    Compilers previous to 2.096 need to flip the order of the checks (visibility
    first, deprecations second), whereas it doesn't matter for compilers 2.096
    onwards. If the order isn't flipped though we get deprecation warnings.
    Having it this way means we get the visibility/deprecation check we want on
    all (supported) compiler versions, but regrettably deprecation messages
    on older compilers. Unsure where the breakpoint is.

    Params:
        Thing = Some aggregate.
        memberstring = String name of the member of `Thing` that we want to check
            the visibility and deprecationness of.
 +/
template memberIsVisibleAndNotDeprecated(Thing, string memberstring)
if (isAggregateType!Thing)
{
    static if (__VERSION__ < 2096L)
    {
        static if (
            (memberstring != "this") &&
            (memberstring != "__ctor") &&
            (memberstring != "__dtor") &&
            (__traits(getProtection, __traits(getMember, Thing, memberstring)) != "private") &&
            (__traits(getProtection, __traits(getMember, Thing, memberstring)) != "package") &&
            !__traits(isDeprecated, __traits(getMember, Thing, memberstring)))
        {
            enum memberIsVisibleAndNotDeprecated = true;
        }
        else
        {
            enum memberIsVisibleAndNotDeprecated = false;
        }
    }
    else
    {
        static if (
            (memberstring != "this") &&
            (memberstring != "__ctor") &&
            (memberstring != "__dtor") &&
            !__traits(isDeprecated, __traits(getMember, Thing, memberstring)) &&
            (__traits(getVisibility, __traits(getMember, Thing, memberstring)) != "private") &&
            (__traits(getVisibility, __traits(getMember, Thing, memberstring)) != "package"))
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
if (isAggregateType!Thing)
{
    import std.traits : isMutable;

    enum memberIsMutable =
        isMutable!(typeof(__traits(getMember, Thing, memberstring))) &&
        __traits(compiles, { Thing thing; auto p = &__traits(getMember, thing, memberstring); });
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
if (isAggregateType!Thing)
{
    import std.traits : isSomeFunction, isType;

    enum memberIsValue =
        !isType!(__traits(getMember, Thing, memberstring)) &&
        !isSomeFunction!(__traits(getMember, Thing, memberstring)) &&
        !__traits(isTemplate, __traits(getMember, Thing, memberstring)) &&
        !is(__traits(getMember, Thing, memberstring) == enum);
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
        import std.traits : hasUDA, isAggregateType;

        string longest;

        foreach (Thing; Things)
        {
            static if (isAggregateType!Thing)
            {
                foreach (immutable memberstring; __traits(derivedMembers, Thing))
                {
                    static if (
                        memberIsVisibleAndNotDeprecated!(Thing, memberstring) &&
                        memberIsValue!(Thing, memberstring) &&
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
                enum pattern = "Non-aggregate type `%s` passed to `longestMemberNameImpl`";
                static assert(0, pattern.format(Thing.stringof));
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
    [lu.uda.Unserialisable|Unserialisable] ones.

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
        import std.traits : hasUDA;

        string longest;

        foreach (Thing; Things)
        {
            static if (isAggregateType!Thing)
            {
                foreach (immutable memberstring; __traits(derivedMembers, Thing))
                {
                    static if (
                        memberIsVisibleAndNotDeprecated!(Thing, memberstring) &&
                        memberIsValue!(Thing, memberstring) &&
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
                enum pattern = "Non-aggregate type `%s` passed to `longestMemberTypeNameImpl`";
                static assert(0, pattern.format(Thing.stringof));
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


// Wrap
/++
    Wraps a value by generating a mutator with a specified name.

    The wrapper returns `this` by reference, allowing for chaining calls.
    Values are assigned, arrays are appended to.

    Params:
        newName = Name of mutator symbol to generate and mix in.
        symbol = Symbol to wrap.
 +/
mixin template Wrap(string newName, alias symbol)
{
    private import std.traits : isArray, isSomeString;

    static if (!__traits(compiles, __traits(identifier, symbol)))
    {
        static assert(0, "Failed to wrap symbol: symbol could not be resolved");
    }
    else static if (!newName.length)
    {
        static assert(0, "Failed to wrap symbol: name to generate is empty");
    }
    else static if (__traits(compiles, mixin(newName)))
    {
        static assert(0, "Failed to wrap symbol: symbol `" ~ newName ~ "` already exists");
    }

    static if (isArray!(typeof(symbol)) && !isSomeString!(typeof(symbol)))
    {
        private import std.range.primitives : ElementEncodingType;
        private import std.traits : fullyQualifiedName;

        mixin(
"ref auto " ~ newName ~ '(' ~ fullyQualifiedName!(ElementEncodingType!(typeof(symbol))) ~ " newVal)
{
    " ~ __traits(identifier, symbol) ~ " ~= newVal;
    return this;
}");
    }
    else
    {
        mixin(
"ref auto " ~ newName ~ '(' ~ typeof(symbol).stringof ~ " newVal)
{
    " ~ __traits(identifier, symbol) ~ " = newVal;
    return this;
}");
    }
}

///
unittest
{
    //import dialect.defs : IRCEvent;

    struct Foo
    {
        IRCEvent.Type[] _acceptedEventTypes;
        bool _verbose;
        bool _chainable;

        mixin Wrap!("onEvent", _acceptedEventTypes);
        mixin Wrap!("verbose", _verbose);
        mixin Wrap!("chainable", _chainable);
    }

    auto f = Foo()
        .onEvent(IRCEvent.Type.CHAN)
        .onEvent(IRCEvent.Type.EMOTE)
        .onEvent(IRCEvent.Type.QUERY)
        .chainable(true)
        .verbose(false);

    assert(f._acceptedEventTypes == [ IRCEvent.Type.CHAN, IRCEvent.Type.EMOTE, IRCEvent.Type.QUERY ]);
    assert(f._chainable);
    assert(!f._verbose);
}

// So the above unittest works.
version(unittest)
{
    import dialect.defs;
}

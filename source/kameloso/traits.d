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
bool memberstringIsThisCtorOrDtor(const string memberstring) pure @safe nothrow @nogc
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
if (isAggregateType!Thing && memberstring.length)
{
    static if (__VERSION__ >= 2096L)
    {
        /+
            __traits(getVisibility) over deprecated __traits(getProtection).
            __traits(isDeprecated) before __traits(getVisibility) to gag
            deprecation warnings.
         +/
        static if (
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
    else static if (__VERSION__ >= 2089L)
    {
        /+
            __traits(isDeprecated) before __traits(getProtection) to gag
            deprecation warnings.
         +/
        static if (
            !__traits(isDeprecated, __traits(getMember, Thing, memberstring)) &&
            (__traits(getProtection, __traits(getMember, Thing, memberstring)) != "private") &&
            (__traits(getProtection, __traits(getMember, Thing, memberstring)) != "package"))
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
        /+
            __traits(getProtection) before __traits(isDeprecated) to actually
            compile if member not visible.

            This order is not necessary for all versions, but the oldest require
            it. Additionally we can't avoid the deprecation messages no matter
            what we do, so just lump the rest here.
         +/
        static if (
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
if (isAggregateType!Thing && memberstring.length)
{
    import std.traits : isMutable;

    enum memberIsMutable =
        isMutable!(typeof(__traits(getMember, Thing, memberstring))) &&
        __traits(compiles, __traits(getMember, Thing, memberstring).offsetof);
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
if (isAggregateType!Thing && memberstring.length)
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
if (newName.length)
{
    private import kameloso.traits : memberstringIsThisCtorOrDtor;
    private import std.traits : isArray, isSomeString;

    static if (memberstringIsThisCtorOrDtor(newName))
    {
        static assert(0, "Wrapper name cannot be special names `this`, `__ctor` or `__dtor`");
    }
    else static if (__traits(compiles, mixin(newName)))
    {
        static assert(0, "Failed to wrap symbol: symbol `" ~ newName ~ "` already exists");
    }
    else static if (isArray!(typeof(symbol)) && !isSomeString!(typeof(symbol)))
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


// UnderscoreOpDispatcher
/++
    Mixin template mixing in an `opDispatch` redirecting calls to members whose
    names match the passed variable string but with an underscore prepended.

    Example:
    ---
    struct Foo
    {
        int _i;
        string _s;
        bool _b;

        mixin UnderscoreOpDispatcher;
    }

    Foo f;
    f.i = 42;       // f.opDispatch!"i"(42);
    f.s = "hello";  // f.opDispatch!"s"("hello");
    f.b = true;     // f.opDispatch!"b"(true);

    assert(f.i == 42);
    assert(f.s == "hello");
    assert(f.b);
    ---
 +/
mixin template UnderscoreOpDispatcher()
{
    ref auto opDispatch(string var, T)(T value)
    {
        import std.traits : isArray, isSomeString;

        enum realVar = '_' ~ var;
        alias V = typeof(mixin(realVar));

        static if (isArray!V && !isSomeString!V)
        {
            mixin(realVar) ~= value;
        }
        else
        {
            mixin(realVar) = value;
        }

        return this;
    }
}

///
unittest
{
    import dialect.defs;

    struct Foo
    {
        IRCEvent.Type[] _acceptedEventTypes;
        alias _onEvent = _acceptedEventTypes;
        bool _verbose;
        bool _chainable;

        mixin UnderscoreOpDispatcher;
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


// longestMemberNames
/++
    Introspects one or more aggregate types and determines the name of the
    longest member found between them, as well as the name of the longest type.
    Ignores [lu.uda.Unserialisable|Unserialisable] members.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect.
 +/
alias longestMemberNames(Things...) = longestMemberNamesImpl!(No.unserialisable, Things);

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

    alias fooNames = longestMemberNames!Foo;
    static assert((fooNames.member == "veryLongName"), fooNames.member);
    static assert((fooNames.type == "char[][string]"), fooNames.type);

    alias barNames = longestMemberNames!Bar;
    static assert((barNames.member == "evenLongerName"), barNames.member);
    static assert((barNames.type == "string"), barNames.type);

    alias bothNames = longestMemberNames!(Foo, Bar);
    static assert((bothNames.member == "evenLongerName"), bothNames.member);
    static assert((bothNames.type == "char[][string]"), bothNames.type);
}


// longestUnserialisableMemberNames
/++
    Introspects one or more aggregate types and determines the name of the
    longest member found between them, as well as the name of the longest type.
    Includes [lu.uda.Unserialisable|Unserialisable] members.

    This is used for formatting terminal output of configuration files, so that
    columns line up.

    Params:
        Things = Types to introspect.
 +/
alias longestUnserialisableMemberNames(Things...) =
    longestMemberNamesImpl!(Yes.unserialisable, Things);

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

    alias fooNames = longestUnserialisableMemberNames!Foo;
    static assert((fooNames.member == "veryVeryVeryLongNameThatIsInvalid"), fooNames.member);
    static assert((fooNames.type == "string[][string]"), fooNames.type);

    alias barNames = longestUnserialisableMemberNames!Bar;
    static assert((barNames.member == "shoooooooooooooooort"), barNames.member);
    static assert((barNames.type == "string"), barNames.type);

    alias bothNames = longestUnserialisableMemberNames!(Foo, Bar);
    static assert((bothNames.member == "veryVeryVeryLongNameThatIsInvalid"), bothNames.member);
    static assert((bothNames.type == "string[][string]"), bothNames.type);
}


// longestMemberNamesImpl
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
private template longestMemberNamesImpl(Flag!"unserialisable" unserialisable, Things...)
if (Things.length > 0)
{
    enum longestMemberNamesImpl = ()
    {
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA, isAggregateType;

        struct Results
        {
            string member;
            string type;
        }

        Results results;

        foreach (Thing; Things)
        {
            static if (isAggregateType!Thing)
            {
                foreach (immutable memberstring; __traits(derivedMembers, Thing))
                {
                    static if (
                        !memberstringIsThisCtorOrDtor(memberstring) &&
                        memberIsVisibleAndNotDeprecated!(Thing, memberstring) &&
                        memberIsValue!(Thing, memberstring) &&
                        isSerialisable!(__traits(getMember, Thing, memberstring)) &&
                        !hasUDA!(__traits(getMember, Thing, memberstring), Hidden) &&
                        (unserialisable || !hasUDA!(__traits(getMember, Thing, memberstring), Unserialisable)))
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
            else
            {
                import std.format : format;
                enum pattern = "Non-aggregate type `%s` passed to `longestNamesImpl`";
                static assert(0, pattern.format(Thing.stringof));
            }
        }

        return results;
    }();
}

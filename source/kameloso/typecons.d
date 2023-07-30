/++
    This module provides a mixin template [UnderscoreOpDispatcher] that
    redirects calls to members whose names match the passed variable string
    but with an underscore prepended.

    This module is a copy of the one from lu.typecons, but with a fallback
    implementation for older versions of lu.

    See_Also:
        https://github.com/zorael/lu/blob/master/source/lu/typecons.d

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.typecons;

private:

import lu.semver : LuSemVer;

public:


// UnderscoreOpDispatcher
/+
    If the version of lu is too old to include UnderscoreOpDispatcher, we
    provide our own. This is the case for lu 1.2.5 and older.
 +/
static if (
    (LuSemVer.majorVersion <= 1) &&
    (LuSemVer.minorVersion <= 2) &&
    (LuSemVer.patchVersion <= 5))
{
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

        auto opDispatch(string var)() const
        {
            enum realVar = '_' ~ var;
            return mixin(realVar);
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

        assert(f.acceptedEventTypes == [ IRCEvent.Type.CHAN, IRCEvent.Type.EMOTE, IRCEvent.Type.QUERY ]);
        assert(f.chainable);
        assert(!f.verbose);
    }
}
else
{
    /+
        Use the one from lu.typecons instead.
     +/
    public import lu.typecons : UnderscoreOpDispatcher;
}

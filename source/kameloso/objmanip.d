/++
 +  This module contains functions that in some way or another manipulates
 +  struct and class instances.
 +/
module kameloso.objmanip;

import kameloso.uda;

public import kameloso.meld;

@safe:


// setMemberByName
/++
 +  Given a struct/class object, sets one of its members by its string name to a
 +  specified value.
 +
 +  It does not currently recurse into other struct/class members.
 +
 +  Example:
 +  ---
 +  IRCUser bot;
 +
 +  bot.setMemberByName("nickname", "kameloso");
 +  bot.setMemberByName("address", "blarbh.hlrehg.org");
 +  bot.setMemberByName("special", "false");
 +
 +  assert(bot.nickname == "kameloso");
 +  assert(bot.address == "blarbh.hlrehg.org");
 +  assert(!bot.special);
 +  ---
 +
 +  Params:
 +      thing = Reference object whose members to set.
 +      memberToSet = String name of the thing's member to set.
 +      valueToSet = String contents of the value to set the member to; string
 +          even if the member is of a different type.
 +
 +  Returns:
 +      `true` if a member was found and set, `false` if not.
 +
 +  Throws: `std.conv.ConvException` if a string could not be converted into an
 +      array, if a passed string could not be converted into a bool, or if
 +      `std.conv.to` failed to convert a string into wanted type T.
 +/
bool setMemberByName(Thing)(ref Thing thing, const string memberToSet, const string valueToSet)
{
    import kameloso.string : stripSuffix, stripped, unquoted;
    import std.conv : ConvException, to;
    import std.format : format;

    bool success;

    top:
    switch (memberToSet)
    {
    static foreach (immutable i; 0..thing.tupleof.length)
    {{
        import kameloso.traits : isConfigurableVariable;
        import std.traits : Unqual, isType;

        alias T = Unqual!(typeof(thing.tupleof[i]));

        static if (!isType!(thing.tupleof[i]) &&
            isConfigurableVariable!(thing.tupleof[i]))
        {
            enum memberstring = __traits(identifier, thing.tupleof[i]);

            case memberstring:
            {
                import std.traits : isArray, isAssociativeArray, isSomeString;

                static if (is(T == struct) || is(T == class))
                {
                    // can't assign whole structs or classes
                }
                else static if (!isSomeString!T && isArray!T)
                {
                    import std.array : replace;
                    import std.traits : getUDAs, hasUDA;

                    thing.tupleof[i].length = 0;

                    static assert(hasUDA!(thing.tupleof[i], Separator),
                        "%s.%s is missing a Separator annotation"
                        .format(Thing.stringof, memberstring));

                    alias separators = getUDAs!(thing.tupleof[i], Separator);
                    enum escapedPlaceholder = "\0\0";  // anything really
                    enum ephemeralSeparator = "\1\1";  // ditto
                    enum doubleEphemeral = ephemeralSeparator ~ ephemeralSeparator;
                    enum doubleEscapePlaceholder = "\2\2";

                    string values = valueToSet.replace("\\\\", doubleEscapePlaceholder);

                    foreach (separator; separators)
                    {
                        enum escaped = '\\' ~ separator.token;
                        values = values
                            .replace(escaped, escapedPlaceholder)
                            .replace(separator.token, ephemeralSeparator)
                            .replace(escapedPlaceholder, separator.token);
                    }

                    import kameloso.string : contains;
                    while (values.contains(doubleEphemeral))
                    {
                        values = values.replace(doubleEphemeral, ephemeralSeparator);
                    }

                    values = values.replace(doubleEscapePlaceholder, "\\");

                    import std.algorithm.iteration : splitter;
                    auto range = values.splitter(ephemeralSeparator);

                    foreach (immutable entry; range)
                    {
                        try
                        {
                            import std.range : ElementType;

                            thing.tupleof[i] ~= entry
                                .stripped
                                .unquoted
                                .to!(ElementType!T);

                            success = true;
                        }
                        catch (const ConvException e)
                        {
                            immutable message = `Could not convert %s.%s array entry "%s" into %s (%s)`
                                .format(Thing.stringof.stripSuffix("Settings"),
                                memberToSet, entry, T.stringof, e.msg);
                            throw new ConvException(message);
                        }
                    }
                }
                else static if (is(T : string))
                {
                    thing.tupleof[i] = valueToSet.stripped.unquoted;
                    success = true;
                }
                else static if (isAssociativeArray!T)
                {
                    // Silently ignore AAs for now
                }
                else static if (is(T == bool))
                {
                    import std.uni : toLower;

                    switch (valueToSet.stripped.unquoted.toLower)
                    {
                    case "true":
                    case "yes":
                    case "on":
                    case "1":
                        thing.tupleof[i] = true;
                        success = true;
                        break;

                    case "false":
                    case "no":
                    case "off":
                    case "0":
                        thing.tupleof[i] = false;
                        success = true;
                        break;

                    default:
                        immutable message = ("Invalid value for setting %s.%s: " ~
                            `could not convert "%s" to a boolean value`)
                            .format(Thing.stringof.stripSuffix("Settings"),
                            memberToSet, valueToSet);
                        throw new ConvException(message);
                    }
                }
                else
                {
                    try
                    {
                        /*writefln("%s.%s = %s.to!%s", Thing.stringof,
                            memberstring, valueToSet, T.stringof);*/
                        thing.tupleof[i] = valueToSet
                            .stripped
                            .unquoted
                            .to!T;
                        success = true;
                    }
                    catch (const ConvException e)
                    {
                        immutable message = `Invalid value for setting %s.%s: " ~
                            "could not convert "%s" to %s (%s)`
                            .format(Thing.stringof.stripSuffix("Settings"),
                            memberToSet, valueToSet, T.stringof, e.msg);
                        throw new ConvException(message);
                    }
                }
                break top;
            }
        }
    }}

    default:
        break;
    }

    return success;
}

///
unittest
{
    import std.conv : to;

    struct Foo
    {
        string bar;
        int baz;

        @Separator("|")
        @Separator(" ")
        {
            string[] arr;
            string[] matey;
        }

        @Separator(";;")
        {
            string[] parrots;
            string[] withSpaces;
        }
    }

    Foo foo;
    bool success;

    success = foo.setMemberByName("bar", "asdf fdsa adf");
    assert(success);
    assert((foo.bar == "asdf fdsa adf"), foo.bar);

    success = foo.setMemberByName("baz", "42");
    assert(success);
    assert((foo.baz == 42), foo.baz.to!string);

    success = foo.setMemberByName("arr", "herp|derp|dirp|darp");
    assert(success);
    assert((foo.arr == [ "herp", "derp", "dirp", "darp"]), foo.arr.to!string);

    success = foo.setMemberByName("arr", "herp derp dirp|darp");
    assert(success);
    assert((foo.arr == [ "herp", "derp", "dirp", "darp"]), foo.arr.to!string);

    success = foo.setMemberByName("matey", "this,should,not,be,separated");
    assert(success);
    assert((foo.matey == [ "this,should,not,be,separated" ]), foo.matey.to!string);

    success = foo.setMemberByName("parrots", "squaawk;;parrot sounds;;repeating");
    assert(success);
    assert((foo.parrots == [ "squaawk", "parrot sounds", "repeating"]),
        foo.parrots.to!string);

    success = foo.setMemberByName("withSpaces", `         squoonk         ;;"  spaced  ";;" "`);
    assert(success);
    assert((foo.withSpaces == [ "squoonk", `  spaced  `, " "]),
        foo.withSpaces.to!string);

    success = foo.setMemberByName("invalid", "oekwpo");
    assert(!success);

    success = foo.setMemberByName("", "true");
    assert(!success);

    success = foo.setMemberByName("matey", "hirr steff\\ stuff staff\\|stirf hooo");
    assert(success);
    assert((foo.matey == [ "hirr", "steff stuff", "staff|stirf", "hooo" ]), foo.matey.to!string);

    success = foo.setMemberByName("matey", "hirr steff\\\\ stuff staff\\\\|stirf hooo");
    assert(success);
    assert((foo.matey == [ "hirr", "steff\\", "stuff", "staff\\", "stirf", "hooo" ]), foo.matey.to!string);

    success = foo.setMemberByName("matey", "asdf\\ fdsa\\\\ hirr                                steff");
    assert(success);
    assert((foo.matey == [ "asdf fdsa\\", "hirr", "steff" ]), foo.matey.to!string);

    class C
    {
        string abc;
        int def;
    }

    C c = new C;

    success = c.setMemberByName("abc", "this is abc");
    assert(success);
    assert((c.abc == "this is abc"), c.abc);

    success = c.setMemberByName("def", "42");
    assert(success);
    assert((c.def == 42), c.def.to!string);
}


// zeroMembers
/++
 +  Zeroes out members of a passed struct that only contain the value of the
 +  passed `emptyToken`. If a string then its contents are thus, if an array
 +  with only one element then if that is thus.
 +
 +  Params:
 +      emptyToken = What string to look for when zeroing out members.
 +      thing = Reference to a struct whose members to iterate over, zeroing.
 +/
void zeroMembers(string emptyToken = "-", Thing)(ref Thing thing)
if (is(Thing == struct))
{
    import std.traits : isArray, isSomeString;

    foreach (immutable i, ref member; thing.tupleof)
    {
        alias T = typeof(member);

        static if (is(T == struct))
        {
            zeroMembers!emptyToken(member);
        }
        else static if (isSomeString!T)
        {
            if (member == emptyToken)
            {
                member = string.init;
            }
        }
        else static if (isArray!T)
        {
            if ((member.length == 1) && (member[0] == emptyToken))
            {
                member.length = 0;
            }
        }
    }
}

///
unittest
{
    struct Bar
    {
        string s = "content";
    }

    struct Foo
    {
        Bar b;
        string s = "more content";
    }

    Foo foo1, foo2;
    zeroMembers(foo1);
    assert(foo1 == foo2);

    foo2.s = "-";
    zeroMembers(foo2);
    assert(!foo2.s.length);
    foo2.b.s = "-";
    zeroMembers(foo2);
    assert(!foo2.b.s.length);

    Foo foo3;
    foo3.s = "---";
    foo3.b.s = "---";
    zeroMembers!"---"(foo3);
    assert(!foo3.s.length);
    assert(!foo3.b.s.length);
}


// deepSizeof
/++
 +  Naïvely sums up the size of something in memory.
 +
 +  It enumerates all fields in classes and structs and recursively sums up the
 +  space everything takes. It's VERY NAÏVE in that it doesn't take into account
 +  that some arrays and such may have been allocated in a larger chunk than the
 +  length of the array itself. It's mostly an approximaion, and not a good one
 +  at that.
 +
 +  Example:
 +  ---
 +  struct Foo
 +  {
 +      string asdf = "qwertyuiopasdfghjklxcvbnm";
 +      int i = 42;
 +      float f = 3.14f;
 +  }
 +
 +  Foo foo;
 +  writeln(foo.deepSizeof);
 +  ---
 +
 +  Params:
 +      thing = Object to enumerate and add up the members of.
 +
 +  Returns:
 +      The calculated *minimum* number of bytes allocated for the passed
 +      object.
 +/
uint deepSizeof(T)(const T thing) pure @nogc @safe
{
    import std.traits : isArray, isAssociativeArray;

    uint total;

    total += T.sizeof;

    static if (is(T == struct) || is(T == class))
    {
        foreach (immutable i, value; thing.tupleof)
        {
            total += deepSizeof(thing.tupleof[i]);
        }
    }
    else static if (isArray!T)
    {
        import std.range : ElementEncodingType;
        alias E = ElementEncodingType!T;
        total += (E.sizeof * thing.length);
    }
    else static if (isAssociativeArray!T)
    {
        foreach (immutable elem; thing)
        {
            total += deepSizeof(elem);
        }
    }
    else
    {
        // T.sizeof is enough
    }

    return total;
}

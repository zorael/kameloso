/++
 +  This module contains functions that in one way or another converts its
 +  arguments into something else.
 +/
module kameloso.conv;

import std.typecons : Flag, No, Yes;

@safe:

// Enum
/++
 +  Template housing optimised functions to get the string name of an enum
 +  member, or the enum member of a name string.
 +
 +  `std.conv.to` is typically the go-to for this job; however it quickly bloats
 +  the binary and is supposedly not performant on larger enums.
 +
 +  Params:
 +      E = `enum` to base this template on.
 +/
template Enum(E)
if (is(E == enum))
{
    // fromString
    /++
     +  Takes the member of an enum by string and returns that enum member.
     +
     +  It lowers to a big switch of the enum member strings. It is faster than
     +  `std.conv.to` and generates less template bloat.
     +
     +  Taken from: https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
     +  written by Stephan Koch (https://github.com/UplinkCoder).
     +
     +  Example:
     +  ---
     +  enum SomeEnum { one, two, three };
     +
     +  SomeEnum foo = Enum!SomeEnum.fromString("one");
     +  SomeEnum bar = Enum!SomeEnum.fromString("three");
     +
     +  assert(foo == SomeEnum.one);
     +  assert(bar == SomeEnum.three);
     +  ---
     +
     +  Params:
     +      enumstring = the string name of an enum member.
     +
     +  Returns:
     +      The enum member whose name matches the enumstring string (not whose
     +      *value* matches the string).
     +
     +  Throws: `std.conv.ConvException` if no matching enum member with the
     +      passed name could be found.
     +/
    E fromString(const string enumstring) pure
    {
        enum enumSwitch = ()
        {
            string enumSwitch = "import std.conv : ConvException;\n";
            enumSwitch ~= "with (E) switch (enumstring)\n{\n";

            foreach (immutable memberstring; __traits(allMembers, E))
            {
                enumSwitch ~= `case "` ~ memberstring ~ `":`;
                enumSwitch ~= "return " ~ memberstring ~ ";\n";
            }

            enumSwitch ~= "default:\n" ~
                "import std.traits : fullyQualifiedName;\n" ~
                `throw new ConvException("No such " ~ fullyQualifiedName!E ~ ": " ~ enumstring);}`;

            return enumSwitch;
        }();

        mixin(enumSwitch);
    }


    // toString
    /++
     +  The inverse of `fromString`, this function takes an enum member value
     +  and returns its string identifier.
     +
     +  It lowers to a big switch of the enum members. It is faster than
     +  `std.conv.to` and generates less template bloat.
     +
     +  Taken from: https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
     +  written by Stephan Koch (https://github.com/UplinkCoder).
     +
     +  Example:
     +  ---
     +  enum SomeEnum { one, two, three };
     +
     +  string foo = Enum!SomeEnum.toString(one);
     +  assert((foo == "one"), foo);
     +  ---
     +
     +  Params:
     +      value = Enum member whose string name we want.
     +
     +  Returns:
     +      The string name of the passed enum member.
     +/
    string toString(E value) pure nothrow
    {
        switch (value)
        {

        foreach (immutable m; __traits(allMembers, E))
        {
            case mixin("E." ~ m) : return m;
        }

        default:
            string result = "cast(" ~ E.stringof ~ ")";
            uint val = value;
            enum headLength = E.stringof.length + "cast()".length;

            immutable log10Val =
                (val < 10) ? 0 :
                (val < 100) ? 1 :
                (val < 1_000) ? 2 :
                (val < 10_000) ? 3 :
                (val < 100_000) ? 4 :
                (val < 1_000_000) ? 5 :
                (val < 10_000_000) ? 6 :
                (val < 100_000_000) ? 7 :
                (val < 1_000_000_000) ? 8 : 9;

            result.length += log10Val + 1;

            for (uint i; i != log10Val + 1; ++i)
            {
                cast(char)result[headLength + log10Val - i] = cast(char)('0' + (val % 10));
                val /= 10;
            }

            return result;
        }
    }
}

///
@system
unittest
{
    import std.conv : ConvException;
    import std.exception  : assertThrown;

    enum T
    {
        UNSET,
        QUERY,
        PRIVMSG,
        RPL_ENDOFMOTD
    }

    with (T)
    {
        assert(Enum!T.fromString("QUERY") == QUERY);
        assert(Enum!T.fromString("PRIVMSG") == PRIVMSG);
        assert(Enum!T.fromString("RPL_ENDOFMOTD") == RPL_ENDOFMOTD);
        assert(Enum!T.fromString("UNSET") == UNSET);
        assertThrown!ConvException(Enum!T.fromString("DOESNTEXIST"));  // needs @system
    }

    with (T)
    {
        assert(Enum!T.toString(QUERY) == "QUERY");
        assert(Enum!T.toString(PRIVMSG) == "PRIVMSG");
        assert(Enum!T.toString(RPL_ENDOFMOTD) == "RPL_ENDOFMOTD");
    }
}


// numFromHex
/++
 +  Returns the decimal value of a hex number in string form.
 +
 +  Example:
 +  ---
 +  int fifteen = numFromHex("F");
 +  int twofiftyfive = numFromHex("FF");
 +  ---
 +
 +  Params:
 +      acceptLowercase = Flag of whether or not to accept rrggbb in lowercase form.
 +      hex = Hexadecimal number in string form.
 +
 +  Returns:
 +      An integer equalling the value of the passed hexadecimal string.
 +
 +  Throws: `std.conv.ConvException` if the hex string was malformed.
 +/
uint numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)(const string hex) pure
{
    import std.string : representation;

    int val = -1;
    int total;

    foreach (immutable c; hex.representation)
    {
        switch (c)
        {
        case '0':
        ..
        case '9':
            val = (c - 48);
            goto case 'F';

    static if (acceptLowercase)
    {
        case 'a':
        ..
        case 'f':
            val = (c - (55+32));
            goto case 'F';
    }

        case 'A':
        ..
        case 'F':
            if (val < 0) val = (c - 55);
            total *= 16;
            total += val;
            val = -1;
            break;

        default:
            import std.conv : ConvException;
            throw new ConvException("Invalid hex string: " ~ hex);
        }
    }

    assert((total < 16^^hex.length), "numFromHex output is too large!");

    return total;
}


// numFromHex
/++
 +  Convenience wrapper that takes a hex string and maps the values to three
 +  integers passed by ref.
 +
 +  This is to be used when mapping a #RRGGBB colour to their decimal
 +  red/green/blue equivalents.
 +
 +  Params:
 +      acceptLowercase = Whether or not to accept the rrggbb string in lowercase letters.
 +      hexString = Hexadecimal number (colour) in string form.
 +      r = Out-reference integer for the red part of the hex string.
 +      g = Out-reference integer for the green part of the hex string.
 +      b = Out-reference integer for the blue part of the hex string.
 +/
void numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hexString, out int r, out int g, out int b) pure
{
    if (!hexString.length) return;

    immutable hex = (hexString[0] == '#') ? hexString[1..$] : hexString;

    r = numFromHex!acceptLowercase(hex[0..2]);
    g = numFromHex!acceptLowercase(hex[2..4]);
    b = numFromHex!acceptLowercase(hex[4..$]);
}

///
unittest
{
    import std.conv : text;
    {
        int r, g, b;
        numFromHex("000102", r, g, b);

        assert((r == 0), r.text);
        assert((g == 1), g.text);
        assert((b == 2), b.text);
    }
    {
        int r, g, b;
        numFromHex("FFFFFF", r, g, b);

        assert((r == 255), r.text);
        assert((g == 255), g.text);
        assert((b == 255), b.text);
    }
    {
        int r, g, b;
        numFromHex("3C507D", r, g, b);

        assert((r == 60), r.text);
        assert((g == 80), g.text);
        assert((b == 125), b.text);
    }
    {
        int r, g, b;
        numFromHex!(Yes.acceptLowercase)("9a4B7c", r, g, b);

        assert((r == 154), r.text);
        assert((g == 75), g.text);
        assert((b == 124), b.text);
    }
}


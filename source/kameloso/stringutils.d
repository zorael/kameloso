module kameloso.stringutils;

import std.datetime;
import std.traits   : isSomeString;
import std.typecons : Flag;

public import std.typecons : No, Yes;

@safe:

// nom
/++
 +  Finds the supplied separator token, returns the string up to that point,
 +  and advances the passed ref string to after the token.
 +
 +  Params:
 +      arr = The array to walk and advance.
 +      separator = The token that delimenates what should be returned and to
 +                  where to advance.
 +
 +  Returns:
 +      the string arr from the start up to the separator.
 +/
pragma(inline)
string nom(Flag!"decode" decode = No.decode, T, C)(ref T[] arr, const C separator) @trusted
{
    static if (decode)
    {
        import std.string : indexOf;

        immutable index = arr.indexOf(separator);
    }
    else
    {
        // Only do this if we know it's not user text
        import std.algorithm.searching : countUntil;

        static if (isSomeString!C)
        {
            immutable index = (cast(ubyte[])arr).countUntil(cast(ubyte[])separator);
        }
        else
        {
            immutable index = (cast(ubyte[])arr).countUntil(cast(ubyte)separator);
        }
    }

    if (index == -1)
    {
        import kameloso.common : logger;

        logger.errorf("-- TRIED TO NOM TOO MUCH:'%s' with '%s'", arr, separator);
        return string.init;
    }

    static if (isSomeString!C)
    {
        immutable separatorLength = separator.length;
    }
    else
    {
        enum separatorLength = 1;
    }

    scope(exit) arr = arr[(index+separatorLength)..$];

    return arr[0..index];
}

pragma(inline)
string plurality(const int num, const string singular, const string plural) pure
{
    return string.init;
}
pragma(inline)
string unquoted(const string line) pure
{
    return string.init;
}

pragma(inline)
bool beginsWith(T)(const T haystack, const T needle) pure
if (isSomeString!T)
{
    if ((needle.length > haystack.length) || !haystack.length)
    {
        return false;
    }

    return (haystack[0..needle.length] == needle);
}

pragma(inline)
bool beginsWith(T)(const T line, const ubyte charcode) pure
if (isSomeString!T)
{
    if (!line.length) return false;

    return (line[0] == charcode);
}

pragma(inline)
T[] arrayify(string separator = ",", T)(const T line)
{
    import std.algorithm.iteration : map, splitter;
    import std.array : array;
    import std.string : strip;

    return line.splitter(separator).map!(a => a.strip).array;
}


pragma(inline)
string stripPrefix(const string line, const string prefix)
{
    import std.regex : ctRegex, matchFirst;
    import std.string : munch, stripLeft;

    string slice = line.stripLeft();

    // the onus is on the caller that slice begins with prefix
    slice.nom(prefix);

    enum pattern = "[:?! ]*(.+)";
    static engine = ctRegex!pattern;
    auto hits = slice.matchFirst(engine);
    return hits[1];
}


void timeSince(Sink)(auto ref Sink sink, const Duration duration)
{
}

/// ditto
string timeSince(const Duration duration)
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(50);
    sink.timeSince(duration);
    return sink.data;
}


pragma(inline)
Enum toEnum(Enum)(const string enumstring) pure
if (is(Enum == enum))
{
    enum enumSwitch = ()
    {
       string enumSwitch = "with (Enum) switch (enumstring)\n{";

        foreach (memberstring; __traits(allMembers, Enum))
        {
            enumSwitch ~= `case "` ~ memberstring ~ `":`;
            enumSwitch ~= "return " ~ memberstring ~ ";\n";
        }

        enumSwitch ~= `default: throw new Exception("No such enum member: "
            ~ enumstring);}`;

        return enumSwitch;
    }();

    mixin(enumSwitch);

    assert(0, "No such member " ~ enumstring);
}

@system
unittest
{
    import kameloso.irc   : IRCEvent;

    import core.exception : AssertError;
    import std.exception  : assertThrown;

    with (IRCEvent)
    with (IRCEvent.Type)
    {
        assert("QUERY".toEnum!Type == QUERY);
        assert("PRIVMSG".toEnum!Type == PRIVMSG);
        assert("RPL_ENDOFMOTD".toEnum!Type == RPL_ENDOFMOTD);
        assert("UNSET".toEnum!Type == UNSET);
        assertThrown!Exception("DOESNTEXIST".toEnum!Type);  // needs @system
    }
}


pragma(inline)
string enumToString(Enum)(Enum value) pure
if (is(Enum == enum))
{
    switch (value)
    {

    foreach (m; __traits(allMembers, Enum))
    {
        case mixin("Enum." ~ m) : return m;
    }

    default:
        string result = "cast(" ~ Enum.stringof ~ ")";
        uint val = value;
        enum headLength = Enum.stringof.length + "cast()".length;

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

        return cast(string) result;
    }
}


int numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hex)
{
    int val = -1;
    int total;

    foreach (immutable c; hex)
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
            assert(0, "Invalid hex string: " ~ hex);
        }
    }

    assert(total < 16^^hex.length);

    return total;
}


void numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hexString, out int r, out int g, out int b)
{
    if (!hexString.length) return;

    immutable hex = (hexString[0] == '#') ? hexString[1..$] : hexString;

    r = numFromHex!acceptLowercase(hex[0..2]);
    g = numFromHex!acceptLowercase(hex[2..4]);
    b = numFromHex!acceptLowercase(hex[4..$]);
}

string stripSuffix(Flag!"allowFullStrip" fullStrip = No.allowFullStrip)
    (const string line, const string suffix) pure
{
    static if (fullStrip)
    {
        if (line.length < suffix.length) return line;
    }
    else
    {
        if (line.length <= suffix.length) return line;
    }

    return (line[($-suffix.length)..$] == suffix) ?
        line[0..($-suffix.length)] : line;
}

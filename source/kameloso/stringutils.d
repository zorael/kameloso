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
    return ((num == 1) || (num == -1)) ? singular : plural;
}
pragma(inline)
string unquoted(const string line) pure
{
    if (line.length < 2)
    {
        return line;
    }
    else if ((line[0] == '"') && (line[$-1] == '"'))
    {
        return line[1..$-1].unquoted;
    }
    else
    {
        return line;
    }
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

// arrayify
/++
 +  Takes a string and, with a separator token, splits it into discrete token
 +  and makes it into a dynamic array.
 +
 +  Params:
 +      separator = The string to use when delimenating fields.
 +      line = The line to split.
 +
 +  Returns:
 +      An array with fields split out of the line argument.
 +/
pragma(inline)
T[] arrayify(string separator = ",", T)(const T line)
{
    import std.algorithm.iteration : map, splitter;
    import std.array : array;
    import std.string : strip;

    return line.splitter(separator).map!(a => a.strip).array;
}



/// stripPrefix
/++
 +  Strips a prefix word from a string.
 +
 +  Params:
 +      line = the prefixed string line.
 +      prefix = the prefix to strip.
 +
 +  Returns:
 +      The passed line with the prefix sliced away.
 +/
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

// timeSince
/++
 +  Express how long time has passed in a Duration, in natural language.
 +
 +  Write the result to a passed output range sink.
 +
 +  Params:
 +      duration = a period of time
 +
 +  Returns:
 +      A humanly-readable string of how long the passed duration is.
 +/
void timeSince(Sink)(auto ref Sink sink, const Duration duration)
{
    import std.format : formattedWrite;

    int days, hours, minutes, seconds;
    duration.split!("days","hours","minutes","seconds")
                   (days, hours, minutes, seconds);

    if (days)
    {
        sink.formattedWrite("%d %s", days, days.plurality("day", "days"));
    }
    if (hours)
    {
        if (days)
        {
            if (minutes) sink.put(", ");
            else sink.put("and ");
        }
        sink.formattedWrite("%d %s", hours, hours.plurality("hour", "hours"));
    }
    if (minutes)
    {
        if (hours) sink.put(" and ");
        sink.formattedWrite("%d %s", minutes, minutes.plurality("minute", "minutes"));
    }
    if (!minutes && !hours && !days)
    {
        sink.formattedWrite("%d %s", seconds, seconds.plurality("second", "seconds"));
    }
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


// toEnum
/++
 +  Takes the member of an enum by string and returns that member.
 +
 +  It lowers to a big switch of the enum member strings. It is faster than
 +  std.conv.to and generates less template bloat.
 +
 +  Params:
 +      enumstring = the string name of an enum member.
 +
 +  Returns:
 +      The enum member whose name matches the enumstring string.
 +/
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


// enumToString
/++
 +  The inverse of toEnum, this function takes an enum member value and returns
 +  its string identifier.
 +
 +  It lowers to a big switch of the enum members. It is faster than std.conv.to
 +  and generates less template bloat.
 +
 +  Taken from: https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
 +
 +  Params:
 +      value = an enum member whose string we want
 +
 +  Returns:
 +      The string name of the passed enum value.
 +/
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


// numFromHex
/++
 +  Returns the decimal value of a hex number in string form.
 +
 +  Params:
 +      hex = a string with a hexadecimal number.
 +
 +  Returns:
 +      An integer equalling the value of the passed hexadecimal string.
 +/
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

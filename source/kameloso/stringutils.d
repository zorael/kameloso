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
string nom(Flag!"decode" decode = No.decode, T, C)(ref T[] arr, const C separator)
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
        import std.string : representation;

        static if (isSomeString!C)
        {
            immutable index = arr.representation.countUntil(separator.representation);
        }
        else
        {
            immutable index = arr.representation.countUntil(cast(ubyte)separator);
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

unittest
{
    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom(" :");
        assert(lorem == "Lorem ipsum", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom!(Yes.decode)(" :");
        assert(lorem == "Lorem ipsum", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom(':');
        assert(lorem == "Lorem ipsum ", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom!(Yes.decode)(':');
        assert(lorem == "Lorem ipsum ", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom(' ');
        assert(lorem == "Lorem", lorem);
        assert(line == "ipsum :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom!(Yes.decode)(' ');
        assert(lorem == "Lorem", lorem);
        assert(line == "ipsum :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom("");
        assert(!lorem.length, lorem);
        assert(line == "Lorem ipsum :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom!(Yes.decode)("");
        assert(!lorem.length, lorem);
        assert(line == "Lorem ipsum :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom("Lorem ipsum");
        assert(!lorem.length, lorem);
        assert(line == " :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        immutable lorem = line.nom!(Yes.decode)("Lorem ipsum");
        assert(!lorem.length, lorem);
        assert(line == " :sit amet", line);
    }
}


// plurality
/++
 +  Get the correct singular or plural form of a word depending on the
 +  numerical count of it.
 +
 +  Params:
 +      num = The numerical count of the noun.
 +      singular = The noun in singular form.
 +      plural = The noun in plural form.
 +
 +  Returns:
 +      The singular string if num is 1 or -1, otherwise the plural string.
 +/
pragma(inline)
string plurality(const int num, const string singular, const string plural) pure
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}

unittest
{
    assert(10.plurality("one","many") == "many");
    assert(1.plurality("one", "many") == "one");
    assert((-1).plurality("one", "many") == "one");
    assert(0.plurality("one", "many") == "many");
}


// unquoted
/++
 +  Removes one preceding and one trailing quote, unquoting a word.
 +
 +  Params:
 +      line = the (potentially) quoted string.
 +
 +  Returns:
 +      A slice of the line argument that excludes the quotes.
 +/
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

unittest
{
    assert(`"Lorem ipsum sit amet"`.unquoted == "Lorem ipsum sit amet");
    assert(`"""""Lorem ipsum sit amet"""""`.unquoted == "Lorem ipsum sit amet");
    // Unbalanced quotes are left untouched
    assert(`"Lorem ipsum sit amet`.unquoted == `"Lorem ipsum sit amet`);
}


// beginsWith
/++
 +  A cheaper variant of std.algorithm.searching.startsWith, since it is
 +  such a hotspot.
 +
 +  Params:
 +      haystack = The original line to examine.
 +      needle = The snippet of text to check if haystack begins with.
 +
 +  Returns:
 +      true if haystack starts with needle, otherwise false.
 +/
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

unittest
{
    assert("Lorem ipsum sit amet".beginsWith("Lorem ip"));
    assert(!"Lorem ipsum sit amet".beginsWith("ipsum sit amet"));
    assert("Lorem ipsum sit amet".beginsWith(""));
}


/// Ditto
pragma(inline)
bool beginsWith(T)(const T line, const ubyte charcode) pure
if (isSomeString!T)
{
    if (!line.length) return false;

    return (line[0] == charcode);
}

unittest
{
    assert(":Lorem ipsum".beginsWith(':'));
    assert(!":Lorem ipsum".beginsWith(';'));
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

unittest
{
    assert("foo,bar,baz".arrayify     == [ "foo", "bar", "baz" ]);
    assert("foo|bar|baz".arrayify!"|" == [ "foo", "bar", "baz" ]);
    assert("foo bar baz".arrayify!" " == [ "foo", "bar", "baz" ]);
    assert("only one entry".arrayify  == [ "only one entry" ]);
    assert("not one entry".arrayify!" "  == [ "not", "one", "entry" ]);
    assert("".arrayify == []);
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
    import std.string : munch, stripLeft;

    string slice = line.stripLeft();

    // the onus is on the caller that slice begins with prefix
    slice.nom(prefix);
    slice.munch(":?! ");

    return slice;
}

unittest
{
    assert("say: lorem ipsum".stripPrefix("say") == "lorem ipsum");
    assert("note!!!! zorael hello".stripPrefix("note") == "zorael hello");
    assert("sudo quit :derp".stripPrefix("sudo") == "quit :derp");
    assert("8ball predicate?".stripPrefix("") == "8ball predicate?");
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

unittest
{
    immutable dur1 = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
    assert((dur1.timeSince == "9 days, 3 hours and 16 minutes"), dur1.timeSince);

    immutable dur2 = 3_620.seconds;  // 1 hour and 20 secs
    assert((dur2.timeSince == "1 hour"), dur2.timeSince);

    immutable dur3 = 30.seconds;  // 30 secs
    assert((dur3.timeSince == "30 seconds"), dur3.timeSince);

    immutable dur4 = 1.seconds;
    assert((dur4.timeSince == "1 second"), dur4.timeSince);

    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for LDC

    immutable dur5 = 0.seconds;
    sink.timeSince(dur5);
    assert((sink.data == "0 seconds"), sink.data);
    sink.clear();

    immutable dur6 = 3_141_519_265.msecs;
    sink.timeSince(dur6);
    assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
    sink.clear();

    immutable dur7 = 3599.seconds;
    sink.timeSince(dur7);
    assert((sink.data == "59 minutes"), sink.data);
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

        enumSwitch ~= `default: assert(0, "No such member " ~ enumstring);}`;

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
        assertThrown!AssertError("DOESNTEXIST".toEnum!Type);  // needs @system
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

unittest
{
    import kameloso.irc : IRCEvent;

    with (IRCEvent)
    with (IRCEvent.Type)
    {
        assert(enumToString(QUERY) == "QUERY");
        assert(enumToString(PRIVMSG) == "PRIVMSG");
        assert(enumToString(RPL_ENDOFMOTD) == "RPL_ENDOFMOTD");
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

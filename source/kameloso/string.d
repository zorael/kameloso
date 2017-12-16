module kameloso.string;

import core.time : Duration;
import std.range.primitives : ElementEncodingType, ElementType;
import std.traits : isArray, isSomeString;
import std.typecons : Flag, No, Yes;

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
 +
 +  ------------
 +  string foobar = "foo bar";
 +  string foo = foobar.nom(" ");
 +  string bar = foobar;
 +
 +  assert((foo == "foo"), foo);
 +  assert((bar == "bar"), bar);
 +  assert(!foobar.length);
 +  ------------
 +/
pragma(inline)
T nom(Flag!"decode" decode = No.decode, T, C)(ref T line, const C separator) @trusted
if (isSomeString!T && (is(C : T) || is(C : ElementType!T) || is(C : ElementEncodingType!T)))
{
    static if (decode || is(T : dstring) || is(T : wstring))
    {
        import std.string : indexOf;
        // dstring and wstring only work with indexOf, not countUntil
        immutable index = line.indexOf(separator);
    }
    else
    {
        // Only do this if we know it's not user text
        import std.algorithm.searching : countUntil;

        static if (isSomeString!C)
        {
            immutable index = (cast(ubyte[])line).countUntil(cast(ubyte[])separator);
        }
        else
        {
            immutable index = (cast(ubyte[])line).countUntil(cast(ubyte)separator);
        }
    }

    if (index == -1)
    {
        import kameloso.common : logger;

        logger.warningf("-- TRIED TO NOM TOO MUCH:'%s' with '%s'", line, separator);
        return T.init;
    }

    static if (isSomeString!C)
    {
        immutable separatorLength = separator.length;
    }
    else
    {
        enum separatorLength = 1;
    }

    scope(exit) line = line[(index+separatorLength)..$];

    return line[0..index];
}

///
unittest
{
    import std.conv : to;

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

    {
        string line = "Lorem ipsum :sit amet";
        immutable dchar dspace = ' ';
        immutable lorem = line.nom(dspace);
        assert(lorem == "Lorem", lorem);
        assert(line == "ipsum :sit amet", line);
    }

    {
        dstring dline = "Lorem ipsum :sit amet"d;
        immutable dspace = " "d;
        immutable lorem = dline.nom(dspace);
        assert((lorem == "Lorem"d), lorem.to!string);
        assert((dline == "ipsum :sit amet"d), dline.to!string);
    }

    {
        dstring dline = "Lorem ipsum :sit amet"d;
        immutable wchar wspace = ' ';
        immutable lorem = dline.nom(wspace);
        assert((lorem == "Lorem"d), lorem.to!string);
        assert((dline == "ipsum :sit amet"d), dline.to!string);
    }

    {
        wstring wline = "Lorem ipsum :sit amet"w;
        immutable wchar wspace = ' ';
        immutable lorem = wline.nom(wspace);
        assert((lorem == "Lorem"w), lorem.to!string);
        assert((wline == "ipsum :sit amet"w), wline.to!string);
    }

    {
        wstring wline = "Lorem ipsum :sit amet"w;
        immutable wspace = " "w;
        immutable lorem = wline.nom(wspace);
        assert((lorem == "Lorem"w), lorem.to!string);
        assert((wline == "ipsum :sit amet"w), wline.to!string);
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
 +
 +  ------------
 +  string one = 1.plurality("one", "two");
 +  string two = 2.plurality("one", "two");
 +  ------------
 +/
pragma(inline)
T plurality(T)(const int num, const T singular, const T plural)
if (isSomeString!T)
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}

///
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
 +
 +  ------------
 +  string quoted= `"This is a quote"`;
 +  string unquotes = quoted.unquoted;
 +  assert((unquoted == "This is a quote"), unquoted);
 +  ------------
 +/
string unquoted(Flag!"recurse" recurse = Yes.recurse)(const string line) @property
{
    if (line.length < 2)
    {
        return line;
    }
    else if ((line[0] == '"') && (line[$-1] == '"'))
    {
        if ((line.length >= 3) && (line[$-2..$] == `\"`))
        {
            // End quote is escaped
            return line;
        }

        static if (recurse)
        {
            return line[1..$-1].unquoted;
        }
        else
        {
            return line[1..$-1];
        }
    }
    else
    {
        return line;
    }
}

///
unittest
{
    assert(`"Lorem ipsum sit amet"`.unquoted == "Lorem ipsum sit amet");
    assert(`"""""Lorem ipsum sit amet"""""`.unquoted == "Lorem ipsum sit amet");
    // Unbalanced quotes are left untouched
    assert(`"Lorem ipsum sit amet`.unquoted == `"Lorem ipsum sit amet`);
    assert(`"Lorem \"`.unquoted == `"Lorem \"`);
    assert("\"Lorem \\\"".unquoted == "\"Lorem \\\"");
    assert(`"\"`.unquoted == `"\"`);
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
 +      `true` if haystack starts with needle, otherwise `false`.
 +
 +  ------------
 +  assert("Lorem ipsum sit amet".beginsWith("Lorem ip"));
 +  assert(!"Lorem ipsum sit amet".beginsWith("ipsum sit amet"));
 +  ------------
 +/
pragma(inline)
bool beginsWith(T)(const T haystack, const T needle) pure
if (isSomeString!T)
{
    if ((needle.length > haystack.length) || !haystack.length)
    {
        return false;
    }

    if (needle.length && (haystack[0] != needle[0])) return false;

    return (haystack[0..needle.length] == needle);
}

///
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

///
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
 +
 +  ------------
 +  string[] things = "one,two,three,four".arrayify;
 +  assert(things == [ "one", "two", "three", "four" ]);
 +  ------------
 +/
T[] arrayify(string separator = ",", T)(const T line)
{
    import std.algorithm.iteration : map, splitter;
    import std.array : array;
    import std.string : strip;

    return line.splitter(separator).map!(a => a.strip()).array;
}

///
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
 +  Strips a prefix word from a string, also stripping away some non-word
 +  characters.
 +
 +  This is to make a helper for stripping away bot prefixes, where such may be
 +  "kameloso:".
 +
 +  Params:
 +      line = the prefixed string line.
 +      prefix = the prefix to strip.
 +
 +  Returns:
 +      The passed line with the prefix sliced away.
 +
 +  ------------
 +  string prefixed = "kameloso: sudo MODE +o #channel :user";
 +  string command = prefixed.stripPrefix("kameloso");
 +  assert((command == "sudo MODE +o #channel :user"), command);
 +  ------------
 +/
string stripPrefix(const string line, const string prefix)
{
    import std.regex : ctRegex, matchFirst;
    import std.string : munch, stripLeft;

    string slice = line.stripLeft();

    // the onus is on the caller that slice begins with prefix
    slice.nom!(Yes.decode)(prefix);

    enum pattern = "[:?! ]*(.+)";
    static engine = ctRegex!pattern;
    auto hits = slice.matchFirst(engine);
    return hits[1];
}

///
unittest
{
    immutable lorem = "say: lorem ipsum".stripPrefix("say");
    assert((lorem == "lorem ipsum"), lorem);

    immutable notehello = "note!!!! zorael hello".stripPrefix("note");
    assert((notehello == "zorael hello"), notehello);

    immutable sudoquit = "sudo quit :derp".stripPrefix("sudo");
    assert((sudoquit == "quit :derp"), sudoquit);

    immutable eightball = "8ball predicate?".stripPrefix("");
    assert((eightball == "8ball predicate?"), eightball);

    immutable isabot = "kamelosois a bot".stripPrefix("kameloso");
    assert((isabot == "is a bot"), isabot);
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
 +
 +  ------------
 +  Appender!string sink;
 +
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = sink.timeSince(duration);
 +  ------------
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

///
unittest
{
    import core.time : msecs, seconds;

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
 +
 +  ------------
 +  enum SomeEnum { one, two, three };
 +
 +  SomeEnum foo = "one".toEnum!someEnum;
 +  SomeEnum bar = "three".toEnum!someEnum;
 +  ------------
 +/
pragma(inline)
Enum toEnum(Enum)(const string enumstring) pure
if (is(Enum == enum))
{
    enum enumSwitch = ()
    {
        string enumSwitch = "import std.conv : ConvException;\n";
        enumSwitch ~= "with (Enum) switch (enumstring)\n{\n";

        foreach (memberstring; __traits(allMembers, Enum))
        {
            enumSwitch ~= `case "` ~ memberstring ~ `":`;
            enumSwitch ~= "return " ~ memberstring ~ ";\n";
        }

        enumSwitch ~= `default: throw new ConvException("No such enum member: "
            ~ enumstring);}`;

        return enumSwitch;
    }();

    mixin(enumSwitch);

    assert(0, "No such member " ~ enumstring);
}

///
@system
unittest
{
    import std.conv : ConvException;
    import std.exception  : assertThrown;

    enum Enum
    {
        UNSET,
        QUERY,
        PRIVMSG,
        RPL_ENDOFMOTD
    }

    with (Enum)
    {
        assert("QUERY".toEnum!Enum == QUERY);
        assert("PRIVMSG".toEnum!Enum == PRIVMSG);
        assert("RPL_ENDOFMOTD".toEnum!Enum == RPL_ENDOFMOTD);
        assert("UNSET".toEnum!Enum == UNSET);
        assertThrown!ConvException("DOESNTEXIST".toEnum!Enum);  // needs @system
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
 +
 +  ------------
 +  enum SomeEnum { one, two, three };
 +
 +  string foo = SomeEnum.one.enumToString;
 +  assert((foo == "one"), foo);
 +  ------------
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

///
unittest
{
    enum Enum
    {
        UNSET,
        QUERY,
        PRIVMSG,
        RPL_ENDOFMOTD
    }

    with (Enum)
    {
        assert(enumToString(QUERY) == "QUERY");
        assert(enumToString(PRIVMSG) == "PRIVMSG");
        assert(enumToString(RPL_ENDOFMOTD) == "RPL_ENDOFMOTD");
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
 +
 +  ------------
 +  int fifteen = numFromHex("F");
 +  int twofiftyfive = numFromHex("FF");
 +  ------------
 +/
uint numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
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
            import std.conv : ConvException;
            throw new ConvException("Invalid hex string: " ~ hex);
        }
    }

    assert(total < 16^^hex.length);

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
 +      hexString = a string with a hexadecimal number (colour)
 +      ref r = ref int for the red part of the hex string
 +      ref g = ref int for the green part of the hex string
 +      ref b = ref int for the blue part of the hex string
 +/
void numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hexString, out int r, out int g, out int b)
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


// stripSuffix
/++
 +  Strips the supplied string from the end of a string.
 +
 +  ------------
 +  string suffixed = "Kameloso";
 +  string stripped = suffixed.stripSuffix("oso");
 +  assert((stripped == "Kamel"), stripped);
 +  ------------
 +/
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

///
unittest
{
    immutable line = "harblsnarbl";
    assert(line.stripSuffix("snarbl") == "harbl");
    assert(line.stripSuffix("") == "harblsnarbl");
    assert(line.stripSuffix("INVALID") == "harblsnarbl");
    assert(!line.stripSuffix!(Yes.allowFullStrip)("harblsnarbl").length);
    assert(line.stripSuffix("harblsnarbl") == "harblsnarbl");
}


/++
 +  Calculates how many dot-separated suffixes two strings share.
 +
 +  This is useful to see to what extent two addresses are similar.
 +
 +  ------------
 +  int numDomains = sharedDomains("irc.freenode.net", "leguin.freenode.net");
 +  assert(numDomains == 2);  // freenode.net
 +  ------------
 +/
uint sharedDomains(const string rawOne, const string rawOther)
{
    uint dots;
    bool doubleDots;

    // If both strings are the same, act as if there's an extra dot.
    // That gives (.)rizon.net and (.)rizon.net two suffixes.
    if (rawOne.length && (rawOne == rawOther)) ++dots;

    immutable one = (rawOne != rawOther) ? '.' ~ rawOne : rawOne;
    immutable other = (rawOne != rawOther) ? '.' ~ rawOther : rawOther;

    foreach (i; 0..one.length)
    {
        if (i == other.length)
        {
            // The first string was longer than the second
            break;
        }

        if (one[$-i-1] != other[$-i-1])
        {
            // There was a character mismatch
            break;
        }

        if (one[$-i-1] == '.')
        {
            if (!doubleDots)
            {
                ++dots;
                doubleDots = true;
            }
        }
        else
        {
            doubleDots = false;
        }
    }

    return dots;
}

///
unittest
{
    import std.conv : text;

    immutable n1 = sharedDomains("irc.freenode.net", "help.freenode.net");
    assert((n1 == 2), n1.text);

    immutable n2 = sharedDomains("irc.rizon.net", "services.rizon.net");
    assert((n2 == 2), n2.text);

    immutable n3 = sharedDomains("www.google.com", "www.yahoo.com");
    assert((n3 == 1), n3.text);

    immutable n4 = sharedDomains("www.google.se", "www.google.co.uk");
    assert((n4 == 0), n4.text);

    immutable n5 = sharedDomains("", string.init);
    assert((n5 == 0), n5.text);

    immutable n6 = sharedDomains("irc.rizon.net", "rizon.net");
    assert((n6 == 2), n6.text);

    immutable n7 = sharedDomains("rizon.net", "rizon.net");
    assert((n7 == 2), n7.text);

    immutable n8 = sharedDomains("net", "net");
    assert((n8 == 1), n8.text);
}


// tabs
/++
 +  Returns spaces equal to that of num tabs (\t).
 +
 +  ------------
 +  string indentation = 2.tabs;
 +  assert((indentation == "        "), `"` ~  indentation ~ `"`);
 +  ------------
 +/
string tabs(uint spaces = 4)(int num) pure
{
    enum tab = ()
    {
        string indentation;

        foreach (i; 0..spaces)
        {
            indentation ~= ' ';
        }

        return indentation;
    }();

    assert((num >= 0), "Negative amount of tabs");

    string total;

    foreach (i; 0..num)
    {
        total ~= tab;
    }

    return total;
}

///
@system
unittest
{
    import std.exception : assertThrown;
    import core.exception : AssertError;

    immutable one = 1.tabs!4;
    immutable two = 2.tabs!3;
    immutable three = 3.tabs!2;
    immutable zero = 0.tabs;

    assert((one == "    "), one ~ '$');
    assert((two == "      "), two ~ '$');
    assert((three == "      "), three ~ '$');
    assert((zero == string.init), zero ~ '$');

    assertThrown!AssertError((-1).tabs);
}


// escaped
/++
 +  Escapes some common character so as to work better in regex expressions.
 +
 +  ------------
 +  string unescaped = "This is (very) difficult to regex[^!]";
 +  string easier = unescaped.escaped;
 +  assert((easier == "This is \(very\) difficult to regex\[\^!\]"), escaped);
 +  ------------
 +/
string escaped(const string line) @safe
{
    import std.regex : regex, replaceAll;

    const string[] toEscape =
    [
        r"\(",
        r"\)",
        r"\^",
        r"\[",
        r"\]",
    ];

    string replaced = line;

    foreach (character; toEscape)
    {
        replaced = replaced.replaceAll(character.regex, character);
    }

    return replaced;
}

///
unittest
{
    assert("(".escaped == r"\(");
    assert(")".escaped == r"\)");
    assert("^".escaped == r"\^");
    assert("[".escaped == r"\[");
    assert("]".escaped == r"\]");
    assert(string.init.escaped == string.init);
    assert("Lorem ipsum (sit amet)".escaped == r"Lorem ipsum \(sit amet\)");
}


// has
/++
 +  Checks a string to see if it contains a given substring or character.
 +
 +  This is not UTF-8 safe. It is naive in how it thinks a string always
 +  correspond to one set of codepoints and one set only.
 +
 +  ------------
 +  assert("Lorem ipsum".has("Lorem"));
 +  assert(!"Lorem ipsum".has('l'));
 +  assert("Lorem ipsum".has!(Yes.decode)(" "));
 +  ------------
 +/
bool has(Flag!"decode" decode = No.decode, T, C)(const T haystack, const C needle) @trusted
if (isSomeString!T && (is(C : T) || is(C : ElementType!T) || is(C : ElementEncodingType!T)))
{
    static if (is(C : T)) if (haystack == needle) return true;

    static if (decode || is(T : dstring) || is(T : wstring))
    {
        import std.string : indexOf;
        // dstring and wstring only work with indexOf, not countUntil
        return haystack.indexOf(needle) != -1;
    }
    else
    {
        // Only do this if we know it's not user text
        import std.algorithm.searching : canFind;

        static if (isSomeString!C)
        {
            return (cast(ubyte[])haystack).canFind(cast(ubyte[])needle);
        }
        else
        {
            return (cast(ubyte[])haystack).canFind(cast(ubyte)needle);
        }
    }
}

///
unittest
{
    assert("Lorem ipsum sit amet".has("sit"));
    assert("".has(""));
    assert(!"Lorem ipsum".has("sit amet"));
    assert("Lorem ipsum".has(' '));
    assert(!"Lorem ipsum".has('!'));
    assert("Lorem ipsum"d.has("m"d));
}

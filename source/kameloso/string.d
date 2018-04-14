/++
 +  String manipulation functions, used throughout the program complementing the
 +  standard library, as well as providing dumbed-down and optimised versions
 +  of existing functions therein.
 +/
module kameloso.string;

import core.time : Duration;
import std.range.primitives : ElementEncodingType, ElementType;
import std.traits : isSomeString;
import std.typecons : Flag, No, Yes;

@safe:


// nom
/++
 +  Finds the supplied separator token, returns the string up to that point,
 +  and advances the passed ref string to after the token.
 +
 +  Example:
 +  ------------
 +  string foobar = "foo bar";
 +  string foo = foobar.nom(" ");
 +  string bar = foobar;
 +
 +  assert((foo == "foo"), foo);
 +  assert((bar == "bar"), bar);
 +  assert(!foobar.length);
 +  ------------
 +
 +  Params:
 +      decode = Whether to use auto-decoding functions, or try to keep to non-
 +          decoding ones (when possible).
 +      line = String to walk and advance.
 +      separator = Token that deliminates what should be returned and to where
 +          to advance.
 +
 +  Returns:
 +      The string `line` from the start up to the separator. The original
 +      variable is advanced to after the separator.
 +/
pragma(inline)
T nom(Flag!"decode" decode = No.decode, T, C)(ref T line, const C separator,
    string callingFile = __FILE__, size_t callingLine = __LINE__) pure
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
        import std.string : representation;

        static if (isSomeString!C)
        {
            immutable index = line.representation.countUntil(separator.representation);
        }
        else
        {
            immutable index = line.representation.countUntil(cast(ubyte)separator);
        }
    }

    if (index == -1)
    {
        import std.format : format;
        throw new Exception(`Tried to nom too much: "%s with "%s"`
            .format(line, separator), callingFile, callingLine);
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
    {
        string user = "foo!bar@asdf.adsf.com";
        user = user.nom('!');
        assert((user == "foo"), user);
    }
}


// plurality
/++
 +  Get the correct singular or plural form of a word depending on the
 +  numerical count of it.
 +
 +  Example:
 +  ------------
 +  string one = 1.plurality("one", "two");
 +  string two = 2.plurality("one", "two");
 +  ------------
 +
 +  Params:
 +      num = Numerical count of the noun.
 +      singular = The noun in singular form.
 +      plural = The noun in plural form.
 +
 +  Returns:
 +      The singular string if num is 1 or -1, otherwise the plural string.
 +/
pragma(inline)
T plurality(T)(const int num, const T singular, const T plural) pure nothrow @nogc
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
 +  Removes paired preceding and trailing double quotes, unquoting a word.
 +
 +  Example:
 +  ------------
 +  string quoted= `"This is a quote"`;
 +  string unquotes = quoted.unquoted;
 +  assert((unquoted == "This is a quote"), unquoted);
 +  ------------
 +
 +  Params:
 +      line = The (potentially) quoted string.
 +
 +  Returns:
 +      A slice of the line argument that excludes the quotes.
 +/
T unquoted(Flag!"recurse" recurse = Yes.recurse, T)(const T line) pure nothrow @property
if (isSomeString!T)
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
 +  A cheaper variant of `std.algorithm.searching.startsWith`, since this is
 +  such a hotspot.
 +
 +  Example:
 +  ------------
 +  assert("Lorem ipsum sit amet".beginsWith("Lorem ip"));
 +  assert(!"Lorem ipsum sit amet".beginsWith("ipsum sit amet"));
 +  ------------
 +
 +  Params:
 +      haystack = Original line to examine.
 +      needle = Snippet of text to check if `haystack` begins with.
 +
 +  Returns:
 +      `true` if `haystack` starts with `needle`, `false` if not.
 +/
pragma(inline)
bool beginsWith(T)(const T haystack, const T needle) pure nothrow @nogc
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
bool beginsWith(T)(const T line, const ubyte charcode) pure nothrow @nogc
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


// stripPrefix
/++
 +  Strips a prefix word from a string, also stripping away some non-word
 +  characters.
 +
 +  This is to make a helper for stripping away bot prefixes, where such may be
 +  "`kameloso:`".
 +
 +  Example:
 +  ------------
 +  string prefixed = "kameloso: sudo MODE +o #channel :user";
 +  string command = prefixed.stripPrefix("kameloso");
 +  assert((command == "sudo MODE +o #channel :user"), command);
 +  ------------
 +
 +  Params:
 +      line = String line prefixed with `prefix`.
 +      prefix = Prefix to strip.
 +
 +  Returns:
 +      The passed line with the `prefix` sliced away.
 +/
string stripPrefix(const string line, const string prefix)
{
    import std.regex : matchFirst, regex;
    import std.string : munch, stripLeft;

    string slice = line.stripLeft();

    // the onus is on the caller that slice begins with prefix
    slice.nom!(Yes.decode)(prefix);

    enum pattern = "[:?! ]*(.+)";
    auto engine = pattern.regex;
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
 +  Express how much time has passed in a `Duration`, in natural (English)
 +  language.
 +
 +  Write the result to a passed output range `sink`.
 +
 +  Example:
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
 +
 +  Params:
 +      duration = A period of time.
 +/
void timeSince(Flag!"abbreviate" abbreviate = No.abbreviate, Sink)
    (auto ref Sink sink, const Duration duration) pure
{
    import std.format : formattedWrite;

    int days, hours, minutes, seconds;
    duration.split!("days", "hours", "minutes", "seconds")
        (days, hours, minutes, seconds);

    if (days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%dd", days);
        }
        else
        {
            sink.formattedWrite("%d %s", days, days.plurality("day", "days"));
        }
    }

    if (hours)
    {
        static if (abbreviate)
        {
            if (days) sink.put(' ');
            sink.formattedWrite("%dh", hours);
        }
        else
        {
            if (days)
            {
                if (minutes) sink.put(", ");
                else sink.put("and ");
            }
            sink.formattedWrite("%d %s", hours, hours.plurality("hour", "hours"));
        }
    }

    if (minutes)
    {
        static if (abbreviate)
        {
            if (hours) sink.put(' ');
            sink.formattedWrite("%dm", minutes);
        }
        else
        {
            if (hours) sink.put(" and ");
            sink.formattedWrite("%d %s", minutes, minutes.plurality("minute", "minutes"));
        }
    }

    if (!minutes && !hours && !days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%ds", seconds);
        }
        else
        {
            sink.formattedWrite("%d %s", seconds, seconds.plurality("second", "seconds"));
        }
    }
}

/// Ditto
string timeSince(Flag!"abbreviate" abbreviate = No.abbreviate)
    (const Duration duration)
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(50);
    sink.timeSince!abbreviate(duration);
    return sink.data;
}

///
unittest
{
    import core.time : msecs, seconds;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }

    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }

    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }

    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }

    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for LDC

    {
        immutable dur = 0.seconds;
        sink.timeSince(dur);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3_141_519_265.msecs;
        sink.timeSince(dur);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3599.seconds;
        sink.timeSince(dur);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }
}


// toEnum
/++
 +  Takes the member of an enum by string and returns that enum member.
 +
 +  It lowers to a big switch of the enum member strings. It is faster than
 +  `std.conv.to` and generates less template bloat.
 +
 +  Example:
 +  ------------
 +  enum SomeEnum { one, two, three };
 +
 +  SomeEnum foo = "one".toEnum!someEnum;
 +  SomeEnum bar = "three".toEnum!someEnum;
 +  ------------
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
        string enumSwitch = "import std.conv : ConvException;\n";
        enumSwitch ~= "with (Enum) switch (enumstring)\n{\n";

        foreach (memberstring; __traits(allMembers, Enum))
        {
            enumSwitch ~= `case "` ~ memberstring ~ `":`;
            enumSwitch ~= "return " ~ memberstring ~ ";\n";
        }

        enumSwitch ~= `default: throw new ConvException("No such " ~
            Enum.stringof ~ ": " ~ enumstring);}`;

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
 +  The inverse of `toEnum`, this function takes an enum member value and
 +  returns its string identifier.
 +
 +  It lowers to a big switch of the enum members. It is faster than
 +  `std.conv.to` and generates less template bloat.
 +
 +  Taken from: https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
 +
 +  Example:
 +  ------------
 +  enum SomeEnum { one, two, three };
 +
 +  string foo = SomeEnum.one.enumToString;
 +  assert((foo == "one"), foo);
 +  ------------
 +
 +  Params:
 +      value = Enum member whose string name we want.
 +
 +  Returns:
 +      The string name of the passed enum member.
 +/
pragma(inline)
string enumToString(Enum)(Enum value) pure nothrow
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
 +  Example:
 +  ------------
 +  int fifteen = numFromHex("F");
 +  int twofiftyfive = numFromHex("FF");
 +  ------------
 +
 +  Params:
 +      hex = Hexadecimal number in string form.
 +
 +  Returns:
 +      An integer equalling the value of the passed hexadecimal string.
 +/
uint numFromHex(Flag!"acceptLowercase" acceptLowercase = No.acceptLowercase)
    (const string hex) pure
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
 +      hexString = Hexadecimal number (colour) in string form.
 +      r = Reference integer for the red part of the hex string.
 +      g = Reference integer for the green part of the hex string.
 +      b = Reference integer for the blue part of the hex string.
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


// stripSuffix
/++
 +  Strips the supplied string from the end of a string.
 +
 +  Example:
 +  ------------
 +  string suffixed = "Kameloso";
 +  string stripped = suffixed.stripSuffix("oso");
 +  assert((stripped == "Kamel"), stripped);
 +  ------------
 +
 +  Params:
 +      fullStrip = Whether to allow for the stripping to clear the entire
 +          string.
 +      line = Original line to strip the suffix from.
 +      suffix = Suffix string to strip.
 +
 +  Returns:
 +      `line` with `suffix` sliced off.
 +/
string stripSuffix(Flag!"allowFullStrip" fullStrip = No.allowFullStrip)
    (const string line, const string suffix) pure nothrow @nogc
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


// sharedDomains
/++
 +  Calculates how many dot-separated suffixes two strings share.
 +
 +  This is useful to see to what extent two addresses are similar.
 +
 +  Example:
 +  ------------
 +  int numDomains = sharedDomains("irc.freenode.net", "leguin.freenode.net");
 +  assert(numDomains == 2);  // freenode.net
 +  ------------
 +
 +  Params:
 +      rawOne = First domain string.
 +      rawOther = Second domain string.
 +
 +  Returns:
 +      The number of domains the two strings share.
 +
 +  TODO:
 +      Support partial globs.
 +/
uint sharedDomains(const string rawOne, const string rawOther) pure nothrow
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
 +  Example:
 +  ------------
 +  string indentation = 2.tabs;
 +  assert((indentation == "        "), `"` ~  indentation ~ `"`);
 +  ------------
 +
 +  Params:
 +      spaces = How many spaces make up a tab.
 +      num = How many tabs we want.
 +
 +  Returns:
 +      Whitespace equalling (`num` ' `spaces`) spaces.
 +/
string tabs(uint spaces = 4)(int num) pure nothrow
{
    import std.range : repeat, takeExactly;
    import std.array : array, join;

    enum tab =  ' '.repeat.takeExactly(spaces).array;

    assert((num >= 0), "Negative amount of tabs");

    return tab.repeat.takeExactly(num).join;
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


// has
/++
 +  Checks a string to see if it contains a given substring or character.
 +
 +  This is not UTF-8 safe. It is naive in how it thinks a string always
 +  correspond to one set of codepoints and one set only.
 +
 +  Example:
 +  ------------
 +  assert("Lorem ipsum".has("Lorem"));
 +  assert(!"Lorem ipsum".has('l'));
 +  assert("Lorem ipsum".has!(Yes.decode)(" "));
 +  ------------
 +
 +  Params:
 +      decode = Whether to use auto-decoding functions, or try to keep to non-
 +          decoding ones (when possible).
 +      haystack = String to search for `needle`.
 +      needle = Substring to search `haystack` for.
 +
 +  Returns:
 +      Whether the passed string contained the passed substring or token.
 +/
bool has(Flag!"decode" decode = No.decode, T, C)(const T haystack, const C needle) pure
if (isSomeString!T && isSomeString!C || (is(C : T) || is(C : ElementType!T) ||
    is(C : ElementEncodingType!T)))
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
        import std.string : representation;

        static if (isSomeString!C)
        {
            return haystack.representation.canFind(needle.representation);
        }
        else
        {
            return haystack.representation.canFind(cast(ubyte)needle);
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


// strippedRight
/++
 +  Returns a slice of the passed string with any trailing whitespace and/or
 +  linebreaks sliced off.
 +
 +  Params:
 +      line = Line to stripRight.
 +
 +  Returns:
 +      The passed line without any trailing whitespace or linebreaks.
 +/
string strippedRight(const string line) pure nothrow @nogc @safe @property
{
    if (!line.length) return line;

    size_t pos = line.length;

    loop:
    while (pos > 0)
    {
        switch (line[pos-1])
        {
        case ' ':
        case '\n':
        case '\r':
        case '\t':
            --pos;
            break;

        default:
            break loop;
        }
    }

    return line[0..pos];
}

///
@safe
unittest
{
    {
        immutable trailing = "abc  ";
        immutable stripped = trailing.strippedRight;
        assert((stripped == "abc"), stripped);
    }
    {
        immutable trailing = "  ";
        immutable stripped = trailing.strippedRight;
        assert((stripped == ""), stripped);
    }
    {
        immutable empty = "";
        immutable stripped = empty.strippedRight;
        assert((stripped == ""), stripped);
    }
    {
        immutable noTrailing = "abc";
        immutable stripped = noTrailing.strippedRight;
        assert((stripped == "abc"), stripped);
    }
    {
        immutable linebreak = "abc\r\n  \r\n";
        immutable stripped = linebreak.strippedRight;
        assert((stripped == "abc"), stripped);
    }
}


// strippedLeft
/++
 +  Returns a slice of the passed string with any preceding whitespace and/or
 +  linebreaks sliced off.
 +
 +  Params:
 +      line = Line to stripLeft.
 +
 +  Returns:
 +      The passed line without any preceding whitespace or linebreaks.
 +/
string strippedLeft(const string line) pure nothrow @nogc @safe @property
{
    if (!line.length) return line;

    size_t pos;

    loop:
    while (pos < line.length)
    {
        switch (line[pos])
        {
        case ' ':
        case '\n':
        case '\r':
        case '\t':
            ++pos;
            break;

        default:
            break loop;
        }
    }

    return line[pos..$];
}

///
@safe
unittest
{
    {
        immutable preceded = "   abc";
        immutable stripped = preceded.strippedLeft;
        assert((stripped == "abc"), stripped);
    }
    {
        immutable preceded = "   ";
        immutable stripped = preceded.strippedLeft;
        assert((stripped == ""), stripped);
    }
    {
        immutable empty = "";
        immutable stripped = empty.strippedLeft;
        assert((stripped == ""), stripped);
    }
    {
        immutable noPreceded = "abc";
        immutable stripped = noPreceded.strippedLeft;
        assert((stripped == noPreceded), stripped);
    }
    {
        immutable linebreak  = "\r\n\r\n  abc";
        immutable stripped = linebreak.strippedLeft;
        assert((stripped == "abc"), stripped);
    }
}


// stripped
/++
 +  Returns a slice of the passed string with any preceding or trailing
 +  whitespace or linebreaks sliced off.
 +
 +  It merely calls both `strippedLeft` and `strippedRight`.
 +
 +  Params:
 +      line = Line to strip.
 +
 +  Returns:
 +      The passed line, stripped.
 +/
string stripped(const string line) pure nothrow @nogc @safe @property
{
    return line.strippedLeft.strippedRight;
}

///
@safe
unittest
{
    {
        immutable line = "   abc   ";
        immutable stripped_ = line.stripped;
        assert((stripped_ == "abc"), stripped_);
    }
    {
        immutable line = "   ";
        immutable stripped_ = line.stripped;
        assert((stripped_ == ""), stripped_);
    }
    {
        immutable line = "";
        immutable stripped_ = line.stripped;
        assert((stripped_ == ""), stripped_);
    }
    {
        immutable line = "abc";
        immutable stripped_ = line.stripped;
        assert((stripped_ == "abc"), stripped_);
    }
    {
        immutable line = " \r\n  abc\r\n\r\n";
        immutable stripped_ = line.stripped;
        assert((stripped_ == "abc"), stripped_);
    }
}

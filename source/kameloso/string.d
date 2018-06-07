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
 +
 +  enum line = "abc def ghi";
 +  string def = line[4..$].nom(" ");  // now with auto ref
 +  ------------
 +
 +  Params:
 +      decode = Whether to use auto-decoding functions, or try to keep to non-
 +          decoding ones (when possible).
 +      line = String to walk and advance.
 +      separator = Token that deliminates what should be returned and to where
 +          to advance.
 +      callingFile = Name of the calling source file.
 +      callingLine = Line number where in the source file this is called.
 +
 +  Returns:
 +      The string `line` from the start up to the separator. The original
 +      variable is advanced to after the separator.
 +/
pragma(inline)
T nom(Flag!"decode" decode = No.decode, T, C)(auto ref T line, const C separator,
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



/// Ditto
pragma(inline)
bool beginsWith(T)(const T line, const ubyte charcode) pure nothrow @nogc
if (isSomeString!T)
{
    if (!line.length) return false;

    return (line[0] == charcode);
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
    import kameloso.string : strippedLeft;
    import std.regex : matchFirst, regex;

    string slice = line.strippedLeft;

    // the onus is on the caller that slice begins with prefix
    slice.nom!(Yes.decode)(prefix);

    enum pattern = "[:?! ]*(.+)";
    auto engine = pattern.regex;
    auto hits = slice.matchFirst(engine);
    return hits[1];
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

    return (line[($-suffix.length)..$] == suffix) ? line[0..($-suffix.length)] : line;
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


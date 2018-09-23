/++
 +  String manipulation functions, used throughout the program complementing the
 +  standard library, as well as providing dumbed-down and optimised versions
 +  of existing functions therein.
 +
 +  Notable functions are `nom`, which allows for advancing a string past a
 +  supplied substring; and `contains`, which uses an educated approach to
 +  finding substrings in a string.
 +/
module kameloso.string;

import std.range.primitives : ElementEncodingType, ElementType, isOutputRange;
import std.traits : isMutable, isSomeString;
import std.typecons : Flag, No, Yes;

@safe:


// nom
/++
 +  Given some string, finds the supplied separator token in it, returns the
 +  string up to that point, and advances the passed string by ref to after the
 +  token.
 +
 +  The naming is in line with standard library functions such as
 +  `std.string.munch`, `std.file.slurp` and others.
 +
 +  Example:
 +  ---
 +  string foobar = "foo bar!";
 +  string foo = foobar.nom(" ");
 +  string bar = foobar.nom("!");
 +
 +  assert((foo == "foo"), foo);
 +  assert((bar == "bar"), bar);
 +  assert(!foobar.length);
 +
 +  enum line = "abc def ghi";
 +  string def = line[4..$].nom(" ");  // now with auto ref
 +  ---
 +
 +  Params:
 +      decode = Whether to use auto-decoding functions, or try to keep to non-
 +          decoding ones (when possible).
 +      line = String to walk and advance.
 +      separator = Token that deliminates what should be returned and to where
 +          to advance.
 +      callingFile = Name of the calling source file, used to pass along when
 +          throwing an exception.
 +      callingLine = Line number where in the source file this is called, used
 +          to pass along when throwing an exception.
 +
 +  Returns:
 +      The string `line` from the start up to the separator token. The original
 +      variable is advanced to after the token.
 +/
pragma(inline)
T nom(Flag!"decode" decode = No.decode, T, C)(auto ref T line, const C separator,
    const string callingFile = __FILE__, const size_t callingLine = __LINE__) pure
if (isMutable!T && isSomeString!T && (is(C : T) || is(C : ElementType!T) || is(C : ElementEncodingType!T)))
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
        throw new Exception(`Tried to nom too much: "%s" with "%s"`
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
    {
        immutable def = "abc def ghi"[4..$].nom(" ");
        assert((def == "def"), def);
    }
}


// plurality
/++
 +  Selects the correct singular or plural form of a word depending on the
 +  numerical count of it.
 +
 +  Example:
 +  ---
 +  string one = 1.plurality("one", "two");
 +  string two = 2.plurality("one", "two");
 +  string many = (-2).plurality("one", "many");
 +  string many0 = 0.plurlity("one", "many");
 +
 +  assert((one == "one"), one);
 +  assert((two == "two"), two);
 +  assert((many == "many"), many);
 +  assert((many0 == "many"), many0);
 +  ---
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


// unenclosed
/++
 +  Removes paired preceding and trailing tokens around a string line.
 +
 +  You should not need to use this directly; rather see `unquoted` and
 +  `unsinglequoted`.
 +
 +  Params:
 +      token = Token character to strip away.
 +  	line = String line to remove any enclosing tokens from.
 +
 +  Returns:
 +      A slice of the passed string line without enclosing tokens.
 +/
private T unenclosed(char token = '"', T)(const T line) pure nothrow @nogc @property
if (isSomeString!T)
{
    enum escaped = "\\" ~ token;

    if (line.length < 2)
    {
        return line;
    }
    else if ((line[0] == token) && (line[$-1] == token))
    {
        if ((line.length >= 3) && (line[$-2..$] == escaped))
        {
            // End quote is escaped
            return line;
        }

        return line[1..$-1].unenclosed!token;
    }
    else
    {
        return line;
    }
}


// unquoted
/++
 +  Removes paired preceding and trailing double quotes, unquoting a word.
 +
 +  Does not decode the string and may thus give weird results on weird inputs.
 +
 +  Example:
 +  ---
 +  string quoted = `"This is a quote"`;
 +  string unquotedLine = quoted.unquoted;
 +  assert((unquotedLine == "This is a quote"), unquotedLine);
 +  ---
 +
 +  Params:
 +      line = The (potentially) quoted string.
 +
 +  Returns:
 +      A slice of the `line` argument that excludes the quotes.
 +/
pragma(inline)
T unquoted(T)(const T line) pure nothrow @nogc @property
{
    return unenclosed!'"'(line);
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


// unsinglequoted
/++
 +  Removes paired preceding and trailing single quotes around a line.
 +
 +  Does not decode the string and may thus give weird results on weird inputs.
 +
 +  Example:
 +  ---
 +  string quoted = `'This is single-quoted'`;
 +  string unquotedLine = quoted.unsinglequoted;
 +  assert((unquotedLine == "This is single-quoted"), unquotedLine);
 +  ---
 +
 +  Params:
 +      line = The (potentially) single-quoted string.
 +
 +  Returns:
 +      A slice of the `line` argument that excludes the single-quotes.
 +/
pragma(inline)
T unsinglequoted(T)(const T line) pure nothrow @nogc @property
{
    return unenclosed!'\''(line);
}

///
unittest
{
    assert(`'Lorem ipsum sit amet'`.unsinglequoted == "Lorem ipsum sit amet");
    assert(`''''Lorem ipsum sit amet''''`.unsinglequoted == "Lorem ipsum sit amet");
    // Unbalanced quotes are left untouched
    assert(`'Lorem ipsum sit amet`.unsinglequoted == `'Lorem ipsum sit amet`);
    assert(`'Lorem \'`.unsinglequoted == `'Lorem \'`);
    assert("'Lorem \\'".unsinglequoted == "'Lorem \\'");
    assert(`'`.unsinglequoted == `'`);
}


// beginsWith
/++
 +  A cheaper variant of `std.algorithm.searching.startsWith`, since this is
 +  such a hotspot.
 +
 +  Merely slices; does not decode the string and may thus give weird results on
 +  weird inputs.
 +
 +  Example:
 +  ---
 +  assert("Lorem ipsum sit amet".beginsWith("Lorem ip"));
 +  assert(!"Lorem ipsum sit amet".beginsWith("ipsum sit amet"));
 +  ---
 +
 +  Params:
 +      haystack = Original line to examine.
 +      needle = Snippet of text to check if `haystack` begins with.
 +
 +  Returns:
 +      `true` if `haystack` begins with `needle`, `false` if not.
 +/
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


// beginsWith
/++
 +  A cheaper variant of `std.algorithm.searching.startsWith`, since this is
 +  such a hotspot.
 +
 +  Merely slices; does not decode the string and may thus give weird results on
 +  weird inputs.
 +
 +  Overload that takes a `char` or `ubyte` as beginning character, instead of
 +  a full string like the primary overload.
 +
 +  Example:
 +  ---
 +  assert("Lorem ipsum sit amet".beginsWith('L'));
 +  assert(!"Lorem ipsum sit amet".beginsWith('o'));
 +  ---
 +
 +  Params:
 +      haystack = Original line to examine.
 +      needle = The `char` (or technically `ubyte`) to check if `haystack`
 +          begins with.
 +
 +  Returns:
 +      `true` if `haystack` begins with `needle`, `false` if not.
 +/
bool beginsWith(T)(const T haystack, const ubyte needle) pure nothrow @nogc
if (isSomeString!T)
{
    if (!haystack.length) return false;

    return (haystack[0] == needle);
}

///
unittest
{
    assert(":Lorem ipsum".beginsWith(':'));
    assert(!":Lorem ipsum".beginsWith(';'));
}


// beginsWithOneOf
/++
 +  Checks whether or not the first letter of a string begins with any of the
 +  passed string of characters.
 +
 +  Wraps `contains`.
 +
 +  Merely slices; does not decode the string and may thus give weird results on
 +  weird inputs.
 +
 +  Params:
 +      haystack = String line to check the beginning of.
 +      needles = String of characters to test and see whether `haystack` begins
 +          with any of them.
 +
 +  Returns:
 +      `true` if the first character of `haystack` is also in `characters`,
 +      `false` if not.
 +/
pragma(inline)
bool beginsWithOneOf(T)(const T haystack, const T needles) pure nothrow @nogc
if (isSomeString!T)
{
    // All strings begin with an empty string
    if (!needles.length) return true;

    // An empty line begins with nothing
    if (!haystack.length) return false;

    return needles.contains(haystack[0]);
}

///
unittest
{
    assert("#channel".beginsWithOneOf("#%+"));
    assert(!"#channel".beginsWithOneOf("~%+"));
    assert("".beginsWithOneOf(""));
    assert("abc".beginsWithOneOf(string.init));
    assert(!"".beginsWithOneOf("abc"));
}


// beginsWithOneOf
/++
 +  Checks whether or not the first letter of a string begins with any of the
 +  passed string of characters.
 +
 +  Overload that takes a single `char` or `ubyte` as "string" to identify the
 +  "beginning" of, which in this case translates to the `char`/`ubyte` itself.
 +
 +  Wraps `contains`.
 +
 +  Merely slices; does not decode the string and may thus give weird results on
 +  weird inputs.
 +
 +  Params:
 +      haystraw = Single character to evaluate whether it exists in `needles`.
 +      needles = String of characters to test and see whether `haystraw`
 +          equals any of them.
 +
 +  Returns:
 +      `true` if the `haystraw` is in `needles`, `false` if not.
 +/
pragma(inline)
bool beginsWithOneOf(T)(const ubyte haystraw, const T needles) pure nothrow @nogc
if (isSomeString!T)
{
    // All strings begin with an empty string, even if we're only looking at one character
    if (!needles.length) return true;

    return needles.contains(haystraw);
}

///
unittest
{
    assert('#'.beginsWithOneOf("#%+"));
    assert(!'#'.beginsWithOneOf("~%+"));
    assert('a'.beginsWithOneOf(string.init));
    assert(!'d'.beginsWithOneOf("abc"));
}


// stripPrefix
/++
 +  Strips a prefix word from a string, optionally also stripping away some
 +  non-word characters (`:?! `).
 +
 +  This is to make a helper for stripping away bot prefixes, where such may be
 +  "`kameloso:`".
 +
 +  Example:
 +  ---
 +  string prefixed = "kameloso: sudo MODE +o #channel :user";
 +  string command = prefixed.stripPrefix("kameloso");
 +  assert((command == "sudo MODE +o #channel :user"), command);
 +  ---
 +
 +  Params:
 +      demandSeparatingChars = Makes it a necessity that `line` is followed
 +          by one of the prefix letters `:?! `. If it isn't, the `line` string
 +          will be returned as is.
 +      line = String line prefixed with `prefix`, potentially including
 +          separating characters.
 +      prefix = Prefix to strip.
 +
 +  Returns:
 +      The passed line with the `prefix` sliced away.
 +/
string stripPrefix(Flag!"demandSeparatingChars" demandSeparatingChars = Yes.demandSeparatingChars)
    (const string line, const string prefix) pure
{
    // Characters to also strip away after `prefix`.
    enum separatingChars = ":?! ";

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.nom!(Yes.decode)(prefix);

    static if (demandSeparatingChars)
    {
        // Return the whole line, a non-match, if there are no separating characters
        // (at least one of [:?! ])
        if (!slice.beginsWithOneOf(separatingChars)) return line;
        slice = slice[1..$];  // One less call to beginsWithOneOf if we do this here
    }

    while (slice.length && slice.beginsWithOneOf(separatingChars))
    {
        slice = slice[1..$];
    }

    return slice;
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

    immutable isnotabot = "kamelosois a bot".stripPrefix("kameloso");
    assert((isnotabot == "kamelosois a bot"), isnotabot);

    immutable isabot = "kamelosois a bot".stripPrefix!(No.demandSeparatingChars)("kameloso");
    assert((isabot == "is a bot"), isabot);
}


// stripSuffix
/++
 +  Strips the supplied string from the end of a string.
 +
 +  Example:
 +  ---
 +  string suffixed = "Kameloso";
 +  string stripped = suffixed.stripSuffix("oso");
 +  assert((stripped == "Kamel"), stripped);
 +  ---
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
 +  ---
 +  int numDomains = sharedDomains("irc.freenode.net", "leguin.freenode.net");
 +  assert(numDomains == 2);  // freenode.net
 +  ---
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

    immutable n9 = sharedDomains("forum.dlang.org", "...");
    assert((n9 == 0), n8.text);
}


// tabs
/++
 +  Returns *spaces* equal to that of `num` tabs (\t).
 +
 +  Example:
 +  ---
 +  string indentation = 2.tabs;
 +  assert((indentation == "        "), `"` ~  indentation ~ `"`);
 +  string smallIndent = 1.tabs!2;
 +  assert((smallIndent == "  "), `"` ~  smallIndent ~ `"`);
 +  ---
 +
 +  Params:
 +      spaces = How many spaces make up a tab.
 +      num = How many tabs we want.
 +
 +  Returns:
 +      Whitespace equalling (`num` * `spaces`) spaces.
 +/
auto tabs(uint spaces = 4)(const int num) pure nothrow @nogc @property
{
    import std.range : repeat, takeExactly;
    import std.algorithm.iteration : joiner;
    import std.array : array;

    assert((num >= 0), "Negative number of tabs");

    enum char[spaces] tab = ' '.repeat.takeExactly(spaces).array;

    return tab[].repeat.takeExactly(num).joiner;
}

///
@system
unittest
{
    import std.array : Appender;
    import std.conv : to;
    import std.exception : assertThrown;
    import std.format : formattedWrite;
    import std.algorithm.comparison : equal;
    import core.exception : AssertError;

    auto one = 1.tabs!4;
    auto two = 2.tabs!3;
    auto three = 3.tabs!2;
    auto zero = 0.tabs;

    assert(one.equal("    "), one.to!string);
    assert(two.equal("      "), two.to!string);
    assert(three.equal("      "), three.to!string);
    assert(zero.equal(string.init), zero.to!string);

    assertThrown!AssertError((-1).tabs);

    Appender!string sink;
    sink.formattedWrite("%sHello world", 2.tabs!2);
    assert((sink.data == "    Hello world"), sink.data);
}


// contains
/++
 +  Checks a string to see if it contains a given substring or character.
 +
 +  Merely slices; this is not UTF-8 safe. It is naive in how it thinks a string
 +  always correspond to one set of codepoints and one set only.
 +
 +  Example:
 +  ---
 +  assert("Lorem ipsum".contains("Lorem"));
 +  assert(!"Lorem ipsum".contains('l'));
 +  assert("Lorem ipsum".contains!(Yes.decode)(" "));
 +  ---
 +
 +  Params:
 +      decode = Whether to use auto-decoding functions, or try to keep to non-
 +          decoding ones (when possible).
 +      haystack = String to search for `needle`.
 +      needle = Substring to search `haystack` for.
 +
 +  Returns:
 +      Whether the passed `haystack` string contained the passed `needle`
 +      substring or token.
 +/
bool contains(Flag!"decode" decode = No.decode, T, C)(const T haystack, const C needle) pure
if (isSomeString!T && isSomeString!C || (is(C : T) || is(C : ElementType!T) ||
    is(C : ElementEncodingType!T)))
{
    static if (is(C : T)) if (haystack == needle) return true;

    static if (decode || is(T : dstring) || is(T : wstring) ||
        is(C : ElementType!T) || is(C : ElementEncodingType!T))
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
    assert("Lorem ipsum sit amet".contains("sit"));
    assert("".contains(""));
    assert(!"Lorem ipsum".contains("sit amet"));
    assert("Lorem ipsum".contains(' '));
    assert(!"Lorem ipsum".contains('!'));
    assert("Lorem ipsum"d.contains("m"d));
    assert("Lorem ipsum".contains(['p', 's', 'u', 'm' ]));
    assert([ 'L', 'o', 'r', 'e', 'm' ].contains([ 'L' ]));
    assert([ 'L', 'o', 'r', 'e', 'm' ].contains("Lor"));
    assert([ 'L', 'o', 'r', 'e', 'm' ].contains(cast(char[])[]));
}

/// Legacy alias to `contains`.
alias has = contains;

///
unittest
{
    assert("Lorem ipsum sit amet".has("sit"));
}

// strippedRight
/++
 +  Returns a slice of the passed string with any trailing whitespace and/or
 +  linebreaks sliced off.
 +
 +  Duplicates `std.string.stripRight`, which we can no longer trust not to
 +  assert on unexpected input.
 +
 +  Params:
 +      line = Line to strip the right side of.
 +
 +  Returns:
 +      The passed line without any trailing whitespace or linebreaks.
 +/
string strippedRight(const string line) pure nothrow @nogc @property
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
 +  Duplicates `std.string.stripLeft`, which we can no longer trust not to
 +  assert on unexpected input.
 +
 +  Params:
 +      line = Line to strip the left side of.
 +
 +  Returns:
 +      The passed line without any preceding whitespace or linebreaks.
 +/
string strippedLeft(const string line) pure nothrow @nogc @property
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
 +  It merely calls both `strippedLeft` and `strippedRight`. As such it
 +  duplicates `std.string.strip`, which we can no longer trust not to assert
 +  on unexpected input.
 +
 +  Params:
 +      line = Line to strip both the right and left side of.
 +
 +  Returns:
 +      The passed line, stripped of surrounding whitespace.
 +/
string stripped(const string line) pure nothrow @nogc @property
{
    return line.strippedLeft.strippedRight;
}

///
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


// encode64
/++
 +  Base64-encodes a string.
 +
 +  Merely wraps `std.base64.Base64.encode` and `std.string.representation`
 +  into one function that will work with strings.
 +
 +  Params:
 +      line = String line to encode.
 +
 +  Returns:
 +      An encoded Base64 string.
 +
 +  See_Also:
 +      https://en.wikipedia.org/wiki/Base64
 +/
string encode64(const string line) pure nothrow
{
    import std.base64 : Base64;
    import std.string : representation;

    return Base64.encode(line.representation);
}

///
unittest
{
    {
        immutable password = "harbl snarbl 12345";
        immutable encoded = encode64(password);
        assert((encoded == "aGFyYmwgc25hcmJsIDEyMzQ1"), encoded);
    }
    {
        immutable string password;
        immutable encoded = encode64(password);
        assert(!encoded.length, encoded);
    }
}


// decode64
/++
 +  Base64-decodes a string.
 +
 +  Merely wraps `std.base64.Base64.decode` and `std.string.representation`
 +  into one function that will work with strings.
 +
 +  Params:
 +      encoded = Encoded string to decode.
 +
 +  Returns:
 +      A decoded normal string.
 +
 +  See_Also:
 +      https://en.wikipedia.org/wiki/Base64
 +/
string decode64(const string encoded) pure
{
    import std.base64 : Base64;
    return (cast(char[])Base64.decode(encoded)).idup;
}

///
unittest
{
    {
        immutable password = "base64:aGFyYmwgc25hcmJsIDEyMzQ1";
        immutable decoded = decode64(password[7..$]);
        assert((decoded == "harbl snarbl 12345"), decoded);
    }
    {
        immutable password = "base64:";
        immutable decoded = decode64(password[7..$]);
        assert(!decoded.length, decoded);
    }
}

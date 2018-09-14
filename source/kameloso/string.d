/++
 +  String manipulation functions, used throughout the program complementing the
 +  standard library, as well as providing dumbed-down and optimised versions
 +  of existing functions therein.
 +/
module kameloso.string;

import std.range.primitives : ElementEncodingType, ElementType, isOutputRange;
import std.traits : isSomeString;
import std.typecons : Flag, No, Yes;

@safe:


// nom
/++
 +  Finds the supplied separator token, returns the string up to that point,
 +  and advances the passed ref string to after the token.
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
 +      callingFile = Name of the calling source file.
 +      callingLine = Line number where in the source file this is called.
 +
 +  Returns:
 +      The string `line` from the start up to the separator. The original
 +      variable is advanced to after the separator.
 +/
pragma(inline)
T nom(Flag!"decode" decode = No.decode, T, C)(auto ref T line, const C separator,
    const string callingFile = __FILE__, const size_t callingLine = __LINE__) pure
if (isSomeString!T && (is(C : T) || is(C : ElementType!T) || is(C : ElementEncodingType!T)))
{
    return T.init;
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
    return T.init;
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
    return T.init;
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
 +      A slice of the line argument that excludes the quotes.
 +/
pragma(inline)
T unquoted(T)(const T line) pure nothrow @nogc @property
{
    return T.init;
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
 +      A slice of the line argument that excludes the single-quotes.
 +/
pragma(inline)
T unsinglequoted(T)(const T line) pure nothrow @nogc @property
{
    return T.init;
}



// beginsWith
/++
 +  A cheaper variant of `std.algorithm.searching.startsWith`, since this is
 +  such a hotspot.
 +
 +  Does not decode the string and may thus give weird results on weird inputs.
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
 +      `true` if `haystack` starts with `needle`, `false` if not.
 +/
pragma(inline)
bool beginsWith(T)(const T haystack, const T needle) pure nothrow @nogc
if (isSomeString!T)
{
    return false;
}

/// Ditto
pragma(inline)
bool beginsWith(T)(const T line, const ubyte charcode) pure nothrow @nogc
if (isSomeString!T)
{
    return false;
}



// beginsWithOneOf
/++
 +  Checks whether or not the first letter of a string begins with any of the
 +  passed string of characters.
 +
 +  Merely a wrapper of `contains`.
 +
 +  Params:
 +      haystack = String line to check the beginning of.
 +      needles = String of characters to test and see if `line` begins with
 +          any of them.
 +
 +  Returns:
 +      True if the first character of `line` is also in `characters`, false if
 +      not.
 +/
pragma(inline)
bool beginsWithOneOf(T)(const T haystack, const T needles) pure nothrow @nogc
if (isSomeString!T)
{
    return false;
}


/// Ditto
pragma(inline)
bool beginsWithOneOf(T)(const ubyte haystraw, const T needles) pure nothrow @nogc
if (isSomeString!T)
{
    return false;
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
 +  ---
 +  string prefixed = "kameloso: sudo MODE +o #channel :user";
 +  string command = prefixed.stripPrefix("kameloso");
 +  assert((command == "sudo MODE +o #channel :user"), command);
 +  ---
 +
 +  Params:
 +      line = String line prefixed with `prefix`.
 +      prefix = Prefix to strip.
 +
 +  Returns:
 +      The passed line with the `prefix` sliced away.
 +/
string stripPrefix(Flag!"demandSeparatingChars" demandSeparatingChars = Yes.demandSeparatingChars)
    (const string line, const string prefix) pure
{
    return "";
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
    return "";
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
    return 0;
}


// tabs
/++
 +  Returns spaces equal to that of num tabs (\t).
 +
 +  Example:
 +  ---
 +  string indentation = 2.tabs;
 +  assert((indentation == "        "), `"` ~  indentation ~ `"`);
 +  ---
 +
 +  Params:
 +      spaces = How many spaces make up a tab.
 +      num = How many tabs we want.
 +
 +  Returns:
 +      Whitespace equalling (`num` ' `spaces`) spaces.
 +/
auto tabs(uint spaces = 4)(const int num) pure nothrow @nogc @property
{
    return "";
}


// contains
/++
 +  Checks a string to see if it contains a given substring or character.
 +
 +  This is not UTF-8 safe. It is naive in how it thinks a string always
 +  correspond to one set of codepoints and one set only.
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
 +      Whether the passed string contained the passed substring or token.
 +/
bool contains(Flag!"decode" decode = No.decode, T, C)(const T haystack, const C needle) pure
if (isSomeString!T && isSomeString!C || (is(C : T) || is(C : ElementType!T) ||
    is(C : ElementEncodingType!T)))
{
    return false;
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
string strippedRight(const string line) pure nothrow @nogc @property
{
    return "";
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
string strippedLeft(const string line) pure nothrow @nogc @property
{
    return "";
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
string stripped(const string line) pure nothrow @nogc @property
{
    return "";
}



// encode64
/++
 +  Base64-encodes a string.
 +
 +  Params:
 +      line = String line to encode.
 +
 +  Returns:
 +      An encoded Base64 string.
 +/
string encode64(const string line) @safe pure nothrow
{
    return "";
}


// decode64
/++
 +  Base64-decodes a string.
 +
 +  Params:
 +      encoded = Encoded string to decode.
 +
 +  Returns:
 +      A decoded normal string.
 +/
string decode64(const string encoded) @safe pure
{
    return "";
}


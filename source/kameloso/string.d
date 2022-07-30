/++
    Various functions that do string manipulation.
 +/
module kameloso.string;

private:

import dialect.defs : IRCClient;
import std.typecons : Flag, No, Yes;

public:


// stripSeparatedPrefix
/++
    Strips a prefix word from a string, optionally also stripping away some
    non-word characters (currently ":;?! ").

    This is to make a helper for stripping away bot prefixes, where such may be
    "kameloso: ".

    Example:
    ---
    string prefixed = "kameloso: sudo MODE +o #channel :user";
    string command = prefixed.stripSeparatedPrefix("kameloso");
    assert((command == "sudo MODE +o #channel :user"), command);
    ---

    Params:
        line = String line prefixed with `prefix`, potentially including
            separating characters.
        prefix = Prefix to strip.
        demandSep = Makes it a necessity that `line` is followed
            by one of the prefix letters ": !?;". If it isn't, the `line` string
            will be returned as is.

    Returns:
        The passed line with the `prefix` sliced away.
 +/
auto stripSeparatedPrefix(const string line,
    const string prefix,
    const Flag!"demandSeparatingChars" demandSep = Yes.demandSeparatingChars) pure @nogc
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
{
    import lu.string : nom, strippedLeft;
    import std.algorithm.comparison : among;
    import std.meta : aliasSeqOf;

    enum separatingChars = ": !?;";  // In reasonable order of likelihood

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.nom!(Yes.decode)(prefix);

    if (demandSep)
    {
        // Return the whole line, a non-match, if there are no separating characters
        // (at least one of the chars in separatingChars)
        if (!slice.length || !slice[0].among!(aliasSeqOf!separatingChars)) return line;
    }

    while (slice.length && slice[0].among!(aliasSeqOf!separatingChars))
    {
        slice = slice[1..$];
    }

    return slice.strippedLeft(separatingChars);
}

///
unittest
{
    immutable lorem = "say: lorem ipsum".stripSeparatedPrefix("say");
    assert((lorem == "lorem ipsum"), lorem);

    immutable notehello = "note!!!! zorael hello".stripSeparatedPrefix("note");
    assert((notehello == "zorael hello"), notehello);

    immutable sudoquit = "sudo quit :derp".stripSeparatedPrefix("sudo");
    assert((sudoquit == "quit :derp"), sudoquit);

    /*immutable eightball = "8ball predicate?".stripSeparatedPrefix("");
    assert((eightball == "8ball predicate?"), eightball);*/

    immutable isnotabot = "kamelosois a bot".stripSeparatedPrefix("kameloso");
    assert((isnotabot == "kamelosois a bot"), isnotabot);

    immutable isabot = "kamelosois a bot"
        .stripSeparatedPrefix("kameloso", No.demandSeparatingChars);
    assert((isabot == "is a bot"), isabot);

    immutable doubles = "kameloso            is a snek"
        .stripSeparatedPrefix("kameloso");
    assert((doubles == "is a snek"), doubles);
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.

    Params:
        line = String to replace tokens in.
        client = The current [dialect.defs.IRCClient|IRCClient].

    Returns:
        A modified string with token occurrences replaced.
 +/
auto replaceTokens(const string line, const IRCClient client) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replaceTokens
        .replace("$nickname", client.nickname);
}

///
unittest
{
    import kameloso.constants : KamelosoInfo;
    import std.format : format;

    IRCClient client;
    client.nickname = "harbl";

    {
        immutable line = "asdf $nickname is kameloso version $version from $source";
        immutable expected = "asdf %s is kameloso version %s from %s"
            .format(client.nickname, cast(string)KamelosoInfo.version_,
                cast(string)KamelosoInfo.source);
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "";
        immutable expected = "";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
    {
        immutable line = "blerp";
        immutable expected = "blerp";
        immutable actual = line.replaceTokens(client);
        assert((actual == expected), actual);
    }
}


// replaceTokens
/++
    Apply some common text replacements. Used on part and quit reasons.
    Overload that doesn't take an [dialect.defs.IRCClient|IRCClient] and as such can't
    replace `$nickname`.

    Params:
        line = String to replace tokens in.

    Returns:
        A modified string with token occurrences replaced.
 +/
auto replaceTokens(const string line) @safe pure nothrow
{
    import kameloso.constants : KamelosoInfo;
    import std.array : replace;

    return line
        .replace("$version", cast(string)KamelosoInfo.version_)
        .replace("$source", cast(string)KamelosoInfo.source);
}


// splitWithQuotes
/++
    Splits a string into an array of strings by whitespace, but honours quotes.

    Intended to be used with ASCII strings; may or may not work with more
    elaborate UTF-8 strings.

    TODO: Replace with [lu.string.splitWithQuotes] after its next release.

    Example:
    ---
    string s = `title "this is my title" author "john doe"`;
    immutable splitUp = splitWithQuotes(s);
    assert(splitUp == [ "title", "this is my title", "author", "john doe" ]);
    ---

    Params:
        line = Input string.

    Returns:
        A `string[]` composed of the input string split up into substrings,
        deliminated by whitespace. Quoted sections are treated as one substring.
 +/
auto splitWithQuotes(const string line)
{
    import std.array : Appender;
    import std.string : representation;

    if (!line.length) return null;

    Appender!(string[]) sink;
    sink.reserve(8);

    size_t start;
    bool betweenQuotes;
    bool escaping;
    bool escapedAQuote;
    bool escapedABackslash;

    string replaceEscaped(const string line)
    {
        import std.array : replace;

        string slice = line;  // mutable
        if (escapedABackslash) slice = slice.replace(`\\`, "\1\1");
        if (escapedAQuote) slice = slice.replace(`\"`, `"`);
        if (escapedABackslash) slice = slice.replace("\1\1", `\`);
        return slice;
    }

    foreach (immutable i, immutable c; line.representation)
    {
        if (escaping)
        {
            if (c == '\\')
            {
                escapedABackslash = true;
            }
            else if (c == '"')
            {
                escapedAQuote = true;
            }

            escaping = false;
        }
        else if (c == ' ')
        {
            if (betweenQuotes)
            {
                // do nothing
            }
            else if (i == start)
            {
                ++start;
            }
            else
            {
                // commit
                sink.put(line[start..i]);
                start = i+1;
            }
        }
        else if (c == '\\')
        {
            escaping = true;
        }
        else if (c == '"')
        {
            if (betweenQuotes)
            {
                if (escapedAQuote || escapedABackslash)
                {
                    sink.put(replaceEscaped(line[start+1..i]));
                    escapedAQuote = false;
                    escapedABackslash = false;
                }
                else if (i > start+1)
                {
                    sink.put(line[start+1..i]);
                }

                betweenQuotes = false;
                start = i+1;
            }
            else if (i > start+1)
            {
                sink.put(line[start+1..i]);
                betweenQuotes = true;
                start = i+1;
            }
            else
            {
                betweenQuotes = true;
            }
        }
    }

    if (line.length > start+1)
    {
        if (betweenQuotes)
        {
            if (escapedAQuote || escapedABackslash)
            {
                sink.put(replaceEscaped(line[start+1..$]));
            }
            else
            {
                sink.put(line[start+1..$]);
            }
        }
        else
        {
            sink.put(line[start..$]);
        }
    }

    return sink.data;
}

///
unittest
{
    import std.conv : text;

    {
        enum input = `title "this is my title" author "john doe"`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            "this is my title",
            "author",
            "john doe"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `string without quotes`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "string",
            "without",
            "quotes",
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = string.init;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `title "this is \"my\" title" author "john\\" doe`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            `this is "my" title`,
            "author",
            `john\`,
            "doe"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `title "this is \"my\" title" author "john\\\" doe`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "title",
            `this is "my" title`,
            "author",
            `john\" doe`
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `this has "unbalanced quotes`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected =
        [
            "this",
            "has",
            "unbalanced quotes"
        ];
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `""`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `"`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
    {
        enum input = `"""""""""""`;
        immutable splitUp = splitWithQuotes(input);
        immutable expected = (string[]).init;
        assert(splitUp == expected, splitUp.text);
    }
}

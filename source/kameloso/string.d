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
auto stripSeparatedPrefix(
    const string line,
    const string prefix,
    const Flag!"demandSeparatingChars" demandSep = Yes.demandSeparatingChars) pure
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


// replaceRandom
/++
    Replaces `$random` and `$random(i..n)` tokens in a string with corresponding
    random values.

    If given only `$random`, a value between the passed `defaultLowerBound` inclusive
    to `defaultUpperBound` exclusive is substituted, whereas if a range of
    `$random(i..n)` is given, a value between `i` inclusive and `n` exclusive is
    substituted.

    On syntax errors, or if `n` is not greater than `i`, the original line is
    silently returned.

    Params:
        line = String to replace tokens in.
        defaultLowerBound = Default lower bound when no range given.
        defaultUpperBound = Default upper bound when no range given.

    Returns:
        A new string with occurences of `$random` and `$random(i..n)` replaced,
        or the original string if there were no changes made.
 +/
auto replaceRandom(
    const string line,
    const long defaultLowerBound = 0,
    const long defaultUpperBound = 100) @safe
{
    import std.conv : text;
    import std.random : uniform;
    import std.string : indexOf;

    immutable randomPos = line.indexOf("$random");

    if (randomPos == -1)
    {
        // No $random token
        return line;
    }

    if (line.length > randomPos)
    {
        immutable openParen = randomPos + "$random".length;

        if (line.length == openParen)
        {
            immutable randomNumber = uniform(defaultLowerBound, defaultUpperBound);
            return text(line[0..randomPos], randomNumber);
        }
        else if (line[openParen] == '(')
        {
            immutable dots = line.indexOf("..", openParen);

            if (dots != -1)
            {
                immutable endParen = line.indexOf(')', dots);

                if (endParen != -1)
                {
                    try
                    {
                        import std.conv : to;

                        immutable lowerBound = line[openParen+1..dots].to!long;
                        immutable upperBound = line[dots+2..endParen].to!long;
                        immutable randomNumber = uniform(lowerBound, upperBound);
                        return text(line[0..randomPos], randomNumber, line[endParen+1..$]);
                    }
                    catch (Exception _)
                    {
                        return line;
                    }
                }
            }
        }
        else if (line[openParen] == ' ')
        {
            immutable randomNumber = uniform(defaultLowerBound, defaultUpperBound);
            return text(line[0..randomPos], randomNumber, line[openParen..$]);
        }
    }

    return line;
}

///
unittest
{
    import lu.string : nom;
    import std.conv : to;

    {
        enum line = "$random bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.nom(' ').to!int;
        assert(((number >= 0) && (number < 100)), number.to!string);
    }
    {
        enum line = "$random(100..200) bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.nom(' ').to!int;
        assert(((number >= 100) && (number < 200)), number.to!string);
    }
    {
        enum line = "$random(-20..-10) bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.nom(' ').to!int;
        assert(((number >= -20) && (number < -10)), number.to!string);
    }
    /*{
        static if (__VERSION__ > 2089L)
        {
            // Fails pre-2.090 with Error: signed integer overflow
            enum line = "$random(-9223372036854775808..9223372036854775807) bottles of beer on the wall";
            string replaced = line.replaceRandom();  // mutable
            immutable number = replaced.nom(' ').to!long;
            //assert(((number >= cast(long)-9223372036854775808) && (number < 9223372036854775807)), number.to!string);
        }
    }*/
    {
        // syntax error, no bounds given
        enum line = "$random() bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, no closing paren
        enum line = "$random( bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, no upper bound given
        enum line = "$random(0..) bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, no boudns given
        enum line = "$random(..) bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, missing closing paren
        enum line = "$random(0..100 bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, parens include text
        enum line = "$random(0..100 bottles of beer on the wall)";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, i == n
        enum line = "$random(0..0) bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, i > n
        enum line = "$random(2..1) bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // empty string
        enum line = string.init;
        string replaced = line.replaceRandom();
        assert(!replaced.length, replaced);
    }
    {
        // no $random token
        enum line = "99 bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
}


// doublyBackslashed
/++
    Returns the supplied string with any backslashes doubled. This is to make
    paths on Windows display properly.

    Merely returns the given string on Posix and other non-Windows platforms.

    Example:
    ---
    string path = r"c:\Windows\system32";
    assert(path.doublyBackslashed == r"c:\\Windows\\system32");
    ---

    Params:
        path = The original path string with only single backslashes.

    Returns:
        The passed `path` but doubly backslashed.
 +/
auto doublyBackslashed(const string path)
{
    if (!path.length) return path;

    version(Windows)
    {
        import std.array : replace;
        import std.string : indexOf;

        string slice = path.replace('\\', r"\\");

        while (slice.indexOf(r"\\\\") != -1)
        {
            slice = slice.replace(r"\\\\", r"\\");
        }

        return slice;
    }
    else
    {
        return path;
    }
}

///
version(Windows)
unittest
{
    {
        enum path = r"c:\windows\system32";
        enum expected = r"c:\\windows\\system32";
        immutable actual = path.doublyBackslashed;
        assert((actual == expected), actual);
    }
    {
        enum path = r"c:\Users\blerp\AppData\Local\kameloso\server\irc.chat.twitch.tv";
        enum expected = r"c:\\Users\\blerp\\AppData\\Local\\kameloso\\server\\irc.chat.twitch.tv";
        immutable actual = path.doublyBackslashed;
        assert((actual == expected), actual);
    }
    {
        enum path = r"c:\\windows\\system32";
        enum expected = r"c:\\windows\\system32";
        immutable actual = path.doublyBackslashed;
        assert((actual == expected), actual);
    }
}

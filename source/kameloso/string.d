/++
    Various functions that do string manipulation.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.string;

private:

import dialect.defs : IRCClient;

public:


// stripSeparatedPrefix
/++
    Strips a prefix word from a string, optionally also stripping away some
    non-word characters (currently "`:;?! `").

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
        demandSeparatingChars = Makes it a necessity that `line` is followed
            by one of the prefix letters "`: !?;`". If it isn't, the `line` string
            will be returned as is.

    Returns:
        The passed line with the `prefix` sliced away.
 +/
auto stripSeparatedPrefix(
    const string line,
    const string prefix,
    const bool demandSeparatingChars = true) pure
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
{
    import lu.string : advancePast, strippedLeft;
    import std.algorithm.comparison : among;
    import std.meta : aliasSeqOf;

    enum separatingChars = ": !?;";  // In reasonable order of likelihood

    string slice = line.strippedLeft;  // mutable

    // the onus is on the caller that slice begins with prefix, else this will throw
    slice.advancePast(prefix);

    if (demandSeparatingChars)
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
        .stripSeparatedPrefix("kameloso", demandSeparatingChars: false);
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
        A new string with occurrences of `$random` and `$random(i..n)` replaced,
        or the original string if there were no changes made.
 +/
auto replaceRandom(
    const string line,
    const long defaultLowerBound = 0,
    const long defaultUpperBound = 100) @safe
{
    import std.array : Appender;
    import std.conv : to;
    import std.random : uniform;
    import std.string : indexOf;

    enum token = "$random";

    Appender!(char[]) sink;
    sink.reserve(line.length);  // overshoots but that's fine
    ptrdiff_t randomPos = line.indexOf(token);
    size_t prevEnd;

    while (randomPos != -1)
    {
        immutable trailingCharPos = randomPos + token.length;
        size_t thisEnd;

        if (line.length == trailingCharPos)
        {
            // Line ends with token
            immutable randomNumber = uniform(defaultLowerBound, defaultUpperBound);
            sink.put(line[prevEnd..randomPos]);
            sink.put(randomNumber.to!string);
            break;
        }
        else if (line[trailingCharPos] == '(')
        {
            // "token("
            immutable dotsPos = line.indexOf("..", trailingCharPos);

            if (dotsPos != -1)
            {
                // "token(*.."
                immutable endParenPos = line.indexOf(')', dotsPos);

                if (endParenPos != -1)
                {
                    // "token(*..*)"
                    try
                    {
                        import std.conv : to;

                        immutable lowerBound = line[trailingCharPos+1..dotsPos].to!long;
                        immutable upperBound = line[dotsPos+2..endParenPos].to!long;
                        immutable randomNumber = uniform(lowerBound, upperBound);
                        sink.put(line[prevEnd..randomPos]);
                        sink.put(randomNumber.to!string);
                        thisEnd = endParenPos+1;
                    }
                    catch (Exception _)
                    {
                        // syntax error, but proceed with the loop
                        sink.put(line[prevEnd..trailingCharPos]);
                        thisEnd = trailingCharPos;
                    }
                }
            }
        }
        else
        {
            // token followed by any other trailing character
            immutable randomNumber = uniform(defaultLowerBound, defaultUpperBound);
            sink.put(line[prevEnd..randomPos]);
            sink.put(randomNumber.to!string);
            thisEnd = trailingCharPos;
        }

        prevEnd = thisEnd;
        randomPos = line.indexOf(token, prevEnd+1);
    }

    // Add any trailing text iff the loop iterated at least once
    if ((randomPos == -1) && (prevEnd != 0)) sink.put(line[prevEnd..$]);

    return () @trusted
    {
        import std.exception : assumeUnique;
        return sink[].length ? sink[].assumeUnique() : line;
    }();
}

///
unittest
{
    import lu.string : advancePast, splitInto;
    import std.conv : to;

    {
        enum line = "$random bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.advancePast(' ').to!int;
        assert(((number >= 0) && (number < 100)), number.to!string);
    }
    {
        enum line = "$random(100..200) bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.advancePast(' ').to!int;
        assert(((number >= 100) && (number < 200)), number.to!string);
    }
    {
        enum line = "$random(-20..-10) bottles of beer on the wall";
        string replaced = line.replaceRandom();  // mutable
        immutable number = replaced.advancePast(' ').to!int;
        assert(((number >= -20) && (number < -10)), number.to!string);
    }
    /*{
        static if (__VERSION__ > 2089L)
        {
            // Fails pre-2.090 with Error: signed integer overflow
            enum line = "$random(-9223372036854775808..9223372036854775807) bottles of beer on the wall";
            string replaced = line.replaceRandom();  // mutable
            immutable number = replaced.advancePast(' ').to!long;
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
        // syntax error, no bounds given
        enum line = "$random(..) bottles of beer on the wall";
        immutable replaced = line.replaceRandom();
        assert((replaced == line), replaced);
    }
    {
        // syntax error, invalid bounds
        enum line = "$random(X.....Y) bottles of beer on the wall";
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
        // partly syntax error
        enum line = "blerp $random(50..55) $random(2..1) $random blarp";
        immutable replaced = line.replaceRandom();
        string slice = replaced;  // mutable
        string blerp, n1s, syntaxError, n2s, blarp;
        slice.splitInto(blerp, n1s, syntaxError, n2s, blarp);
        immutable n1 = n1s.to!int;
        immutable n2 = n2s.to!int;
        assert((blerp == "blerp"), blerp);
        assert((n1 >= 50 && n1 < 55), n1.to!string);
        assert((syntaxError == "$random(2..1)"), syntaxError);
        assert((n2 >= 0 && n2 < 100), n2.to!string);
        assert((blarp == "blarp"), blarp);
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
    {
        // multiple tokens
        enum line = "$random(1..100) $random(101..200) $random(201..300)";
        immutable replaced = line.replaceRandom();
        string slice = replaced;  // mutable
        string n1s, n2s, n3s;
        slice.splitInto(n1s, n2s, n3s);
        immutable n1 = n1s.to!int;
        immutable n2 = n2s.to!int;
        immutable n3 = n3s.to!int;
        assert((n1 >= 1 && n1 < 100), n1.to!string);
        assert((n2 >= 101 && n2 < 200), n2.to!string);
        assert((n3 >= 201 && n3 < 300), n3.to!string);
    }
    {
        // multiple tokens with other text
        enum line = "$random $randomz $random gau gau";
        immutable replaced = line.replaceRandom();
        string slice = replaced;  // mutable
        string n1s, n2z, n3s;
        slice.splitInto(n1s, n2z, n3s);
        immutable n1 = n1s.to!int;
        immutable n2 = n2z[0..$-1].to!int;
        immutable n3 = n3s.to!int;
        immutable z = n2z[$-1..$];
        assert((n1 >= 0 && n1 < 100), n1.to!string);
        assert((n2 >= 0 && n2 < 100), n1.to!string);
        assert((n3 >= 0 && n3 < 100), n3.to!string);
        assert((z == "z"), z);
        assert((slice == "gau gau"), slice);
    }
    {
        // multiple tokens with other text again
        enum line = "$random, $random! $random?";
        immutable replaced = line.replaceRandom();
        string slice = replaced;  // mutable
        string n1comma, n2excl, n3question;
        slice.splitInto(n1comma, n2excl, n3question);
        immutable n1 = n1comma[0..$-1].to!int;
        immutable comma = n1comma[$-1..$];
        immutable n2 = n2excl[0..$-1].to!int;
        immutable excl = n2excl[$-1..$];
        immutable n3 = n3question[0..$-1].to!int;
        immutable question = n3question[$-1..$];
        assert((n1 >= 0 && n1 < 100), n1.to!string);
        assert((n2 >= 0 && n2 < 100), n1.to!string);
        assert((n3 >= 0 && n3 < 100), n3.to!string);
        assert((comma == ","), comma);
        assert((excl == "!"), excl);
        assert((question == "?"), question);
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
    version(Windows)
    {
        import std.array : replace;
        import std.string : indexOf;

        if (!path.length) return path;

        // Duplicate every backslash
        string slice = path.replace('\\', `\\`);
        auto quadBackslashPos = slice.indexOf(`\\\\`);

        while (quadBackslashPos != -1)
        {
            // Halve every quadruple backslash
            slice = slice.replace(`\\\\`, `\\`);
            quadBackslashPos = slice.indexOf(`\\\\`, quadBackslashPos);
        }
        return slice;
    }
    else /*version(Posix)*/
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

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

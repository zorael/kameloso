/++
    A collection of functions used to translate tags in messages into terminal colours.

    See_Also:
        [kameloso.terminal],
        [kameloso.terminal.colours],
        [kameloso.terminal.colours.defs]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.terminal.colours.tags;

private:

import kameloso.logger : LogLevel;

public:


// expandTags
/++
    String-replaces `<tags>` in a string with the results from calls to `Tint`.
    Also works with `dstring`s and `wstring`s.

    `<tags>` are the lowercase first letter of all
    [kameloso.logger.LogLevel|LogLevel]s; `<l>`, `<t>`, `<i>`, `<w>`
    `<e>`, `<c>` and `<f>`. `<a>` is not included.

    `</>` equals the passed `baseLevel` and is used to terminate colour sequences,
    returning to a default.

    Lastly, text between a `<h>` and a `</>` are replaced with the results from
    a call to [kameloso.terminal.colours.colourByHash|colourByHash].

    This should hopefully make highlighted strings more readable.

    Example:
    ---
    enum oldPattern = "
        %1$sYour private authorisation key is: %2$s%3$s%4$s
        It should be entered as %2$spass%4$s under %2$s[IRCBot]%4$s.
        ";
    immutable oldMessage = oldPattern.format(Tint.log, Tint.info, pass, Tint.off);

    enum newPattern = "
        <l>Your private authorisation key is: <i>%s</>
        It should be entered as <i>pass</> under <i>[IRCBot]</>
        ";
    immutable newMessage = newPattern
        .format(pass)
        .expandTags(LogLevel.off);

    enum patternWithColouredNickname = "No quotes for nickname <h>%s<h>.";

    immutable colouredMessage = patternWithColouredNickname
        .format(event.sender.nickname)
        .expandTags(LogLevel.off);
    ---

    Params:
        line = A line of text, presumably with `<tags>`.
        baseLevel = The base [kameloso.logger.LogLevel|LogLevel] to fall back to on `</>` tags.
        strip = Whether to expand tags or strip them.

    Returns:
        The passed `line` but with any `<tags>` replaced with ANSI colour sequences.
        The original string is passed back if there was nothing to replace.
 +/
auto expandTags(T)(const T line, const LogLevel baseLevel, const bool strip) @safe
{
    import kameloso.common : logger;
    import std.algorithm.searching : canFind;
    import std.array : Appender;
    import std.range : ElementEncodingType;
    import std.traits : Unqual, isSomeString;
    static import kameloso.common;

    static if (!isSomeString!T)
    {
        import std.format : format;

        enum pattern = "`%s` only works on string types, not `%s`";
        enum message = pattern.format(__FUNCTION__, T.stringof);
        static assert(0, message);
    }

    alias E = Unqual!(ElementEncodingType!T);

    if (!line.length || !line.canFind('<')) return line;

    // Without marking this as @trusted, we can't have @safe expandTags...
    static auto wrappedIndexOf(H, N)(const H haystack, const N rawNeedle) @trusted
    {
        import std.string : indexOf;

        static if (is(N : ubyte))
        {
            immutable needle = cast(char) rawNeedle;
        }
        else
        {
            alias needle = rawNeedle;
        }

        return (cast(T) haystack).indexOf(needle);
    }

    Appender!(E[]) sink;
    size_t lastEnd;
    bool reserved;
    bool escaping;

    // Work around the immutability being lost with -dip1000
    // The @safe alternative is to use .idup, which is not really desirable here
    // so cheat a bit.
    immutable asBytes = () @trusted
    {
        import std.exception : assumeUnique;
        import std.string : representation;
        return line.representation.assumeUnique();
    }();

    void commitUpTo(const size_t i)
    {
        if (!reserved)
        {
            sink.reserve(asBytes.length + 16);  // guesstimate
            reserved = true;
        }
        sink.put(asBytes[lastEnd..i]);
    }

    byteloop:
    for (size_t i; i<asBytes.length; ++i)
    {
        //charswitch:
        switch (asBytes[i])
        {
        case '\\':
            commitUpTo(i);
            if (escaping) sink.put('\\');
            lastEnd = i+1;
            escaping = !escaping;
            continue byteloop;

        case '<':
            if (escaping)
            {
                commitUpTo(i);
                sink.put('<');
                lastEnd = i+1;
                escaping = false;
                continue byteloop;
            }

            immutable closingBracketPos = wrappedIndexOf(asBytes[i..$], '>');
            if (closingBracketPos == -1) continue byteloop;

            if (asBytes.length < i+2)
            {
                // Too close to the end to have a meaningful tag
                // Break and return
                break byteloop;
            }

            immutable tag = asBytes[i+1..i+closingBracketPos];
            if (tag.length != 1) continue byteloop;

            commitUpTo(i);

            tagswitch:
            switch (tag[0])
            {
            version(Colours)
            {
                case 'l':
                    if (!strip) sink.put(logger.logtint);
                    break;

                case 't':
                    if (!strip) sink.put(logger.tracetint);
                    break;

                case 'i':
                    if (!strip) sink.put(logger.infotint);
                    break;

                case 'w':
                    if (!strip) sink.put(logger.warningtint);
                    break;

                case 'e':
                    if (!strip) sink.put(logger.errortint);
                    break;

                case 'c':
                    if (!strip) sink.put(logger.criticaltint);
                    break;

                case 'f':
                    if (!strip) sink.put(logger.fataltint);
                    break;

                case 'o':
                    if (!strip) sink.put(logger.offtint);
                    break;

                case '/':
                    if (!strip)
                    {
                        with (LogLevel)
                        final switch (baseLevel)
                        {
                        case all:  //log
                            //goto case 'l';
                            sink.put(logger.logtint);
                            break tagswitch;

                        case trace:
                            //goto case 't';
                            sink.put(logger.tracetint);
                            break tagswitch;

                        case info:
                            //goto case 'i';
                            sink.put(logger.infotint);
                            break tagswitch;

                        case warning:
                            //goto case 'w';
                            sink.put(logger.warningtint);
                            break tagswitch;

                        case error:
                            //goto case 'e';
                            sink.put(logger.errortint);
                            break tagswitch;

                        case critical:
                            //goto case 'c';
                            sink.put(logger.criticaltint);
                            break tagswitch;

                        case fatal:
                            //goto case 'f';
                            sink.put(logger.fataltint);
                            break tagswitch;

                        case off:
                            //goto case 'o';
                            sink.put(logger.offtint);
                            break tagswitch;
                        }
                    }
                    break tagswitch;
            }
            else /*version(!Colours)*/
            {
                // Let everything pass through with no action taken
                case 'l':
                case 't':
                case 'i':
                case 'w':
                case 'e':
                case 'c':
                case 'f':
                case 'o':
                    break;

                case '/':
                    break tagswitch;
            }

            case 'h':
                immutable closingHashMarkPos = wrappedIndexOf(asBytes[i+3..$], "</>");
                if (closingHashMarkPos == -1) goto default;

                // Advance past "<h>"
                i += "<h>".length;
                immutable word = cast(string) asBytes[i..i+closingHashMarkPos];

                version(Colours)
                {
                    if (!strip)
                    {
                        import kameloso.terminal.colours : colourByHash;

                        sink.put(colourByHash(word, kameloso.common.coreSettings));

                        with (LogLevel)
                        levelswitch:
                        final switch (baseLevel)
                        {
                        case all:  //log
                            sink.put(logger.logtint);
                            break levelswitch;

                        case trace:
                            sink.put(logger.tracetint);
                            break levelswitch;

                        case info:
                            sink.put(logger.infotint);
                            break levelswitch;

                        case warning:
                            sink.put(logger.warningtint);
                            break levelswitch;

                        case error:
                            sink.put(logger.errortint);
                            break levelswitch;

                        case critical:
                            sink.put(logger.criticaltint);
                            break levelswitch;

                        case fatal:
                            sink.put(logger.fataltint);
                            break levelswitch;

                        case off:
                            sink.put(logger.offtint);
                            break levelswitch;
                        }
                    }
                    else
                    {
                        sink.put(word);
                    }
                }
                else /*version(!Colours)*/
                {
                    sink.put(word);
                }

                // Don't advance the full "<h>".length 3
                // because the for-loop ++i will advance one ahead
                i += closingHashMarkPos+2;
                lastEnd = i+1;
                continue byteloop;  // Not break

            default:  // tagswitch
                // Invalid control character, just ignore
                // set lastEnd but otherwise skip ahead past the tag
                lastEnd = i;
                i += tag.length+1;
                continue byteloop;
            }

            // Switch cases drop down to here
            i += closingBracketPos;
            lastEnd = i+1;
            continue byteloop;

        default:  // charswitch
            if (escaping)
            {
                // Cancel escape if we're not escaping a tag
                escaping = false;
            }
            continue byteloop;
        }
    }

    // Return the line as-is if it didn't contain any tags
    if (!sink[].length) return line;

    sink.put(asBytes[lastEnd..$]);

    /+
        Since we can't manage to make this pure (because KamelosoLogger tints aren't),
        we have to cheat and force sink[] to be unique and immutable.
     +/
    return () @trusted
    {
        import std.exception : assumeUnique;
        return sink[].assumeUnique();
    }();
}

///
unittest
{
    import kameloso.common : logger;
    import std.conv : text, to;
    import std.format : format;

    {
        immutable line = "This is a <l>log</> line.";
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        immutable expected = text("This is a ", logger.logtint, "log", logger.offtint, " line.");
        assert((replaced == expected), replaced);
    }
    {
        import std.conv : wtext;

        immutable line = "This is a <l>log</> line."w;
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        immutable expected = wtext("This is a "w, logger.logtint, "log"w, logger.offtint, " line."w);
        assert((replaced == expected), replaced.to!string);
    }
    {
        import std.conv : dtext;

        immutable line = "This is a <l>log</> line."d;
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        immutable expected = dtext("This is a "d, logger.logtint, "log"d, logger.offtint, " line."d);
        assert((replaced == expected), replaced.to!string);
    }
    {
        immutable line = `<i>info</>nothing<c>critical</>nothing\<w>not warning`;
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        immutable expected = text(logger.infotint, "info", logger.offtint, "nothing",
            logger.criticaltint, "critical", logger.offtint, "nothing<w>not warning");
        assert((replaced == expected), replaced);
    }
    {
        immutable line = "This is a line with no tags";
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        assert(line is replaced);
    }
    {
        immutable emptyLine = string.init;
        immutable replaced = emptyLine.expandTags(LogLevel.off, strip: false);
        assert(replaced is emptyLine);
    }
    {
        immutable line = "hello<h>kameloso</>hello";
        immutable replaced = line.expandTags(LogLevel.off, strip: true);
        immutable expected = "hellokamelosohello";
        assert((replaced == expected), replaced);
    }
    {
        immutable line = "hello<h></>hello";
        immutable replaced = line.expandTags(LogLevel.off, strip: true);
        immutable expected = "hellohello";
        assert((replaced == expected), replaced);
    }
    {
        immutable line = `hello\<harbl>kameloso<h>hello</>hi`;
        immutable replaced = line.expandTags(LogLevel.off, strip: true);
        immutable expected = "hello<harbl>kamelosohellohi";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s<e> on <l>%s<e>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.off, strip: false);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            logger.logtint ~ "nickname" ~ logger.errortint ~ " on " ~ logger.logtint ~
            "<no channel>" ~ logger.errortint ~ ": " ~ logger.logtint ~ "error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s<e> on <l>%s<e>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.off, strip: true);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            "nickname on <no channel>: error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s</> on <l>%s</>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.error, strip: false);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            logger.logtint ~ "nickname" ~ logger.errortint ~ " on " ~ logger.logtint ~
            "<no channel>" ~ logger.errortint ~ ": " ~ logger.logtint ~ "error";
        assert((replaced == expected), replaced);
    }
    {
        enum pattern = "Failed to fetch, replay and clear notes for " ~
            "<l>%s</> on <l>%s</>: <l>%s";
        immutable line = pattern.format("nickname", "<no channel>", "error");
        immutable replaced = line.expandTags(LogLevel.error, strip: true);
        immutable expected = "Failed to fetch, replay and clear notes for " ~
            "nickname on <no channel>: error";
        assert((replaced == expected), replaced);
    }
    {
        enum origPattern = "Could not apply <i>+%s<l> <i>%s<l> in <i>%s<l> " ~
            "because we are not an operator in the channel.";
        enum newPattern = "Could not apply <i>+%s</> <i>%s</> in <i>%s</> " ~
            "because we are not an operator in the channel.";
        immutable origLine = origPattern.format("o", "nickname", "#channel").expandTags(LogLevel.off, strip: false);
        immutable newLine = newPattern.format("o", "nickname", "#channel").expandTags(LogLevel.all, strip: false);
        assert((origLine == newLine), newLine);
    }

    version(Colours)
    {
        import kameloso.terminal.colours : colourByHash;
        import kameloso.pods : CoreSettings;

        CoreSettings brightSettings;
        CoreSettings darkSettings;
        brightSettings.brightTerminal = true;

        {
            immutable line = "hello<h>kameloso</>hello";
            immutable replaced = line.expandTags(LogLevel.off, strip: false);
            immutable expected = text("hello", colourByHash("kameloso",
                darkSettings), logger.offtint, "hello");
            assert((replaced == expected), replaced);
        }
        {
            immutable line = `hello\<harbl>kameloso<h>hello</>hi`;
            immutable replaced = line.expandTags(LogLevel.off, strip: false);
            immutable expected = text("hello<harbl>kameloso", colourByHash("hello",
                darkSettings), logger.offtint, "hi");
            assert((replaced == expected), replaced);
        }
        {
            immutable line = "<l>%%APPDATA%%\\\\kameloso</>.";
            immutable replaced = line.expandTags(LogLevel.off, strip: false);
            immutable expected = logger.logtint ~ "%%APPDATA%%\\kameloso" ~ logger.offtint ~ ".";
            assert((replaced == expected), replaced);
        }
        {
            immutable line = "<l>herp\\</>herp\\\\herp\\\\<l>herp</>";
            immutable replaced = line.expandTags(LogLevel.off, strip: false);
            immutable expected = logger.logtint ~ "herp</>herp\\herp\\" ~ logger.logtint ~ "herp" ~ logger.offtint;
            assert((replaced == expected), replaced);
        }
        {
            immutable line = "Added <h>hirrsteff</> as a blacklisted user in #garderoben";
            immutable replaced = line.expandTags(LogLevel.off, strip: false);
            immutable expected = "Added " ~
                colourByHash("hirrsteff", brightSettings) ~
                logger.offtint ~ " as a blacklisted user in #garderoben";
            assert((replaced == expected), replaced);
        }
    }
}


// expandTags
/++
    String-replaces `<tags>` in a string with the results from calls to
    [kameloso.logger.KamelosoLogger|KamelosoLogger] `*tint` methods.
    Also works with `dstring`s and `wstring`s. Overload that does not take a
    `strip` bool.

    Params:
        line = A line of text, presumably with `<tags>`.
        baseLevel = The base [kameloso.logger.LogLevel|LogLevel] to fall back to on `</>` tags.

    Returns:
        The passed `line` but with any `<tags>` replaced with ANSI colour sequences.
        The original string is passed back if there was nothing to replace.
 +/
auto expandTags(T)(const T line, const LogLevel baseLevel) @safe
{
    import std.traits : isSomeString;
    static import kameloso.common;

    static if (!isSomeString!T)
    {
        import std.format : format;

        enum pattern = "`%s` only works on string types, not `%s`";
        enum message = pattern.format(__FUNCTION__, T.stringof);
        static assert(0, message);
    }

    return expandTags(line, baseLevel, strip: !kameloso.common.coreSettings.colours);
}

///
unittest
{
    import kameloso.common : logger;
    import std.conv : text, to;

    {
        immutable line = "This is a <l>log</> line.";
        immutable replaced = line.expandTags(LogLevel.off);
        immutable expected = text("This is a ", logger.logtint, "log", logger.offtint, " line.");
        assert((replaced == expected), replaced);
    }
}


// stripTags
/++
    Removes `<tags>` from a string.

    Example:
    ---
    enum pattern = "
        <l>Your private authorisation key is: <i>%s</>
        It should be entered as <i>pass</> under <i>[IRCBot]</>
        ";
    immutable newMessage = newPattern
        .format(pass)
        .stripTags();

    enum patternWithColouredNickname = "No quotes for nickname <h>%s<h>.";
    immutable uncolouredMessage = patternWithColouredNickname
        .format(event.sender.nickname)
        .stripTags();
    ---

    Params:
        line = A line of text, presumably with `<tags>` to remove.

    Returns:
        The passed `line` with any `<tags>` removed.
        The original string is passed back if there was nothing to remove.
 +/
auto stripTags(T)(const T line) @safe
{
    import std.traits : isSomeString;

    static if (!isSomeString!T)
    {
        import std.format : format;

        enum pattern = "`%s` only works on string types, not `%s`";
        enum message = pattern.format(__FUNCTION__, T.stringof);
        static assert(0, message);
    }

    return expandTags(line, LogLevel.off, strip: true);
}

///
unittest
{
    {
        immutable line = "This is a <l>log</> line.";
        immutable replaced = line.stripTags();
        immutable expected = "This is a log line.";
        assert((replaced == expected), replaced);
    }
}

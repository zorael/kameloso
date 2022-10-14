/++
    The SedReplace plugin imitates the UNIX `sed` tool, allowing for the
    replacement/substitution of text. It does not require the tool itself though,
    and will work on Windows too.

    $(CONSOLE
        $ echo "foo bar baz" | sed "s/bar/qux/"
        foo qux baz
    )

    It has no bot commands, as everything is done by scanning messages for signs
    of `s/this/that/` patterns.

    It supports a delimiter of `/`, `|`, `#`, `@`, ` `, `_` and `;`, but more
    can be trivially added. See the [DelimiterCharacters] alias.

    You can also end it with a `g` to set the global flag, to have more than one
    match substituted.

    $(CONSOLE
        $ echo "foo bar baz" | sed "s/bar/qux/g"
        $ echo "foo bar baz" | sed "s|bar|qux|g"
        $ echo "foo bar baz" | sed "s#bar#qux#g"
        $ echo "foo bar baz" | sed "s@bar@qux@"
        $ echo "foo bar baz" | sed "s bar qux "
        $ echo "foo bar baz" | sed "s_bar_qux_"
        $ echo "foo bar baz" | sed "s;bar;qux"  // only if relaxSyntax is true
    )

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#sedreplace
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.sedreplace;

version(WithSedReplacePlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import lu.string : beginsWith;
import std.meta : aliasSeqOf;
import std.typecons : Flag, No, Yes;


/++
    Characters to support as delimiters in the replace expression.

    More can be added but if any are removed unittests will need to be updated.
 +/
alias DelimiterCharacters = aliasSeqOf!("/|#@ _;");


// SedReplaceSettings
/++
    All sed-replace plugin settings, gathered in a struct.
 +/
@Settings struct SedReplaceSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /++
        How many lines back a sed-replacement call may reach. If this is 3, then
        the last 3 messages will be taken into account and examined for
        applicability when replacing.
     +/
    int history = 3;

    /++
        Toggles whether or not replacement expressions have to properly end with
        the delimiter (`s/abc/ABC/`), or if it may be omitted (`s/abc/ABC`).
     +/
    bool relaxSyntax = true;
}


// Line
/++
    Struct aggregate of a spoken line and the timestamp when it was said.
 +/
struct Line
{
    /// Contents of last line uttered.
    string content;

    /// When the last line was spoken, in UNIX time.
    long timestamp;
}


// sedReplace
/++
    `sed`-replaces a line with a substitution string.

    This clones the behaviour of the UNIX-like `echo "foo" | sed 's/foo/bar/'`.

    Example:
    ---
    string line = "This is a line";
    string expression = "s/s/z/g";
    assert(line.sedReplace(expression, No.relaxSyntax) == "Thiz iz a line");
    ---

    Params:
        line = Line to apply the `sed`-replace pattern to.
        expr = Replacement pattern to apply.
        relaxSyntax = Whether or not to require the expression to end with the delimiter.

    Returns:
        Original line with the changes the replace pattern incurred.
 +/
auto sedReplace(
    const string line,
    const string expr,
    const Flag!"relaxSyntax" relaxSyntax) @safe pure nothrow
in (line.length, "Tried to `sedReplace` an empty line")
in ((expr.length >= 5), "Tried to `sedReplace` with an invalid-length expression")
in (expr.beginsWith('s'), "Tried to `sedReplace` with a non-expression expression")
{
    immutable delimiter = expr[1];

    switch (delimiter)
    {
    foreach (immutable c; DelimiterCharacters)
    {
        case c:
            return line.sedReplaceImpl!c(expr, relaxSyntax);
    }
    default:
        return line;
    }
}

///
unittest
{
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789/", No.relaxSyntax);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "I am a fish";
        immutable after = before.sedReplace("s|a|e|g", No.relaxSyntax);
        assert((after == "I em e fish"), after);
    }
    {
        enum before = "Lorem ipsum dolor sit amet";
        immutable after = before.sedReplace("s###g", No.relaxSyntax);
        assert((after == "Lorem ipsum dolor sit amet"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所/", No.relaxSyntax);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-/", No.relaxSyntax);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", No.relaxSyntax);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "there are four lights";
        immutable after = before.sedReplace("s@ @_@g", No.relaxSyntax);
        assert((after == "there_are_four_lights"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot ", No.relaxSyntax);
        assert((after == "kameboto"), after);
    }
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789", Yes.relaxSyntax);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所", Yes.relaxSyntax);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-", Yes.relaxSyntax);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", Yes.relaxSyntax);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot", Yes.relaxSyntax);
        assert((after == "kameboto"), after);
    }
}


// sedReplaceImpl
/++
    Private sed-replace implementation.

    Works on any given character delimiter. Works with escapes.

    Params:
        char_ = Delimiter character, generally one of [DelimiterCharacters].
        line = Original line to apply the replacement expression to.
        expr = Replacement expression to apply.
        relaxSyntax = Whether or not to require the expression to end with the delimiter.

    Returns:
        The passed line with the relevant bits replaced, or as is if the expression
        didn't apply.
 +/
auto sedReplaceImpl(char char_)
    (const string line,
    const string expr,
    const Flag!"relaxSyntax" relaxSyntax)
in (line.length, "Tried to `sedReplaceImpl` on an empty line")
in (expr.length, "Tried to `sedReplaceImpl` with an empty expression")
in (expr.beginsWith("s" ~ char_), "Tried to `sedReplaceImpl` with an invalid expression")
{
    import lu.string : strippedRight;
    import std.array : replace;
    import std.string : indexOf;

    enum charAsString = "" ~ char_;
    enum escapedChar = "\\" ~ char_;

    static ptrdiff_t getNextUnescaped(const string lineWithChar)
    {
        string slice = lineWithChar;  // mutable
        ptrdiff_t offset;
        ptrdiff_t charPos = slice.indexOf(char_);

        while (charPos != -1)
        {
            if (charPos == 0) return offset;
            else if (slice[charPos-1] == '\\')
            {
                slice = slice[charPos+1..$];
                offset += (charPos + 1);
                charPos = slice.indexOf(char_);
                continue;
            }
            else
            {
                return (offset + charPos);
            }
        }

        return -1;
    }

    string slice = (char_ == ' ') ? expr : expr.strippedRight;  // mutable
    slice = slice[2..$];  // nom 's' ~ char_

    bool global;

    if ((slice[$-2] == char_) && (slice[$-1] == 'g'))
    {
        slice = slice[0..$-1];
        global = true;
    }

    immutable openEnd = slice[$-1] != char_;
    if (openEnd && !relaxSyntax) return line;

    immutable delimPos = getNextUnescaped(slice);
    if (delimPos == -1) return line;

    immutable replaceThis = slice[0..delimPos].replace(escapedChar, charAsString);
    slice = slice[delimPos+1..$];

    immutable endDelimPos = getNextUnescaped(slice);

    if (relaxSyntax)
    {
        if ((endDelimPos == -1) || (endDelimPos+1 == slice.length))
        {
            // Either there were no more delimiters or there was one at the very end
            // Syntax is relaxed; continue
        }
        else
        {
            // Found extra delimiters, expression is malformed; abort
            return line;
        }
    }
    else
    {
        if ((endDelimPos == -1) || (endDelimPos+1 != slice.length))
        {
            // Either there were no more delimiters or one was found before the end
            // Syntax is strict; abort
            return line;
        }
    }

    immutable withThis = openEnd ? slice : slice[0..$-1];

    if (global)
    {
        return line.replace(replaceThis, withThis);
    }
    else
    {
        immutable replaceThisPos = line.indexOf(replaceThis);
        if (replaceThisPos == -1) return line;  // This can happen, I *think*.
        return line.replace(replaceThisPos, replaceThisPos+replaceThis.length, withThis);
    }
}

///
unittest
{
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C/", No.relaxSyntax);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", No.relaxSyntax);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", No.relaxSyntax);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "I am a fish".sedReplaceImpl!'|'("s|fish|snek|g", No.relaxSyntax);
        assert((replaced == "I am a snek"), replaced);
    }
    {
        immutable replaced = "This is /a/a space".sedReplaceImpl!'/'("s/a\\//_/g", No.relaxSyntax);
        assert((replaced == "This is /_a space"), replaced);
    }
    {
        immutable replaced = "This is INVALID"
            .sedReplaceImpl!'#'("s#asdfasdf#asdfasdf#asdfafsd#g", No.relaxSyntax);
        assert((replaced == "This is INVALID"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C", Yes.relaxSyntax);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", Yes.relaxSyntax);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L", Yes.relaxSyntax);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", Yes.relaxSyntax);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "This is INVALID".sedReplaceImpl!'#'("s#INVALID#valid##", Yes.relaxSyntax);
        assert((replaced == "This is INVALID"), replaced);
    }
}


// onMessage
/++
    Parses a channel message and looks for any sed-replace expressions therein,
    to apply on the previous message.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(ChannelPolicy.home)
)
void onMessage(SedReplacePlugin plugin, const ref IRCEvent event)
{
    import lu.string : beginsWith, stripped;

    immutable stripped_ = event.content.stripped;
    if (!stripped_.length) return;

    static void recordLineAsLast(SedReplacePlugin plugin, const string sender,
        const string string_, const long time)
    {
        Line line;
        line.content = string_;
        line.timestamp = time;

        auto senderLines = sender in plugin.prevlines;

        if (!senderLines)
        {
            plugin.prevlines[sender] = Line[].init;
            senderLines = sender in plugin.prevlines;
            senderLines.length = plugin.sedReplaceSettings.history;
        }

        foreach_reverse (immutable i; 1..plugin.sedReplaceSettings.history)
        {
            (*senderLines)[i] = (*senderLines)[i-1];
        }

        (*senderLines)[0] = line;
    }

    if (stripped_.beginsWith('s') && (stripped_.length >= 5))
    {
        immutable delimiter = stripped_[1];

        delimiterswitch:
        switch (delimiter)
        {
        foreach (immutable c; DelimiterCharacters[1..$])
        {
            case c:
                goto case DelimiterCharacters[0];
        }

        case DelimiterCharacters[0]:
            if (const senderLines = event.sender.nickname in plugin.prevlines)
            {
                foreach (immutable line; (*senderLines)[])
                {
                    if ((event.time - line.timestamp) > plugin.replaceTimeoutSeconds)
                    {
                        // Entry is too old, any further entries will be even older
                        break delimiterswitch;
                    }

                    immutable result = line.content.sedReplace(event.content,
                        cast(Flag!"relaxSyntax")plugin.sedReplaceSettings.relaxSyntax);

                    if ((result == line.content) || !result.length) continue;

                    import kameloso.messaging : chan;
                    import std.format : format;

                    enum pattern = "<h>%s<h> | %s";
                    immutable message = pattern.format(event.sender.nickname, result);
                    chan(plugin.state, event.channel, message);

                    // Record as last even if there are more lines
                    return recordLineAsLast(plugin, event.sender.nickname, result, event.time);
                }
                break;
            }
            else
            {
                // No lines to replace; don't record this as a line
                return;
            }

        default:
            // Drop down to record line
            break;
        }
    }

    recordLineAsLast(plugin, event.sender.nickname, stripped_, event.time);
}


// onWelcome
/++
    Sets up a Fiber to periodically clear the lists of previous messages from
    users once every [SedReplacePlugin.timeBetweenPurges|timeBetweenPurges].

    This is to prevent the lists from becoming huge over time.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
    .fiber(true)
)
void onWelcome(SedReplacePlugin plugin)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;

    delay(plugin, plugin.timeBetweenPurges, Yes.yield);

    while (true)
    {
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime.toUnixTime;

        foreach (immutable sender, const lines; plugin.prevlines)
        {
            if (!lines.length ||
                ((now - lines[0].timestamp) >= plugin.replaceTimeoutSeconds))
            {
                // Something is either wrong with the sender's entries or
                // the most recent entry is too old
                plugin.prevlines.remove(sender);
            }
        }

        delay(plugin, plugin.timeBetweenPurges, Yes.yield);
    }
}


// onQuit
/++
    Removes the records of previous messages from a user when they quit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(SedReplacePlugin plugin, const ref IRCEvent event)
{
    plugin.prevlines.remove(event.sender.nickname);
}


mixin MinimalAuthentication;

public:


// SedReplacePlugin
/++
    The SedReplace plugin stores a buffer of the last said line of every user,
    and if a new message comes in with a sed-replace-like pattern in it, tries
    to apply it on the original message as a regex-like replace.
 +/
@IRCPluginHook
final class SedReplacePlugin : IRCPlugin
{
private:
    import core.time : seconds;

    /// All sed-replace options gathered.
    SedReplaceSettings sedReplaceSettings;

    /// Lifetime of a [Line] in [prevlines], in seconds.
    enum replaceTimeoutSeconds = 3600;

    /// How often to purge the [prevlines] list of messages.
    static immutable timeBetweenPurges = (replaceTimeoutSeconds * 3).seconds;

    /++
        A `Line[string]` buffer of the previous line every user said, with
        with nickname as key.
     +/
    Line[][string] prevlines;

    mixin IRCPluginImpl;
}

/++
 +  The SedReplace plugin imitates the UNIX `sed` tool, allowing for the
 +  replacement/substitution of text. It does not require the tool itself though,
 +  and will work on Windows builds too.
 +
 +  ---
 +  $ echo "foo bar baz" | sed "s/bar/qux/"
 +  foo qux baz
 +  ---
 +
 +  It has no bot commands, as everything is done by scanning messages for signs
 +  of `s/this/that/` patterns.
 +
 +  It supports a delimiter of `/`, `|`, `#`, `@`, ` `, `_` and `;`, but more
 +  can be trivially added.
 +
 +  You can also end it with a `g` to set the global flag, to have more than one
 +  match substituted.
 +
 +  ---
 +  $ echo "foo bar baz" | sed "s/bar/qux/g"
 +  $ echo "foo bar baz" | sed "s|bar|qux|g"
 +  $ echo "foo bar baz" | sed "s#bar#qux#g"
 +  $ echo "foo bar baz" | sed "s@bar@qux@"
 +  $ echo "foo bar baz" | sed "s bar qux "
 +  $ echo "foo bar baz" | sed "s;bar;qux"  // only if relaxSyntax is true
 +  ---
 +/
module kameloso.plugins.sedreplace;

version(WithPlugins):
version(WithSedReplacePlugin):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// SedReplaceSettings
/++
 +  All sed-replace plugin settings, gathered in a struct.
 +/
@Settings struct SedReplaceSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;

    /++
     +  Toggles whether or not replacement expressions have to properly end with
     +  the delimeter (`s/abc/ABC/`), or if it may be omitted (`s/abc/ABC`).
     +/
    bool relaxSyntax = true;
}


// Line
/++
 +  Struct aggregate of a spoken line and the timestamp when it was said.
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
 +  `sed`-replaces a line with a substitution string.
 +
 +  This clones the behaviour of the UNIX-like `echo "foo" | sed 's/foo/bar/'`.
 +
 +  Example:
 +  ---
 +  string line = "This is a line";
 +  string expression = "s/s/z/g";
 +  assert(line.sedReplace(expression) == "Thiz iz a line");
 +  ---
 +
 +  Params:
 +      originalLine = Line to apply the `sed`-replace pattern to.
 +      expression = Replacement pattern to apply.
 +      relaxSyntax = Whether or not to require the expression to end with the delimeter.
 +
 +  Returns:
 +      Original line with the changes the replace pattern incurred.
 +/
string sedReplace(const string line, const string expr, const bool relaxSyntax) @safe pure nothrow
{
    if (expr.length < 5) return line;

    immutable delimeter = expr[1];

    switch (delimeter)
    {
    case '/':
        return line.sedReplaceImpl!'/'(expr, relaxSyntax);

    case '|':
        return line.sedReplaceImpl!'|'(expr, relaxSyntax);

    case '#':
        return line.sedReplaceImpl!'#'(expr, relaxSyntax);

    case '@':
        return line.sedReplaceImpl!'@'(expr, relaxSyntax);

    case ' ':
        return line.sedReplaceImpl!' '(expr, relaxSyntax);

    case '_':
        return line.sedReplaceImpl!'_'(expr, relaxSyntax);

    case ';':
        return line.sedReplaceImpl!';'(expr, relaxSyntax);

    default:
        return line;
    }
}

///
unittest
{
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789/", false);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "I am a fish";
        immutable after = before.sedReplace("s|a|e|g", false);
        assert((after == "I em e fish"), after);
    }
    {
        enum before = "Lorem ipsum dolor sit amet";
        immutable after = before.sedReplace("s###g", false);
        assert((after == "Lorem ipsum dolor sit amet"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所/", false);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-/", false);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", false);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "there are four lights";
        immutable after = before.sedReplace("s@ @_@g", false);
        assert((after == "there_are_four_lights"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot ", false);
        assert((after == "kameboto"), after);
    }
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789", true);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所", true);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-", true);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", true);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot", true);
        assert((after == "kameboto"), after);
    }
}


// sedReplaceImpl
/++
 +  Private sed-replace implementation.
 +
 +  Works on any given character deliminator. Works with escapes.
 +
 +  Params:
 +      char_ = Deliminator character, usually '/'.
 +      line = Original line to apply the replacement expression to.
 +      expr = Replacement expression to apply.
 +      relaxSyntax = Whether or not to require the expression to end with the delimeter.
 +
 +  Returns:
 +      The passed line with the relevant bits replaced, or as is if the expression
 +      was invalid or didn't apply.
 +/
string sedReplaceImpl(char char_)(const string line, const string expr, const bool relaxSyntax)
{
    import std.algorithm.searching : startsWith;
    import std.array : replace;
    import std.string : indexOf;

    enum charAsString = "" ~ char_;
    enum escapedChar = "\\" ~ char_;

    static ptrdiff_t getNextUnescaped(const string lineWithChar)
    {
        string slice = lineWithChar;  // mutable
        ptrdiff_t offset;
        ptrdiff_t charPos = slice[offset..$].indexOf(char_);

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

    // No need to test for this, sedReplace only calls us if this is already true
    //if (!expr.startsWith("s" ~ char_)) return line;

    string slice = expr;  // mutable
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
            // Either there were no more delimeters or there was one at the very end
            // Syntax is relaxed; continue
        }
        else
        {
            // Found extra delimeters, expression is malformed; abort
            return line;
        }
    }
    else
    {
        if ((endDelimPos == -1) || (endDelimPos+1 != slice.length))
        {
            // Either there were no more delimeters or one was found before the end
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
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C/", false);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", false);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", false);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "I am a fish".sedReplaceImpl!'|'("s|fish|snek|g", false);
        assert((replaced == "I am a snek"), replaced);
    }
    {
        immutable replaced = "This is /a/a space".sedReplaceImpl!'/'("s/a\\//_/g", false);
        assert((replaced == "This is /_a space"), replaced);
    }
    {
        immutable replaced = "This is INVALID".sedReplaceImpl!'#'("s#asdfasdf#asdfasdf#asdfafsd#g", false);
        assert((replaced == "This is INVALID"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C", true);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", true);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L", true);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", true);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "This is INVALID".sedReplaceImpl!'#'("s#INVALID#valid##", true);
        assert((replaced == "This is INVALID"), replaced);
    }
}


// onMessage
/++
 +  Parses a channel message and looks for any sed-replace expressions therein,
 +  to apply on the previous message.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.ignore)
@(ChannelPolicy.home)
void onMessage(SedReplacePlugin plugin, const IRCEvent event)
{
    import lu.string : beginsWith, stripped;

    immutable stripped_ = event.content.stripped;

    static void recordLineAsLast(SedReplacePlugin plugin, const string sender,
        const string string_, const long time)
    {
        Line line;
        line.content = string_;
        line.timestamp = time;
        plugin.prevlines[sender] = line;
    }

    if (stripped_.beginsWith('s') && (stripped_.length >= 5))
    {
        immutable delimeter = stripped_[1];

        switch (delimeter)
        {
        case '/':
        case '|':
        case '#':
        case '@':
        case ' ':
        case '_':
        case ';':
            if (const line = event.sender.nickname in plugin.prevlines)
            {
                if ((event.time - line.timestamp) > plugin.replaceTimeoutSeconds)
                {
                    // Entry is too old, remove it
                    plugin.prevlines.remove(event.sender.nickname);
                    return;
                }

                immutable result = line.content.sedReplace(event.content,
                    plugin.sedReplaceSettings.relaxSyntax);

                if ((result == event.content) || !result.length) return;

                import kameloso.common : settings;
                import kameloso.messaging : chan;
                import std.format : format;

                chan(plugin.state, event.channel, "%s | %s".format(event.sender.nickname, result));
                recordLineAsLast(plugin, event.sender.nickname, result, event.time);
            }

            // Processed a sed-replace command (successfully or not); return
            return;

        default:
            // Drop down
            break;
        }
    }

    // We're either here because !stripped_.beginsWith("s") *or* stripped_[1]
    // is not '/', '|' nor '#'
    // --> normal message, store as previous line
    recordLineAsLast(plugin, event.sender.nickname, stripped_, event.time);
}


mixin MinimalAuthentication;

public:


// SedReplacePlugin
/++
 +  The SedReplace plugin stores a buffer of the last said line of every user,
 +  and if a new message comes in with a sed-replace-like pattern in it, tries
 +  to apply it on the original message as a regex replace.
 +/
final class SedReplacePlugin : IRCPlugin
{
private:
    /// All sed-replace options gathered.
    SedReplaceSettings sedReplaceSettings;

    /// Lifetime of a `Line` in `SedReplacePlugin.prevlines`, in seconds.
    enum replaceTimeoutSeconds = 3600;

    /++
     +  A `Line[string]` 1-buffer of the previous line every user said, with
     +  with nickname as key.
     +/
    Line[string] prevlines;

    mixin IRCPluginImpl;
}

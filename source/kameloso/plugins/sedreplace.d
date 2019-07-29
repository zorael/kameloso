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
 +  It supports a delimiter of `/`, `#` and `|`. You can also end it with a
 +  `g` to set the global flag, to have more than one match substituted.
 +
 +  ---
 +  $ echo "foo bar baz" | sed "s/bar/qux/g"
 +  $ echo "foo bar baz" | sed "s#bar#qux#g"
 +  $ echo "foo bar baz" | sed "s|bar|qux|g"
 +  ---
 +
 +  It is very optional.
 +/
module kameloso.plugins.sedreplace;

version(WithPlugins):
version(WithSedReplacePlugin):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.messaging;

import std.typecons : Flag, No, Yes;

/// Lifetime of a `Line` in `prevlines`, in seconds.
enum replaceTimeoutSeconds = 3600;


// SedReplaceSettings
/++
 +  All sed-replace plugin settings, gathered in a struct.
 +/
struct SedReplaceSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    @Enabler bool enabled = true;
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
 +
 +  Returns:
 +      Original line with the changes the replace pattern incurred.
 +/
string sedReplace(const string line, const string expr) @safe pure nothrow
{
    if (expr.length < 5) return line;

    switch (expr[1])
    {
    case '/':
        return line.sedReplaceImpl!'/'(expr);

    case '|':
        return line.sedReplaceImpl!'|'(expr);

    case '#':
        return line.sedReplaceImpl!'#'(expr);

    default:
        return line;
    }
}

///
unittest
{
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789/");
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "I am a fish";
        immutable after = before.sedReplace("s|a|e|g");
        assert((after == "I em e fish"), after);
    }
    {
        enum before = "Lorem ipsum dolor sit amet";
        immutable after = before.sedReplace("s###g");
        assert((after == "Lorem ipsum dolor sit amet"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所/");
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-/");
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/");
        assert((after == "H_RBL"), after);
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
 +
 +  Returns:
 +      The passed line with the relevant bits replaced, or as is if the expression
 +      was invalid or didn't apply.
 +/
string sedReplaceImpl(char char_)(const string line, const string expr)
{
    import std.algorithm.searching : startsWith;
    import std.array : replace;
    import std.string : indexOf;

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

    if (!expr.startsWith("s" ~ char_)) return line;

    string slice = expr;  // mutable
    slice = slice[2..$];  // nom 's' ~ char_

    bool global;

    if (slice[$-1] == 'g')
    {
        slice = slice[0..$-1];
        global = true;
    }

    if (slice[$-1] != char_) return line;

    immutable firstSlashPos = getNextUnescaped(slice);
    if (firstSlashPos == -1) return line;

    immutable replaceThis = slice[0..firstSlashPos].replace("\\" ~ char_, "" ~ char_);
    slice = slice[firstSlashPos+1..$];

    immutable secondSlashPos = getNextUnescaped(slice);
    if (secondSlashPos == -1) return line;
    else if (secondSlashPos+1 != slice.length) return line;

    immutable withThis = slice[0..$-1];

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
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C/");
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g");
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/");
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "I am a fish".sedReplaceImpl!'|'("s|fish|snek|g");
        assert((replaced == "I am a snek"), replaced);
    }
    {
        immutable replaced = "This is /a/a space".sedReplaceImpl!'/'("s/a\\//_/g");
        assert((replaced == "This is /_a space"), replaced);
    }
    {
        immutable replaced = "This is INVALID".sedReplaceImpl!'#'("s#asdfasdf#asdfasdf#asdfafsd#g");
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
    import kameloso.string : beginsWith, stripped;
    import std.datetime.systime : Clock;

    immutable stripped_ = event.content.stripped;

    if (stripped_.beginsWith("s") && (stripped_.length >= 5))
    {
        immutable delimeter = stripped_[1];

        switch (delimeter)
        {
        case '/':
        case '|':
        case '#':
            if (const line = event.sender.nickname in plugin.prevlines)
            {
                if ((Clock.currTime.toUnixTime - line.timestamp) > replaceTimeoutSeconds)
                {
                    // Entry is too old, remove it
                    plugin.prevlines.remove(event.sender.nickname);
                    return;
                }

                immutable result = line.content.sedReplace(event.content);
                if ((result == event.content) || !result.length) return;

                import kameloso.common : settings;
                import kameloso.messaging : chan;
                import std.format : format;

                chan(plugin.state, event.channel, "%s | %s".format(event.sender.nickname, result));
                plugin.prevlines.remove(event.sender.nickname);
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

    Line line;
    line.content = stripped_;
    line.timestamp = Clock.currTime.toUnixTime;
    plugin.prevlines[event.sender.nickname] = line;
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
    @Settings SedReplaceSettings sedReplaceSettings;

    /++
     +  A `Line[string]` 1-buffer of the previous line every user said, with
     +  with nickname as key.
     +/
    Line[string] prevlines;

    mixin IRCPluginImpl;
}

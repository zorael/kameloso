/++
 +  The SedReplace plugin imitates the UNIX `sed` tool, allowing for the
 +  replacemnt/substitution of text. It does not require the tool itself though,
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
 +  It supports a delimiteter of `/`, `#` and `|`. You can also end it with a
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

private:

import kameloso.plugins.common;
import kameloso.irc.defs;

/// Lifetime of a `Line` in `prevlines`, in seconds.
enum replaceTimeoutSeconds = 3600;

/// Regex patterns to find lines like `s/foo/bar/`.
enum sedPattern  = `^s/([^/]+)/([^/]*)/(g?)$`;
enum sedPattern2 = `^s#([^#]+)#([^#]*)#(g?)$`;
enum sedPattern3 = `^s\|([^|]+)\|([^|]*)\|(g?)$`;


// SedReplaceSettings
/++
 +  All sed-replace plugin settings, gathered in a struct.
 +/
struct SedReplaceSettings
{
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;
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
 +  This clones the behaviour of the UNIX-like `echo "foo" | sed 's/foo/bar'`.
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
string sedReplace(const string originalLine, const string expression) @safe
{
    import std.regex : matchAll, regex;

    static string doReplace(T)(T matches, const string originalLine) @safe
    {
        import std.array : replace;
        import std.regex : replaceAll, replaceFirst, regex;
        string result = originalLine;  // need mutable

        result = result
            .replace(`\[`, `\\[`)
            .replace(`\]`, `\\]`);

        foreach (const hit; matches)
        {
            const changeThis = hit[1];
            const toThis = hit[2];
            immutable globalFlag = (hit[3].length > 0);

            if (globalFlag)
            {
                result = result.replaceAll(changeThis.regex, toThis);
            }
            else
            {
                // We only care about the first result
                return result.replaceFirst(changeThis.regex, toThis);
            }
        }

        return result;
    }

    assert((expression.length > 2), originalLine);

    switch (expression[1])
    {
    case '/':
        static engine1 = sedPattern.regex;
        return doReplace(expression.matchAll(engine1), originalLine);

    case '#':
        static engine2 = sedPattern2.regex;
        return doReplace(expression.matchAll(engine2), originalLine);

    case '|':
        static engine3 = sedPattern3.regex;
        return doReplace(expression.matchAll(engine3), originalLine);

    default:
        return string.init;
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
}


// onMessage
/++
 +  Parses a channel message and looks for any sed-replace expressions therein,
 +  to apply on the previous message.
 +/
@(Terminating)
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
void onMessage(SedReplacePlugin plugin, const IRCEvent event)
{
    if (!plugin.sedReplaceSettings.enabled) return;

    import kameloso.string : beginsWith, stripped;
    import std.datetime.systime : Clock;

    immutable stripped_ = event.content.stripped;

    if (stripped_.beginsWith("s") && (stripped_.length > 2))
    {
        switch (stripped_[1])
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

                import kameloso.messaging : chan;
                import std.format : format;

                plugin.chan(event.channel, "%s | %s".format(event.sender.nickname, result));

                plugin.prevlines.remove(event.sender.nickname);
            }

            // Processed a sed-replace command (succesfully or not); return
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
    /++
     +  A `Line[string]` 1-buffer of the previous line every user said, with
     +  with nickname as key.
     +/
    Line[string] prevlines;

    /// All sed-replace options gathered.
    @Settings SedReplaceSettings sedReplaceSettings;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

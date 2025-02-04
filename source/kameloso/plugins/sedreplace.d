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
        https://github.com/zorael/kameloso/wiki/Current-plugins#sedreplace,
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.sedreplace;

version(WithSedReplacePlugin):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.messaging;
import dialect.defs;
import lu.container : CircularBuffer;
import std.algorithm.searching : startsWith;
import std.meta : AliasSeq;


/++
    Characters to support as delimiters in the replace expression.

    More can be added but if any are removed unit tests will need to be updated.
 +/
alias DelimiterCharacters = AliasSeq!('/', '|', '#', '@', ' ', '_', ';');


// SedReplaceSettings
/++
    All sed-replace plugin settings, gathered in a struct.
 +/
@Settings struct SedReplaceSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
     +/
    @Enabler bool enabled = true;

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
    /++
        Contents of last line uttered.
     +/
    string content;

    /++
        When the last line was spoken, in UNIX time.
     +/
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
    assert(line.sedReplace(expression, relaxSyntax: false) == "Thiz iz a line");
    ---

    Params:
        line = Line to apply the `sed`-replace pattern to.
        expr = Replacement pattern to apply.
        relaxSyntax = Whether or not to require the expression to end with the delimiter.

    Returns:
        Original line with the changes the replace pattern incurred, or an empty
        `string.init` if nothing was changed.
 +/
auto sedReplace(
    const string line,
    const string expr,
    const bool relaxSyntax)
in (line.length, "Tried to `sedReplace` an empty line")
in ((expr.length >= 5), "Tried to `sedReplace` with an invalid-length expression")
in (expr.startsWith('s'), "Tried to `sedReplace` with a non-expression expression")
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
        immutable after = before.sedReplace("s/123/789/", relaxSyntax: false);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "I am a fish";
        immutable after = before.sedReplace("s|a|e|g", relaxSyntax: false);
        assert((after == "I em e fish"), after);
    }
    {
        enum before = "Lorem ipsum dolor sit amet";
        immutable after = before.sedReplace("s###g", relaxSyntax: false);
        assert((after == "Lorem ipsum dolor sit amet"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所/", relaxSyntax: false);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-/", relaxSyntax : false);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", relaxSyntax : false);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "there are four lights";
        immutable after = before.sedReplace("s@ @_@g", relaxSyntax : false);
        assert((after == "there_are_four_lights"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot ", relaxSyntax : false);
        assert((after == "kameboto"), after);
    }
    {
        enum before = "abc 123 def 456";
        immutable after = before.sedReplace("s/123/789", relaxSyntax : true);
        assert((after == "abc 789 def 456"), after);
    }
    {
        enum before = "高所恐怖症";
        immutable after = before.sedReplace("s/高所/閉所", relaxSyntax : true);
        assert((after == "閉所恐怖症"), after);
    }
    {
        enum before = "asdf/fdsa";
        immutable after = before.sedReplace("s/\\//-", relaxSyntax : true);
        assert((after == "asdf-fdsa"), after);
    }
    {
        enum before = "HARBL";
        immutable after = before.sedReplace("s/A/_/", relaxSyntax : true);
        assert((after == "H_RBL"), after);
    }
    {
        enum before = "kameloso";
        immutable after = before.sedReplace("s los bot", relaxSyntax : true);
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
        The passed line with the relevant bits replaced, or `string.init` if the
        expression didn't apply.
 +/
auto sedReplaceImpl(char char_)
    (const string line,
    const string expr,
    const bool relaxSyntax)
in (line.length, "Tried to `sedReplaceImpl` on an empty line")
in (expr.length, "Tried to `sedReplaceImpl` with an empty expression")
{
    import lu.string : strippedRight;
    import std.array : replace;
    import std.string : indexOf;

    enum charAsString = "" ~ char_;
    enum escapedCharAsString = "\\" ~ char_;

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
    slice = slice[2..$];  // advance past 's' ~ char_

    bool global;

    if ((slice[$-2] == char_) && (slice[$-1] == 'g'))
    {
        slice = slice[0..$-1];
        global = true;
    }

    immutable openEnd = (slice[$-1] != char_);
    if (openEnd && !relaxSyntax) return string.init;

    immutable delimPos = getNextUnescaped(slice);
    if (delimPos == -1) return string.init;

    // Defer string-replace until after slice advance and subsequent length check
    string replaceThis = slice[0..delimPos];  // mutable

    slice = slice[delimPos+1..$];
    if (!slice.length) return slice;

    // ...to here.
    replaceThis = replaceThis.replace(escapedCharAsString, charAsString);

    immutable replaceThisPos = line.indexOf(replaceThis);
    if (replaceThisPos == -1) return string.init;

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
            return string.init;
        }
    }
    else
    {
        if ((endDelimPos == -1) || (endDelimPos+1 != slice.length))
        {
            // Either there were no more delimiters or one was found before the end
            // Syntax is strict; abort
            return string.init;
        }
    }

    immutable withThis = openEnd ? slice : slice[0..$-1];

    return global ?
        line.replace(replaceThis, withThis) :
        line.replace(replaceThisPos, replaceThisPos+replaceThis.length, withThis);
}

///
unittest
{
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C/", relaxSyntax : false);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", relaxSyntax : false);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", relaxSyntax : false);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "I am a fish".sedReplaceImpl!'|'("s|fish|snek|g", relaxSyntax : false);
        assert((replaced == "I am a snek"), replaced);
    }
    {
        immutable replaced = "This is /a/a space".sedReplaceImpl!'/'("s/a\\//_/g", relaxSyntax : false);
        assert((replaced == "This is /_a space"), replaced);
    }
    {
        immutable replaced = "This is INVALID"
            .sedReplaceImpl!'#'("s#asdfasdf#asdfasdf#asdfafsd#g", relaxSyntax : false);
        assert(!replaced.length, replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/Hello D/Hullo C", relaxSyntax : true);
        assert((replaced == "Hullo C"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/g", relaxSyntax : true);
        assert((replaced == "HeLLo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L", relaxSyntax : true);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "Hello D".sedReplaceImpl!'/'("s/l/L/", relaxSyntax : true);
        assert((replaced == "HeLlo D"), replaced);
    }
    {
        immutable replaced = "This is INVALID".sedReplaceImpl!'#'("s#INVALID#valid##", relaxSyntax : true);
        assert(!replaced.length, replaced);
    }
    {
        immutable replaced = "snek".sedReplaceImpl!'/'("s/snek/", relaxSyntax : true);
        assert(!replaced.length, replaced);
    }
    {
        immutable replaced = "snek".sedReplaceImpl!'/'("s/snek", relaxSyntax : true);
        assert(!replaced.length, replaced);
    }
    {
        immutable replaced = "hink".sedReplaceImpl!'/'("s/honk/henk/", relaxSyntax : true);
        assert(!replaced.length, replaced);
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
void onMessage(SedReplacePlugin plugin, const IRCEvent event)
{
    import lu.string : stripped;
    import std.algorithm.searching : startsWith;

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    immutable stripped_ = event.content.stripped;
    if (!stripped_.length) return;

    void recordLineAsLast(const string string_)
    {
        Line line = Line(string_, event.time);  // implicit ctor

        auto channelLines = event.channel in plugin.prevlines;
        if (!channelLines)
        {
            initPrevlines(plugin, event.channel, event.sender.nickname);
            channelLines = event.channel in plugin.prevlines;
        }

        auto senderLines = event.sender.nickname in *channelLines;
        if (!senderLines)
        {
            initPrevlines(plugin, event.channel, event.sender.nickname);
            senderLines = event.sender.nickname in *channelLines;
        }

        senderLines.put(line);
    }

    if (stripped_.startsWith('s') && (stripped_.length >= 5))
    {
        immutable delimiter = stripped_[1];

        delimiterswitch:
        switch (delimiter)
        {
        static if (DelimiterCharacters.length > 1)
        {
            foreach (immutable c; DelimiterCharacters[1..$])
            {
                case c:
                    goto case DelimiterCharacters[0];
            }
        }

        case DelimiterCharacters[0]:
            auto channelLines = event.channel in plugin.prevlines;
            if (!channelLines) return;  // Don't save

            auto senderLines = event.sender.nickname in *channelLines;
            if (!senderLines) return;  // As above

            // Work around CircularBuffer pre-1.2.3 having save annotated const
            foreach (immutable line; cast()senderLines.save)
            {
                import kameloso.messaging : chan;
                import std.format : format;

                if (!line.content.length)
                {
                    // line is Line.init
                    continue;
                }

                if ((event.time - line.timestamp) > plugin.prevlineLifetime)
                {
                    // Entry is too old, any further entries will be even older
                    break delimiterswitch;
                }

                immutable result = line.content.sedReplace(
                    event.content,
                    relaxSyntax: plugin.sedReplaceSettings.relaxSyntax);

                if (!result.length) continue;

                enum pattern = "<h>%s<h> | %s";
                immutable message = pattern.format(event.sender.nickname, result);
                chan(plugin.state, event.channel, message);

                // Record as last even if there are more lines
                return recordLineAsLast(result);
            }

            // Don't save as last, this was a query
            return;

        default:
            // Drop down to record line
            break;
        }
    }

    recordLineAsLast(stripped_);
}


// onWelcome
/++
    Sets up a fiber to periodically clear the lists of previous messages from
    users once every [SedReplacePlugin.timeBetweenPurges|timeBetweenPurges].

    This is to prevent the lists from becoming huge over time.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
    .fiber(true)
)
void onWelcome(SedReplacePlugin plugin)
{
    import kameloso.plugins.common.scheduling : delay;
    import std.datetime.systime : Clock;

    while (true)
    {
        // delay immediately so the first purge only happens after the first
        // timeBetweenPurges duration has passed
        delay(plugin, plugin.timeBetweenPurges, yield: true);

        immutable nowInUnix = Clock.currTime.toUnixTime();

        foreach (ref channelLines; plugin.prevlines)
        {
            foreach (immutable nickname, const senderLines; channelLines)
            {
                immutable delta = (nowInUnix - senderLines.front.timestamp);

                if (senderLines.empty || (delta >= plugin.prevlineLifetime))
                {
                    // Something is either wrong with the sender's entries or
                    // the most recent entry is too old
                    channelLines.remove(nickname);
                }
            }
        }
    }
}


// onJoin
/++
    Initialises the records of previous messages from a user when they join a channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.JOIN)
    .channelPolicy(ChannelPolicy.home)
)
void onJoin(SedReplacePlugin plugin, const IRCEvent event)
{
    initPrevlines(plugin, event.channel, event.sender.nickname);
}


// onPart
/++
    Removes the records of previous messages from a user when they leave a channel.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.PART)
    .channelPolicy(ChannelPolicy.home)
)
void onPart(SedReplacePlugin plugin, const IRCEvent event)
{
    if (auto channelLines = event.channel in plugin.prevlines)
    {
        (*channelLines).remove(event.sender.nickname);
    }
}


// onQuit
/++
    Removes the records of previous messages from a user when they quit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(SedReplacePlugin plugin, const IRCEvent event)
{
    foreach (ref channelLines; plugin.prevlines)
    {
        channelLines.remove(event.sender.nickname);
    }
}


// initPrevlines
/++
    Initialises the records of previous messages from a user when they join a channel.

    Params:
        plugin = Plugin instance.
        channelName = Name of channel to initialise.
        nickname = Nickname of user to initialise.
 +/
void initPrevlines(
    SedReplacePlugin plugin,
    const string channelName,
    const string nickname)
{
    auto channelLines = channelName in plugin.prevlines;
    if (!channelLines)
    {
        plugin.prevlines[channelName][nickname] = SedReplacePlugin.BufferType.init;
        auto senderLines = nickname in plugin.prevlines[channelName];
        senderLines.resize(SedReplacePlugin.messageMemory);
        return;
    }

    auto senderLines = nickname in *channelLines;
    if (!senderLines)
    {
        (*channelLines)[nickname] = SedReplacePlugin.BufferType.init;
        senderLines = nickname in *channelLines;
        senderLines.resize(SedReplacePlugin.messageMemory);
    }
}


// selftest
/++
    Performs self-tests against another bot.
 +/
version(Selftests)
auto selftest(SedReplacePlugin plugin, Selftester s)
{
    import kameloso.plugins.common.scheduling : delay;
    import core.time : seconds;

    s.sendPlain("I am a fish");
    s.sendPlain("s/fish/snek/");
    s.expect("${bot} | I am a snek");

    s.sendPlain("I am a fish fish");
    s.sendPlain("s#fish#snek#");
    s.expect("${bot} | I am a snek fish");

    s.sendPlain("I am a fish fish");
    s.sendPlain("s_fish_snek_g");
    s.expect("${bot} | I am a snek snek");

    s.sendPlain("s/harbusnarbu");
    s.sendPlain("s#snarbu#snofl/#");

    // Should be no response
    static immutable delayDuration = 5.seconds;
    delay(plugin, delayDuration, yield: true);
    s.requireTriggeredByTimer();

    return true;
}


mixin MinimalAuthentication;
mixin PluginRegistration!SedReplacePlugin;

public:


// SedReplacePlugin
/++
    The SedReplace plugin stores a buffer of the last said line of every user,
    and if a new message comes in with a sed-replace-like pattern in it, tries
    to apply it on the original message as a regex-like replace.
 +/
final class SedReplacePlugin : IRCPlugin
{
private:
    import std.typecons : Flag, No, Yes;
    import core.time : seconds;

    /++
        All sed-replace options gathered.
     +/
    SedReplaceSettings sedReplaceSettings;

    /++
        Lifetime of a [Line] in [prevlines], in seconds.
     +/
    enum prevlineLifetime = 3600;

    /++
        How often to purge the [prevlines] list of messages.
     +/
    static immutable timeBetweenPurges = (prevlineLifetime * 3).seconds;

    /++
        How many messages to keep in memory.
     +/
    enum messageMemory = 8;

    /++
        What kind of container to use for sent lines.
        Now static and hardcoded to a history length of 8 messages.
     +/
    alias BufferType = CircularBuffer!(Line, Yes.dynamic, messageMemory);

    /++
        An associative array of [BufferType]s of the previous line(s) every user said,
        keyed by nickname keyed by channel.
     +/
    BufferType[string][string] prevlines;

    mixin IRCPluginImpl;
}

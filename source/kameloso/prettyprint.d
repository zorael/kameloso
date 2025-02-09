/++
    Functions related to (formatting and) printing structs and classes to the
    local terminal, listing each member variable and their contents in an
    easy-to-visually-parse way.

    Example:

    `prettyprint(client, bot, server);`
    ---
/* Output to screen:

-- IRCClient
   string nickname               "kameloso"(8)
   string user                   "kameloso"(8)
   string ident                  "NaN"(3)
   string realName               "kameloso IRC bot"(16)

-- IRCBot
   string account                "kameloso"(8)
 string[] admins                 ["zorael"](1)
 string[] homeChannels           ["#flerrp"](1)
 string[] guestChannels          ["#d"](1)

-- IRCServer
   string address                "irc.libera.chat"(16)
   ushort port                    6667
 */
    ---

    Distance between types, member names and member values are deduced automatically
    based on how long they are (in terms of characters). If it doesn't line up,
    it's a bug.

    See_Also:
        [kameloso.terminal.colours]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.prettyprint;

private:

import std.range : isOutputRange;
import std.typecons : Flag, No, Yes;


// minimumTypeWidth
/++
    The minimum width of the type column, in characters.

    The current sweet spot is enough to accommodate
    [kameloso.plugins.quote.QuoteSettings.Precision|QuoteSettings.Precision].
 +/
enum minimumTypeWidth = 12;


// minimumNameWidth
/++
    The minimum width of the type column, in characters.

    The current sweet spot is enough to accommodate
    [kameloso.plugins.counter.CounterSettings.minimumPermissionsNeeded|CounterSettings.minimumPermissionsNeeded].
 +/
enum minimumNameWidth = 24;


public:


// Widths
/++
    Calculates the minimum padding needed to accommodate the strings of all the
    types and names of the members of the passed struct and/or classes, for
    formatting into neat columns.

    Params:
        all = Whether or not to also include [lu.uda.Unserialisable|Unserialisable] members.
        Things = Variadic list of aggregates to introspect.
 +/
private template Widths(Flag!"all" all, Things...)
if (Things.length > 0)
{
private:
    import std.algorithm.comparison : max;

    static if (all)
    {
        import kameloso.traits : longestUnserialisableMemberNames;

        alias names = longestUnserialisableMemberNames!Things;
        public enum type = max(minimumTypeWidth, names.type.length);
        enum initialWidth = names.member.length;
    }
    else
    {
        import kameloso.traits : longestMemberNames;

        alias names = longestMemberNames!Things;
        public enum type = max(minimumTypeWidth, names.type.length);
        enum initialWidth = names.member.length;
    }

    enum ptrdiff_t compensatedWidth = (type > minimumTypeWidth) ?
        (initialWidth - type + minimumTypeWidth) : initialWidth;
    public enum ptrdiff_t name = max(minimumNameWidth, compensatedWidth);
}

///
unittest
{
    import std.algorithm.comparison : max;

    struct S1
    {
        string someString;
        int someInt;
        string[] aaa;
    }

    struct S2
    {
        string longerString;
        int i;
    }

    alias widths = Widths!(No.all, S1, S2);

    static assert(widths.type == max(minimumTypeWidth, "string[]".length));
    static assert(widths.name == max(minimumNameWidth, "longerString".length));
}


// prettyprint
/++
    Prettyprints out aggregate objects, with all their printable members with all their
    printable values.

    This is not only convenient for debugging but also usable to print out
    current settings and state, where such is kept in structs.

    Example:
    ---
    struct Foo
    {
        int foo;
        string bar;
        float f;
        double d;
    }

    Foo foo, bar;
    prettyprint(foo, bar);
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        things = Variadic list of aggregate objects to enumerate.
 +/
void prettyprint(Flag!"all" all = No.all, Things...)(const auto ref Things things)
{
    import kameloso.constants : BufferSize;
    import std.array : Appender;
    import std.meta : allSatisfy;
    import std.stdio : stdout, writeln;
    import std.traits : isAggregateType;
    static import kameloso.common;

    static if (!Things.length)
    {
        import std.format : format;

        enum pattern = "`%s` was not passed anything to print";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }
    else static if (!allSatisfy!(isAggregateType, Things))
    {
        import std.format : format;

        enum pattern = "`%s` was passed one or more non-aggregate types";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    /+
        This is regrettable, but we need to be able to check the global headless
        flag to avoid printing anything if we shouldn't.
        I trust a simple __gshared return.
     +/
    immutable returnBecauseHeadless = () @trusted
    {
        return kameloso.common.globalHeadless;
    }();

    if (returnBecauseHeadless) return;

    alias widths = Widths!(all, Things);

    static Appender!(char[]) outbuffer;
    scope(exit) outbuffer.clear();
    outbuffer.reserve(BufferSize.prettyprintBufferPerObject * Things.length);

    foreach (immutable i, ref thing; things)
    {
        bool put;

        version(Colours)
        {
            if (kameloso.common.coreSettings.colours)
            {
                prettyformatImpl!(all, Yes.coloured)
                    (outbuffer,
                    brightTerminal: kameloso.common.coreSettings.brightTerminal,
                    thing,
                    widths.type+1,
                    widths.name);
                put = true;
            }
        }

        if (!put)
        {
            // Brightness setting is irrelevant; pass No
            prettyformatImpl!(all, No.coloured)
                (outbuffer,
                brightTerminal: false,
                thing,
                widths.type+1,
                widths.name);
        }

        static if (i+1 < things.length)
        {
            // Pad between things
            outbuffer.put('\n');
        }
    }

    writeln(outbuffer[]);

    /+
        writeln trusts stdout.flush, so we will too.
     +/
    () @trusted
    {
        // Flush stdout to make sure we don't lose any output
        if (kameloso.common.coreSettings.flush) stdout.flush();
    }();
}


// prettyformat
/++
    Formats an aggregate object, with all its printable members with all their
    printable values. Overload that writes to a passed output range sink.

    Example:
    ---
    struct Foo
    {
        int foo = 42;
        string bar = "arr matey";
        float f = 3.14f;
        double d = 9.99;
    }

    Foo foo, bar;
    Appender!(char[]) sink;

    sink.prettyformat!(Yes.all, Yes.coloured)(foo);
    sink.prettyformat!(No.all, No.coloured)(bar);
    writeln(sink[]);
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        coloured = Whether to display in colours or not.
        sink = Output range to write to.
        brightTerminal = Whether or not to format for a bright terminal background.
        things = Variadic list of aggregate objects to enumerate and format.
 +/
void prettyformat(
    Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured,
    Sink,
    Things...)
    (auto ref Sink sink,
    const bool brightTerminal,
    const auto ref Things things)
{
    import std.meta : allSatisfy;
    import std.traits : isAggregateType;
    import std.range.primitives : isOutputRange;

    static if (!Things.length)
    {
        import std.format : format;

        enum pattern = "`%s` was not passed anything to print";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }
    else static if (!allSatisfy!(isAggregateType, Things))
    {
        import std.format : format;

        enum pattern = "`%s` was passed one or more non-aggregate types";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }
    else static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    alias widths = Widths!(all, Things);

    foreach (immutable i, ref thing; things)
    {
        prettyformatImpl!(all, coloured)
            (sink,
            brightTerminal: brightTerminal,
            thing,
            widths.type+1,
            widths.name);

        static if ((i+1 < things.length) || !__traits(hasMember, Sink, "data"))
        {
            // Not an Appender, make sure it has a final linebreak to be consistent
            // with Appender writeln
            sink.put('\n');
        }
    }
}


// FormatStringMemberArguments
/++
    Argument aggregate for invocations of [prettyformatStringMemberImpl].
 +/
private struct FormatStringMemberArguments
{
    /++
        Type name.
     +/
    string typestring;

    /++
        Member name.
     +/
    string memberstring;

    /++
        Value of member.
     +/
    string value;

    /++
        Width (length) of longest type name.
     +/
    uint typewidth;

    /++
        Width (length) of longest member name.
     +/
    uint namewidth;

    /++
        Whether or not we should compensate for a bright terminal background.
     +/
    bool bright;

    /++
        How many characters to truncate the string to, if it's too long.
     +/
    size_t truncateAfter;
}


// prettyformatStringMemberImpl
/++
    Formats the description of a string for insertion into a [prettyformat] listing.
    The full string is passed and the function will truncate it if it's too long.

    Broken out of [prettyformat] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
 +/
private void prettyformatStringMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink,
    const FormatStringMemberArguments args)
{
    import std.format : formattedWrite;

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : asANSI;

        if (args.value.length > args.truncateAfter)
        {
            enum pattern = `%s%*s %s%-*s %s"%s"%s ... (%d)` ~ '\n';
            immutable memberCode = args.bright ? F.black : F.white;
            immutable valueCode  = args.bright ? F.green : F.lightgreen;
            immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
            immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

            sink.formattedWrite(
                pattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                //(args.value.length ? string.init : " "),
                valueCode.asANSI,
                args.value[0..args.truncateAfter],
                lengthCode.asANSI,
                args.value.length);
        }
        else
        {
            enum pattern = `%s%*s %s%-*s %s%s"%s"%s(%d)` ~ '\n';
            immutable memberCode = args.bright ? F.black : F.white;
            immutable valueCode  = args.bright ? F.green : F.lightgreen;
            immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
            immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

            sink.formattedWrite(
                pattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                (args.value.length ? string.init : " "),
                valueCode.asANSI,
                args.value,
                lengthCode.asANSI,
                args.value.length);
        }
    }
    else
    {
        if (args.value.length > args.truncateAfter)
        {
            enum pattern = `%*s %-*s "%s" ... (%d)` ~ '\n';
            sink.formattedWrite(
                pattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                //(args.value.length ? string.init : " "),
                args.value[0..args.truncateAfter],
                args.value.length);
        }
        else
        {
            enum pattern = `%*s %-*s %s"%s"(%d)` ~ '\n';
            sink.formattedWrite(
                pattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                (args.value.length ? string.init : " "),
                args.value,
                args.value.length);
        }
    }
}


// FormatArrayMemberArguments
/++
    Argument aggregate for invocations of [prettyformatArrayMemberImpl].
 +/
private struct FormatArrayMemberArguments
{
    /++
        Refers to different kinds of quotation signs (e.g. ´"´ or ´'´).
     +/
    enum QuoteSign
    {
        string_, /// ´"´
        char_,   /// ´'´
        none,    /// Nothing.
    }

    /++
        What sign (e.g. ´"´ or ´'´) to use when quoting the key.
     +/
    QuoteSign keyQuoteSign;

    /++
        What sign (e.g. ´"´ or ´'´) to use when quoting the value.
     +/
    QuoteSign valueQuoteSign;

    /++
        Alias to [valueQuoteSign] for consistency.
     +/
    alias elemQuoteSign = valueQuoteSign;

    /++
        Type name.
     +/
    string typestring;

    /++
        Member name.
     +/
    string memberstring;

    /++
        Value of member, as an array of strings.
     +/
    string[] value;

    /++
        Width (length) of longest type name.
     +/
    uint typewidth;

    /++
        Width (length) of longest member name.
     +/
    uint namewidth;

    /++
        Whether or not we should compensate for a bright terminal background.
     +/
    bool bright;

    /++
        Whether or not the array was truncated due to being too large.
     +/
    bool truncated;

    /++
        Original length of the array, prior to truncation.
     +/
    size_t length;
}


// prettyformatArrayMemberImpl
/++
    Formats the description of an array for insertion into a [prettyformat] listing.

    Broken out of [prettyformat] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
 +/
private void prettyformatArrayMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink,
    const FormatArrayMemberArguments args)
{
    import std.format : formattedWrite;
    import std.range.primitives : ElementEncodingType;
    import std.traits : TemplateOf;
    import std.typecons : Nullable;

    /// Quote character to enclose elements in
    immutable elemQuote =
        !args.value.length ? string.init :
        (args.elemQuoteSign == FormatArrayMemberArguments.QuoteSign.string_) ? `"` :
        (args.elemQuoteSign == FormatArrayMemberArguments.QuoteSign.char_) ? "'" :
        string.init;

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : asANSI;

        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        if (args.truncated)
        {
            immutable rtPattern = "%s%*s %s%-*s %s[%-(" ~
                elemQuote ~ "%s" ~ elemQuote ~ ", %)" ~ elemQuote ~ "]%s ... (%d)\n";

            sink.formattedWrite(
                rtPattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                valueCode.asANSI,
                args.value,
                lengthCode.asANSI,
                args.length);
        }
        else
        {
            immutable rtPattern = "%s%*s %s%-*s %s%s[%-(" ~
                elemQuote ~ "%s" ~ elemQuote ~ ", %)" ~ elemQuote ~ "]%s(%d)\n";

            sink.formattedWrite(
                rtPattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                (args.value.length ? string.init : " "),
                valueCode.asANSI,
                args.value,
                lengthCode.asANSI,
                args.length);
        }
    }
    else
    {
        if (args.truncated)
        {
            immutable rtPattern = "%*s %-*s [%-(" ~
                elemQuote ~ "%s" ~ elemQuote ~ ", %)" ~ elemQuote ~ "] ... (%d)\n";

            sink.formattedWrite(
                rtPattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                args.value,
                args.length);
        }
        else
        {
            immutable rtPattern = "%*s %-*s %s[%-(" ~
                elemQuote ~ "%s" ~ elemQuote ~ ", %)" ~ elemQuote ~ "](%d)\n";

            sink.formattedWrite(
                rtPattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                (args.value.length ? string.init : " "),
                args.value,
                args.length);
        }
    }
}


// prettyformatAssociativeArrayMemberImpl
/++
    Formats the description of an associative array for insertion into a
    [prettyformat] listing.

    Broken out of [prettyformat] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
        content = The associative array we're describing.
 +/
private void prettyformatAssociativeArrayMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink,
    const FormatArrayMemberArguments args,
    const string[string] content)
{
    import std.format : formattedWrite;

    /// Quote character to enclose keys in
    immutable keyQuote =
        !content.length ? string.init :
        (args.keyQuoteSign == FormatArrayMemberArguments.QuoteSign.string_) ? `"` :
        (args.keyQuoteSign == FormatArrayMemberArguments.QuoteSign.char_) ? "'" :
        string.init;

    /// Quote character to enclose values in
    immutable valueQuote =
        !content.length ? string.init :
        (args.valueQuoteSign == FormatArrayMemberArguments.QuoteSign.string_) ? `"` :
        (args.valueQuoteSign == FormatArrayMemberArguments.QuoteSign.char_) ? "'" :
        string.init;

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : asANSI;

        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        if (args.truncated)
        {
            immutable rtPattern = "%s%*s %s%-*s %s[%-(" ~
                keyQuote ~ "%s" ~ keyQuote ~ ":" ~
                valueQuote ~ "%s" ~ valueQuote~  ", %)" ~ valueQuote ~ "]%s ... (%d)\n";

            sink.formattedWrite(
                rtPattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                valueCode.asANSI,
                content,
                lengthCode.asANSI,
                args.length);
        }
        else
        {
            immutable rtPattern = "%s%*s %s%-*s %s%s[%-(" ~
                keyQuote ~ "%s" ~ keyQuote ~ ":" ~
                valueQuote ~ "%s" ~ valueQuote ~ ", %)" ~ valueQuote ~ "]%s(%d)\n";

            sink.formattedWrite(
                rtPattern,
                typeCode.asANSI,
                args.typewidth,
                args.typestring,
                memberCode.asANSI,
                args.namewidth,
                args.memberstring,
                (content.length ? string.init : " "),
                valueCode.asANSI,
                content,
                lengthCode.asANSI,
                args.length);
        }
    }
    else
    {
        if (args.truncated)
        {
            immutable rtPattern = "%*s %-*s [%-(" ~
                keyQuote ~ "%s" ~ keyQuote  ~ ":" ~
                valueQuote ~ "%s" ~ valueQuote ~ ", %)" ~ valueQuote ~ "] ... (%d)\n";

            sink.formattedWrite(
                rtPattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                content,
                args.length);
        }
        else
        {
            immutable rtPattern = "%*s %-*s %s[%-(" ~
                keyQuote ~ "%s" ~ keyQuote  ~ ":" ~
                valueQuote ~ "%s" ~ valueQuote ~ ", %)" ~ valueQuote ~ "](%d)\n";

            sink.formattedWrite(
                rtPattern,
                args.typewidth,
                args.typestring,
                args.namewidth,
                args.memberstring,
                (content.length ? string.init : " "),
                content,
                args.length);
        }
    }
}


// FormatAggregateMemberArguments
/++
    Argument aggregate for invocations of [prettyformatAggregateMemberImpl].
 +/
private struct FormatAggregateMemberArguments
{
    /++
        Type name.
     +/
    string typestring;

    /++
        Member name.
     +/
    string memberstring;

    /++
        Type of member aggregate; one of "struct", "class", "interface" and "union".
     +/
    string aggregateType;

    /++
        Text snippet indicating whether or not the aggregate is in an initial state.
     +/
    string initText;

    /++
        Width (length) of longest type name.
     +/
    uint typewidth;

    /++
        Width (length) of longest member name.
     +/
    uint namewidth;

    /++
        Whether or not we should compensate for a bright terminal background.
     +/
    bool bright;
}


// prettyformatAggregateMemberImpl
/++
    Formats the description of an aggregate for insertion into a [prettyformat] listing.

    Broken out of [prettyformat] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
 +/
private void prettyformatAggregateMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink,
    const FormatAggregateMemberArguments args)
{
    import std.format : formattedWrite;

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : asANSI;

        enum pattern = "%s%*s %s%-*s %s<%s>%s\n";
        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        sink.formattedWrite(
            pattern,
            typeCode.asANSI,
            args.typewidth,
            args.typestring,
            memberCode.asANSI,
            args.namewidth,
            args.memberstring,
            valueCode.asANSI,
            args.aggregateType,
            args.initText);
    }
    else
    {
        enum pattern = "%*s %-*s <%s>%s\n";
        sink.formattedWrite(
            pattern,
            args.typewidth,
            args.typestring,
            args.namewidth,
            args.memberstring,
            args.aggregateType,
            args.initText);
    }
}


// FormatOtherMemberArguments
/++
    Argument aggregate for invocations of [prettyformatOtherMemberImpl].
 +/
private struct FormatOtherMemberArguments
{
    /++
        Type name.
     +/
    string typestring;

    /++
        Member name.
     +/
    string memberstring;

    /++
        Value of member, as string.
     +/
    string value;

    /++
        Width (length) of longest type name.
     +/
    uint typewidth;

    /++
        Width (length) of longest member name.
     +/
    uint namewidth;

    /++
        Whether or not we should compensate for a bright terminal background.
     +/
    bool bright;
}


// prettyformatOtherMemberImpl
/++
    Formats the description of a non-string, non-array, non-aggregate value
    for insertion into a [prettyformat] listing.

    Broken out of [prettyformat] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
 +/
private void prettyformatOtherMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink,
    const FormatOtherMemberArguments args)
{
    import std.format : formattedWrite;

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : asANSI;

        enum pattern = "%s%*s %s%-*s  %s%s\n";
        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        sink.formattedWrite(
            pattern,
            typeCode.asANSI,
            args.typewidth,
            args.typestring,
            memberCode.asANSI,
            args.namewidth,
            args.memberstring,
            valueCode.asANSI,
            args.value);
    }
    else
    {
        enum pattern = "%*s %-*s  %s\n";
        sink.formattedWrite(
            pattern,
            args.typewidth,
            args.typestring,
            args.namewidth,
            args.memberstring,
            args.value);
    }
}


// prettyformatImpl
/++
    Formats an aggregate object, with all its printable members with all their
    printable values. This is an implementation template and should not be
    called directly; instead use [prettyprint] or [prettyformat].

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        coloured = Whether to display in colours or not.
        sink = Output range to write to.
        bright = Whether or not to format for a bright terminal background.
        thing = Aggregate object to enumerate and format.
        typewidth = The width with which to pad type names, to align properly.
        namewidth = The width with which to pad variable names, to align properly.
 +/
private void prettyformatImpl(
    Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured,
    Sink,
    Thing)
    (auto ref Sink sink,
    const bool brightTerminal,
    const auto ref Thing thing,
    const uint typewidth,
    const uint namewidth)
{
    import lu.string : stripSuffix;
    import std.format : formattedWrite;
    import std.meta : allSatisfy;
    import std.range.primitives : isOutputRange;
    import std.traits : Unqual, isAggregateType;

    static if (!isAggregateType!Thing)
    {
        import std.format : format;

        enum pattern = "`%s` was passed a non-aggregate type `%s`";
        enum message = pattern.format(__FUNCTION__, T.stringof);
        static assert(0, message);
    }
    else static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    static if (coloured)
    {
        import kameloso.terminal.colours.defs : F = TerminalForeground;
        import kameloso.terminal.colours : applyANSI;

        immutable titleCode = brightTerminal ? F.black : F.white;
        sink.applyANSI(titleCode);
        scope(exit) sink.applyANSI(F.default_);
    }

    alias Thing = Unqual!(typeof(thing));

    sink.formattedWrite("-- %s\n", Thing.stringof.stripSuffix("Settings"));

    foreach (immutable memberstring; __traits(derivedMembers, Thing))
    {
        import kameloso.traits :
            memberIsMutable,
            memberIsValue,
            memberIsVisibleAndNotDeprecated,
            memberstringIsThisCtorOrDtor;
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA;

        enum namePadding = 2;
        enum stringTruncation = 128;
        enum arrayTruncation = 5;
        enum aaTruncation = 5;

        static if (
            !memberstringIsThisCtorOrDtor(memberstring) &&
            memberIsVisibleAndNotDeprecated!(Thing, memberstring) &&
            memberIsValue!(Thing, memberstring) &&
            memberIsMutable!(Thing, memberstring) &&
            (all ||
                (isSerialisable!(__traits(getMember, Thing, memberstring)) &&
                !hasUDA!(__traits(getMember, Thing, memberstring), Hidden) &&
                !hasUDA!(__traits(getMember, Thing, memberstring), Unserialisable))))
        {
            import lu.traits : isTrulyString;
            import std.conv : to;
            import std.traits : isAggregateType, isArray, isAssociativeArray;

            alias T = Unqual!(typeof(__traits(getMember, Thing, memberstring)));

            static if (isTrulyString!T)
            {
                FormatStringMemberArguments args;
                const content = __traits(getMember, thing, memberstring);
                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = brightTerminal;
                args.truncateAfter = all ? uint.max : stringTruncation;
                args.value = content.to!string;
                prettyformatStringMemberImpl!coloured(sink, args);
            }
            else static if (isArray!T || isAssociativeArray!T)
            {
                import lu.traits : UnqualArray;
                import std.conv : to;
                import std.range : take;
                import std.range.primitives : ElementEncodingType;

                enum quoteSign(Type) =
                    (is(Type == char) ||
                     is(Type == dchar) ||
                     is(Type == wchar)) ? FormatArrayMemberArguments.QuoteSign.char_ :
                    (is(Type == string) ||
                     is(Type == dstring) ||
                     is(Type == wstring)) ? FormatArrayMemberArguments.QuoteSign.string_ :
                    FormatArrayMemberArguments.QuoteSign.none;

                FormatArrayMemberArguments args;
                auto content = __traits(getMember, thing, memberstring);
                args.typestring = UnqualArray!T.stringof;
                args.memberstring = memberstring;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.truncated = !all && (content.length > arrayTruncation);
                args.bright = brightTerminal;

                static if (isArray!T)
                {
                    import std.algorithm.iteration : map;
                    import std.array : array;
                    import std.traits : TemplateOf;
                    import std.typecons : Nullable;

                    alias ElemType = Unqual!(ElementEncodingType!T);

                    static if (__traits(isSame, TemplateOf!ElemType, Nullable))
                    {
                        import std.traits : TemplateArgsOf;
                        args.typestring = "N!" ~ TemplateArgsOf!ElemType.stringof;
                    }
                    else
                    {
                        args.typestring = UnqualArray!T.stringof;
                    }

                    enum truncateAfter = all ? uint.max : arrayTruncation;
                    args.elemQuoteSign = quoteSign!ElemType;
                    args.length = content.length;
                    args.value = content[]
                        .take(truncateAfter)
                        .map!(a => a.to!string)
                        .array;
                    prettyformatArrayMemberImpl!coloured(sink, args);
                }
                else /*static if (isAssociativeArray!T)*/
                {
                    import std.traits : KeyType, ValueType;

                    alias AAKeyType = Unqual!(KeyType!T);
                    alias AAValueType = Unqual!(ValueType!T);

                    enum truncateAfter = all ? uint.max : aaTruncation;
                    args.keyQuoteSign = quoteSign!(AAKeyType);
                    args.valueQuoteSign = quoteSign!(AAValueType);
                    args.length = content.length;

                    static if (!is(T : string[string]))
                    {
                        string[string] asStringAA;
                        auto range = content
                            .byKeyValue
                            .take(truncateAfter);

                        foreach (kv; range)
                        {
                            asStringAA[kv.key.to!string] = kv.value.to!string;
                        }
                    }
                    else
                    {
                        alias asStringAA = content;
                    }

                    prettyformatAssociativeArrayMemberImpl!coloured(sink, args, asStringAA);
                }
            }
            else static if (isAggregateType!T)
            {
                enum aggregateType =
                    is(T == struct) ? "struct" :
                    is(T == class) ? "class" :
                    is(T == interface) ? "interface" :
                    /*is(T == union) ?*/ "union"; //: "<error>";

                FormatAggregateMemberArguments args;

                static if (is(Thing == struct) && is(T == struct))
                {
                    const constTemporary = __traits(getMember, Thing.init, memberstring);
                    immutable isInit = (__traits(getMember, thing, memberstring) == constTemporary);
                    args.initText = isInit ?
                        " (init)" :
                        string.init;
                }
                else static if (is(T == class) || is(T == interface))
                {
                    immutable isInit = (__traits(getMember, thing, memberstring) is null);
                    args.initText = isInit ?
                        " (null)" :
                        string.init;
                }

                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.aggregateType = aggregateType;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = brightTerminal;
                prettyformatAggregateMemberImpl!coloured(sink, args);
            }
            else
            {
                FormatOtherMemberArguments args;
                auto content = __traits(getMember, thing, memberstring);
                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = brightTerminal;

                static if (isTrulyString!T)
                {
                    args.value = content.to!string;
                }
                else static if (is(T == enum))
                {
                    import lu.conv : toString;

                    static if (__traits(compiles, content.toString()))
                    {
                        args.value = content.toString();
                    }
                    else
                    {
                        import std.conv : to;
                        args.value = content.to!string;
                    }
                }
                else static if (is(T == bool))
                {
                    args.value = content ? "true" : "false";
                }
                else static if (is(T : long))
                {
                    args.value = (cast(long)content).to!string;
                }
                else static if (is(T : double))
                {
                    args.value = (cast(double)content).to!string;
                }
                else
                {
                    args.value = content.to!string;
                }

                prettyformatOtherMemberImpl!coloured(sink, args);
            }
        }
    }
}

///
@system unittest
{
    import lu.assert_ : assertMultilineEquals;
    import std.array : Appender;
    import std.string : indexOf;

    Appender!(char[]) sink;
    sink.reserve(512);  // ~323

    {
        struct Struct
        {
            string members;
            int asdf;
        }

        struct StructName
        {
            Struct struct_;
            int i = 12_345;
            string s = "the moon; the sign of hope! it appeared when we left the pain " ~
                "of the ice desert behind. we faced up to the curse and endured " ~
                "misery. condemned we are! we brought hope but also lies, and treachery...";
            string p = "!";
            string p2;
            bool b = true;
            float f = 3.14f;
            double d = 99.9;
            const(char)[] c = [ 'a', 'b', 'c' ];
            const(char)[] emptyC;
            string[] dynA = [ "foo", "bar", "baz" ];
            int[] iA = [ 1, 2, 3, 4 ];
            const(char)[char] cC;
        }

        StructName s;
        s.cC = [ 'k':'v', 'K':'V' ];

        enum theMoon = `"the moon; the sign of hope! it appeared when we left the ` ~
            `pain of the ice desert behind. we faced up to the curse and endured mis"`;

        enum structNameSerialised =
`-- StructName
       Struct struct_                    <struct> (init)
          int i                           12345
       string s                          ` ~ theMoon ~ ` ... (198)
       string p                          "!"(1)
       string p2                          ""(0)
         bool b                           true
        float f                           3.14
       double d                           99.9
       char[] c                          ['a', 'b', 'c'](3)
       char[] emptyC                      [](0)
     string[] dynA                       ["foo", "bar", "baz"](3)
        int[] iA                         [1, 2, 3, 4](4)
   char[char] cC                         ['k':'v', 'K':'V'](2)
`;

        sink.prettyformat!(No.all, No.coloured)(brightTerminal: false, s);
        sink[].assertMultilineEquals(structNameSerialised);
        sink.clear();

        // Class copy
        class ClassName
        {
            Struct struct_;
            int i = 12_345;
            string s = "foo";
            string p = "!";
            string p2;
            bool b = true;
            float f = 3.14f;
            double d = 99.9;
            const(char)[] c = [ 'a', 'b', 'c' ];
            const(char)[] emptyC;
            string[] dynA = [ "foo", "bar", "baz" ];
            int[] iA = [ 1, 2, 3, 4 ];
            int[] iA2 = [ 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
            const(char)[char] cC;
            bool[int] aa;
            string[string] aa2;
        }

        auto c1 = new ClassName;
        c1.aa = [ 1 : true, 2 : false, 3 : true, 4 : false, 5: true, 6 : false];
        c1.aa2 = [ "harbl" : "snarbl", "foo" : "bar"];

        enum classNameSerialised =
`-- ClassName
         Struct struct_                    <struct>
            int i                           12345
         string s                          "foo"(3)
         string p                          "!"(1)
         string p2                          ""(0)
           bool b                           true
          float f                           3.14
         double d                           99.9
         char[] c                          ['a', 'b', 'c'](3)
         char[] emptyC                      [](0)
       string[] dynA                       ["foo", "bar", "baz"](3)
          int[] iA                         [1, 2, 3, 4](4)
          int[] iA2                        [5, 6, 7, 8, 9] ... (11)
     char[char] cC                          [](0)
      bool[int] aa                         [6:false, 4:false, 1:true, 3:true, 5:true] ... (6)
 string[string] aa2                        ["foo":"bar", "harbl":"snarbl"](2)
`;

        sink.prettyformat!(No.all, No.coloured)(brightTerminal: false, c1);
        sink[].assertMultilineEquals(classNameSerialised);
        sink.clear();
    }
    {
        // Two at a time
        struct Struct1
        {
            string members;
            int asdf;
        }

        struct Struct2
        {
            string mumburs;
            int fdsa;
        }

        Struct1 st1;
        Struct2 st2;

        st1.members = "harbl";
        st1.asdf = 42;
        st2.mumburs = "hirrs";
        st2.fdsa = -1;

        enum st1st2Formatted =
`-- Struct1
       string members                    "harbl"(5)
          int asdf                        42

-- Struct2
       string mumburs                    "hirrs"(5)
          int fdsa                        -1
`;

        sink.prettyformat!(No.all, No.coloured)(brightTerminal: false, st1, st2);
        sink[].assertMultilineEquals(st1st2Formatted);
        sink.clear();
    }
    {
        version(Colours)
        {
            // Colour
            struct StructName2Settings
            {
                int int_ = 12_345;
                string string_ = "foo";
                bool bool_ = true;
                float float_ = 3.14f;
                double double_ = 99.9;
            }
            StructName2Settings s2;

            sink.clear();
            sink.reserve(256);  // ~239
            sink.prettyformat!(No.all, Yes.coloured)(brightTerminal: false, s2);

            assert((sink[].length > 12), "Empty sink after coloured fill");

            assert(sink[].indexOf("-- StructName2\n") != -1);  // Settings stripped
            assert(sink[].indexOf("int_") != -1);
            assert(sink[].indexOf("12345") != -1);

            assert(sink[].indexOf("string_") != -1);
            assert(sink[].indexOf(`"foo"`) != -1);

            assert(sink[].indexOf("bool_") != -1);
            assert(sink[].indexOf("true") != -1);

            assert(sink[].indexOf("float_") != -1);
            assert(sink[].indexOf("3.14") != -1);

            assert(sink[].indexOf("double_") != -1);
            assert(sink[].indexOf("99.9") != -1);

            sink.clear();
        }
    }
    {
        class C
        {
            string a = "abc";
            bool b = true;
            int i = 42;
        }

        C c2 = new C;

        enum cFormatted =
`-- C
       string a                          "abc"(3)
         bool b                           true
          int i                           42
`;

        sink.prettyformat!(No.all, No.coloured)(brightTerminal: false, c2);
        sink[].assertMultilineEquals(cFormatted);
        sink.clear();
    }
    {
        interface I3
        {
            void foo();
        }

        class C3 : I3
        {
            void foo() {}
            int i;
        }

        class C4
        {
            I3 i3;
            C3 c3;
            int i = 42;
        }

        C4 c4 = new C4;
        //c4.i3 = new C3;
        c4.c3 = new C3;
        c4.c3.i = -1;

        enum c4Formatted =
`-- C4
           I3 i3                         <interface> (null)
           C3 c3                         <class>
          int i                           42

-- I3

-- C3
          int i                           -1
`;

        sink.prettyformat!(No.all, No.coloured)(brightTerminal: false, c4, c4.i3, c4.c3);
        sink[].assertMultilineEquals(c4Formatted);
        //sink.clear();
    }
}


// prettyformat
/++
    Formats a struct object, with all its printable members with all their
    printable values. A `string`-returning overload that doesn't take an input range.

    This is useful when you just want the object(s) formatted without having to
    pass it a sink.

    Example:
    ---
    struct Foo
    {
        int foo = 42;
        string bar = "arr matey";
        float f = 3.14f;
        double d = 9.99;
    }

    Foo foo, bar;

    writeln(prettyformat!(No.all, Yes.coloured)(foo));
    writeln(prettyformat!(Yes.all, No.coloured)(bar));
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        coloured = Whether to display in colours or not.
        brightTerminal = Whether or not to format for a bright terminal background.
        things = Variadic list of structs to enumerate and format.

    Returns:
        String with the object formatted, as per the passed arguments.
 +/
string prettyformat(
    Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured,
    Things...)
    (const bool brightTerminal,
    const auto ref Things things) pure
if ((Things.length > 0) && !isOutputRange!(Things[0], char[]))  // must be a constraint
{
    import kameloso.constants : BufferSize;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(BufferSize.prettyprintBufferPerObject * Things.length);

    prettyformat!(all, coloured)(sink, brightTerminal: brightTerminal, things);
    return sink[];
}

///
unittest
{
    import lu.assert_ : assertMultilineEquals;

    // Rely on the main unit tests of the output range version of prettyformat
    {
        struct Struct
        {
            string members;
            int asdf;
        }

        Struct s;
        s.members = "foo";
        s.asdf = 42;

        enum expected =
`-- Struct
       string members                    "foo"(3)
          int asdf                        42
`;

        immutable actual = prettyformat!(No.all, No.coloured)(brightTerminal: false, s);
        actual.assertMultilineEquals(expected);
    }
    {
        class Nested
        {
            int harbl;
            string snarbl;
        }

        class ClassSettings
        {
            string s = "arb";
            int i;
            string someLongConfiguration = "acdc adcadcad acacdadc";
            int[] arrMatey = [ 1, 2, 3, 42 ];
            Nested nest;
        }

        auto c = new ClassSettings;
        c.i = 2;

        enum expected =
`-- Class
       string s                          "arb"(3)
          int i                           2
       string someLongConfiguration      "acdc adcadcad acacdadc"(22)
        int[] arrMatey                   [1, 2, 3, 42](4)
       Nested nest                       <class> (null)
`;

        immutable actual = prettyformat!(No.all, No.coloured)(brightTerminal: false, c);
        actual.assertMultilineEquals(expected);

        c.nest = new Nested;
        enum expected2 =
`-- Class
       string s                          "arb"(3)
          int i                           2
       string someLongConfiguration      "acdc adcadcad acacdadc"(22)
        int[] arrMatey                   [1, 2, 3, 42](4)
       Nested nest                       <class>
`;

        immutable actual2 = prettyformat!(No.all, No.coloured)(brightTerminal: false, c);
        actual2.assertMultilineEquals(expected2);
    }
    {
        struct Reparse {}
        struct Client {}
        struct Server {}

        struct State
        {
            Client client;
            Server server;
            Reparse[] reparses;
            bool hasReplays;
        }

        State state;

        enum expected =
`-- State
       Client client                     <struct> (init)
       Server server                     <struct> (init)
    Reparse[] reparses                    [](0)
         bool hasReplays                  false
`;

        immutable actual = prettyformat!(No.all, No.coloured)(brightTerminal: false, state);
        actual.assertMultilineEquals(expected);
    }
}

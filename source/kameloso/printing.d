/++
    Functions related to (formatting and) printing structs and classes to the
    local terminal, listing each member variable and their contents in an
    easy-to-visually-parse way.

    Example:

    `printObjects(client, bot, settings);`
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
    its a bug.

    See_Also:
        [kameloso.terminal.colours]
 +/
module kameloso.printing;

private:

import std.range.primitives : isOutputRange;
import std.meta : allSatisfy;
import std.traits : isAggregateType;
import std.typecons : Flag, No, Yes;

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
{
private:
    import std.algorithm.comparison : max;

    enum minimumTypeWidth = 8;  // Current sweet spot, accommodates well for `string[]`
    enum minimumNameWidth = 24;  // Current minimum 22, TwitchSettings' "caseSensitiveTriggers"

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

    enum minimumTypeWidth = 8;  // Current sweet spot, accommodates well for `string[]`
    enum minimumNameWidth = 24;  // Current minimum 22, TwitchSettings' "caseSensitiveTriggers"

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


// printObjects
/++
    Prints out aggregate objects, with all their printable members with all their
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
    printObjects(foo, bar);
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        things = Variadic list of aggregate objects to enumerate.
 +/
void printObjects(Flag!"all" all = No.all, Things...)(auto ref Things things) @trusted // for stdout.flush()
if ((Things.length > 0) && allSatisfy!(isAggregateType, Things))
{
    static import kameloso.common;
    import kameloso.constants : BufferSize;
    import std.array : Appender;
    import std.stdio : stdout, writeln;

    alias widths = Widths!(all, Things);

    static Appender!(char[]) outbuffer;
    scope(exit) outbuffer.clear();
    outbuffer.reserve(BufferSize.printObjectBufferPerObject * Things.length);

    foreach (immutable i, ref thing; things)
    {
        bool put;

        version(Colours)
        {
            if (!kameloso.common.settings)
            {
                // Threading and/or otherwise forgot to assign pointer `kameloso.common.settings`
                // It will be wrong but initialise it here so we at least don't crash
                kameloso.common.settings = new typeof(*kameloso.common.settings);
            }

            if (!kameloso.common.settings.monochrome)
            {
                formatObjectImpl!(all, Yes.coloured)(outbuffer,
                    cast(Flag!"brightTerminal")kameloso.common.settings.brightTerminal,
                    thing, widths.type+1, widths.name);
                put = true;
            }
        }

        if (!put)
        {
            // Brightness setting is irrelevant; pass false
            formatObjectImpl!(all, No.coloured)(outbuffer, No.brightTerminal,
                thing, widths.type+1, widths.name);
        }

        static if (i+1 < things.length)
        {
            // Pad between things
            outbuffer.put('\n');
        }
    }

    writeln(outbuffer.data);
    if (kameloso.common.settings.flush) stdout.flush();
}


/// Ditto
alias printObject = printObjects;


// formatObjects
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

    sink.formatObjects!(Yes.all, Yes.coloured)(foo);
    sink.formatObjects!(No.all, No.coloured)(bar);
    writeln(sink.data);
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        coloured = Whether to display in colours or not.
        sink = Output range to write to.
        bright = Whether or not to format for a bright terminal background.
        things = Variadic list of aggregate objects to enumerate and format.
 +/
void formatObjects(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Things...)
    (auto ref Sink sink,
    const Flag!"brightTerminal" bright,
    auto ref Things things)
if ((Things.length > 0) && allSatisfy!(isAggregateType, Things) && isOutputRange!(Sink, char[]))
{
    alias widths = Widths!(all, Things);

    foreach (immutable i, ref thing; things)
    {
        formatObjectImpl!(all, coloured)(sink, bright, thing, widths.type+1, widths.name);

        static if ((i+1 < things.length) || !__traits(hasMember, Sink, "data"))
        {
            // Not an Appender, make sure it has a final linebreak to be consistent
            // with Appender writeln
            sink.put('\n');
        }
    }
}

/// Ditto
alias formatObject = formatObjects;


// FormatStringMemberArguments
/++
    Argument aggregate for invocations of [formatStringMemberImpl].
 +/
private struct FormatStringMemberArguments
{
    /// Type name.
    string typestring;

    /// Member name.
    string memberstring;

    /// Width (length) of longest type name.
    uint typewidth;

    /// Width (length) of longest member name.
    uint namewidth;

    /// Whether or not we should compensate for a bright terminal background.
    bool bright;

    /// Whether or not to truncate long lines.
    bool truncate = true;
}


// formatStringMemberImpl
/++
    Formats the description of a string for insertion into a [formatObjects] listing.

    Broken out of [formatObjects] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
        content = The contents of the string member we're describing.
 +/
private void formatStringMemberImpl(Flag!"coloured" coloured, T, Sink)
    (auto ref Sink sink, const FormatStringMemberArguments args, const auto ref T content)
{
    import std.format : formattedWrite;

    enum truncateAfter = 128;

    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour;

        if (args.truncate && (content.length > truncateAfter))
        {
            enum stringPattern = `%s%*s %s%-*s %s"%s"%s ... (%d)` ~ '\n';
            immutable memberCode = args.bright ? F.black : F.white;
            immutable valueCode  = args.bright ? F.green : F.lightgreen;
            immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
            immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

            sink.formattedWrite(stringPattern,
                typeCode.colour, args.typewidth, args.typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                //(content.length ? string.init : " "),
                valueCode.colour, content[0..truncateAfter],
                lengthCode.colour, content.length);
        }
        else
        {
            enum stringPattern = `%s%*s %s%-*s %s%s"%s"%s(%d)` ~ '\n';
            immutable memberCode = args.bright ? F.black : F.white;
            immutable valueCode  = args.bright ? F.green : F.lightgreen;
            immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
            immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

            sink.formattedWrite(stringPattern,
                typeCode.colour, args.typewidth, args.typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                valueCode.colour, content,
                lengthCode.colour, content.length);
        }
    }
    else
    {
        if (args.truncate && (content.length > truncateAfter))
        {
            enum stringPattern = `%*s %-*s "%s" ... (%d)` ~ '\n';
            sink.formattedWrite(stringPattern,
                args.typewidth, args.typestring,
                args.namewidth, args.memberstring,
                //(content.length ? string.init : " "),
                content[0..truncateAfter],
                content.length);
        }
        else
        {
            enum stringPattern = `%*s %-*s %s"%s"(%d)` ~ '\n';
            sink.formattedWrite(stringPattern,
                args.typewidth, args.typestring,
                args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                content,
                content.length);
        }
    }
}


// FormatArrayMemberArguments
/++
    Argument aggregate for invocations of [formatArrayMemberImpl].
 +/
private struct FormatArrayMemberArguments
{
    /// Type name.
    string typestring;

    /// Member name.
    string memberstring;

    /// Element type name.
    string elemstring;

    /// Whether or not the element is a `char`.
    bool elemIsCharacter;

    /// Width (length) of longest type name.
    uint typewidth;

    /// Width (length) of longest member name.
    uint namewidth;

    /// Whether or not we should compensate for a bright terminal background.
    bool bright;

    /// Whether or not to truncate big arrays.
    bool truncate = true;
}


// formatArrayMemberImpl
/++
    Formats the description of an array for insertion into a [formatObjects] listing.

    Broken out of [formatObjects] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
        rawContent = The array we're describing.
 +/
private void formatArrayMemberImpl(Flag!"coloured" coloured, T, Sink)
    (auto ref Sink sink, const FormatArrayMemberArguments args, const auto ref T rawContent)
{
    import std.format : formattedWrite;
    import std.range.primitives : ElementEncodingType;
    import std.traits : TemplateOf;
    import std.typecons : Nullable;

    enum truncateAfter = 5;

    static if (__traits(isSame, TemplateOf!(ElementEncodingType!T), Nullable))
    {
        import std.array : replace;
        import std.conv : to;
        import std.traits : TemplateArgsOf;

        immutable typestring = "N!" ~ TemplateArgsOf!(ElementEncodingType!T).stringof;
        immutable endIndex = (args.truncate && (rawContent.length > truncateAfter)) ?
            truncateAfter :
            rawContent.length;
        immutable content = rawContent[0..endIndex]
            .to!string
            .replace("Nullable.null", "N.null");
        immutable length = rawContent.length;
        enum alreadyTruncated = true;
    }
    else
    {
        import lu.traits : UnqualArray;

        immutable typestring = UnqualArray!T.stringof;
        alias content = rawContent;
        immutable length = content.length;
        enum alreadyTruncated = false;
    }

    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour;

        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        if (!alreadyTruncated && args.truncate && (content.length > truncateAfter))
        {
            immutable rtArrayPattern = args.elemIsCharacter ?
                "%s%*s %s%-*s %s[%(%s, %)]%s ... (%d)\n" :
                "%s%*s %s%-*s %s%s%s ... (%d)\n";

            sink.formattedWrite(rtArrayPattern,
                typeCode.colour, args.typewidth, typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                valueCode.colour, content[0..truncateAfter],
                lengthCode.colour, length);
        }
        else
        {
            immutable rtArrayPattern = args.elemIsCharacter ?
                "%s%*s %s%-*s %s%s[%(%s, %)]%s(%d)\n" :
                "%s%*s %s%-*s %s%s%s%s(%d)\n";

            sink.formattedWrite(rtArrayPattern,
                typeCode.colour, args.typewidth, typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                valueCode.colour, content,
                lengthCode.colour, length);
        }
    }
    else
    {
        if (!alreadyTruncated && args.truncate && (content.length > truncateAfter))
        {
            immutable rtArrayPattern = args.elemIsCharacter ?
                "%*s %-*s [%(%s, %)] ... (%d)\n" :
                "%*s %-*s %s ... (%d)\n";

            sink.formattedWrite(rtArrayPattern,
                args.typewidth, typestring,
                args.namewidth, args.memberstring,
                content[0..truncateAfter], length);
        }
        else
        {
            immutable rtArrayPattern = args.elemIsCharacter ?
                "%*s %-*s %s[%(%s, %)](%d)\n" :
                "%*s %-*s %s%s(%d)\n";

            sink.formattedWrite(rtArrayPattern,
                args.typewidth, typestring,
                args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                content, length);
        }
    }
}


// formatAssociativeArrayMemberImpl
/++
    Formats the description of an associative array for insertion into a
    [formatObjects] listing.

    Broken out of [formatObjects] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
        content = The associative array we're describing.
 +/
private void formatAssociativeArrayMemberImpl(Flag!"coloured" coloured, T, Sink)
    (auto ref Sink sink, const FormatArrayMemberArguments args, const auto ref T content)
{
    import std.format : formattedWrite;

    enum truncateAfter = 5;

    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour;

        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable lengthCode = args.bright ? F.default_ : F.darkgrey;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        if (args.truncate && (content.length > truncateAfter))
        {
            enum aaPattern = "%s%*s %s%-*s %s%s%s ... (%d)\n";

            sink.formattedWrite(aaPattern,
                typeCode.colour, args.typewidth, args.typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                valueCode.colour, content.keys[0..truncateAfter],
                lengthCode.colour, content.length);
        }
        else
        {
            enum aaPattern = "%s%*s %s%-*s %s%s%s%s(%d)\n";

            sink.formattedWrite(aaPattern,
                typeCode.colour, args.typewidth, args.typestring,
                memberCode.colour, args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                valueCode.colour, content.keys,
                lengthCode.colour, content.length);
        }
    }
    else
    {
        if (args.truncate && (content.length > truncateAfter))
        {
            enum aaPattern = "%*s %-*s %s ... (%d)\n";

            sink.formattedWrite(aaPattern,
                args.typewidth, args.typestring,
                args.namewidth, args.memberstring,
                content.keys[0..truncateAfter],
                content.length);
        }
        else
        {
            enum aaPattern = "%*s %-*s %s%s(%d)\n";

            sink.formattedWrite(aaPattern,
                args.typewidth, args.typestring,
                args.namewidth, args.memberstring,
                (content.length ? string.init : " "),
                content,
                content.length);
        }
    }
}


// FormatAggregateMemberArguments
/++
    Argument aggregate for invocations of [formatAggregateMemberImpl].
 +/
private struct FormatAggregateMemberArguments
{
    /// Type name.
    string typestring;

    /// Member name.
    string memberstring;

    /// Type of member aggregate; one of "struct", "class", "interface" and "union".
    string aggregateType;

    /// Text snippet indicating whether or not the aggregate is in an initial state.
    string initText;

    /// Width (length) of longest type name.
    uint typewidth;

    /// Width (length) of longest member name.
    uint namewidth;

    /// Whether or not we should compensate for a bright terminal background.
    bool bright;
}


// formatAggregateMemberImpl
/++
    Formats the description of an aggregate for insertion into a [formatObjects] listing.

    Broken out of [formatObjects] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
 +/
private void formatAggregateMemberImpl(Flag!"coloured" coloured, Sink)
    (auto ref Sink sink, const FormatAggregateMemberArguments args)
{
    import std.format : formattedWrite;

    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour;

        enum normalPattern = "%s%*s %s%-*s %s<%s>%s\n";
        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        sink.formattedWrite(normalPattern,
            typeCode.colour, args.typewidth, args.typestring,
            memberCode.colour, args.namewidth, args.memberstring,
            valueCode.colour, args.aggregateType, args.initText);
    }
    else
    {
        enum normalPattern = "%*s %-*s <%s>%s\n";
        sink.formattedWrite(normalPattern, args.typewidth, args.typestring,
            args.namewidth, args.memberstring, args.aggregateType,args.initText);
    }
}


// FormatOtherMemberArguments
/++
    Argument aggregate for invocations of [formatOtherMemberImpl].
 +/
private struct FormatOtherMemberArguments
{
    /// Type name.
    string typestring;

    /// Member name.
    string memberstring;

    /// Width (length) of longest type name.
    uint typewidth;

    /// Width (length) of longest member name.
    uint namewidth;

    /// Whether or not we should compensate for a bright terminal background.
    bool bright;
}


// formatOtherMemberImpl
/++
    Formats the description of a non-string, non-array, non-aggregate value
    for insertion into a [formatObjects] listing.

    Broken out of [formatObjects] to reduce template bloat.

    Params:
        coloured = Whether or no to display terminal colours.
        sink = Output range to store output in.
        args = Argument aggregate for easier passing.
        content = The value we're describing.
 +/
private void formatOtherMemberImpl(Flag!"coloured" coloured, T, Sink)
    (auto ref Sink sink, const FormatOtherMemberArguments args, const auto ref T content)
{
    import std.format : formattedWrite;

    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour;

        enum normalPattern = "%s%*s %s%-*s  %s%s\n";
        immutable memberCode = args.bright ? F.black : F.white;
        immutable valueCode  = args.bright ? F.green : F.lightgreen;
        immutable typeCode   = args.bright ? F.lightcyan : F.cyan;

        sink.formattedWrite(normalPattern,
            typeCode.colour, args.typewidth, args.typestring,
            memberCode.colour, args.namewidth, args.memberstring,
            valueCode.colour, content);
    }
    else
    {
        enum normalPattern = "%*s %-*s  %s\n";
        sink.formattedWrite(normalPattern, args.typewidth, args.typestring,
            args.namewidth, args.memberstring, content);
    }
}


// formatObjectImpl
/++
    Formats an aggregate object, with all its printable members with all their
    printable values. This is an implementation template and should not be
    called directly; instead use [printObjects] or [formatObjects].

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
private void formatObjectImpl(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Thing)
    (auto ref Sink sink,
    const Flag!"brightTerminal" bright,
    auto ref Thing thing,
    const uint typewidth,
    const uint namewidth)
if (isOutputRange!(Sink, char[]) && isAggregateType!Thing)
{
    static if (coloured)
    {
        import kameloso.terminal.colours : F = TerminalForeground, colour, colourWith;
    }

    import lu.string : stripSuffix;
    import std.format : formattedWrite;
    import std.traits : Unqual;

    alias Thing = Unqual!(typeof(thing));

    static if (coloured)
    {
        immutable titleCode = bright ? F.black : F.white;
        sink.colourWith(titleCode);
        scope(exit) sink.colourWith(F.default_);
    }

    sink.formattedWrite("-- %s\n", Thing.stringof.stripSuffix("Settings"));

    foreach (immutable memberstring; __traits(derivedMembers, Thing))
    {
        import kameloso.traits : memberIsMutable, memberIsValue,
            memberIsVisibleAndNotDeprecated, memberstringIsThisCtorOrDtor;
        import lu.traits : isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : hasUDA;

        enum namePadding = 2;

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
            import std.traits : isAggregateType, isArray, isAssociativeArray;

            alias T = Unqual!(typeof(__traits(getMember, Thing, memberstring)));

            static if (isTrulyString!T)
            {
                FormatStringMemberArguments args;
                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = bright;
                args.truncate = !all;
                formatStringMemberImpl!(coloured, T)(sink, args, __traits(getMember, thing, memberstring));
            }
            else static if (isArray!T || isAssociativeArray!T)
            {
                import lu.traits : UnqualArray;
                import std.range.primitives : ElementEncodingType;

                alias ElemType = Unqual!(ElementEncodingType!T);

                FormatArrayMemberArguments args;
                args.typestring = UnqualArray!T.stringof;
                args.memberstring = memberstring;
                args.elemstring = ElemType.stringof;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.truncate = !all;
                args.bright = bright;

                static if (isArray!T)
                {
                    enum elemIsCharacter =
                        is(ElemType == char) ||
                        is(ElemType == dchar) ||
                        is(ElemType == wchar);

                    args.elemIsCharacter = elemIsCharacter;
                    formatArrayMemberImpl!(coloured, T)(sink, args,
                        __traits(getMember, thing, memberstring));
                }
                else /*static if (isAssociativeArray!T)*/
                {
                    // Can't pass T for some reason, nor UnqualArray
                    formatAssociativeArrayMemberImpl!(coloured, T)(sink, args,
                        __traits(getMember, thing, memberstring));
                }
            }
            else static if (isAggregateType!T)
            {
                enum aggregateType =
                    is(T == struct) ? "struct" :
                    is(T == class) ? "class" :
                    is(T == interface) ? "interface" :
                    /*is(T == union) ?*/ "union"; //: "<error>";

                static if (is(Thing == struct) && is(T == struct))
                {
                    immutable initText = (__traits(getMember, thing, memberstring) ==
                        __traits(getMember, Thing.init, memberstring)) ?
                            " (init)" :
                            string.init;
                }
                else static if (is(T == class) || is(T == interface))
                {
                    immutable initText = (__traits(getMember, thing, memberstring) is null) ?
                        " (null)" :
                        string.init;
                }
                else
                {
                    enum initText = string.init;
                }

                FormatAggregateMemberArguments args;
                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.aggregateType = aggregateType;
                args.initText = initText;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = bright;

                formatAggregateMemberImpl!coloured(sink, args);
            }
            else
            {
                FormatOtherMemberArguments args;
                args.typestring = T.stringof;
                args.memberstring = memberstring;
                args.typewidth = typewidth;
                args.namewidth = namewidth + namePadding;
                args.bright = bright;

                formatOtherMemberImpl!(coloured, T)(sink, args, __traits(getMember, thing, memberstring));
            }
        }
    }
}

///
@system unittest
{
    import lu.string : contains;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(512);  // ~323

    struct Struct
    {
        string members;
        int asdf;
    }

    // Monochrome

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
    s.cC = [ 'a':'a', 'b':'b' ];
    assert('a' in s.cC);
    assert('b' in s.cC);

    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, s);

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
 char[char] cC                         ['b':'b', 'a':'a'](2)
`;
    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Adding Settings does nothing
    alias StructNameSettings = StructName;
    StructNameSettings so = s;
    sink.clear();
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, so);

    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

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
        const(char)[char] cC;
    }

    auto c1 = new ClassName;
    sink.clear();
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, c1);

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
 char[char] cC                          [](0)
`;

    assert((sink.data == classNameSerialised), '\n' ~ sink.data);

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

    sink.clear();
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, st1, st2);
    enum st1st2Formatted =
`-- Struct1
   string members                    "harbl"(5)
      int asdf                        42

-- Struct2
   string mumburs                    "hirrs"(5)
      int fdsa                        -1
`;
    assert((sink.data == st1st2Formatted), '\n' ~ sink.data);

    // Colour
    struct StructName2
    {
        int int_ = 12_345;
        string string_ = "foo";
        bool bool_ = true;
        float float_ = 3.14f;
        double double_ = 99.9;
    }

    version(Colours)
    {
        StructName2 s2;

        sink.clear();
        sink.reserve(256);  // ~239
        sink.formatObjects!(No.all, Yes.coloured)(No.brightTerminal, s2);

        assert((sink.data.length > 12), "Empty sink after coloured fill");

        assert(sink.data.contains("-- StructName"));
        assert(sink.data.contains("int_"));
        assert(sink.data.contains("12345"));

        assert(sink.data.contains("string_"));
        assert(sink.data.contains(`"foo"`));

        assert(sink.data.contains("bool_"));
        assert(sink.data.contains("true"));

        assert(sink.data.contains("float_"));
        assert(sink.data.contains("3.14"));

        assert(sink.data.contains("double_"));
        assert(sink.data.contains("99.9"));

        // Adding Settings does nothing
        alias StructName2Settings = StructName2;
        immutable sinkCopy = sink.data.idup;
        StructName2Settings s2o;

        sink.clear();
        sink.formatObjects!(No.all, Yes.coloured)(No.brightTerminal, s2o);
        assert((sink.data == sinkCopy), sink.data);
    }

    class C
    {
        string a = "abc";
        bool b = true;
        int i = 42;
    }

    C c2 = new C;

    sink.clear();
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, c2);
    enum cFormatted =
`-- C
   string a                          "abc"(3)
     bool b                           true
      int i                           42
`;
    assert((sink.data == cFormatted), '\n' ~ sink.data);

    sink.clear();

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

    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, c4, c4.i3, c4.c3);
    enum c4Formatted =
`-- C4
       I3 i3                         <interface> (null)
       C3 c3                         <class>
      int i                           42

-- I3

-- C3
      int i                           -1
`;
    assert((sink.data == c4Formatted), '\n' ~ sink.data);
}


// formatObjects
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

    writeln(formatObjects!(No.all, Yes.coloured)(foo));
    writeln(formatObjects!(Yes.all, No.coloured)(bar));
    ---

    Params:
        all = Whether or not to also display members marked as
            [lu.uda.Unserialisable|Unserialisable]; usually transitive
            information that doesn't carry between program runs.
            Also those annotated [lu.uda.Hidden|Hidden].
        coloured = Whether to display in colours or not.
        bright = Whether or not to format for a bright terminal background.
        things = Variadic list of structs to enumerate and format.

    Returns:
        String with the object formatted, as per the passed arguments.
 +/
string formatObjects(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Things...)
    (const Flag!"brightTerminal" bright, auto ref Things things)
if ((Things.length > 0) && !isOutputRange!(Things[0], char[]))
{
    import kameloso.constants : BufferSize;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(BufferSize.printObjectBufferPerObject * Things.length);

    formatObjects!(all, coloured)(sink, bright, things);
    return sink.data;
}

///
unittest
{
    // Rely on the main unit tests of the output range version of formatObjects

    struct Struct
    {
        string members;
        int asdf;
    }

    Struct s;
    s.members = "foo";
    s.asdf = 42;

    immutable formatted = formatObjects!(No.all, No.coloured)(No.brightTerminal, s);
    assert((formatted ==
`-- Struct
   string members                    "foo"(3)
      int asdf                        42
`), '\n' ~ formatted);

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

    immutable formattedClass = formatObjects!(No.all, No.coloured)(No.brightTerminal, c);
    assert((formattedClass ==
`-- Class
   string s                          "arb"(3)
      int i                           2
   string someLongConfiguration      "acdc adcadcad acacdadc"(22)
    int[] arrMatey                   [1, 2, 3, 42](4)
   Nested nest                       <class> (null)
`), '\n' ~ formattedClass);

    c.nest = new Nested;
    immutable formattedClass2 = formatObjects!(No.all, No.coloured)(No.brightTerminal, c);
    assert((formattedClass2 ==
`-- Class
   string s                          "arb"(3)
      int i                           2
   string someLongConfiguration      "acdc adcadcad acacdadc"(22)
    int[] arrMatey                   [1, 2, 3, 42](4)
   Nested nest                       <class>
`), '\n' ~ formattedClass2);

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

    immutable formattedState = formatObjects!(No.all, No.coloured)(No.brightTerminal, state);
    assert((formattedState ==
`-- State
    Client client                     <struct> (init)
    Server server                     <struct> (init)
 Reparse[] reparses                    [](0)
      bool hasReplays                  false
`), '\n' ~ formattedState);
}

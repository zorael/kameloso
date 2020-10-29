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
 string[] admins                ["zorael"](1)
 string[] homeChannels          ["#flerrp"](1)
 string[] guestChannels         ["#d"](1)

-- IRCServer
   string address                "irc.freenode.net"(16)
   ushort port                    6667
*/
    ---

    Distance between types, member names and member values are deduced automatically
    based on how long they are (in terms of characters). If it doesn't line up,
    its a bug.
 +/
module kameloso.printing;

private:

import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

public:


// Widths
/++
    Calculates the minimum padding needed to accommodate the strings of all the
    types and names of the members of the passed struct and/or classes, for
    formatting into neat columns.

    Params:
        all = Whether or not to also include `lu.uda.Unserialisable` members.
        Things = Variadic list of aggregates to inspect.
 +/
private template Widths(Flag!"all" all, Things...)
{
private:
    import std.algorithm.comparison : max;

    enum minimumTypeWidth = 8;  // Current sweet spot, accommodates well for `string[]`
    enum minimumNameWidth = 24;  // Current minimum 22, TwitchBotSettings' "caseSensitiveTriggers"

    static if (all)
    {
        import kameloso.traits : longestUnserialisableMemberName,
            longestUnserialisableMemberTypeName;

        public enum type = max(minimumTypeWidth,
            longestUnserialisableMemberTypeName!Things.length);
        enum initialWidth = longestUnserialisableMemberName!Things.length;
    }
    else
    {
        import kameloso.traits : longestMemberName, longestMemberTypeName;
        public enum type = max(minimumTypeWidth, longestMemberTypeName!Things.length);
        enum initialWidth = longestMemberName!Things.length;
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
    enum minimumNameWidth = 24;  // Current minimum 22, TwitchBotSettings' "caseSensitiveTriggers"

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
    Prints out struct objects, with all their printable members with all their
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
            `lu.uda.Unserialisable`; usually transitive information that
            doesn't carry between program runs. Also those annotated `lu.uda.Hidden`.
        things = Variadic list of struct objects to enumerate.
 +/
void printObjects(Flag!"all" all = No.all, Things...)
    (auto ref Things things)
{
    import kameloso.common : settings;
    import kameloso.constants : BufferSize;
    import std.array : Appender;
    import std.stdio : writeln;

    alias widths = Widths!(all, Things);

    static Appender!(char[]) outbuffer;
    scope(exit) outbuffer.clear();
    outbuffer.reserve(BufferSize.printObjectBufferPerObject * Things.length);

    foreach (immutable i, thing; things)
    {
        bool put;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                formatObjectImpl!(all, Yes.coloured)(outbuffer,
                    (settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal),
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
}


/// Ditto
alias printObject = printObjects;


// formatObjects
/++
    Formats a struct object, with all its printable members with all their
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
    Appender!string sink;

    sink.formatObjects!(Yes.coloured)(foo);
    sink.formatObjects!(No.coloured)(bar);
    writeln(sink.data);
    ---

    Params:
        all = Whether or not to also display members marked as
            `lu.uda.Unserialisable`; usually transitive information that
            doesn't carry between program runs. Also those annotated `lu.uda.Hidden`.
        coloured = Whether to display in colours or not.
        sink = Output range to write to.
        bright = Whether or not to format for a bright terminal background.
        things = Variadic list of structs or classes to enumerate and format.
 +/
void formatObjects(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Things...)
    (auto ref Sink sink, const Flag!"brightTerminal" bright, auto ref Things things)
if (isOutputRange!(Sink, char[]))
{
    alias widths = Widths!(all, Things);

    foreach (immutable i, thing; things)
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


// formatObjectImpl
/++
    Formats a struct object, with all its printable members with all their
    printable values. This is an implementation template and should not be
    called directly; instead use `printObjects` or `formatObjects`.

    Params:
        all = Whether or not to also display members marked as
            `lu.uda.Unserialisable`; usually transitive information that
            doesn't carry between program runs. Also those annotated `lu.uda.Hidden`.
        coloured = Whether to display in colours or not.
        sink = Output range to write to.
        bright = Whether or not to format for a bright terminal background.
        thing = Struct or class to enumerate and format.
        typewidth = The width with which to pad type names, to align properly.
        namewidth = The width with which to pad variable names, to align properly.
 +/
private void formatObjectImpl(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Sink, Thing)
    (auto ref Sink sink, const Flag!"brightTerminal" bright, auto ref Thing thing,
    const uint typewidth, const uint namewidth)
if (isOutputRange!(Sink, char[]))
{
    static if (coloured)
    {
        import kameloso.terminal : TerminalForeground, colour;
        alias F = TerminalForeground;
    }

    import lu.string : stripSuffix;
    import std.format : formattedWrite;
    import std.traits : Unqual;

    alias Thing = Unqual!(typeof(thing));

    static if (coloured)
    {
        immutable titleCode = bright ? F.black : F.white;
        sink.formattedWrite("%s-- %s\n", titleCode.colour,
            Thing.stringof.stripSuffix("Settings"));
    }
    else
    {
        sink.formattedWrite("-- %s\n", Thing.stringof.stripSuffix("Settings"));
    }

    foreach (immutable i, member; thing.tupleof)
    {
        import lu.traits : isAnnotated, isSerialisable;
        import lu.uda : Hidden, Unserialisable;
        import std.traits : isAssociativeArray, isType;

        enum shouldBePrinted = all ||
            (!__traits(isDeprecated, thing.tupleof[i]) &&
            isSerialisable!member &&
            !isAnnotated!(thing.tupleof[i], Hidden) &&
            !isAnnotated!(thing.tupleof[i], Unserialisable));

        static if (shouldBePrinted)
        {
            import lu.traits : isTrulyString;
            import std.traits : isArray;

            alias T = Unqual!(typeof(member));

            enum memberstring = __traits(identifier, thing.tupleof[i]);

            static if (isTrulyString!T)
            {
                static if (coloured)
                {
                    enum stringPattern = `%s%*s %s%-*s %s%s"%s"%s(%d)` ~ '\n';
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable lengthCode = bright ? F.lightgrey : F.darkgrey;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(stringPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        (member.length < 2) ? " " : string.init,
                        valueCode.colour, member,
                        lengthCode.colour, member.length);
                }
                else
                {
                    enum stringPattern = `%*s %-*s %s"%s"(%d)` ~ '\n';
                    sink.formattedWrite(stringPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring,
                        (member.length < 2) ? " " : string.init,
                        member, member.length);
                }
            }
            else static if (isArray!T || isAssociativeArray!T)
            {
                import std.range.primitives : ElementEncodingType;

                alias ElemType = Unqual!(ElementEncodingType!T);

                enum elemIsCharacter = is(ElemType == char) ||
                    is(ElemType == dchar) || is(ElemType == wchar);

                immutable thisWidth = member.length ? (namewidth + 2) : (namewidth + 4);

                static if (coloured)
                {
                    static if (elemIsCharacter)
                    {
                        enum arrayPattern = "%s%*s %s%-*s%s[%(%s, %)]%s(%d)\n";
                    }
                    else
                    {
                        enum arrayPattern = "%s%*s %s%-*s%s%s%s(%d)\n";
                    }

                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable lengthCode = bright ? F.lightgrey : F.darkgrey;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    import lu.traits : UnqualArray;

                    sink.formattedWrite(arrayPattern,
                        typeCode.colour, typewidth, UnqualArray!T.stringof,
                        memberCode.colour, thisWidth, memberstring,
                        valueCode.colour, member,
                        lengthCode.colour, member.length);
                }
                else
                {
                    static if (elemIsCharacter)
                    {
                        enum arrayPattern = "%*s %-*s[%(%s, %)](%d)\n";
                    }
                    else
                    {
                        enum arrayPattern = "%*s %-*s%s(%d)\n";
                    }

                    import lu.traits : UnqualArray;

                    sink.formattedWrite(arrayPattern,
                        typewidth, UnqualArray!T.stringof,
                        thisWidth, memberstring,
                        member,
                        member.length);
                }
            }
            else static if (is(T == struct) || is(T == class))
            {
                enum classOrStruct = is(T == struct) ? "struct" : "class";

                immutable initText = (thing.tupleof[i] == Thing.init.tupleof[i]) ?
                    " (init)" :
                    string.init;

                static if (coloured)
                {
                    enum normalPattern = "%s%*s %s%-*s %s<%s>%s\n";
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(normalPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        valueCode.colour, classOrStruct, initText);
                }
                else
                {
                    enum normalPattern = "%*s %-*s <%s>%s\n";
                    sink.formattedWrite(normalPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring, classOrStruct, initText);
                }
            }
            else
            {
                static if (coloured)
                {
                    enum normalPattern = "%s%*s %s%-*s  %s%s\n";
                    immutable memberCode = bright ? F.black : F.white;
                    immutable valueCode = bright ? F.green : F.lightgreen;
                    immutable typeCode = bright ? F.lightcyan : F.cyan;

                    sink.formattedWrite(normalPattern,
                        typeCode.colour, typewidth, T.stringof,
                        memberCode.colour, (namewidth + 2), memberstring,
                        valueCode.colour, member);
                }
                else
                {
                    enum normalPattern = "%*s %-*s  %s\n";
                    sink.formattedWrite(normalPattern, typewidth, T.stringof,
                        (namewidth + 2), memberstring, member);
                }
            }
        }
    }

    static if (coloured)
    {
        enum defaultColour = F.default_.colour.idup;
        sink.put(defaultColour);
    }
}

///
@system unittest
{
    import lu.string : contains;
    import std.array : Appender;

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

    StructName s;
    s.cC = [ 'a':'a', 'b':'b' ];
    assert('a' in s.cC);
    assert('b' in s.cC);
    Appender!(char[]) sink;

    sink.reserve(512);  // ~323
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, s);

    enum structNameSerialised =
`-- StructName
     Struct struct_                    <struct> (init)
        int i                           12345
     string s                          "foo"(3)
     string p                           "!"(1)
     string p2                          ""(0)
       bool b                           true
      float f                           3.14
     double d                           99.9
     char[] c                         ['a', 'b', 'c'](3)
     char[] emptyC                      [](0)
   string[] dynA                      ["foo", "bar", "baz"](3)
      int[] iA                        [1, 2, 3, 4](4)
 char[char] cC                        ['b':'b', 'a':'a'](2)
`;
    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

    // Adding Settings does nothing
    alias StructNameSettings = StructName;
    StructNameSettings so = s;
    sink.clear();
    sink.formatObjects!(No.all, No.coloured)(No.brightTerminal, so);

    assert((sink.data == structNameSerialised), "\n" ~ sink.data);

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
            `lu.uda.Unserialisable`; usually transitive information that
            doesn't carry between program runs. Also those annotated `lu.uda.Hidden`.
        coloured = Whether to display in colours or not.
        bright = Whether or not to format for a bright terminal background.
        things = Variadic list of structs to enumerate and format.

    Returns:
        String with the object formatted, as per the passed arguments.
 +/
string formatObjects(Flag!"all" all = No.all,
    Flag!"coloured" coloured = Yes.coloured, Things...)
    (const Flag!"brightTerminal" bright, Things things)
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

    class ClassSettings
    {
        string s = "arb";
        int i;
        string someLongConfiguration = "acdc adcadcad acacdadc";
        int[] arrMatey = [ 1, 2, 3, 42 ];

    }

    auto c = new ClassSettings;
    c.i = 2;

    immutable formattedClass = formatObjects!(No.all, No.coloured)(No.brightTerminal, c);
    assert((formattedClass ==
`-- Class
   string s                          "arb"(3)
      int i                           2
   string someLongConfiguration      "acdc adcadcad acacdadc"(22)
    int[] arrMatey                  [1, 2, 3, 42](4)
`), '\n' ~ formattedClass);
}

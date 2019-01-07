/++
 +  Various functions related to serialising structs into .ini file-like files.
 +/
module kameloso.config;

import std.typecons : Flag, No, Yes;

@safe:


// configReader
/++
 +  Reads configuration file into a string.
 +
 +  Example:
 +  ---
 +  string configText = configReader("kameloso.conf");
 +  ---
 +
 +  Params:
 +      configFile = Filename of file to read from.
 +
 +  Returns:
 +      The contents of the supplied file.
 +
 +  Throws:
 +      `kameloso.common.FileTypeMismatchException` if the configuration file is a directory, a
 +      character file or any other non-file type we can't write to.
 +      `ConfigurationFileReadFailureException` if the reading and decoding of
 +      the configuration file failed.
 +/
string configReader(const string configFile)
{
    import kameloso.common : FileTypeMismatchException;
    import std.file : exists, getAttributes, isFile, readText;
    import std.string : chomp;

    if (!configFile.exists) return string.init;
    else if (!configFile.isFile)
    {
        throw new FileTypeMismatchException("Configuration file is not a file",
            configFile, cast(ushort)getAttributes(configFile), __FILE__);
    }

    try
    {
        return configFile
            .readText
            .chomp;
    }
    catch (Exception e)
    {
        // catch Exception instead of UTFException, just in case there are more
        // kinds of error than the normal "Invalid UTF-8 sequence".
        throw new ConfigurationFileReadFailureException(e.msg, configFile,
            __FILE__, __LINE__);
    }
}


// readConfigInto
/++
 +  Reads a configuration file and applies the settings therein to passed objects.
 +
 +  More than one can be supplied, and invalid ones for which there are no
 +  settings will be silently ignored with no errors.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +
 +  "kameloso.conf".readConfigInto(client, server);
 +  ---
 +
 +  Params:
 +      configFile = Filename of file to read from.
 +      things = Reference variadic list of things to set values of, according
 +          to the text in the configuration file.
 +
 +  Returns:
 +      An associative array of string arrays of invalid configuration entries
 +      encountered while reading the configuration file.
 +      The associative array key is the section the entry was found under, and
 +      the arrays merely lists of such erroneous entries thereunder.
 +/
string[][string] readConfigInto(T...)(const string configFile, ref T things)
{
    import std.algorithm.iteration : splitter;

    return configFile
        .configReader
        .splitter("\n")
        .applyConfiguration(things);
}


// serialise
/++
 +  Convenience method to call `serialise` on several objects.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  IRCClient client;
 +  IRCServer server;
 +  sink.serialise(client, server);
 +  assert(!sink.data.empty);
 +  ---
 +
 +  Params:
 +      sink = Reference output range to write the serialised objects to (in
 +          their .ini file-like format).
 +      things = Variadic list of objects to serialise.
 +/
void serialise(Sink, Things...)(ref Sink sink, Things things)
if (Things.length > 1)
{
    foreach (const thing; things)
    {
        sink.serialise(thing);
    }
}


// serialise
/++
 +  Serialises the fields of an object into an .ini file-like format.
 +
 +  It only serialises fields not annotated with `kameloso.uda.Unconfigurable`,
 +  and it doesn't recurse into other structs or classes.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  IRCClient client;
 +
 +  sink.serialise(client);
 +  assert(!sink.data.empty);
 +  ---
 +
 +  Params:
 +      sink = Reference output range to write to, usually an `Appender!string`.
 +      thing = Object to serialise.
 +/
void serialise(Sink, QualThing)(ref Sink sink, QualThing thing)
{
    import kameloso.string : stripSuffix;
    import kameloso.uda : Separator, Unconfigurable;
    import std.format : format, formattedWrite;
    import std.range : hasLength;
    import std.traits : Unqual;

    static if (__traits(hasMember, Sink, "data"))
    {
        // Sink is not empty, place a newline between current content and new
        if (sink.data.length) sink.put("\n");
    }

    alias Thing = Unqual!QualThing;

    sink.formattedWrite("[%s]\n", Thing.stringof.stripSuffix("Settings"));

    foreach (immutable i, member; thing.tupleof)
    {
        import kameloso.traits : isConfigurableVariable;
        import std.traits : Unqual, hasUDA, isType;

        alias T = Unqual!(typeof(member));

        static if (!isType!member &&
            isConfigurableVariable!(member) &&
            !hasUDA!(Thing.tupleof[i], Unconfigurable) &&
            !is(T == struct) && !is(T == class))
        {
            import std.traits : isArray, isSomeString;

            static if (!isSomeString!T && isArray!T)
            {
                import std.algorithm.iteration : map;
                import std.array : replace;

                // array, join it together
                static assert (hasUDA!(thing.tupleof[i], Separator),
                    "%s.%s is not annotated with a Separator"
                    .format(Thing.stringof, __traits(identifier, thing.tupleof[i])));

                import std.traits : getUDAs;
                alias separators = getUDAs!(thing.tupleof[i], Separator);
                enum separator = separators[0].token;
                static assert(separator.length, "%s.%s has invalid Separator (empty)"
                    .format(Thing.stringof, __traits(identifier, thing.tupleof[i])));

                enum arrayPattern = "%-(%s" ~ separator ~ "%)";

                static if (is(typeof(member) == string[]))
                {
                    string value;

                    if (member.length)
                    {
                        enum escaped = '\\' ~ separator;
                        enum placeholder = "\0\0";  // anything really

                        // Replace separators with a placeholder and flatten with format

                        auto separatedElements = member.map!(a => a.replace(separator, placeholder));
                        value = arrayPattern
                            .format(separatedElements)
                            .replace(placeholder, escaped);

                        static if (separators.length > 1)
                        {
                            foreach (furtherSeparator; separators[1..$])
                            {
                                // We're serialising; escape any other separators
                                enum furtherEscaped = '\\' ~ furtherSeparator.token;
                                value = value.replace(furtherSeparator.token, furtherEscaped);
                            }
                        }
                    }
                }
                else
                {
                    immutable value = arrayPattern.format(member);
                }
            }
            else static if (is(T == enum))
            {
                import kameloso.conv : Enum;
                immutable value = Enum!T.toString(member);
            }
            else
            {
                immutable value = member;
            }

            static if (is(T == bool) || is(T == enum))
            {
                enum comment = false;
            }
            else static if (is(T == float) || is(T == double))
            {
                import std.conv : to;
                import std.math : isNaN;
                immutable comment = member.to!T.isNaN;
            }
            else static if (hasLength!T)
            {
                immutable comment = !member.length;
            }
            else
            {
                immutable comment = (member == T.init);
            }

            if (comment)
            {
                // .init or otherwise disabled
                sink.formattedWrite("#%s\n", __traits(identifier, thing.tupleof[i]));
            }
            else
            {
                sink.formattedWrite("%s %s\n", __traits(identifier, thing.tupleof[i]), value);
            }
        }
    }
}

unittest
{
    import std.array : Appender;

    struct FooSettings
    {
        string fooasdf = "foo 1";
        string bar = "foo 1";
        string bazzzzzzz = "foo 1";
        double pi = 3.14159;
    }

    struct BarSettings
    {
        string foofdsa = "foo 2";
        string bar = "bar 2";
        string bazyyyyyyy = "baz 2";
        double pipyon = 3.0;
    }

    enum fooSerialised =
`[Foo]
fooasdf foo 1
bar foo 1
bazzzzzzz foo 1
pi 3.14159
`;

    Appender!string fooSink;
    fooSink.reserve(64);

    fooSink.serialise(FooSettings.init);
    assert((fooSink.data == fooSerialised), '\n' ~ fooSink.data);

    enum barSerialised =
`[Bar]
foofdsa foo 2
bar bar 2
bazyyyyyyy baz 2
pipyon 3
`;

    Appender!string barSink;
    barSink.reserve(64);

    barSink.serialise(BarSettings.init);
    assert(barSink.data == barSerialised);

    // try two at once
    Appender!string bothSink;
    bothSink.reserve(128);
    bothSink.serialise(FooSettings.init, BarSettings.init);
    assert(bothSink.data == fooSink.data ~ '\n' ~ barSink.data);
}


// applyConfiguration
/++
 +  Takes an input range containing configuration text and applies the contents
 +  therein to one or more passed struct/class objects.
 +
 +  This is one of our last few uses of regex, but the use case lends itself to
 +  it for separating values with the [ \t] deliminator. While slicing would
 +  probably lower compilation memory use considerably, it becomes very tricky
 +  as we're supporting both spaces and tabs.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +
 +  "kameloso.conf"
 +      .configReader
 +      .splitter("\n")
 +      .applyConfiguration(client, server);
 +  ---
 +
 +  Params:
 +      range = Input range from which to read the configuration text.
 +      things = Reference variadic list of one or more objects to apply the
 +          configuration to.
 +
 +  Returns:
 +      An associative array of string arrays of invalid configuration entries.
 +      The associative array key is the section the entry was found under, and
 +      the arrays merely lists of such erroneous entries thereunder.
 +/
string[][string] applyConfiguration(Range, Things...)(Range range, ref Things things)
{
    import kameloso.string : stripSuffix, stripped;
    import kameloso.uda : CannotContainComments, Unconfigurable;
    import std.format : format;

    string section;
    string[][string] invalidEntries;

    lineloop:
    foreach (const rawline; range)
    {
        string line = rawline.stripped;
        if (!line.length) continue;

        switch (line[0])
        {
        case '#':
        case ';':
            // Comment
            continue;

        case '[':
            // New section
            immutable sectionBackup = line;

            try
            {
                import std.format : formattedRead;
                line.formattedRead("[%s]", section);
            }
            catch (Exception e)
            {
                throw new ConfigurationFileParsingException("Malformed configuration " ~
                    `section header "%s", %s`.format(sectionBackup, e.msg));
            }
            continue;

        default:
            // entry-value line
            if (!section.length)
            {
                throw new ConfigurationFileParsingException("Malformed configuration " ~
                    `line, sectionless orphan "%s"`.format(line));
            }

            static if (Things.length == 1)
            {
                import std.traits : Unqual;

                enum settingslessThing = Unqual!Things.stringof.stripSuffix("Settings");
                // Early continue if there's only one Thing and we're in the wrong section
                if (section != settingslessThing) continue lineloop;
            }

            immutable result = splitEntryValue(line);
            immutable entry = result.entry;
            if (!entry.length) continue;
            string value = result.value;  // mutable for later slicing

            thingloop:
            foreach (immutable i, thing; things)
            {
                import std.traits : Unqual, hasUDA, isType;
                alias T = Unqual!(typeof(thing));

                enum settingslessT = T.stringof.stripSuffix("Settings");
                if (section != settingslessT) continue thingloop;

                static if (!is(T == enum))
                {
                    switch (entry)
                    {
                    static foreach (immutable n; 0..things[i].tupleof.length)
                    {{
                        static if (!isType!(Things[i].tupleof[n]) &&
                            !hasUDA!(Things[i].tupleof[n], Unconfigurable))
                        {
                            enum memberstring = __traits(identifier, Things[i].tupleof[n]);

                            case memberstring:
                                import kameloso.objmanip : setMemberByName;

                                static if (hasUDA!(Things[i].tupleof[n], CannotContainComments))
                                {
                                    things[i].setMemberByName(entry, value);
                                }
                                else
                                {
                                    import kameloso.string : contains, nom;

                                    // Slice away any comments
                                    value = value.contains('#') ? value.nom('#') : value;
                                    value = value.contains(';') ? value.nom(';') : value;
                                    things[i].setMemberByName(entry, value);
                                }
                                continue lineloop;
                        }
                    }}

                    default:
                        // Unknown setting in known section
                        invalidEntries[section] ~= entry.length ? entry : line;
                        break;
                    }
                }
            }

            break;
        }
    }

    return invalidEntries;
}

unittest
{
    import kameloso.uda : Separator;
    import std.algorithm.iteration : splitter;
    import std.conv : text;

    struct Foo
    {
        enum Bar { blaawp = 5, oorgle = -1 }
        int i;
        string s;
        bool b;
        float f;
        double d;
        Bar bar;

        @Separator(",")
        {
            int[] ia;
            string[] sa;
            bool[] ba;
            float[] fa;
            double[] da;
            Bar[] bara;
        }
    }

    enum configurationFileContents = `

[Foo]
i       42
ia      1,2,-3,4,5
s       hello world!
sa      hello,world,!
b       true
ba      true,false,true

# comment
; other type of comment


f       3.14
fa      0.0,1.1,-2.2,3.3
d       99.9
da      99.9999,0.0001,-1
bar     oorgle
bara    blaawp,oorgle,blaawp

[DifferentSection]
ignored completely
because no DifferentSection struct was passed
nil     5
naN     !"¤%&/`;

    Foo foo;
    configurationFileContents
        .splitter("\n")
        .applyConfiguration(foo);

    with (foo)
    {
        assert((i == 42), i.text);
        assert((ia == [ 1, 2, -3, 4, 5 ]), ia.text);
        assert((s == "hello world!"), s);
        assert((sa == [ "hello", "world", "!" ]), sa.text);
        assert(b);
        assert((ba == [ true, false, true ]), ba.text);
        assert((f == 3.14f), f.text);
        assert((fa == [ 0.0f, 1.1f, -2.2f, 3.3f ]), fa.text);
        assert((d == 99.9), d.text);
        // rounding errors with LDC on Windows
        // assert((da == [ 99.9999, 0.0001, -1.0 ]), da.text);
        assert(da[0]-99.999 < 0.001);
        assert(da[1..$] == [ 0.0001, -1.0 ]);
        with (Foo.Bar)
        {
            assert((bar == oorgle), b.text);
            assert((bara == [ blaawp, oorgle, blaawp ]), bara.text);
        }
    }

    struct DifferentSection
    {
        string ignored;
        string because;
        int nil;
        string naN;
    }

    // Can read other structs from the same file

    DifferentSection diff;
    configurationFileContents
        .splitter("\n")
        .applyConfiguration(diff);

    with (diff)
    {
        assert((ignored == "completely"), ignored);
        assert((because == "no DifferentSection struct was passed"), because);
        assert((nil == 5), nil.text);
        assert((naN == `!"¤%&/`), naN);
    }
}


// justifiedConfigurationText
/++
 +  Takes an unformatted string of configuration text and justifies it to neat columns.
 +
 +  It does one pass through it all first to determine the maximum width of the
 +  entry names, then another to format it and eventually return a flat string.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.serialise(client, server);
 +  immutable justified = sink.data.justifiedConfigurationText;
 +  ---
 +
 +  Params:
 +      origLines = Unjustified raw configuration text.
 +
 +  Returns:
 +      .ini file-like configuration text, justified into two columns.
 +/
auto justifiedConfigurationText(const string origLines)
{
    import kameloso.string : stripped;
    import std.algorithm.iteration : splitter;
    import std.array : Appender;

    Appender!(string[]) unjustified;
    size_t longestEntryLength;

    foreach (immutable rawline; origLines.splitter("\n"))
    {
        string line = rawline.stripped;

        if (!line.length)
        {
            unjustified.put("");
            continue;
        }

        switch (line[0])
        {
        case '#':
        case ';':
            longestEntryLength = (line.length > longestEntryLength) ?
                line.length : longestEntryLength;
            goto case '[';

        case '[':
            // comment or section header
            unjustified.put(line);
            continue;

        default:
            import std.format : format;

            immutable result = splitEntryValue(line);
            longestEntryLength = (result.entry.length > longestEntryLength) ?
                result.entry.length : longestEntryLength;

            unjustified.put("%s %s".format(result.entry, result.value));
            break;
        }
    }

    import kameloso.common : getMultipleOf;
    import std.algorithm.iteration : joiner;
    import std.algorithm.comparison : max;

    Appender!string justified;
    justified.reserve(128);

    assert((longestEntryLength > 0), "No longest entry; is the struct empty?");
    assert((unjustified.data.length > 0), "Unjustified data is empty");

    enum minimumWidth = 24;
    immutable width = max(minimumWidth, longestEntryLength.getMultipleOf!(Yes.alwaysOneUp)(4));

    foreach (line; unjustified.data)
    {
        if (!line.length)
        {
            // Don't add a linebreak at the top of the file
            if (justified.data.length) justified.put("\n");
            continue;
        }

        switch (line[0])
        {
        case '#':
        case ';':
        case '[':
            justified.put(line);
            justified.put("\n");
            continue;

        default:
            import std.format : formattedWrite;

            immutable result = splitEntryValue(line);
            justified.formattedWrite("%-*s%s\n", width, result.entry, result.value);
            break;
        }
    }

    return justified.data.stripped;
}

unittest
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import kameloso.uda : Separator;

    struct Foo
    {
        enum Bar { blaawp = 5, oorgle = -1 }
        int someInt = 42;
        string someString = "hello world!";
        bool someBool = true;
        float someFloat = 3.14f;
        double someDouble = 99.9;
        Bar someBars = Bar.oorgle;
        string harbl;

        @Separator(",")
        {
            int[] intArray = [ 1, 2, -3, 4, 5 ];
            string[] stringArrayy = [ "hello", "world", "!" ];
            bool[] boolArray = [ true, false, true ];
            float[] floatArray = [ 0.0, 1.1, -2.2, 3.3 ];
            double[] doubleArray = [ 99.9999, 0.0001, -1.0 ];
            Bar[] barArray = [ Bar.blaawp, Bar.oorgle, Bar.blaawp ];
            string[] yarn;
        }
    }

    struct DifferentSection
    {
        string ignored = "completely";
        string because = "   no DifferentSection struct was passed";
        int nil = 5;
        string naN = `!"#¤%&/`;
    }

    Appender!string sink;
    sink.reserve(512);
    Foo foo;
    DifferentSection diff;
    enum unjustified =
`[Foo]
someInt 42
someString hello world!
someBool true
someFloat 3.14
someDouble 99.9
someBars oorgle
#harbl
intArray 1,2,-3,4,5
stringArrayy hello,world,!
boolArray true,false,true
floatArray 0,1.1,-2.2,3.3
doubleArray 99.9999,0.0001,-1
barArray blaawp,oorgle,blaawp
#yarn

[DifferentSection]
ignored completely
because    no DifferentSection struct was passed
nil 5
naN !"#¤%&/
`;

    enum justified =
`[Foo]
someInt                 42
someString              hello world!
someBool                true
someFloat               3.14
someDouble              99.9
someBars                oorgle
#harbl
intArray                1,2,-3,4,5
stringArrayy            hello,world,!
boolArray               true,false,true
floatArray              0,1.1,-2.2,3.3
doubleArray             99.9999,0.0001,-1
barArray                blaawp,oorgle,blaawp
#yarn

[DifferentSection]
ignored                 completely
because                 no DifferentSection struct was passed
nil                     5
naN                     !"#¤%&/`;

    sink.serialise(foo, diff);
    assert((sink.data == unjustified), '\n' ~ sink.data);
    immutable configText = justifiedConfigurationText(sink.data);

    assert((configText == justified), '\n' ~ configText);
}


// ConfigurationFileReadFailureException
/++
 +  Exception, to be thrown when the specified configuration file could not be
 +  read, for whatever reason.
 +
 +  It is a normal `Exception` but with an attached filename string.
 +/
final class ConfigurationFileReadFailureException : Exception
{
@safe:
    /// The name of the configuration file the exception refers to.
    string filename;

    /++
     +  Create a new `ConfigurationFileReadFailureException`, without attaching
     +  a filename.
     +/
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /++
     +  Create a new `ConfigurationFileReadFailureException`, attaching a
     +  filename.
     +/
    this(const string message, const string filename, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.filename = filename;
        super(message, file, line);
    }
}


// ConfigurationFileParsingException
/++
 +  Exception, to be thrown when the specified configuration file could not be
 +  parsed, for whatever reason.
 +/
final class ConfigurationFileParsingException : Exception
{
@safe:
    /++
     +  Create a new `ConfigurationFileParsingException`.
     +/
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }
}


// splitEntryValue
/++
 +  Splits a line into an entry and a value component.
 +
 +  This drop-in-replaces the regex: r"^(?P<entry>[^ \t]+)[ \t]+(?P<value>.+)".
 +
 +  Params:
 +      line = String to split up.
 +
 +  Returns:
 +      A Voldemort struct with an `entry` and a `value` member.
 +/
auto splitEntryValue(const string line)
{
    import std.string : representation;
    import std.ascii : isWhite;

    struct EntryValue
    {
        string entry;
        string value;
    }

    EntryValue result;

    foreach (immutable i, immutable c; line.representation)
    {
        if (!c.isWhite)
        {
            if (result.entry.length)
            {
                result.value = line[i..$];
                break;
            }
        }
        else if (!result.entry.length)
        {
            result.entry = line[0..i];
        }
    }

    return result;
}

///
unittest
{
    {
        immutable line = "monochrome            true";
        immutable result = splitEntryValue(line);
        assert((result.entry == "monochrome"), result.entry);
        assert((result.value == "true"), result.value);
    }
    {
        immutable line = "monochrome\tfalse";
        immutable result = splitEntryValue(line);
        assert((result.entry == "monochrome"), result.entry);
        assert((result.value == "false"), result.value);
    }
    {
        immutable line = "harbl                  ";
        immutable result = splitEntryValue(line);
        assert((result.entry == "harbl"), result.entry);
        assert(!result.value.length, result.value);
    }
    {
        immutable line = "ha\t \t \t\t  \t  \t      \tha";
        immutable result = splitEntryValue(line);
        assert((result.entry == "ha"), result.entry);
        assert((result.value == "ha"), result.value);
    }
}

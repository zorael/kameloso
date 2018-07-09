/++
 +  Various functions related to serialising structs into .ini file-like files.
 +/
module kameloso.config;

import kameloso.common : logger;
import kameloso.uda;

import std.typecons : Flag, No, Yes;

@safe:


// writeToDisk
/++
 +  Saves the passed configuration text to disk, with the given filename.
 +
 +  Optionally add the `kameloso` version banner at the head of it.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  sink.serialise(bot, bot.server, settings);
 +  immutable configText = sink.data.justifiedConfigurationText;
 +  writeToDisk!(Yes.addBanner)("kameloso.conf", configText);
 +  ---
 +
 +  Params:
 +      banner = Whether to add the "*kameloso bot*" banner at the head of the
 +          file.
 +      filename = Filename of file to write to.
 +      configurationText = Content to write to file.
 +/
void writeToDisk(Flag!"addBanner" banner = Yes.addBanner)
    (const string filename, const string configurationText)
{
    import std.stdio : File, writefln, writeln;

    auto file = File(filename, "w");

    static if (banner)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = 0.msecs;

        file.writefln("# kameloso bot config (%s)\n", timestamp);
    }

    file.writeln(configurationText);
}


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
 +/
string configReader(const string configFile)
{
    import std.file : exists, isFile, readText;
    import std.string : chomp;

    if (!configFile.exists) return string.init;
    else if (!configFile.isFile)
    {
        logger.info("Config file does not exist or is not a file!");
        return string.init;
    }

    return configFile
        .readText
        .chomp;
}


// readConfigInto
/++
 +  Reads a configuration file and applies the settings therein to passed
 +  objects.
 +
 +  More than one can be supplied, and invalid ones for which there are no
 +  settings will be silently ignored with no errors.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf".readConfigInto(bot, server);
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
 +  Convenience method to call serialise on several objects.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  IRCBot bot;
 +  IRCServer server;
 +  sink.serialise(bot, server);
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
 +  IRCBot bot;
 +
 +  sink.serialise(bot);
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
    import kameloso.traits : isConfigurableVariable;
    import std.algorithm.iteration : joiner;
    import std.conv : to;
    import std.format : format, formattedWrite;
    import std.range : hasLength;
    import std.traits : Unqual, getUDAs, hasUDA, isArray, isSomeString, isType;

    static if (__traits(hasMember, Sink, "data"))
    {
        // Sink is not empty, place a newline between current content and new
        if (sink.data.length) sink.put("\n");
    }

    alias Thing = Unqual!QualThing;

    sink.formattedWrite("[%s]\n", Thing.stringof.stripSuffix("Settings"));

    foreach (immutable i, member; thing.tupleof)
    {
        alias T = Unqual!(typeof(member));

        static if (!isType!member &&
            isConfigurableVariable!(member) &&
            !hasUDA!(Thing.tupleof[i], Unconfigurable) &&
            !is(T == struct) && !is(T == class))
        {
            static if (!isSomeString!T && isArray!T)
            {
                import std.algorithm.iteration : map;
                import std.array : replace;

                // array, join it together
                static assert (hasUDA!(thing.tupleof[i], Separator),
                    "%s.%s is not annotated with a Separator"
                    .format(Thing.stringof, __traits(identifier, thing.tupleof[i])));

                alias separators = getUDAs!(thing.tupleof[i], Separator);
                enum separator = separators[0].token;
                static assert(separator.length, "%s.%s has invalid Separator (empty)"
                    .format(Thing.stringof, __traits(identifier, thing.tupleof[i])));

                enum arrayPattern = "%-(%s" ~ separator ~ "%)";

                static if (is(typeof(member) == string[]))
                {
                    if (!member.length) continue;

                    enum escaped = '\\' ~ separator;
                    enum placeholder = "\0\0";  // anything really

                    // Replace separators with a placeholder and flatten with format

                    auto separatedElements = member.map!(a => a.replace(separator, placeholder));
                    string value = arrayPattern
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
                else
                {
                    immutable value = arrayPattern.format(member);
                }
            }
            else static if (is(T == enum))
            {
                import std.conv : to;
                immutable value = member.to!string;
            }
            else
            {
                immutable value = member;
            }

            static if (is(T == bool) || is(T == enum))
            {
                immutable comment = false;
            }
            else static if (is(T == float) || is(T == double))
            {
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
 +  Example:
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf"
 +      .configReader
 +      .splitter("\n")
 +      .applyConfiguration(bot, server);
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
    import kameloso.string : stripped, stripSuffix;
    import std.format : formattedRead;
    import std.regex : matchFirst, regex;
    import std.traits : Unqual, hasUDA, isType;

    string section;
    string[][string] invalidEntries;

    foreach (rawline; range)
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
            try
            {
                line.formattedRead("[%s]", section);
            }
            catch (const Exception e)
            {
                logger.warningf(`Malformed configuration line "%s": %s`,
                    line, e.msg);
            }
            break;

        default:
            // entry-value line
            if (!section.length)
            {
                logger.warningf(`Malformed configuration line, orphan "%s"`, line);
                continue;
            }

            enum pattern = r"^(?P<entry>\w+)\s+(?P<value>.+)";
            auto engine = pattern.regex;
            auto hits = line.matchFirst(engine);

            thingloop:
            foreach (immutable i, thing; things)
            {
                alias T = Unqual!(typeof(thing));

                static if (!is(T == enum))
                {
                    if (section != T.stringof.stripSuffix("Settings")) continue;

                    immutable entry = hits["entry"];

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
                                        things[i].setMemberByName(entry, hits["value"]);
                                    }
                                    else
                                    {
                                        import kameloso.string : has, nom;
                                        // Slice away any comments
                                        string value = hits["value"];
                                        value = value.has('#') ? value.nom('#') : value;
                                        value = value.has(';') ? value.nom(';') : value;
                                        things[i].setMemberByName(entry, value);
                                    }
                                    continue thingloop;
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
 +  Takes an unformatted string of configuration text and justifies it to neat
 +  columns.
 +
 +  It does one pass through it all first to determine the maximum width of the
 +  entry names, then another to format it and eventually return a flat string.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.serialise(bot, server);
 +  immutable justified = sink.data.justifiedConfigurationText;
 +  ---
 +
 +  Params:
 +      origLines = Unjustified raw configuration text.
 +
 +  Returns:
 +      .ini file-like configuration text, justified into two columns.
 +/
string justifiedConfigurationText(const string origLines)
{
    import kameloso.string : stripped;
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.regex : matchFirst, regex;

    enum entryValuePattern = r"^(?P<entry>\w+)\s+(?P<value>.+)";
    auto entryValueEngine = entryValuePattern.regex;

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

            auto hits = line.matchFirst(entryValueEngine);

            longestEntryLength = (hits["entry"].length > longestEntryLength) ?
                hits["entry"].length : longestEntryLength;

            unjustified.put("%s %s".format(hits["entry"], hits["value"]));
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

            auto hits = line.matchFirst(entryValueEngine);
            justified.formattedWrite("%-*s%s\n", width, hits["entry"], hits["value"]);
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
        }
    }

    struct DifferentSection
    {
        string ignored = "completely";
        string because = "   no DifferentSeection struct was passed";
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

[DifferentSection]
ignored completely
because    no DifferentSeection struct was passed
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

[DifferentSection]
ignored                 completely
because                 no DifferentSeection struct was passed
nil                     5
naN                     !"#¤%&/`;

    sink.serialise(foo, diff);
    assert((sink.data == unjustified), '\n' ~ sink.data);
    immutable configText = justifiedConfigurationText(sink.data);

    assert((configText == justified), '\n' ~ configText);
}

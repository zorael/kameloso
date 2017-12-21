module kameloso.config;

import kameloso.common;

import std.typecons : Flag, No, Yes;

import std.stdio;


// writeToDisk
/++
 +  Saves the passed configuration text to disk, with the given filename.
 +
 +  Optionally add the `kameloso` version banner at the head of it.
 +
 +  ------------
 +  Appender!string sink;
 +  sink.serialise(bot, bot.server, settings);
 +  immutable configText = sink.data.justifiedConfigurationText;
 +  writeToDisk!(Yes.addBanner)("kameloso.conf", configText);
 +  ------------
 +/
void writeToDisk(Flag!"addBanner" banner = Yes.addBanner)
    (const string filename, const string configurationText)
{
    auto file = File(filename, "w");

    static if (banner)
    {
        import core.time : msecs;
        import std.datetime.systime : Clock;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = 0.msecs;

        file.writefln("# kameloso bot config (%s)", timestamp);
        file.writeln();
    }

    file.writeln(configurationText);
}


// configReader
/++
 +  Read configuration file into a string.
 +
 +  ------------
 +  string configText = configReader("kameloso.conf");
 +  ------------
 +/
string configReader(const string configFile)
{
    import std.file   : exists, isFile, readText;
    import std.string : chomp;

    if (!configFile.exists || !configFile.isFile)
    {
        logger.info("Config file does not exist or is not a file!");
        return string.init;
    }

    // Read the contents and split by newline
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
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf".readConfigInto(bot, server);
 +  ------------
 +/
void readConfigInto(T...)(const string configFile, ref T things)
{
    import std.algorithm.iteration : splitter;
    import std.ascii  : newline;

    configFile
        .configReader
        .splitter(newline)
        .applyConfiguration(things);
}


// serialise
/++
 +  Convenience method to call serialise on several objects.
 +
 +  ------------
 +  Appender!string sink;
 +  IRCBot bot;
 +  IRCServer server;
 +  sink.serialise(bot, server);
 +  assert(!sink.data.empty);
 +  ------------
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
 +  Serialise the fields of an object into an .ini file-like format.
 +
 +  It only serialises fields not annotated with `Unconfigurable`, and it
 +  doesn't recurse into other structs or classes.
 +
 +  Params:
 +      ref sink = output range to save into, usually an `Appender!string`
 +      thing = object to serialise
 +
 +  ------------
 +  Appender!string sink;
 +  IRCBot bot;
 +
 +  sink.serialise(bot);
 +  assert(!sink.data.empty);
 +  ------------
 +/
void serialise(Sink, QualThing)(ref Sink sink, QualThing thing)
{
    import kameloso.string : stripSuffix;
    import std.algorithm : joiner;
    import std.ascii : newline;
    import std.conv : to;
    import std.format : format, formattedWrite;
    import std.range : hasLength;
    import std.traits : Unqual, getUDAs, hasUDA, isArray, isSomeString, isType;

    static if (__traits(hasMember, Sink, "data"))
    {
        // Sink is not empty, place a newline between current content and new
        if (sink.data.length) sink.put(newline);
    }

    alias Thing = Unqual!QualThing;

    sink.formattedWrite("[%s]%s", Thing.stringof.stripSuffix("Settings"), newline);

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
                // array, join it together
                static assert (hasUDA!(thing.tupleof[i], Separator),
                    "%s.%s is not annotated with a Separator"
                    .format(Thing.stringof,
                    __traits(identifier, thing.tupleof[i])));

                enum separator = getUDAs!(thing.tupleof[i], Separator)[0].token;
                static assert(separator.length, "Invalid separator (empty)");

                enum arrayPattern = "%-(%s" ~ separator ~ "%)";
                immutable value = arrayPattern.format(member);
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
                sink.formattedWrite("#%s%s",
                    __traits(identifier, thing.tupleof[i]), newline);
            }
            else
            {
                sink.formattedWrite("%s %s%s",
                    __traits(identifier, thing.tupleof[i]), value, newline);
            }
        }
    }
}

unittest
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.ascii : newline;

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
    assert(fooSink.data == fooSerialised);

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
    assert(bothSink.data == fooSink.data ~ newline ~ barSink.data);
}


// setMemberByName
/++
 +  Given a struct/class object, sets one of its members by string name to a
 +  specified value.
 +
 +  It does not currently recurse into other struct/class members.
 +
 +  ------------
 +  IRCBot bot;
 +
 +  bot.setMemberByName("nickname", "kameloso");
 +  bot.setMemberByName("address", "blarbh.hlrehg.org");
 +  bot.setMemberByName("special", "false");
 +  ------------
 +/
void setMemberByName(Thing)(ref Thing thing, const string memberToSet,
    const string valueToSet)
{
    import kameloso.string : unquoted;
    import std.conv : ConvException, to;
    import std.traits : Unqual, getUDAs, hasUDA, isArray, isSomeString, isType;

    top:
    switch (memberToSet)
    {
        foreach (immutable i, member; thing.tupleof)
        {
            alias T = Unqual!(typeof(member));

            static if (!isType!member &&
                isConfigurableVariable!member &&
                !hasUDA!(member, Unconfigurable))
            {
                enum memberstring = __traits(identifier, thing.tupleof[i]);

                case memberstring:
                {
                    static if (is(T == struct) || is(T == class))
                    {
                        // can't assign whole structs or classes
                    }
                    else static if (!isSomeString!T && isArray!T)
                    {
                        import std.algorithm.iteration : splitter;
                        import std.format : format;

                        thing.tupleof[i].length = 0;

                        static assert(hasUDA!(thing.tupleof[i], Separator),
                            "Field %s is missing a Separator annotation"
                            .format(memberstring));

                        enum separator = getUDAs!(thing.tupleof[i], Separator)[0].token;

                        foreach (immutable entry; valueToSet.splitter(separator))
                        {
                            try
                            {
                                import std.range : ElementType;
                                import std.string : strip;

                                thing.tupleof[i] ~= entry
                                    .strip()
                                    .unquoted
                                    .to!(ElementType!T);
                            }
                            catch (const ConvException e)
                            {
                                logger.warningf("Can't convert array '%s' into '%s': %s",
                                    entry, T.stringof, e.msg);
                                break top;
                            }
                        }
                    }
                    else static if (isSomeString!T)
                    {
                        thing.tupleof[i] = valueToSet.unquoted;
                    }
                    else
                    {
                        try
                        {
                            /*writefln("%s.%s = %s.to!%s", Thing.stringof,
                                memberstring, valueToSet, T.stringof);*/
                            thing.tupleof[i] = valueToSet.unquoted.to!T;
                        }
                        catch (const ConvException e)
                        {
                            logger.warningf("Can't convert value '%s' into '%s': %s",
                                valueToSet, T.stringof, e.msg);
                        }
                    }
                    break;
                }
            }
        }

    default:
        break;
    }
}

///
unittest
{
    import std.conv : to;

    struct Foo
    {
        string bar;
        int baz;

        @Separator("|")
        {
            string[] arr;
            string[] matey;
        }

        @Separator(";;")
        {
            string[] parrots;
            string[] withSpaces;
        }
    }

    Foo foo;
    foo.setMemberByName("bar", "asdf fdsa adf");
    assert((foo.bar == "asdf fdsa adf"), foo.bar);
    foo.setMemberByName("baz", "42");
    assert((foo.baz == 42), foo.baz.to!string);
    foo.setMemberByName("arr", "herp|derp|dirp|darp");
    assert((foo.arr == [ "herp", "derp", "dirp", "darp"]), foo.arr.to!string);
    foo.setMemberByName("matey", "this,should,not,be,separated");
    assert((foo.matey == [ "this,should,not,be,separated" ]), foo.matey.to!string);
    foo.setMemberByName("parrots", "squaawk;;parrot sounds;;repeating");
    assert((foo.parrots == [ "squaawk", "parrot sounds", "repeating"]),
        foo.parrots.to!string);
    foo.setMemberByName("withSpaces", `         squoonk         ;;"  spaced  ";;" "`);
    assert((foo.withSpaces == [ "squoonk", `  spaced  `, " "]),
        foo.withSpaces.to!string);
}


// applyConfiguration
/++
 +  Takes an input range containing configuration text and applies the contents
 +  therein to one or more passed struct/class objects.
 +
 +  Params:
 +      range = input range from which to read the configuration text
 +      things = one or more objects to apply the configuration to
 +
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf"
 +      .configReader
 +      .splitter("\n")
 +      .applyConfiguration(bot, server);
 +  ------------
 +/
void applyConfiguration(Range, Things...)(Range range, ref Things things)
{
    import kameloso.string : stripSuffix;
    import std.format : formattedRead;
    import std.regex  : ctRegex, matchFirst;
    import std.string : strip, stripLeft;
    import std.traits : Unqual, hasUDA, isType;

    string section;

    foreach (rawline; range)
    {
        string line = rawline.strip();
        if (!rawline.length) continue;

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
            static engine = ctRegex!pattern;
            auto hits = line.matchFirst(engine);

            thingloop:
            foreach (immutable i, thing; things)
            {
                alias T = Unqual!(typeof(thing));

                if (section != T.stringof.stripSuffix("Settings")) continue;

                switch (hits["entry"])
                {
                    static if (!is(T == enum))
                    {
                        foreach (immutable n, ref member; things[i].tupleof)
                        {
                            static if (!isType!member &&
                                !hasUDA!(Things[i].tupleof[n], Unconfigurable))
                            {
                                enum memberstring = __traits(identifier,
                                    Things[i].tupleof[n]);

                                case memberstring:
                                    things[i].setMemberByName(hits["entry"],
                                        hits["value"]);
                                    continue thingloop;
                            }
                        }
                    }

                default:
                    // Unknown setting in known section
                    logger.infof("Found invalid %s under [%s]. " ~
                        "It is either malformed or no longer in use.",
                        hits["entry"], section);
                    logger.info("Use --writeconfig to update your configuration file.");
                    break;
                }
            }

            break;
        }
    }
}

unittest
{
    import std.algorithm : splitter;
    import std.ascii : newline;
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
naN     !"#¤%&/`;

    Foo foo;
    configurationFileContents
        .splitter(newline)
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
        assert((da == [ 99.9999, 0.0001, -1.0 ]), da.text);
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
        .splitter(newline)
        .applyConfiguration(diff);

    with (diff)
    {
        assert((ignored == "completely"), ignored);
        assert((because == "no DifferentSection struct was passed"), because);
        assert((nil == 5), nil.text);
        assert((naN == `!"#¤%&/`), naN);
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
 +  Params:
 +      origLines = unjustified raw configuration text
 +
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.serialise(bot, server);
 +  immutable justified = sink.data.justifiedConfigurationText;
 +  ------------
 +/
string justifiedConfigurationText(const string origLines)
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.ascii : newline;
    import std.regex : ctRegex, matchFirst;
    import std.string : strip;

    enum entryValuePattern = r"^(?P<entry>\w+)\s+(?P<value>.+)";
    static entryValueEngine = ctRegex!entryValuePattern;

    Appender!(string[]) unjustified;
    size_t longestEntryLength;

    foreach (immutable rawline; origLines.splitter(newline))
    {
        if (!rawline.length)
        {
            unjustified.put("");
            continue;
        }

        string line = rawline.strip();

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

    import std.algorithm.iteration : joiner;
    import std.algorithm.comparison : max;

    Appender!string justified;
    justified.reserve(128);

    assert(longestEntryLength);
    assert(unjustified.data.length);

    // subtract 1 from the width to allow for the pattern to have a space in it
    immutable width = max(12, longestEntryLength
        .getMultipleOf!(Yes.alwaysOneUp)(4)) - 1;

    foreach (line; unjustified.data)
    {
        if (!line.length)
        {
            // Don't add a linebreak at the top of the file
            if (justified.data.length) justified.put(newline);
            continue;
        }

        switch (line[0])
        {
        case '#':
        case ';':
        case '[':
            justified.put(line);
            justified.put(newline);
            continue;

        default:
            import std.format : formattedWrite;

            auto hits = line.matchFirst(entryValueEngine);

            justified.formattedWrite("%-*s %s%s", width, hits["entry"],
                hits["value"], newline);
            break;
        }
    }

    string completedList = justified.data;

    while ((completedList[$-1] == '\n') || (completedList[$-1] == '\r'))
    {
        completedList = completedList[0..$-1];
    }

    return completedList;
}

unittest
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.conv : text;
    import kameloso.common : Separator;

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
someInt         42
someString      hello world!
someBool        true
someFloat       3.14
someDouble      99.9
someBars        oorgle
#harbl
intArray        1,2,-3,4,5
stringArrayy    hello,world,!
boolArray       true,false,true
floatArray      0,1.1,-2.2,3.3
doubleArray     99.9999,0.0001,-1
barArray        blaawp,oorgle,blaawp

[DifferentSection]
ignored         completely
because         no DifferentSeection struct was passed
nil             5
naN             !"#¤%&/`;

    sink.serialise(foo, diff);
    assert((sink.data == unjustified), sink.data);
    immutable configText = justifiedConfigurationText(sink.data);

    assert((configText == justified), configText);
}

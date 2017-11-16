module kameloso.config2;

import kameloso.common;

import std.array : Appender;
import std.ascii : newline;
import std.stdio;
import std.typecons : Flag, No, Yes;


void writeToDisk(Flag!"addBanner" banner = Yes.addBanner)
    (const string filename, const string configurationText)
{
    import std.file : exists, isFile, removeFile = remove;

    if (filename.exists && filename.isFile)
    {
        removeFile(filename); // Is this wise? What else to do?
    }

    auto file = File(filename, "a");

    static if (banner)
    {
        import std.datetime : Clock;
        file.writefln("# kameloso bot config (%s)", Clock.currTime);
        file.write(newline);
    }

    file.writeln(configurationText);
    file.flush();
}


string configReader(const string configFile)
{
    import std.file   : exists, isFile, readText;
    import std.string : chomp;

    if (!configFile.exists)
    {
        logger.info("Config file does not exist");
        return string.init;
    }
    else if (!configFile.isFile)
    {
        logger.error("Config file is not a file!");
        return string.init;
    }

    // Read the contents and split by newline
    return configFile
        .readText
        .chomp;
}


void readConfigInto(T...)(const string configFile, ref T things)
{
    import std.algorithm.iteration : splitter;
    import std.ascii  : newline;

    configFile
        .configReader
        .splitter(newline)
        .applyConfiguration(things);
}


void serialise(Sink, Things...)(ref Sink sink, Things things)
if (Things.length > 1)
{
    foreach (const thing; things)
    {
        sink.serialise(thing);
    }
}


void serialise(Sink, Thing)(ref Sink sink, Thing thing)
{
    import kameloso.stringutils : stripSuffix;
    import std.algorithm : joiner;
    import std.array : array;
    import std.conv : to;
    import std.format : format, formattedWrite;
    import std.range : hasLength;
    import std.traits;

    static if (__traits(hasMember, Sink, "data"))
    {
        // Sink is not empty, place a newline between current content and new
        if (sink.data.length) sink.put(newline);
    }

    sink.formattedWrite("[%s]%s", Thing.stringof.stripSuffix("Options"), newline);

    foreach (immutable i, member; thing.tupleof)
    {
        alias T = typeof(member);

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
                    .format(Thing.stringof, __traits(identifier, thing.tupleof[i])));

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

    struct FooOptions
    {
        string fooasdf = "foo 1";
        string bar = "foo 1";
        string bazzzzzzz = "foo 1";
        double pi = 3.14159;
    }

    struct BarOptions
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

    fooSink.serialise(FooOptions.init);
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

    barSink.serialise(BarOptions.init);
    assert(barSink.data == barSerialised);

    // try two at once
    Appender!string bothSink;
    bothSink.reserve(128);
    bothSink.serialise(FooOptions.init, BarOptions.init);
    assert(bothSink.data == fooSink.data ~ newline ~ barSink.data);
}


void setMemberByName(Thing)(ref Thing thing, const string memberToSet, const string valueToSet)
{
    import std.conv : to;
    import std.traits : hasUDA, isArray, isSomeString, isType;

    top:
    switch (memberToSet)
    {
        foreach (immutable i, member; thing.tupleof)
        {
            alias T = typeof(member);

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

                        thing.tupleof[i].length = 0;

                        foreach (immutable entry; valueToSet.splitter(","))
                        {
                            try
                            {
                                import std.range : ElementType;
                                import std.string : strip;

                                /*writefln("%s.%s ~= %s.to!%s", Thing.stringof,
                                    memberstring, entry.strip(),
                                    (ElementType!T).stringof);*/
                                thing.tupleof[i] ~= entry.strip().to!(ElementType!T);
                            }
                            catch (const Exception e)
                            {
                                logger.errorf("Can't convert array '%s' into '%s': %s",
                                    entry, T.stringof, e.msg);
                                break top;
                            }
                        }
                    }
                    else static if (isSomeString!T)
                    {
                        thing.tupleof[i] = valueToSet;
                    }
                    else
                    {
                        try
                        {
                            /*writefln("%s.%s = %s.to!%s", Thing.stringof,
                                memberstring, valueToSet, T.stringof);*/
                            thing.tupleof[i] = valueToSet.to!T;
                        }
                        catch (const Exception e)
                        {
                            logger.errorf("Can't convert value '%s' into '%s': %s",
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


void applyConfiguration(Range, Things...)(Range range, ref Things things)
{
    import kameloso.stringutils : stripSuffix;
    import std.format : formattedRead;
    import std.string : munch, strip, stripLeft;
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
                logger.errorf(`Malformed configuration line "%s": %s`,
                    line, e.msg);
            }
            break;

        default:
            // entry-value line
            if (!section.length)
            {
                logger.errorf(`Malformed configuration line, orphan "%s"`, line);
                continue;
            }

            // FIXME: regex
            immutable entry = line.munch("^ \t");
            immutable value = line.stripLeft();

            thingloop:
            foreach (immutable i, thing; things)
            {
                alias T = Unqual!(typeof(thing));

                if (section != T.stringof.stripSuffix("Options")) continue;

                switch (entry)
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
                                    things[i].setMemberByName(entry, value);
                                    continue thingloop;
                            }
                        }
                    }

                default:
                    // Unknown setting in known section
                    logger.infof("Found invalid %s under [%s]. " ~
                        "It is either malformed or no longer in use. " ~
                        "Use --writeconfig to update your configuration file.",
                        entry, section);
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
    import std.conv : text;

    struct Foo
    {
        enum Bar { blaawp = 5, oorgle = -1 }
        int i;
        int[] ia;
        string s;
        string[] sa;
        bool b;
        bool[] ba;
        float f;
        float[] fa;
        double d;
        double[] da;
        Bar bar;
        Bar[] bara;
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
NaN     !"#¤%&/`;

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
        string NaN;
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
        assert((NaN == `!"#¤%&/`), NaN);
    }
}

string justifiedConfigurationText(const string origLines)
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
    import std.string : munch, strip, stripLeft;

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

            // FIXME: regex
            immutable entry = line.munch("^ \t");
            immutable value = line.stripLeft();

            longestEntryLength = (entry.length > longestEntryLength) ?
                entry.length : longestEntryLength;

            unjustified.put("%s %s".format(entry, value));
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
            // Don't adda a linebreak at the top of the file
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

            immutable entry = line.munch("^ \t");
            immutable value = line.stripLeft();
            justified.formattedWrite("%-*s %s%s", width, entry, value, newline);
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
        string NaN = `!"#¤%&/`;
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
NaN !"#¤%&/
`;

    enum justified =
`[Foo]
someInt         42
someString      hello world!
someBool        true
someFloat       3.14
someDouble      99.9
someBars        oorgle
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
NaN             !"#¤%&/`;

    sink.serialise(foo, diff);
    assert((sink.data == unjustified), sink.data);
    immutable configText = justifiedConfigurationText(sink.data);

    assert((configText == justified), configText);
}


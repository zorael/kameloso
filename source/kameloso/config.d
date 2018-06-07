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
 +  ------------
 +  Appender!string sink;
 +  sink.serialise(bot, bot.server, settings);
 +  immutable configText = sink.data.justifiedConfigurationText;
 +  writeToDisk!(Yes.addBanner)("kameloso.conf", configText);
 +  ------------
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
 +  ------------
 +  string configText = configReader("kameloso.conf");
 +  ------------
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
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf".readConfigInto(bot, server);
 +  ------------
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
 +  ------------
 +  Appender!string sink;
 +  IRCBot bot;
 +  IRCServer server;
 +  sink.serialise(bot, server);
 +  assert(!sink.data.empty);
 +  ------------
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
 +  ------------
 +  Appender!string sink;
 +  IRCBot bot;
 +
 +  sink.serialise(bot);
 +  assert(!sink.data.empty);
 +  ------------
 +
 +  Params:
 +      sink = Reference output range to write to, usually an `Appender!string`.
 +      thing = Object to serialise.
 +/
void serialise(Sink, QualThing)(ref Sink sink, QualThing thing)
{
    import kameloso.string : stripSuffix;
    import kameloso.traits : isConfigurableVariable;
    import std.algorithm : joiner;
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
                sink.formattedWrite("#%s\n", __traits(identifier, thing.tupleof[i]));
            }
            else
            {
                sink.formattedWrite("%s %s\n", __traits(identifier, thing.tupleof[i]), value);
            }
        }
    }
}

// setMemberByName
/++
 +  Given a struct/class object, sets one of its members by its string name to a
 +  specified value.
 +
 +  It does not currently recurse into other struct/class members.
 +
 +  Example:
 +  ------------
 +  IRCBot bot;
 +
 +  bot.setMemberByName("nickname", "kameloso");
 +  bot.setMemberByName("address", "blarbh.hlrehg.org");
 +  bot.setMemberByName("special", "false");
 +
 +  assert(bot.nickname == "kameloso");
 +  assert(bot.address == "blarbh.hlrehg.org");
 +  assert(!bot.special);
 +  ------------
 +
 +  Params:
 +      thing = Reference object whose members to set.
 +      memberToSet = String name of the thing's member to set.
 +      valueToSet = String contents of the value to set the member to; string
 +          even if the member is of a different type.
 +
 +  Returns:
 +      `true` if a member was found and set, `false` if not.
 +/
bool setMemberByName(Thing)(ref Thing thing, const string memberToSet,
    const string valueToSet)
{
    import kameloso.string : stripped, unquoted;
    import kameloso.traits : isConfigurableVariable;
    import std.conv : ConvException, to;
    import std.traits : Unqual, getUDAs, hasUDA, isArray, isAssociativeArray,
        isSomeString, isType;

    bool success;

    top:
    switch (memberToSet)
    {
        static foreach (immutable i; 0..thing.tupleof.length)
        {{
            alias T = Unqual!(typeof(thing.tupleof[i]));

            static if (!isType!(thing.tupleof[i]) &&
                isConfigurableVariable!(thing.tupleof[i]) &&
                !hasUDA!(thing.tupleof[i], Unconfigurable))
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

                                thing.tupleof[i] ~= entry
                                    .stripped
                                    .unquoted
                                    .to!(ElementType!T);

                                success = true;
                            }
                            catch (const ConvException e)
                            {
                                logger.warningf("Can't convert array '%s' into '%s': %s",
                                    entry, T.stringof, e.msg);
                                break top;
                            }
                        }
                    }
                    else static if (is(T : string))
                    {
                        thing.tupleof[i] = valueToSet.unquoted;
                        success = true;
                    }
                    else static if (isAssociativeArray!T)
                    {
                        // Silently ignore AAs for now
                    }
                    else
                    {
                        try
                        {
                            /*writefln("%s.%s = %s.to!%s", Thing.stringof,
                                memberstring, valueToSet, T.stringof);*/
                            thing.tupleof[i] = valueToSet.unquoted.to!T;
                            success = true;
                        }
                        catch (const ConvException e)
                        {
                            logger.warningf("Can't convert value '%s' into '%s': %s",
                                valueToSet, T.stringof, e.msg);
                        }
                    }
                    break top;
                }
            }
        }}

    default:
        break;
    }

    return success;
}


// applyConfiguration
/++
 +  Takes an input range containing configuration text and applies the contents
 +  therein to one or more passed struct/class objects.
 +
 +  Example:
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf"
 +      .configReader
 +      .splitter("\n")
 +      .applyConfiguration(bot, server);
 +  ------------
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
                                    things[i].setMemberByName(entry, hits["value"]);
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


// justifiedConfigurationText
/++
 +  Takes an unformatted string of configuration text and justifies it to neat
 +  columns.
 +
 +  It does one pass through it all first to determine the maximum width of the
 +  entry names, then another to format it and eventually return a flat string.
 +
 +  Example:
 +  ------------
 +  IRCBot bot;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.serialise(bot, server);
 +  immutable justified = sink.data.justifiedConfigurationText;
 +  ------------
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

    assert(longestEntryLength);
    assert(unjustified.data.length);

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

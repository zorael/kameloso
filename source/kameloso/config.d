module kameloso.config;

import kameloso.common;
import kameloso.constants;

import std.stdio;
import std.traits : hasUDA, isArray, isType;


// walkConfigLines
/++
 +  Walks a list of configuration lines, such as those read from a config file.
 +  Sets the members of passed structs to the values of read lines by calling
 +  setMember.
 +
 +  It ignores commented lines and calls setMember on the valid ones to
 +  reconstruct objects.
 +
 +  Params:
 +      wholeFile = a range providing the configuration lines.
 +      ref things = a compile-time variadic list of structs whose members
 +                   should be configured.
 +/
void walkConfigLines(Range_, Things...)(Range_ range, ref Things things)
{
    string currentSection;

    foreach (rawline; range)
    {
        import std.string : strip;

        string line = rawline.strip();

        if (!line.length) continue;

        switch (line[0])
        {
        case '#':
        case ';':
            // Comment, skip
            continue;

        case '[':
            // Section header
            import std.format : formattedRead;

            line.formattedRead("[%s]", currentSection);

            break;

        default:
            import std.string : munch, stripLeft;

            if (!currentSection.length) continue;

            // entry-value line
            immutable entry = line.munch("^ \t");
            immutable value = line.stripLeft();

            mid:
            foreach (immutable i, thing; things)
            {
                import std.typecons : Unqual;

                enum Thing = Unqual!(typeof(thing)).stringof;

                if (currentSection != Thing) continue;

                switch (entry)
                {

                foreach (immutable n, ref member; things[i].tupleof)
                {
                    static if (!isType!member)
                    {
                        static if (!hasUDA!(Things[i].tupleof[n], Unconfigurable))
                        {
                            enum memberstring = __traits(identifier, Things[i].tupleof[n]);

                            case memberstring:
                                things[i].setMember(entry, value);
                                continue mid;
                        }
                    }
                }

                default:
                    break;
                }
            }

            break;
        }
    }
}


// readConfig
/++
 +  Reads a config file and sets structs' members as they are described there.
 +
 +  Params:
 +      configFile = the string name of a configuration file.
 +      ref things = a compile-time variadic list of structs whose members
 +                   should be configured.
 +/
void readConfig(T...)(const string configFile, ref T things)
{
    import std.algorithm.iteration : splitter;
    import std.ascii  : newline;

    configFile
        .configReader
        .splitter(newline)
        .walkConfigLines(things);
}


// configReader
/++
 +  Reads a file from disk and returns its contents.
 +
 +  Params:
 +      configFile = the filename of the file to read
 +
 +  Returns:
 +      the file's contents in a string
 +/
string configReader(const string configFile)
{
    import std.file   : exists, isFile, readText, write;
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


// writeConfigToDisk
/++
 +  Takes a compile-time variadic list of struct objects, reads their contents
 +  and writes them to the configuration filename supplied.
 +
 +  Not all fields can be serialised this way, but strings and integers can.
 +
 +  Params:
 +      configFile = the string name of a configuration file.
 +      things = a compile-time variadic list of structs whose members should
 +               be read and saved to disk.
 +/
void writeConfigToDisk(T...)(const string configFile, T things)
{
    import std.datetime : Clock;
    import std.file : exists, isFile, removeFile = remove;
    import std.stdio  : File;

    if (configFile.exists && configFile.isFile)
    {
        removeFile(configFile); // Is this wise? What else to do?
    }

    auto f = File(configFile, "a");

    f.writefln("# kameloso bot config (%s)\n", Clock.currTime);
    f.write(things.configText);
}


// setMember
/++
 +  Set the member of a struct to a supplied value, by string name.
 +
 +  This is a template-heavy thing but it is in principle fairly straight-
 +  forward. For each member of a struct, if member name is the supplied
 +  member string, use std.conv.to and set it to this value.
 +
 +  No value is returned as the struct object is passed by ref.
 +
 +  Params:
 +      ref thing = the struct object whose member should be assigned to.
 +      memberstring = the string name of one of thing's members.
 +      value = the value to assign, in string form.
 +/
void setMember(Thing)(ref Thing thing, const string memberToSet,
                      const string value) @safe
{
    top:
    switch (memberToSet)
    {

    foreach (immutable i, ref member; thing.tupleof)
    {
        static if (!isType!member &&
                   isConfigurableVariable!member &&
                   !hasUDA!(member, Unconfigurable))
        {
            enum memberstring = __traits(identifier, thing.tupleof[i]);
            alias MemberType = typeof(member);

            case memberstring:
                static if (is(MemberType == struct) || is(MemberType == class))
                {
                    // Can't reconstruct nested structs/classes
                    return;
                }
                else static if (isArray!MemberType && !is(MemberType : string))
                {
                    import std.format : format;
                    import std.traits : getUDAs;

                    static assert(hasUDA!(thing.tupleof[i], Separator),
                            "%s %s.%s is not properly annotated with a separator token"
                            .format(MemberType.stringof, Thing.stringof, memberstring));

                    //thing.tupleof[i] = MemberType.init;
                    thing.tupleof[i].length = 0;

                    static if (getUDAs!(thing.tupleof[i], Separator).length > 0)
                    {
                        import std.algorithm.iteration : splitter;

                        enum separator = getUDAs!(thing.tupleof[i], Separator)[0].token;

                        foreach (entry; value.splitter(separator))
                        {
                            static if (is(MemberType : string[]))
                            {
                                import std.string : strip;

                                // Reconstruct it by appending each field in turn
                                thing.tupleof[i] ~= entry.strip();
                            }
                            else
                            {
                                import std.conv : to;

                                try member ~= value.to!MemberType;
                                catch (const Exception e)
                                {
                                    logger.warningf("Caught Exception trying " ~
                                        "to convert '%s' to %s: %s",
                                        value, MemberType.stringof, e.msg);
                                }
                            }
                        }

                        break top;
                    }
                }
                else static if (is(MemberType : string))
                {
                    // Simple assignment
                    thing.tupleof[i] = value;
                    return;
                }
                else
                {
                    import std.conv : to;

                    // Trust to std.conv.to for conversion
                    try thing.tupleof[i] = value.to!MemberType;
                    catch (const Exception e)
                    {
                        writefln("Caught Exception trying to convert '%s' to %s: %s",
                                value, MemberType.stringof, e.msg);
                    }

                    return;
                }
            }
        }

    default:
        break;
    }
}


// configText
/++
 +  Takes a compile-time variadic list of struct objects and passes them each
 +  by each to the configText(T) that only takes one parameter.
 +
 +  This is merely for convenience.
 +
 +  Params:
 +      things = A compile-time variadic list of things to "serialise".
 +
 +  Returns:
 +      Config text for all the serialised Things.
 +/
string configText(Things...)(const Things things) @safe
if (Things.length > 1)
{
    import std.array : Appender;

    Appender!string all;

    enum entryPadding = longestMemberName!Things.length + 2;

    foreach (i, thing; Things)
    {
        all.put(things[i].configText!entryPadding);
        all.put("\n");
    }

    return all.data;
}


// configText
/++
 +  The inverse of setMember, this walks through the members of a class or
 +  struct and makes configuration lines of their contents.
 +
 +  This is later saved to disk as configuration files.
 +
 +  Params:
 +      thing = A struct object, whose members should be "serialised".
 +
 +  Returns:
 +      Config text for the serialised Thing.
 +/
string configText(size_t entryPadding = 16, Thing)(const Thing thing) @safe
{
    import std.array : Appender;
    import std.format : format, formattedWrite;

    Appender!string sink;

    // An IRCBot + IRCServer + Settings combo weighs in at around 700 bytes
    sink.reserve(1024);

    sink.formattedWrite("[%s]\n", Thing.stringof); // Section header

    enum pattern = "%-*s  %s\n";
    enum patternCommented = "#%s\n";

    foreach (immutable i, member; thing.tupleof)
    {
        static if (!isType!member &&
                   isConfigurableVariable!(member) &&
                   !hasUDA!(Thing.tupleof[i], Unconfigurable))
        {
            enum memberstring = __traits(identifier, thing.tupleof[i]);
            alias MemberType = typeof(member);

            static if ((is(MemberType == struct) || is(MemberType == class)))
            {
                // Can't reconstruct nested structs/classes
                continue;
            }
            else
            {
                static if (isArray!MemberType && !is(MemberType : string))
                {
                    import std.traits : getUDAs;

                    static assert (hasUDA!(thing.tupleof[i], Separator),
                        "%s.%s is not annotated with a Separator"
                        .format(Thing.stringof, memberstring));

                    enum separator = getUDAs!(thing.tupleof[i], Separator)[0].token;
                    static assert(separator.length, "Invalid separator (empty)");

                    // Array; use std.format.format to get a Separator-separated line
                    enum arrayPattern = "%-(%s" ~ separator ~ "%)";
                    immutable value = arrayPattern.format(member);
                }
                else
                {
                    // Simple assignment
                    immutable value = member;
                }

                static if (is(MemberType : string))
                {
                    if (value.length)
                    {
                        sink.formattedWrite(pattern, entryPadding,
                            memberstring, value);
                    }
                    else
                    {
                        sink.formattedWrite(patternCommented, memberstring);
                    }
                }
                else
                {
                    // bool.init is false, can't treat that as unset

                    if (is(MemberType : bool) || (value != typeof(value).init))
                    {
                        sink.formattedWrite(pattern, entryPadding,
                            memberstring, value);
                    }
                    else
                    {
                        sink.formattedWrite(patternCommented, memberstring);
                    }
                }
            }
        }
    }

    return sink.data;
}


// replaceConfig
/++
 +  Replaces the saved settings for a plugin, in the configuration file.
 +
 +  It reads in the settings into an Appender sink, and omits the configuration
 +  for the supplied plugin. Then it appends the new configuration block to the
 +  end of the sink and writes it to disk.
 +
 +  Params:
 +      configFile = filename of the configuration file
 +      things = plugin option types whose saved settings should be replaced
 +/
void replaceConfig(Things...)(const string configFile, Things things)
{
    import std.algorithm : splitter;
    import std.array : Appender;
    import std.datetime : Clock;

    Appender!string sink;
    sink.reserve(1024);  // 731 with Notes and Printer settings enabled

    auto configSource = configFile
        .configReader
        .splitter('\n');

	configSource.walkConfigExcluding(sink, things);

	sink.put(configText(things));

    auto f = File(configFile, "w");

    f.writefln("# kameloso bot config (%s)\n", Clock.currTime);
    f.write(sink.data);
}


// walkConfigExcluding
/++
 +  Reads a config file line by line from an input range and omits sections
 +  pertaining to the types passed.
 +
 +  It's a way to strip configuration files of types.
 +
 +  Params:
 +      range = input range to read the configuration lines from
 +      sink = output range to save included lines into
 +      things = variadic list of types to omit from the saved configuration
 +/
void walkConfigExcluding(Range_, Sink, Things...)(Range_ range,
	auto ref Sink sink, Things things)
{
	import std.range : enumerate;
	import std.string : strip;

    string currentSection;
	uint configLine;
	bool skipping;

    foreach (i, rawline; range.enumerate)
    {
        string line = rawline.strip();

        if (!line.length)
		{
			skipping = false;
			continue;
		}

        switch (line[0])
        {
        case '#':
        case ';':
            // Comment
            if (skipping || !currentSection.length) continue;

            sink.put(line);
            sink.put('\n');
			break;

        case '[':
            // Section header
            import std.format : formattedRead;

			immutable lineCopy = line;  // formattedRead will advance line
            line.formattedRead("[%s]", currentSection);

            skipping = false;

			foreach (Thing; Things)
			{
				// Is it one of Things?
				if (currentSection == Thing.stringof)
				{
					skipping = true;
				}
			}

			if (skipping) continue;

			if (configLine > 0) sink.put('\n');
			sink.put(lineCopy);
			sink.put('\n');
            break;

        default:
            sink.put(line);
            sink.put('\n');
            break;
        }

		++configLine;
    }

	sink.put('\n');
}

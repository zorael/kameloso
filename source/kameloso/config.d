module kameloso.config;

import kameloso.common;
import kameloso.constants;

import std.range  : isInputRange;
import std.traits : isArray, isSomeFunction, hasUDA;


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
void walkConfigLines(Range, Things...)(Range range, ref Things things)
{
    string currentSection;

    top:
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

            line.formattedRead("[%s]", &currentSection);

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
                    static if (is(typeof(member)))
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
    import std.file   : write, exists, isFile, readText;
    import std.string : chomp;
    import std.ascii  : newline;
    import std.algorithm.iteration : splitter;

    if (!configFile.exists)
    {
        writeln(Foreground.lightred, "Config file does not exist");
        return;
    }
    else if (!configFile.isFile)
    {
        writeln(Foreground.lightred, "Config file is not a file!");
        return;
    }

    // Read the contents and split by newline
    auto wholeFile = configFile
        .readText
        .chomp
        .splitter(newline);

    wholeFile.walkConfigLines(things);
}


// writeConfig
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
void writeConfig(T...)(const string configFile, T things)
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
void setMember(Thing)(ref Thing thing, const string memberToSet, const string value)
{
    top:
    switch (memberToSet)
    {

    foreach (immutable i, ref member; thing.tupleof)
    {
        static if (is(typeof(member)) &&
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

                        foreach (entry; value.splitter(getUDAs!(thing.tupleof[i], Separator)[0].token))
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
                                catch (Exception e)
                                {
                                    writefln("Caught Exception trying to convert '%s' to %s: %s",
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
                    catch (Exception e)
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
string configText(Things...)(const Things things)
if (Things.length > 1)
{
    import std.array : Appender;
    import std.traits : hasUDA;

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
string configText(size_t entryPadding = 20, Thing)(const Thing thing)
{
    import std.format : format, formattedWrite;
    import std.array : Appender;

    Appender!string sink;

    // An IRCBot + IRCServer + Settings combo weighs in at around 700 bytes
    sink.reserve(1024);

    sink.formattedWrite("[%s]\n", Thing.stringof); // Section header

    enum pattern = "%%-%ds  %%s\n".format(entryPadding);
    enum patternCommented = "#%s\n"; //%-%ds\n".format(entryPadding);

    foreach (immutable i, ref member; thing.tupleof)
    {
        static if (is(typeof(member)) &&
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
                    enum arrayPattern = "%%-(%%s%s%%)".format(separator);
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
                        sink.formattedWrite(pattern, memberstring, value);
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
                        sink.formattedWrite(pattern, memberstring, value);
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

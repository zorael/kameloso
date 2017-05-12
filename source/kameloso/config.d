module kameloso.config;

import kameloso.common;

import std.stdio  : File, writeln, writefln;
import std.format : format;
import std.range  : isInputRange;
import std.traits : isArray, isSomeFunction, hasUDA;


// walkConfigLines
/++
 +  Walks a list of configuration lines, such as those read from a config file. It ignores
 +  commented lines and calls setMember on the valid ones to reconstruct objects.
 +
 +  Params:
 +      wholeFile = A range providing the configuration lines.
 +      ref things = The structs whose members should be assigned values from the lines.
 +/
void walkConfigLines(Range, T...)(Range wholeFile, ref T things)
if (isInputRange!Range && (T.length > 0))
{
    import std.string : strip, stripLeft, munch, chomp;

    size_t typeIndex;

    top:
    foreach (line; wholeFile)
    {
        line = line.chomp.strip;

        if (!line.length) continue;

        switch (line[0])
        {
        case '#':
        case ';':
            // Comment, skip
            continue;

        case '[':
            // Header switch
            switch (line)
            {
            foreach (i, section; T)
            {
                case "[%s]".format(T[i].stringof):
                    typeIndex = i;
                    continue top;
            }

            default:
                // writefln("Malformed config file at line %d", lineNumber);
                // writefln("invalid header: '%s'", line);

                continue top;
            } // Header switch

        default:
            // Entry-value line: "^entry[ \t]+value$"
            auto entry = line.munch("^ \t");
            line = line.stripLeft;

            //writefln("(%s) %s=%s", typeIndex, entry, value);

            switch (typeIndex)
            {
            foreach (i, thing; things)
            {
                case i:
                    things[i].setMember(entry, line);
                    continue top;
            }
            default:
                break;
            }
        } // line[0] switch
    } // top switch
}


// readConfig
/++
 +  Takes a string to a configuration file, reads it and sets the memer of the passed
 +  structs as the contents of the configuration file dictate. "Read config file into these."
 +
 +  Params:
 +      configFile = The string name of a configuration file.
 +      things = A compile-time variadic list of structs whose members should be configured.
 +/
void readConfig(T...)(const string configFile, ref T things)
{
    import std.file   : write, exists, isFile, readText;
    import std.string : chomp;
    import std.ascii  : newline;
    import std.algorithm.iteration : splitter;

    if (!configFile.exists)
    {
        writeln("Config file does not exist");
        return;
    }
    else if (!configFile.isFile)
    {
        writeln("Config file is not a file!");
        return;
    }

    // Read the contents and split by newline
    auto wholeFile = configFile.readText.chomp.splitter(newline);

    wholeFile.walkConfigLines(things);
}


// writeConfig
/++
 +  Takes a compile-time variadic list of struct objects, reads their contents and writes
 *  them to the configuration filename supplied. Not all fields can be serialised this way,
 *  but strings and integers can.
 *
 *  Params:
 +      configFile = The string name of a configuration file.
 +      things = A compile-time variadic list of structs whose members should be read and
 +               saved to disk.
 +/
void writeConfig(T...)(const string configFile, T things)
{
    import std.datetime : Clock;
    import std.file : exists, isFile, removeFile = remove;

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
 +  Given a struct and the string name of one of its members, assign it the supplied value.
 +  This is a template-heavy thing but it is in principle fairly straight-forward.
 +  Foreach member of a struct, if member name is the supplied member string, use std.conv.to
 +  and set it to this value. No vaue is returned as the stuct object is passed by ref.
 +
 +  Params:
 +      ref thing = The struct object whose member should be assigned to.
 +      memberstring = The string name of one of thing's members.
 +      value = The value to assign, in string form.
 +/
void setMember(T)(ref T thing, string memberstring, string value)
{
    import std.conv : to, ConvException;
    import std.algorithm.iteration : splitter;
    import std.traits : getUDAs;

    top:
    switch (memberstring)
    {

    foreach (name; __traits(allMembers, T))
    {
        static if (!memberIsType!(T, name) &&
                   !memberSatisfies!(isSomeFunction, T, name) &&
                   !memberSatisfies!("isTemplate", T, name) &&
                   !memberSatisfies!("isAssociativeArray", T, name) &&
                   !memberSatisfies!("isStaticArray", T, name) &&
                   !hasUDA!(__traits(getMember, T, name), Unconfigurable))
        {
        alias MemberType = typeof(__traits(getMember, T, name));

        case name:
            static if (is(MemberType == struct) || is(MemberType == class))
            {
                // Can't reconstruct nested structs/classes
                return;
            }
            else static if (isArray!MemberType && !is(MemberType : string))
            {
                static assert((hasUDA!(__traits(getMember, T, name), Separator)),
                        "%s %s.%s is not properly annotated with a separator token"
                        .format(MemberType.stringof, T.stringof, name));

                __traits(getMember, thing, name) = MemberType.init;

                static if (getUDAs!(__traits(getMember, T, name), Separator).length > 0)
                {
                    foreach (entry; value.splitter(getUDAs!(__traits(getMember, T, name), Separator)[0].token))
                    {
                        static if (is(MemberType : string[]))
                        {
                            import std.string : strip;

                            // Reconstruct it by appending each field in turn
                            __traits(getMember, thing, name) ~= entry.strip;
                        }
                        else
                        {
                            try __traits(getMember, thing, name) ~= value.to!MemberType;
                            catch (ConvException e)
                            {
                                writefln("Caught ConvException trying to convert '%s' to %s",
                                        value, MemberType.stringof);
                            }
                        }
                    }
                    break top;
                }
                // break top;
            }
            else static if (is(MemberType : string))
            {
                // Simple assignment
                __traits(getMember, thing, name) = value;
                break top;
            }
            else
            {
                // Trust to std.conv.to for conversion
                try __traits(getMember, thing, name) = value.to!MemberType;
                catch (ConvException e)
                {
                    writefln("Caught ConvException trying to convert '%s' to %s",
                            value, MemberType.stringof);
                }
                break top;
            }
        }
    }

    default:
        break;
    }
}


// longestMemberName
/++
 +  Gets the name of the longest member in a struct.
 +
 +  This is used for formatting configuration files, so that columns line up.
 +
 +  Template param:
 +      T = the struct type to inspect for member name lengths.
 +/
template longestMemberName(T)
{
    enum longestMemberName = ()
    {
        string longest;

        foreach (name; __traits(allMembers, T))
        {
            static if (!memberIsType!(T, name) &&
                    !memberSatisfies!(isSomeFunction, T, name) &&
                    !memberSatisfies!("isTemplate", T, name) &&
                    !memberSatisfies!("isAssociativeArray", T, name) &&
                    !memberSatisfies!("isStaticArray", T, name) &&
                    !hasUDA!(__traits(getMember, T, name), Unconfigurable))
            {
                if (name.length > longest.length)
                {
                    longest = name;
                }
            }
        }

        return longest;
    }();
}


// configText
/++
 +  Takes a compile-time variadic list of struct objects and passes them each by each to
 +  the configText(T) that only takes one parameter. This is merely for convenience.
 +
 +  Params:
 +      things = A compile-time variadic list of things to "serialise".
 +/
string configText(T...)(const T things)
if (T.length > 1)
{
    import std.array : Appender;
    Appender!string all;

    foreach (i, thing; T)
    {
        all.put(things[i].configText);
        all.put("\n");
    }

    return all.data;
}


// configText
/++
 + The inverse of setMember, this walks through the members of a class and makes configuration
 + lines of their contents. This is later saved to disk as configuration files.
 +
 +  Params:
 +      thing = A struct object, whose members should be "serialised".
 +/
string configText(T)(const T thing)
{
    import std.format : formattedWrite;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(256); // An IrcBot weighs in at a rough minimum of 128 characters

    sink.formattedWrite("[%s]\n", T.stringof); // Section header

    enum distance = (longestMemberName!T.length + 2);
    enum pattern = "%%-%ds  %%s\n".format(distance);
    enum patternCommented = "# %%-%ds(unset)\n".format(distance);

    foreach (name; __traits(allMembers, T))
    {
        static if (!memberIsType!(T, name) &&
                   !memberSatisfies!(isSomeFunction, T, name) &&
                   !memberSatisfies!("isTemplate", T, name) &&
                   !memberSatisfies!("isAssociativeArray", T, name) &&
                   !memberSatisfies!("isStaticArray", T, name) &&
                   !hasUDA!(__traits(getMember, T, name), Unconfigurable))
        {
            alias MemberType = typeof(__traits(getMember, T, name));

            static if ((is(MemberType == struct) || is(MemberType == class)))
            {
                // Can't reconstruct nested structs/classes
                continue;
            }
            else
            {
                static if (isArray!MemberType && !is(MemberType : string))
                {
                    // Array; use std.format.format to get a separated line
                    enum arrayPattern = "%%-(%%s%s%%)".format(separatorOf!(T, name));
                    auto value = arrayPattern.format(__traits(getMember, thing, name));
                }
                else
                {
                    // Simple assignment
                    auto value = __traits(getMember, thing, name);
                }

                static if (is(MemberType : string) || isArray!MemberType)
                {
                    if (!value.length)
                    {
                        sink.formattedWrite(patternCommented, name);
                        continue;
                    }
                }

                sink.formattedWrite(pattern, name, value);
            }
        }
    }

    return sink.data;
}

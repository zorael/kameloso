module kameloso.config;


import kameloso.common;

import std.array : Appender;
import std.ascii : newline;
import std.stdio;
import std.typecons : Flag, No, Yes;


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

string justifiedConfigurationText(const string origLines)
{
    import std.algorithm.iteration : splitter;
    import std.array : Appender;
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

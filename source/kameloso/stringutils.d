module kameloso.stringutils;

import std.traits   : isSomeString;
import std.typecons : Flag;
import std.datetime;


/// Flag denoting whether stripPrefix should assume the text begins with the supplied prefix
alias CheckIfBeginsWith = Flag!"checkIfBeginsWith";


// nom
/++
 +  Finds the supplied separator token, returns the string up to that point, and advances
 +  the passed ref string to after the token.
 +
 +  Params:
 +      arr = The array to walk and advance.
 +      separator = The token that delimenates what should be returned and to where to advance.
 +
 +  Returns:
 +      the string arr from the start up to the separator.
 +/
pragma(inline)
string nom(T, C)(ref T[] arr, C separator)
{
    // We must always decode user-written text not sent by the server
    import std.string : indexOf;

    immutable index = arr.indexOf(separator);

    if (index == -1)
    {
        import kameloso.common : writefln;
        import kameloso.constants : Foreground;

        writefln(Foreground.lightred, "--------- TRIED TO NOM TOO MUCH:'%s' with '%s'",
            arr, separator);
        return string.init;
    }

    static if (isSomeString!C)
    {
        immutable separatorLength = separator.length;
    }
    else
    {
        enum separatorLength = 1;
    }

    scope(exit) arr = arr[(index+separatorLength)..$];

    return arr[0..index];
}
unittest
{
    {
        string line = "Lorem ipsum :sit amet";
        string lorem = line.nom(" :");
        assert(lorem == "Lorem ipsum", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        string lorem = line.nom(':');
        assert(lorem == "Lorem ipsum ", lorem);
        assert(line == "sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        string lorem = line.nom(' ');
        assert(lorem == "Lorem", lorem);
        assert(line == "ipsum :sit amet", line);
    }

    {
        string line = "Lorem ipsum :sit amet";
        string lorem = line.nom("");
        assert(!lorem.length, lorem);
        assert(line == "Lorem ipsum :sit amet", line);
    }
}


// plurality
/++
 +  Get the correct singular or plural form of a word depending on the numerical count of it.
 +
 +  Params:
 +      num = The numerical count of the noun.
 +      singular = The noun in singular form.
 +      plural = The noun in plural form.
 +
 +  Returns:
 +      The singular string if num is 1 or -1, otherwise the plural string.
 +/
pragma(inline)
string plurality(int num, string singular, string plural) pure
{
    return ((num == 1) || (num == -1)) ? singular : plural;
}
unittest
{
    assert(10.plurality("one","many") == "many");
    assert(1.plurality("one", "many") == "one");
    assert((-1).plurality("one", "many") == "one");
    assert(0.plurality("one", "many") == "many");
}


// unquoted
/++
 +  Removes one preceding and one trailing quote, unquoting a word. Potential improvements
 +  include making it recursively remove more than one pair of quotes.
 +
 +  Params:
 +      line = the (potentially) quoted string.
 +
 +  Returns:
 +      A slice of the line argument that excludes the quotes.
 +/
pragma(inline)
string unquoted(string line) pure
{
    if (line.length < 2)
    {
        return line;
    }
    else if ((line[0] == '"') && (line[$-1] == '"'))
    {
        return line[1..$-1].unquoted;
    }
    else
    {
        return line;
    }
}
unittest
{
    assert(`"Lorem ipsum sit amet"`.unquoted == "Lorem ipsum sit amet");
    assert(`"""""Lorem ipsum sit amet"""""`.unquoted == "Lorem ipsum sit amet");
    // Unbalanced quotes are left untouched
    assert(`"Lorem ipsum sit amet`.unquoted == `"Lorem ipsum sit amet`);
}


// beginsWith
/++
 +  A cheaper variant of std.algorithm.searching.startsWith, since it is such a hot spot.
 +
 +  Params:
 +      haystack = The original line to examine.
 +      needle = The snippet of text to check if haystack begins with.
 +
 +  Returns:
 +      true if haystack starts with needle, otherwise false.
 +/
pragma(inline)
bool beginsWith(T)(const T haystack, const T needle) pure
if (isSomeString!T)
{
    if ((needle.length > haystack.length) || !haystack.length)
    {
        return false;
    }

    return (haystack[0..needle.length] == needle);
}
unittest
{
    assert("Lorem ipsum sit amet".beginsWith("Lorem ip"));
    assert(!"Lorem ipsum sit amet".beginsWith("ipsum sit amet"));
    assert("Lorem ipsum sit amet".beginsWith(""));
}


/// Ditto
pragma(inline)
bool beginsWith(T)(const T line, const ubyte charcode) pure
if (isSomeString!T)
{
    if (!line.length) return false;

    return (line[0] == charcode);
}
unittest
{
    assert(":Lorem ipsum".beginsWith(':'));
    assert(!":Lorem ipsum".beginsWith(';'));
}


// arrayify
/++
 +  Takes a string and, with a separator token, splits it into discrete token and makes it
 +  into a dynamic array. If the fields are numbers, use std.algorithm.iteration.map;
 +
 +  Params:
 +      separator = The string to use when delimenating fields.
 +      line = The line to split.
 +
 +  Returns:
 +      An array with fields split out of the line argument.
 +/
pragma(inline)
T[] arrayify(string separator = ",", T)(const T line)
{
    import std.algorithm.iteration : splitter, map;
    import std.string : strip;
    import std.array : array;

    return line.splitter(separator).map!(a => a.strip).array;
}
unittest
{
    assert("foo,bar,baz".arrayify     == [ "foo", "bar", "baz" ]);
    assert("foo|bar|baz".arrayify!"|" == [ "foo", "bar", "baz" ]);
    assert("foo bar baz".arrayify!" " == [ "foo", "bar", "baz" ]);
    assert("only one entry".arrayify  == [ "only one entry" ]);
    assert("not one entry".arrayify!" "  == [ "not", "one", "entry" ]);
    assert("".arrayify == []);
}


/// stripPrefix
/++
 +  Strips a prefix word from a string.
 +
 +
 +/
pragma(inline)
string stripPrefix(const string line, const string prefix)
{
    import std.string : stripLeft, munch;

    string slice = line.stripLeft();

    if (prefix.length)
    {
        slice = slice[(prefix.length+1)..$];
    }

    slice.munch(":?! ");

    return slice;
}
unittest
{
    assert("say: lorem ipsum".stripPrefix("say") == "lorem ipsum");
    assert("note!!!! zorael hello".stripPrefix("note") == "zorael hello");
    assert("sudo quit :derp".stripPrefix("sudo") == "quit :derp");
    assert("8ball predicate?".stripPrefix("") == "8ball predicate?");
}


// timeSince
/++
 +  Express how long time has passed in a Duration, in natural language.
 +
 +  Params:
 +      duration : a period of time
 +/
pragma(inline)
string timeSince(const Duration duration)
{
    import std.array  : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(50);

    int days, hours, minutes, seconds;
    duration.split!("days","hours","minutes","seconds")(days, hours, minutes, seconds);

    if (days)
    {
        sink.formattedWrite("%d %s", days, days.plurality("day", "days"));
    }
    if (hours)
    {
        if (days)
        {
            if (minutes) sink.put(", ");
            else sink.put("and ");
        }
        sink.formattedWrite("%d %s", hours, hours.plurality("hour", "hours"));
    }
    if (minutes)
    {
        if (hours) sink.put(" and ");
        sink.formattedWrite("%d %s", minutes, minutes.plurality("minute", "minutes"));
    }
    if (!minutes && !hours && !days)
    {
        sink.formattedWrite("%d %s", seconds, seconds.plurality("second", "seconds"));
    }

    return sink.data;
}


Enum toEnum(Enum)(const string enumstring)
if (is(Enum == enum))
{
	enum enumSwitch = () {
		string enumSwitch = "with (Enum) switch (enumstring)\n{";

        foreach (memberstring; __traits(allMembers, Enum))
        {
            enumSwitch ~= `case "` ~ memberstring ~ `":`;
			enumSwitch ~= "return " ~ memberstring ~ ";\n";
        }

		enumSwitch ~= `default: assert("No such member");}`;

		return enumSwitch;
	}();

	mixin(enumSwitch);

	assert(false);
}


// https://forum.dlang.org/post/bfnwstkafhfgihavtzsz@forum.dlang.org
string enumToString(Enum)(Enum value)
if (is(Enum == enum))
{
    switch (value)
    {

    foreach (m; __traits(allMembers, Enum))
    {
        case mixin("Enum." ~ m) : return m;
    }

    default:
        string result = "cast(" ~ Enum.stringof ~ ")";
        uint val = value;
        enum headLength = Enum.stringof.length + "cast()".length;

        uint log10Val =
            (val < 10) ? 0 :
            (val < 100) ? 1 :
            (val < 1_000) ? 2 :
            (val < 10_000) ? 3 :
            (val < 100_000) ? 4 :
            (val < 1_000_000) ? 5 :
            (val < 10_000_000) ? 6 :
            (val < 100_000_000) ? 7 :
            (val < 1_000_000_000) ? 8 : 9;

        result.length += log10Val + 1;

        for (uint i; i != log10Val + 1; ++i)
        {
            cast(char)result[headLength + log10Val - i] = cast(char)('0' + (val % 10));
            val /= 10;
        }

        return cast(string) result;
    }
}

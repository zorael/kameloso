module kameloso.stringutils;

import std.datetime;
import std.traits   : isSomeString;
import std.typecons : Flag;

public import std.typecons : No, Yes;

@safe:

// nom
/++
 +  Finds the supplied separator token, returns the string up to that point,
 +  and advances the passed ref string to after the token.
 +
 +  Params:
 +      arr = The array to walk and advance.
 +      separator = The token that delimenates what should be returned and to
 +                  where to advance.
 +
 +  Returns:
 +      the string arr from the start up to the separator.
 +/
pragma(inline)
string nom(Flag!"decode" decode = No.decode, T, C)(ref T[] arr, const C separator) @trusted
{
    static if (decode)
    {
        import std.string : indexOf;

        immutable index = arr.indexOf(separator);
    }
    else
    {
        // Only do this if we know it's not user text
        import std.algorithm.searching : countUntil;

        static if (isSomeString!C)
        {
            immutable index = (cast(ubyte[])arr).countUntil(cast(ubyte[])separator);
        }
        else
        {
            immutable index = (cast(ubyte[])arr).countUntil(cast(ubyte)separator);
        }
    }

    if (index == -1)
    {
        import kameloso.common : logger;

        logger.errorf("-- TRIED TO NOM TOO MUCH:'%s' with '%s'", arr, separator);
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


/// stripPrefix
/++
 +  Strips a prefix word from a string.
 +
 +  Params:
 +      line = the prefixed string line.
 +      prefix = the prefix to strip.
 +
 +  Returns:
 +      The passed line with the prefix sliced away.
 +/
pragma(inline)
string stripPrefix(const string line, const string prefix)
{
    import std.regex : ctRegex, matchFirst;
    import std.string : munch, stripLeft;

    string slice = line.stripLeft();

    // the onus is on the caller that slice begins with prefix
    slice.nom(prefix);

    enum pattern = "[:?! ]*(.+)";
    static engine = ctRegex!pattern;
    auto hits = slice.matchFirst(engine);
    return hits[1];
}



string stripSuffix(Flag!"allowFullStrip" fullStrip = No.allowFullStrip)
    (const string line, const string suffix) pure
{
    static if (fullStrip)
    {
        if (line.length < suffix.length) return line;
    }
    else
    {
        if (line.length <= suffix.length) return line;
    }

    return (line[($-suffix.length)..$] == suffix) ?
        line[0..($-suffix.length)] : line;
}


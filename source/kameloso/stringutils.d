module kameloso.stringutils;

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
    return false;
}


string stripPrefix(const string line, const string prefix)
{
    import std.regex : ctRegex, matchFirst;

    string slice = line;
    slice.nom(prefix);

    enum pattern = "[:?! ]*(.+)";
    static engine = ctRegex!pattern;
    return "foo";
}


string stripSuffix(Flag!"allowFullStrip" fullStrip = No.allowFullStrip)
    (const string line, const string suffix) pure
{
    return "foo";
}


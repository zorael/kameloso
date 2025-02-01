/++
    Functions related to reading from a configuration file, broken out of
    [kameloso.config] to avoid cyclic dependencies.

    See_Also:
        [kameloso.config]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.configreader;

private:

import lu.traits : isStruct;
import std.meta : allSatisfy;

public:


// readConfigInto
/++
    Reads a configuration file and applies the settings therein to passed objects.

    More than one object can be supplied; invalid ones for which there are no
    settings in the configuration file will be silently ignored with no errors.
    Orphan settings in the configuration file for which no appropriate
    object was passed will be saved to `invalidEntries`.

    Example:
    ---
    IRCClient client;
    IRCServer server;
    string[][string] missingEntries;
    string[][string] invalidEntries;

    "kameloso.conf".readConfigInto(missingEntries, invalidEntries, client, server);
    ---

    Params:
        configFile = Filename of file to read from.
        missingEntries = Reference to an associative array of string arrays
            of expected configuration entries that were missing.
        invalidEntries = Reference to an associative array of string arrays
            of unexpected configuration entries that did not belong.
        things = Reference variadic list of things to set values of, according
            to the text in the configuration file.
 +/
void readConfigInto(T...)
    (const string configFile,
    ref string[][string] missingEntries,
    ref string[][string] invalidEntries,
    ref T things)
if (allSatisfy!(isStruct, T))  // must be a constraint
{
    import lu.serialisation : deserialise;
    import std.algorithm.iteration : splitter;

    return configFile
        .configurationText
        .splitter('\n')
        .deserialise(missingEntries, invalidEntries, things);
}


// readConfigInto
/++
    Reads a configuration file and applies the settings therein to passed objects.
    Merely wraps the other [readConfigInto] overload and distinguishes itself
    from it by not taking the two `string[][string]` out parameters it does.

    Params:
        configFile = Filename of file to read from.
        things = Reference variadic list of things to set values of, according
            to the text in the configuration file.
 +/
void readConfigInto(T...)(const string configFile, ref T things)
if (allSatisfy!(isStruct, T))  // must be a constraint
{
    // Use two variables to satisfy -preview=dip1021
    string[][string] ignore1;
    string[][string] ignore2;
    return configFile.readConfigInto(ignore1, ignore2, things);
}


// configurationText
/++
    Reads a configuration file into a string.

    Example:
    ---
    string configText = "kameloso.conf".configurationText;
    ---

    Params:
        configFile = Filename of file to read from.

    Returns:
        The contents of the supplied file.

    Throws:
        [lu.misc.FileTypeMismatchException|FileTypeMismatchException] if the
        configuration file is a directory, a character file or any other non-file
        type we can't write to.

        [lu.serialisation.ConfigurationFileReadFailureException|ConfigurationFileReadFailureException]
        if the reading and decoding of the configuration file failed.
 +/
auto configurationText(const string configFile) @safe
{
    import std.file : exists, getAttributes, isFile;

    if (!configFile.exists)
    {
        return string.init;
    }
    else if (!configFile.isFile)
    {
        import lu.misc : FileTypeMismatchException;
        throw new FileTypeMismatchException(
            "Configuration file is not a file",
            configFile,
            cast(ushort)getAttributes(configFile),
            __FILE__);
    }

    try
    {
        import std.file : readText;
        import std.string : chomp;

        return configFile
            .readText
            .chomp;
    }
    catch (Exception e)
    {
        // catch Exception instead of UTFException, just in case there are more
        // kinds of error than the normal "Invalid UTF-8 sequence".
        throw new ConfigurationFileReadFailureException(
            e.msg,
            configFile,
            __FILE__,
            __LINE__);
    }
}


// ConfigurationFileReadFailureException
/++
    Exception, to be thrown when the specified configuration file could not be
    read, for whatever reason.

    It is a normal [object.Exception|Exception] but with an attached filename string.
 +/
final class ConfigurationFileReadFailureException : Exception
{
@safe:
    /++
        The name of the configuration file the exception refers to.
     +/
    string filename;

    /++
        Create a new [ConfigurationFileReadFailureException], without attaching a filename.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [ConfigurationFileReadFailureException], attaching a filename.
     +/
    this(
        const string message,
        const string filename,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.filename = filename;
        super(message, file, line, nextInChain);
    }
}

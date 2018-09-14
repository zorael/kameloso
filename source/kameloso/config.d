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
 +  ---
 +  Appender!string sink;
 +  sink.serialise(bot, bot.server, settings);
 +  immutable configText = sink.data.justifiedConfigurationText;
 +  writeToDisk!(Yes.addBanner)("kameloso.conf", configText);
 +  ---
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
}


// configReader
/++
 +  Reads configuration file into a string.
 +
 +  Example:
 +  ---
 +  string configText = configReader("kameloso.conf");
 +  ---
 +
 +  Params:
 +      configFile = Filename of file to read from.
 +
 +  Returns:
 +      The contents of the supplied file.
 +/
string configReader(const string configFile)
{
    return "";
}


// FileIsNotAFileException
/++
 +  Exception, to be thrown when the specified file is not a file (instead a
 +  directory, a block or character device, etc).
 +
 +  It is a normal `Exception` but with an attached filename string.
 +/
final class FileIsNotAFileException : Exception
{
    /// The name of the non-file the exception refers to.
    string filename;

    /++
     +  Create a new `FileIsNotAFileException`, without attaching a filename.
     +/
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /++
     +  Create a new `FileIsNotAFileException`, attaching a filename.
     +/
    this(const string message, const string filename, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.filename = filename;
        super(message, file, line);
    }
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
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf".readConfigInto(bot, server);
 +  ---
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
 +  ---
 +  Appender!string sink;
 +  IRCBot bot;
 +  IRCServer server;
 +  sink.serialise(bot, server);
 +  assert(!sink.data.empty);
 +  ---
 +
 +  Params:
 +      sink = Reference output range to write the serialised objects to (in
 +          their .ini file-like format).
 +      things = Variadic list of objects to serialise.
 +/
void serialise(Sink, Things...)(ref Sink sink, Things things)
if (Things.length > 1)
{
}


// serialise
/++
 +  Serialises the fields of an object into an .ini file-like format.
 +
 +  It only serialises fields not annotated with `kameloso.uda.Unconfigurable`,
 +  and it doesn't recurse into other structs or classes.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  IRCBot bot;
 +
 +  sink.serialise(bot);
 +  assert(!sink.data.empty);
 +  ---
 +
 +  Params:
 +      sink = Reference output range to write to, usually an `Appender!string`.
 +      thing = Object to serialise.
 +/
void serialise(Sink, QualThing)(ref Sink sink, QualThing thing)
{
}


// applyConfiguration
/++
 +  Takes an input range containing configuration text and applies the contents
 +  therein to one or more passed struct/class objects.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +
 +  "kameloso.conf"
 +      .configReader
 +      .splitter("\n")
 +      .applyConfiguration(bot, server);
 +  ---
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
    string[][string] invalidEntries;
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
 +  ---
 +  IRCBot bot;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.serialise(bot, server);
 +  immutable justified = sink.data.justifiedConfigurationText;
 +  ---
 +
 +  Params:
 +      origLines = Unjustified raw configuration text.
 +
 +  Returns:
 +      .ini file-like configuration text, justified into two columns.
 +/
string justifiedConfigurationText(const string origLines)
{
    return "";
}

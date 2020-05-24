/++
 +  Functionality related to configuration; verifying it, correcting it, and
 +  reading it from/writing it to disk.
 +/
module kameloso.config;

private:

import kameloso.common : IRCBot, Kameloso;
import dialect.defs : IRCClient, IRCServer;
import std.typecons : Flag, No, Yes;

public:

@safe:


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Example:
 +  ---
 +  Kameloso instance;
 +  instance.writeConfigurationFile(settings.configFile);
 +  ---
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`,
 +          with all its plugins and settings.
 +      filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref Kameloso instance, const string filename) @system
{
    import lu.serialisation : justifiedEntryValueText, serialise;
    import lu.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(4096);  // ~2234

    with (instance)
    {
        if (bot.password.length && !bot.password.beginsWith("base64:"))
        {
            bot.password = "base64:" ~ encode64(bot.password);
        }

        sink.serialise(parser.client, bot, parser.server, connSettings, settings);
        sink.put('\n');

        foreach (immutable i, plugin; instance.plugins)
        {
            immutable addedSomething = plugin.serialiseConfigInto(sink);

            if (addedSomething && (i+1 < instance.plugins.length))
            {
                sink.put('\n');
            }
        }

        immutable justified = sink.data.justifiedEntryValueText;
        writeToDisk(filename, justified, Yes.addBanner);
    }
}


// writeToDisk
/++
 +  Saves the passed configuration text to disk, with the given filename.
 +
 +  Optionally (and by default) adds the "kameloso" version banner at the head of it.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  sink.serialise(client, server, settings);
 +  immutable configText = sink.data.justifiedEntryValueText;
 +  writeToDisk("kameloso.conf", configText, Yes.addBanner);
 +  ---
 +
 +  Params:
 +      filename = Filename of file to write to.
 +      configurationText = Content to write to file.
 +      banner = Whether or not to add the "*kameloso bot*" banner at the head of the file.
 +/
void writeToDisk(const string filename, const string configurationText,
    Flag!"addBanner" banner = Yes.addBanner)
{
    import std.file : mkdirRecurse;
    import std.path : dirName;
    import std.stdio : File, writefln, writeln;

    immutable dir = filename.dirName;
    mkdirRecurse(dir);

    auto file = File(filename, "w");

    if (banner)
    {
        import kameloso.constants : KamelosoInfo;
        import core.time : msecs;
        import std.datetime.systime : Clock;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = 0.msecs;

        file.writefln("# kameloso v%s configuration file (%s)\n",
            cast(string)KamelosoInfo.version_, timestamp);
    }

    file.writeln(configurationText);
}


// complainAboutIncompleteConfiguration
/++
 +  Displays an error on how to complete a minimal configuration file.
 +
 +  It assumes that the bot's `kameloso.common.IRCBot.admins` and
 +  `kameloso.common.IRCBot.homeChannels` are both empty.
 +
 +  Used in both `kameloso.getopt` and `kameloso.kameloso.initBot`,
 +  so place it here.
 +/
void complainAboutIncompleteConfiguration()
{
    import kameloso.common : Tint, logger;

    logger.logf("...one or more %sadmins%s who get administrative control over the bot.",
        Tint.info, Tint.log);
    logger.logf("...one or more %shomeChannels%s in which to operate.", Tint.info, Tint.log);
}


// applyDefaults
/++
 +  Completes a client's, server's and bot's member fields. Empty members are
 +  given values from compile-time defaults.
 +
 +  Nickname, user, GECOS/"real name", server address and server port are
 +  required. If there is no nickname, generate a random one, then just update
 +  the other members to have the same value (if they're empty) OR with values
 +  stored in `kameloso.constants.KamelosoDefaultStrings`.
 +
 +  Params:
 +      client = Reference to the `dialect.defs.IRCClient` to complete.
 +      server = Reference to the `dialect.defs.IRCServer` to complete.
 +      bot = Reference to the `kameloso.common.IRCBot` to complete.
 +/
void applyDefaults(ref IRCClient client, ref IRCServer server, ref IRCBot bot)
out (; (client.nickname.length), "Empty client nickname")
out (; (client.user.length), "Empty client username")
out (; (client.realName.length), "Empty client GECOS/real name")
out (; (server.address.length), "Empty server address")
out (; (server.port != 0), "Server port of 0")
out (; (bot.quitReason.length), "Empty bot quit reason")
out (; (bot.partReason.length), "Empty bot part reason")
do
{
    import kameloso.constants : KamelosoDefaultIntegers, KamelosoDefaultStrings;

    // If no client.nickname set, generate a random guest name.
    if (!client.nickname.length)
    {
        import std.format : format;
        import std.random : uniform;

        client.nickname = "guest%03d".format(uniform(0, 1000));
    }

    // If no client.user set, inherit from `kameloso.constants.KamelosoDefaultStrings`.
    if (!client.user.length)
    {
        client.user = KamelosoDefaultStrings.user;
    }

    // If no client.realName set, inherit.
    if (!client.realName.length)
    {
        client.realName = KamelosoDefaultStrings.realName;
    }

    // If no server.address set, inherit.
    if (!server.address.length)
    {
        server.address = KamelosoDefaultStrings.serverAddress;
    }

    // Ditto but `kameloso.constants.KamelosoDefaultIntegers`.
    if (server.port == 0)
    {
        server.port = KamelosoDefaultIntegers.port;
    }

    if (!bot.quitReason.length)
    {
        bot.quitReason = KamelosoDefaultStrings.quitReason;
    }

    if (!bot.partReason.length)
    {
        bot.partReason = KamelosoDefaultStrings.partReason;
    }
}

///
unittest
{
    import kameloso.constants : KamelosoDefaultIntegers, KamelosoDefaultStrings;
    import std.conv : text;

    IRCClient client;
    IRCServer server;
    IRCBot bot;

    assert(!client.nickname.length, client.nickname);
    assert(!client.user.length, client.user);
    assert(!client.ident.length, client.ident);
    assert(!client.realName.length, client.realName);
    assert(!server.address, server.address);
    assert((server.port == 0), server.port.text);

    applyDefaults(client, server, bot);

    assert(client.nickname.length);
    assert((client.user == KamelosoDefaultStrings.user), client.user);
    assert(!client.ident.length, client.ident);
    assert((client.realName == KamelosoDefaultStrings.realName), client.realName);
    assert((server.address == KamelosoDefaultStrings.serverAddress), server.address);
    assert((server.port == KamelosoDefaultIntegers.port), server.port.text);
    assert((bot.quitReason == KamelosoDefaultStrings.quitReason), bot.quitReason);
    assert((bot.partReason == KamelosoDefaultStrings.partReason), bot.partReason);

    client.nickname = string.init;
    applyDefaults(client, server, bot);

    assert(client.nickname.length, client.nickname);
}


// configurationText
/++
 +  Reads a configuration file into a string.
 +
 +  Example:
 +  ---
 +  string configText = "kameloso.conf".configurationText;
 +  ---
 +
 +  Params:
 +      configFile = Filename of file to read from.
 +
 +  Returns:
 +      The contents of the supplied file.
 +
 +  Throws:
 +      `lu.common.FileTypeMismatchException` if the configuration file is a directory, a
 +      character file or any other non-file type we can't write to.
 +      `lu.serialisation.ConfigurationFileReadFailureException` if the reading and decoding of
 +      the configuration file failed.
 +/
string configurationText(const string configFile)
{
    import lu.common : FileTypeMismatchException;
    import std.file : exists, getAttributes, isFile, readText;
    import std.string : chomp;

    if (!configFile.exists)
    {
        return string.init;
    }
    else if (!configFile.isFile)
    {
        throw new FileTypeMismatchException("Configuration file is not a file",
            configFile, cast(ushort)getAttributes(configFile), __FILE__);
    }

    try
    {
        return configFile
            .readText
            .chomp;
    }
    catch (Exception e)
    {
        // catch Exception instead of UTFException, just in case there are more
        // kinds of error than the normal "Invalid UTF-8 sequence".
        throw new ConfigurationFileReadFailureException(e.msg, configFile,
            __FILE__, __LINE__);
    }
}


// ConfigurationFileReadFailureException
/++
 +  Exception, to be thrown when the specified configuration file could not be
 +  read, for whatever reason.
 +
 +  It is a normal `object.Exception` but with an attached filename string.
 +/
final class ConfigurationFileReadFailureException : Exception
{
@safe:
    /// The name of the configuration file the exception refers to.
    string filename;

    /++
     +  Create a new `ConfigurationFileReadFailureException`, without attaching
     +  a filename.
     +/
    this(const string message, const string file = __FILE__,
        const size_t line = __LINE__) pure nothrow @nogc
    {
        super(message, file, line);
    }

    /++
     +  Create a new `ConfigurationFileReadFailureException`, attaching a
     +  filename.
     +/
    this(const string message, const string filename, const string file = __FILE__,
        const size_t line = __LINE__) pure nothrow @nogc
    {
        this.filename = filename;
        super(message, file, line);
    }
}


private import std.meta : allSatisfy;
private import lu.traits : isStruct;

// readConfigInto
/++
 +  Reads a configuration file and applies the settings therein to passed objects.
 +
 +  More than one can be supplied, and invalid ones for which there are no
 +  settings will be silently ignored with no errors.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +  string[][string] missingEntries;
 +  string[][string] invalidEntries;
 +
 +  "kameloso.conf".readConfigInto(missingEntries, invalidEntries, client, server);
 +  ---
 +
 +  Params:
 +      configFile = Filename of file to read from.
 +      missingEntries = Out reference of an associative array of string arrays
 +          of expected configuration entries that were missing.
 +      invalidEntries = Out reference of an associative array of string arrays
 +          of unexpected configuration entries that did not belong.
 +      things = Reference variadic list of things to set values of, according
 +          to the text in the configuration file.
 +/
void readConfigInto(T...)(const string configFile,
    out string[][string] missingEntries,
    out string[][string] invalidEntries, ref T things)
if (allSatisfy!(isStruct, T))
{
    import lu.serialisation : deserialise;
    import std.algorithm.iteration : splitter;

    return configFile
        .configurationText
        .splitter('\n')
        .deserialise(missingEntries, invalidEntries, things);
}

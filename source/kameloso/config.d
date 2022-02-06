module kameloso.config;

private:

import kameloso.kameloso : Kameloso, IRCBot;
import dialect.defs : IRCClient, IRCServer;
import lu.common : Next;
import std.getopt : GetoptResult;
import std.typecons : Flag, No, Yes;

void writeToDisk(const string filename,
    const string configurationText,
    const Flag!"addBanner" banner = Yes.addBanner)
{}

void giveConfigurationMinimalIntructions()
{}

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
        throw new ConfigurationFileReadFailureException(e.msg, configFile,
            __FILE__, __LINE__);
    }
}

public:

Next handleGetopt(ref Kameloso instance,
    string[] args,
    out string[] customSettings) @system
{
    return Next.init;
}

void writeConfigurationFile(ref Kameloso instance, const string filename) @system {}

void notifyAboutMissingSettings(const string[][string] missingEntries,
    const string binaryPath,
    const string configFile)
{}

void notifyAboutIncompleteConfiguration(const string configFile, const string binaryPath)
{
    import kameloso.common : Tint, logger;
    import std.file : exists;
    import std.path : baseName;

    logger.info("No administrators nor home channels configured!");

    if (configFile.exists)
    {
        logger.logf("Edit %s%s%s and make sure it has at least one of the following:",
            Tint.info, configFile, Tint.log);
        giveConfigurationMinimalIntructions();
    }
    else
    {
        logger.logf("Use %s%s --save%s to generate a configuration file.",
            Tint.info, binaryPath.baseName, Tint.log);
    }

    logger.trace();
}

void applyDefaults(ref IRCClient client, ref IRCServer server, ref IRCBot bot)
out (; (client.nickname.length), "Empty client nickname")
out (; (bot.quitReason.length), "Empty bot quit reason")
out (; (bot.partReason.length), "Empty bot part reason")
{}

final class ConfigurationFileReadFailureException : Exception
{
@safe:
    string filename;

    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }

    this(const string message,
        const string filename,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.filename = filename;
        super(message, file, line, nextInChain);
    }
}

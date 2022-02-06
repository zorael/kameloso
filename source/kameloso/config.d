
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
{
    
}




void giveConfigurationMinimalIntructions()
{
    
}




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
    version(none)
    with (instance)
    {
        import kameloso.common : Tint, printVersionInfo;
        import std.getopt : arraySep, config, getopt;

        bool shouldWriteConfig;
        bool shouldOpenTerminalEditor;
        bool shouldOpenGraphicalEditor;
        bool shouldShowVersion;
        bool shouldShowSettings;
        bool shouldAppendToArrays;

        string[] inputGuestChannels;
        string[] inputHomeChannels;
        string[] inputAdmins;

        arraySep = ",";

        

        
        auto argsSlice = args[];
        const configFileResults = getopt(argsSlice,
            config.caseSensitive,
            config.bundling,
            config.passThrough,
            "c|config", &settings.configFile,
            "version", &shouldShowVersion,
        );

        if (shouldShowVersion)
        {
            
            printVersionInfo(No.colours);
            return Next.returnSuccess;
        }

        import kameloso.terminal : isTTY;

        
        settings.configFile.readConfigInto(parser.client, bot, parser.server, connSettings, settings);
        applyDefaults(parser.client, parser.server, bot);

        if (!isTTY)
        {
            
            instance.settings.monochrome = true;
        }

        
        cast(void)getopt(argsSlice,
            config.caseSensitive,
            config.bundling,
            config.passThrough,
            "monochrome", &settings.monochrome
        );

        
        Tint.monochrome = settings.monochrome;

        
        auto callGetopt( string[] theseArgs, const Flag!"quiet" quiet)
        {
            import std.conv : text, to;
            import std.format : format;
            import std.process : environment;
            import std.random : uniform;
            import std.range : repeat;

            immutable setSyntax = quiet ? string.init :
                "%s--set plugin%s.%1$ssetting%2$s=%1$svalue%2$s"
                    .format(Tint.info, Tint.off);

            immutable nickname = quiet ? string.init :
                parser.client.nickname.length ? parser.client.nickname : "<random>";

            immutable sslText = quiet ? string.init :
                connSettings.ssl ? "true" :
                    settings.force ? "false" : "inferred by port";

            immutable passwordMask = quiet ? string.init :
                bot.password.length ? '*'.repeat(uniform(6, 10)).to!string : string.init;

            immutable passMask = quiet ? string.init :
                bot.pass.length ? '*'.repeat(uniform(6, 10)).to!string : string.init;

            immutable editorCommand = quiet ? string.init :
                environment.get("EDITOR", string.init);

            immutable editorVariableValue = quiet ? string.init :
                editorCommand.length ?
                    " [%s%s%s]".format(Tint.info, editorCommand, Tint.off) :
                    string.init;

            string formatNum(const size_t num)
            {
                return (quiet || (num == 0)) ? string.init :
                    " (%s%d%s)".format(Tint.info, num, Tint.off);
            }

            return getopt(theseArgs,
                config.caseSensitive,
                config.bundling,
                "n|nickname",
                    quiet ? string.init :
                        "Nickname [%s%s%s]"
                            .format(Tint.info, nickname, Tint.off),
                    &parser.client.nickname,
                "s|server",
                    quiet ? string.init :
                        "Server address [%s%s%s]"
                            .format(Tint.info, parser.server.address, Tint.off),
                    &parser.server.address,
                "P|port",
                    quiet ? string.init :
                        "Server port [%s%d%s]"
                            .format(Tint.info, parser.server.port, Tint.off),
                    &parser.server.port,
                "6|ipv6",
                    quiet ? string.init :
                        "Use IPv6 when available [%s%s%s]"
                            .format(Tint.info, connSettings.ipv6, Tint.off),
                    &connSettings.ipv6,
                "ssl",
                    quiet ? string.init :
                        "Attempt SSL connection [%s%s%s]"
                            .format(Tint.info, sslText, Tint.off),
                    &connSettings.ssl,
                "A|account",
                    quiet ? string.init :
                        "Services account name" ~ (bot.account.length ?
                            " [%s%s%s]".format(Tint.info, bot.account, Tint.off) :
                            string.init),
                    &bot.account,
                "p|password",
                    quiet ? string.init :
                        "Services account password" ~ (bot.password.length ?
                            " [%s%s%s]".format(Tint.info, passwordMask, Tint.off) :
                            string.init),
                    &bot.password,
                "pass",
                    quiet ? string.init :
                        "Registration pass" ~ (bot.pass.length ?
                            " [%s%s%s]".format(Tint.info, passMask, Tint.off) :
                            string.init),
                    &bot.pass,
                "admins",
                    quiet ? string.init :
                        "Administrators' services accounts, comma-separated" ~
                            formatNum(bot.admins.length),
                    &inputAdmins,
                "H|homeChannels",
                    quiet ? string.init :
                        text("Home channels to operate in, comma-separated " ~
                            "(escape or enquote any octothorpe ",
                            Tint.info, '#', Tint.off, "s)",
                            formatNum(bot.homeChannels.length)),
                    &inputHomeChannels,
                "C|guestChannels",
                    quiet ? string.init :
                        "Non-home channels to idle in, comma-separated (ditto)" ~
                            formatNum(bot.guestChannels.length),
                    &inputGuestChannels,
                "a|append",
                    quiet ? string.init :
                        "Append input home channels, guest channels and " ~
                            "admins instead of overriding",
                    &shouldAppendToArrays,
                "settings",
                    quiet ? string.init :
                        "Show all plugins' settings",
                    &shouldShowSettings,
                "bright",
                    quiet ? string.init :
                        "Adjust colours for bright terminal backgrounds [%s%s%s]"
                            .format(Tint.info, settings.brightTerminal, Tint.off),
                    &settings.brightTerminal,
                "monochrome",
                    quiet ? string.init :
                        "Use monochrome output [%s%s%s]"
                            .format(Tint.info, settings.monochrome, Tint.off),
                    &settings.monochrome,
                "set",
                    quiet ? string.init :
                        text("Manually change a setting (syntax: ", setSyntax, ')'),
                    &customSettings,
                "c|config",
                    quiet ? string.init :
                        "Specify a different configuration file [%s%s%s]"
                            .format(Tint.info, settings.configFile, Tint.off),
                    &settings.configFile,
                "r|resourceDir",
                    quiet ? string.init :
                        "Specify a different resource directory [%s%s%s]"
                            .format(Tint.info, settings.resourceDirectory, Tint.off),
                    &settings.resourceDirectory,
                
                "numeric",
                    quiet ? string.init :
                        "Use numeric output of addresses",
                    &settings.numericAddresses,
                "summary",
                    quiet ? string.init :
                        "Show a connection summary on program exit [%s%s%s]"
                            .format(Tint.info, settings.exitSummary, Tint.off),
                    &settings.exitSummary,
                "force",
                    quiet ? string.init :
                        "Force connect (skips some sanity checks)",
                    &settings.force,
                "flush",
                    quiet ? string.init :
                        "Set terminal mode to flush screen output after each line written to it. " ~
                            "(Use this if the screen only occasionally updates)",
                    &settings.flush,
                "w|save",
                    quiet ? string.init :
                        "Write configuration to file",
                    &shouldWriteConfig,
                "edit",
                    quiet ? string.init :
                        text("Open the configuration file in a *terminal* text editor " ~
                            "(or the application defined in the ", Tint.info,
                            "$EDITOR", Tint.off, " environment variable)", editorVariableValue),
                    &shouldOpenTerminalEditor,
                "gedit",
                    quiet ? string.init :
                        text("Open the configuration file in a *graphical* text editor " ~
                            "(or the default application used to open ", Tint.info,
                            "*.conf", Tint.off, " files on your system)"),
                    &shouldOpenGraphicalEditor,
                "version",
                    quiet ? string.init :
                        "Show version information",
                    &shouldShowVersion,
            );
        }

        
        cast(void)callGetopt(args, Yes.quiet);

        
        if (connSettings.receiveTimeout == 0)
        {
            import kameloso.constants : Timeout;
            connSettings.receiveTimeout = Timeout.receiveMsecs;
        }

        
        import kameloso.common : initLogger;
        initLogger(cast(Flag!"monochrome")settings.monochrome,
            cast(Flag!"brightTerminal")settings.brightTerminal);

        
        if (shouldAppendToArrays)
        {
            if (inputHomeChannels.length) bot.homeChannels ~= inputHomeChannels;
            if (inputGuestChannels.length) bot.guestChannels ~= inputGuestChannels;
            if (inputAdmins.length) bot.admins ~= inputAdmins;
        }
        else
        {
            if (inputHomeChannels.length) bot.homeChannels = inputHomeChannels;
            if (inputGuestChannels.length) bot.guestChannels = inputGuestChannels;
            if (inputAdmins.length) bot.admins = inputAdmins;
        }

        
        static void stripAndLower(ref string[] channels)
        {
            import lu.string : stripped;
            import std.algorithm.iteration : map, uniq;
            import std.algorithm.sorting : sort;
            import std.array : array;
            import std.uni : toLower;

            channels = channels
                .map!(channelName => channelName.stripped.toLower)
                .array
                .sort
                .uniq
                .array;
        }

        stripAndLower(bot.homeChannels);
        stripAndLower(bot.guestChannels);

        
        size_t[] duplicates;

        foreach (immutable channelName; bot.homeChannels)
        {
            import std.algorithm.searching : countUntil;
            immutable chanIndex = bot.guestChannels.countUntil(channelName);
            if (chanIndex != -1) duplicates ~= chanIndex;
        }

        foreach_reverse (immutable chanIndex; duplicates)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            bot.guestChannels = bot.guestChannels.remove!(SwapStrategy.unstable)(chanIndex);
        }

        
        import lu.objmanip : replaceMembers;

        parser.client.replaceMembers("-");
        bot.replaceMembers("-");

        

        if (configFileResults.helpWanted)
        {
            
            
            
            printHelp(callGetopt(args, No.quiet));
            return Next.returnSuccess;
        }

        if (shouldWriteConfig || shouldOpenTerminalEditor || shouldOpenGraphicalEditor)
        {
            import std.stdio : writeln;

            
            manageConfigFile(instance, shouldWriteConfig, shouldOpenTerminalEditor,
                shouldOpenGraphicalEditor, customSettings);
            return Next.returnSuccess;
        }

        if (shouldShowSettings)
        {
            
            printSettings(instance, customSettings);
            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}




void writeConfigurationFile(ref Kameloso instance, const string filename) @system
{
    
}




void notifyAboutMissingSettings(const string[][string] missingEntries,
    const string binaryPath,
    const string configFile)
{
    
}




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
{
    
}







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



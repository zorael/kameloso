/++
    Functionality related to configuration; verifying it, correcting it,
    reading it from/writing it to disk, and parsing it from command-line arguments.

    Employs the standard [std.getopt] to read arguments from the command line
    to construct and populate instances of the structs needed for the bot to
    function, like [dialect.defs.IRCClient|IRCClient], [dialect.defs.IRCServer|IRCServer],
    [kameloso.kameloso.IRCBot|IRCBot] and [kameloso.kameloso.CoreSettings|CoreSettings].

    See_Also:
        [kameloso.kameloso]
        [kameloso.common]
 +/
module kameloso.config;

private:

import kameloso.kameloso : Kameloso, IRCBot;
import dialect.defs : IRCClient, IRCServer;
import lu.common : Next;
import std.getopt : GetoptResult;
import std.typecons : Flag, No, Yes;

@safe:


// printHelp
/++
    Prints the [std.getopt.getopt|getopt] "helpWanted" help table to screen.

    Merely leverages [std.getopt.defaultGetoptPrinter|defaultGetoptPrinter] for the printing.

    Example:
    ---
    auto results = args.getopt(
        "n|nickname",   "Bot nickname", &nickname,
        "s|server",     "Server",       &server,
        // ...
    );

    if (results.helpWanted)
    {
        printHelp(results, No.monochrome, No.brightTerminal);
    }
    ---

    Params:
        results = Results from a [std.getopt.getopt|getopt] call.
 +/
void printHelp(GetoptResult results) @system
{
    import kameloso.common : printVersionInfo;
    import std.getopt : defaultGetoptPrinter;
    import std.stdio : writeln;

    printVersionInfo();

    defaultGetoptPrinter(string.init, results.options);
    writeln();
    writeln("A dash (-) clears, so -C- translates to no channels, -A- to no account name, etc.");
    writeln();
}


// writeConfig
/++
    Writes configuration to file, verbosely. Additionally gives some empty
    settings default values..

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        client = Reference to the current [dialect.defs.IRCClient|IRCClient].
        server = Reference to the current [dialect.defs.IRCServer|IRCServer].
        bot = Reference to the current [kameloso.kameloso.IRCBot|IRCBot].
        customSettings = const string array to all the custom settings set
            via [std.getopt.getopt|getopt], to apply to things before saving to disk.
        giveInstructions = Whether or not to give instructions to edit the
            generated file and supply admins and/or home channels.
 +/
void writeConfig(ref Kameloso instance,
    ref IRCClient client,
    ref IRCServer server,
    ref IRCBot bot,
    const string[] customSettings,
    const Flag!"giveInstructions" giveInstructions = Yes.giveInstructions) @system
{
    import kameloso.common : Tint, logger, printVersionInfo;
    import kameloso.constants : KamelosoDefaults;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    // --save was passed; write configuration to file and quit

    if (!instance.settings.headless)
    {
        printVersionInfo();
        writeln();
    }

    // If we don't initialise the plugins there'll be no plugins array
    instance.initPlugins(customSettings);

    // Take the opportunity to set a default quit reason. We can't do this in
    // applyDefaults because it's a perfectly valid use-case not to have a quit
    // string, and having it there would enforce the default string if none present.
    if (!instance.bot.quitReason.length) instance.bot.quitReason = KamelosoDefaults.quitReason;

    instance.writeConfigurationFile(instance.settings.configFile);

    if (!instance.settings.headless)
    {
        printObjects(client, instance.bot, server, instance.connSettings, instance.settings);
        logger.log("Configuration written to ", Tint.info, instance.settings.configFile);

        if (!instance.bot.admins.length && !instance.bot.homeChannels.length && giveInstructions)
        {
            logger.trace();
            logger.log("Edit it and make sure it contains at least one of the following:");
            giveConfigurationMinimalInstructions();
        }
    }
}


// printSettings
/++
    Prints the core settings and all plugins' settings to screen.

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        customSettings = Array of all the custom settings set
            via [std.getopt.getopt|getopt], to apply to things before saving to disk.
 +/
void printSettings(ref Kameloso instance, const string[] customSettings) @system
{
    import kameloso.common : printVersionInfo;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    printVersionInfo();
    writeln();

    printObjects!(No.all)(instance.parser.client, instance.bot,
        instance.parser.server, instance.connSettings, instance.settings);

    instance.initPlugins(customSettings);

    foreach (plugin; instance.plugins) plugin.printSettings();
}


// manageConfigFile
/++
    Writes and/or edits the configuration file. Broken out into a separate
    function to lower the size of [handleGetopt].

    Takes bool parameters instead of [std.typecons.Flag|Flag]s to work with getopt bools.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        shouldWriteConfig = Writing to the configuration file was requested.
        shouldOpenTerminalEditor = Opening the configuration file in a
            terminal text editor was requested.
        shouldOpenGraphicalEditor = Opening the configuration file in a
            graphical text editor was requested.
        customSettings = Custom settings supplied at the command line, to be
            passed to [writeConfig] when writing to the configuration file.

    Throws:
        [object.Exception|Exception] on unexpected platforms where we did not
        know how to open the configuration file in a text editor.
 +/
void manageConfigFile(ref Kameloso instance,
    const bool shouldWriteConfig,
    const bool shouldOpenTerminalEditor,
    const bool shouldOpenGraphicalEditor,
    ref string[] customSettings) @system
{
    import kameloso.common : expandTags, logger;

    /++
        Opens up the configuration file in a terminal text editor.
     +/
    void openTerminalEditor()
    {
        import std.process : environment, spawnProcess, wait;

        // Let exceptions (ProcessExceptions) fall through and get caught
        // by [kameloso.main.tryGetopt].

        immutable editor = environment.get("EDITOR", string.init);

        if (!editor.length)
        {
            enum pattern = "Missing <l>$EDITOR<e> environment variable; cannot guess editor.";
            logger.error(pattern.expandTags);
            return;
        }

        enum pattern = "Attempting to open <i>%s<l> in <i>%s<l>...";
        logger.logf(pattern.expandTags, instance.settings.configFile, editor);

        immutable command = [ editor, instance.settings.configFile ];
        spawnProcess(command).wait;
    }

    /++
        Opens up the configuration file in a graphical text editor.
     +/
    void openGraphicalEditor()
    {
        import std.process : execute;

        version(OSX)
        {
            enum editor = "open";
        }
        else version(Posix)
        {
            import std.process : environment;

            // Assume XDG
            enum editor = "xdg-open";

            immutable isGraphicalEnvironment =
                instance.settings.force ||
                environment.get("DISPLAY", string.init).length ||
                environment.get("WAYLAND_DISPLAY", string.init).length;

            if (!isGraphicalEnvironment && !instance.settings.force)
            {
                logger.error("No graphical environment appears to be running; " ~
                    "cannot open editor.");
                return;
            }
        }
        else version(Windows)
        {
            enum editor = "explorer.exe";
        }
        else
        {
            static assert(0, "Unexpected platform, please file a bug");
        }

        // Let exceptions (ProcessExceptions) fall through and get caught
        // by [kameloso.main.tryGetopt].

        enum pattern = "Attempting to open <i>%s<l> in a graphical text editor...";
        logger.logf(pattern.expandTags, instance.settings.configFile);

        immutable command = [ editor, instance.settings.configFile ];
        execute(command);
    }

    if (shouldWriteConfig)
    {
        // --save was passed; write configuration to file and quit
        writeConfig(instance, instance.parser.client, instance.parser.server,
            instance.bot, customSettings);
    }

    if (shouldOpenTerminalEditor || shouldOpenGraphicalEditor)
    {
        import std.file : exists;

        // --edit or --gedit was passed, so open up a text editor before exiting

        if (!instance.settings.configFile.exists)
        {
            // No config file exists to open up, so create one first
            writeConfig(instance, instance.parser.client, instance.parser.server,
                instance.bot, customSettings, No.giveInstructions);
        }

        if (shouldOpenTerminalEditor)
        {
            openTerminalEditor();
        }
        else /*if (shouldOpenGraphicalEditor)*/
        {
            openGraphicalEditor();
        }
    }
}


// writeToDisk
/++
    Saves the passed configuration text to disk, with the given filename.

    Optionally (and by default) adds the "kameloso" version banner at the head of it.

    Example:
    ---
    Appender!(char[]) sink;
    sink.serialise(client, server, settings);
    immutable configText = sink.data.justifiedEntryValueText;
    writeToDisk("kameloso.conf", configText, Yes.addBanner);
    ---

    Params:
        filename = Filename of file to write to.
        configurationText = Content to write to file.
        banner = Whether or not to add the "kameloso bot" banner at the head of the file.
 +/
void writeToDisk(const string filename,
    const string configurationText,
    const Flag!"addBanner" banner = Yes.addBanner)
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
        import std.datetime.systime : Clock;
        import core.time : msecs;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = 0.msecs;

        file.writefln("# kameloso v%s configuration file (%s)\n",
            cast(string)KamelosoInfo.version_, timestamp);
    }

    file.writeln(configurationText);
}


// giveConfigurationMinimalInstructions
/++
    Displays a hint on how to complete a minimal configuration file.

    It assumes that the bot's [kameloso.kameloso.IRCBot.admins|IRCBot.admins] and
    [kameloso.kameloso.IRCBot.homeChannels|IRCBot.homeChannels] are both empty.
    (Else it should not have been called.)
 +/
void giveConfigurationMinimalInstructions()
{
    import kameloso.common : expandTags, logger;

    enum adminPattern = "...one or more <i>admins<t> who get administrative control over the bot.";
    logger.trace(adminPattern.expandTags);
    enum homePattern = "...one or more <i>homeChannels<t> in which to operate.";
    logger.trace(homePattern.expandTags);
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
        [lu.common.FileTypeMismatchException|FileTypeMismatchException] if the
        configuration file is a directory, a character file or any other non-file
        type we can't write to.

        [lu.serialisation.ConfigurationFileReadFailureException|ConfigurationFileReadFailureException]
        if the reading and decoding of the configuration file failed.
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


public:


// handleGetopt
/++
    Reads command-line options and applies them over values previously read from
    the configuration file, as well as dictates some other behaviour.

    The priority of options then becomes getopt over config file over hardcoded defaults.

    Example:
    ---
    Kameloso instance;
    Next next = instance.handleGetopt(args, customSettings);

    if (next == Next.returnSuccess) return 0;
    // ...
    ---

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso].
        args = The command-line arguments the program was called with.
        customSettings = Out array of custom settings to apply on top of
            the settings read from the configuration file.

    Returns:
        [lu.common.Next.continue_|Next.continue_] or
        [lu.common.Next.returnSuccess|Next.returnSuccess] depending on whether
        the arguments chosen mean the program should proceed or not.

    Throws:
        [std.getopt.GetOptException|GetOptException] if an unknown flag is passed.
 +/
Next handleGetopt(ref Kameloso instance,
    string[] args,
    out string[] customSettings) @system
{
    with (instance)
    {
        import kameloso.common : Tint, expandTags, printVersionInfo;
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

        /+
            Call getopt on args once and look for any specified configuration files
            so we know what to read. As such it has to be done before the
            [readConfigInto]  call. Then call getopt on the rest.
            Include "c|config" in the normal getopt to have it automatically
            included in the --help text.
         +/

        // Results can be const
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
            // --version was passed; show version info and quit
            printVersionInfo(No.colours);
            return Next.returnSuccess;
        }

        import kameloso.terminal : isTTY;

        // Ignore invalid/missing entries here, report them when initialising plugins
        settings.configFile.readConfigInto(parser.client, bot, parser.server, connSettings, settings);
        applyDefaults(parser.client, parser.server, bot);

        if (!isTTY)
        {
            // Non-TTYs (eg. pagers) can't show colours
            instance.settings.monochrome = true;
        }

        // Get `--monochrome` again; let it overwrite what isTTY and readConfigInto set it to
        cast(void)getopt(argsSlice,
            config.caseSensitive,
            config.bundling,
            config.passThrough,
            "monochrome", &settings.monochrome
        );

        // Set Tint.monochrome manually so callGetopt results below is properly (un-)tinted
        Tint.monochrome = settings.monochrome;

        /++
            Call getopt in a nested function so we can call it both to merely
            parse for settings and to format the help listing.
         +/
        auto callGetopt(/*const*/ string[] theseArgs, const Flag!"quiet" quiet)
        {
            import std.conv : text, to;
            import std.format : format;
            import std.process : environment;
            import std.random : uniform;
            import std.range : repeat;

            immutable setSyntax = quiet ? string.init :
                "<i>--set plugin</>.<i>setting</>=<i>value</>".expandTags;

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
                    " [<i>%s</>]".expandTags.format(editorCommand) :
                    string.init;

            string formatNum(const size_t num)
            {
                return (quiet || (num == 0)) ? string.init :
                    " (<i>%d</>)".expandTags.format(num);
            }

            void appendCustomSetting(const string _, const string setting)
            {
                customSettings ~= setting;
            }

            return getopt(theseArgs,
                config.caseSensitive,
                config.bundling,
                "n|nickname",
                    quiet ? string.init :
                        "Nickname [<i>%s</>]"
                            .expandTags
                            .format(nickname),
                    &parser.client.nickname,
                "s|server",
                    quiet ? string.init :
                        "Server address [<i>%s</>]"
                            .expandTags
                            .format(parser.server.address),
                    &parser.server.address,
                "P|port",
                    quiet ? string.init :
                        "Server port [<i>%d</>]"
                            .expandTags
                            .format(parser.server.port),
                    &parser.server.port,
                "6|ipv6",
                    quiet ? string.init :
                        "Use IPv6 where available [<i>%s</>]"
                            .expandTags
                            .format(connSettings.ipv6),
                    &connSettings.ipv6,
                "ssl",
                    quiet ? string.init :
                        "Attempt SSL connection [<i>%s</>]"
                            .expandTags
                            .format(sslText),
                    &connSettings.ssl,
                "A|account",
                    quiet ? string.init :
                        "Service account name" ~
                            (bot.account.length ?
                                " [<i>%s</>]"
                                    .expandTags
                                    .format(bot.account) :
                                string.init),
                    &bot.account,
                "p|password",
                    quiet ? string.init :
                        "Service account password" ~
                            (bot.password.length ?
                                " [<i>%s</>]"
                                    .expandTags
                                    .format(passwordMask) :
                                string.init),
                    &bot.password,
                "pass",
                    quiet ? string.init :
                        "Registration pass" ~
                            (bot.pass.length ?
                                " [<i>%s</>]"
                                    .expandTags
                                    .format(passMask) :
                                string.init),
                    &bot.pass,
                "admins",
                    quiet ? string.init :
                        "Administrators' services accounts, comma-separated" ~
                            formatNum(bot.admins.length),
                    &inputAdmins,
                "H|homeChannels",
                    quiet ? string.init :
                        text(("Home channels to operate in, comma-separated " ~
                            "(escape or enquote any octothorpe <i>#</>s)").expandTags,
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
                        "Adjust colours for bright terminal backgrounds [<i>%s</>]"
                            .expandTags
                            .format(settings.brightTerminal),
                    &settings.brightTerminal,
                "monochrome",
                    quiet ? string.init :
                        "Use monochrome output [<i>%s</>]"
                            .expandTags
                            .format(settings.monochrome),
                    &settings.monochrome,
                "set",
                    quiet ? string.init :
                        text("Manually change a setting (syntax: ", setSyntax, ')'),
                    &appendCustomSetting,
                "c|config",
                    quiet ? string.init :
                        "Specify a different configuration file [<i>%s</>]"
                            .expandTags
                            .format(settings.configFile),
                    &settings.configFile,
                "r|resourceDir",
                    quiet ? string.init :
                        "Specify a different resource directory [<i>%s</>]"
                            .expandTags
                            .format(settings.resourceDirectory),
                    &settings.resourceDirectory,
                /+"receiveTimeout",
                    quiet ? string.init :
                        ("Socket receive timeout in milliseconds; lower numbers " ~
                            "improve worse-case responsiveness of outgoing messages [<i>%d</>]")
                                .expandTags
                                .format(connSettings.receiveTimeout),
                    &connSettings.receiveTimeout,
                "privateKey",
                    quiet ? string.init :
                        "Path to private key file, used to authenticate some SSL connections",
                    &connSettings.privateKeyFile,
                "cert",
                    quiet ? string.init :
                        "Path to certificate file, ditto",
                    &connSettings.certFile,
                "cacert",
                    quiet ? string.init :
                        "Path to <i>cacert.pem</> certificate bundle, or equivalent"
                            .expandTags,
                    &connSettings.caBundleFile,+/
                "numeric",
                    quiet ? string.init :
                        "Use numeric output of addresses",
                    &settings.numericAddresses,
                "summary",
                    quiet ? string.init :
                        "Show a connection summary on program exit [<i>%s</>]"
                            .expandTags
                            .format(settings.exitSummary),
                    &settings.exitSummary,
                "force",
                    quiet ? string.init :
                        "Force connect (skips some checks)",
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
                        ("Open the configuration file in a *terminal* text editor " ~
                            "(or the application defined in the <i>$EDITOR</> " ~
                            "environment variable)").expandTags ~ editorVariableValue,
                    &shouldOpenTerminalEditor,
                "gedit",
                    quiet ? string.init :
                        ("Open the configuration file in a *graphical* text editor " ~
                            "(or the default application used to open <i>*.conf</> files on your system")
                                .expandTags,
                    &shouldOpenGraphicalEditor,
                "headless",
                    quiet ? string.init :
                        "Enable headless mode, disabling all terminal output",
                    &settings.headless,
                "version",
                    quiet ? string.init :
                        "Show version information",
                    &shouldShowVersion,
            );
        }

        // No need to catch the return value, only used for --help
        cast(void)callGetopt(args, Yes.quiet);

        // Save the user from themselves. (A receive timeout of 0 breaks all sorts of things.)
        if (connSettings.receiveTimeout == 0)
        {
            import kameloso.constants : Timeout;
            connSettings.receiveTimeout = Timeout.receiveMsecs;
        }

        // Reinitialise the logger with new settings
        import kameloso.common : initLogger;
        initLogger(
            cast(Flag!"monochrome")settings.monochrome,
            cast(Flag!"brightTerminal")settings.brightTerminal,
            cast(Flag!"headless")settings.headless);

        // Manually override or append channels, depending on `shouldAppendChannels`
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

        /// Strip channel whitespace and make lowercase
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

        // Remove duplicate channels (where a home is also featured as a normal channel)
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

        // Clear entries that are dashes
        import lu.objmanip : replaceMembers;

        parser.client.replaceMembers("-");
        bot.replaceMembers("-");

        // Handle showstopper arguments (that display something and then exits)

        if (configFileResults.helpWanted)
        {
            // --help|-h was passed, show the help table and quit
            // It's okay to reuse args, it's probably empty save for arg0
            // and we just want the help listing
            if (!settings.headless) printHelp(callGetopt(args, No.quiet));
            return Next.returnSuccess;
        }

        if (shouldWriteConfig || shouldOpenTerminalEditor || shouldOpenGraphicalEditor)
        {
            // --save and/or --edit was passed; defer to manageConfigFile
            manageConfigFile(instance, shouldWriteConfig, shouldOpenTerminalEditor,
                shouldOpenGraphicalEditor, customSettings);
            return Next.returnSuccess;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            if (!settings.headless) printSettings(instance, customSettings);
            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}


// writeConfigurationFile
/++
    Write all settings to the configuration filename passed.

    It gathers configuration text from all plugins before formatting it into
    nice columns, then writes it all in one go.

    Example:
    ---
    Kameloso instance;
    instance.writeConfigurationFile(settings.configFile);
    ---

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso],
            with all its plugins and settings.
        filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref Kameloso instance, const string filename) @system
{
    import lu.serialisation : justifiedEntryValueText, serialise;
    import lu.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(4096);  // ~2234

    with (instance)
    {
        if (!instance.settings.force && bot.password.length && !bot.password.beginsWith("base64:"))
        {
            bot.password = "base64:" ~ encode64(bot.password);
        }

        if (!instance.settings.force && bot.pass.length && !bot.pass.beginsWith("base64:"))
        {
            bot.pass = "base64:" ~ encode64(bot.pass);
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

        immutable justified = sink.data.idup.justifiedEntryValueText;
        writeToDisk(filename, justified, Yes.addBanner);
    }
}


// notifyAboutMissingSettings
/++
    Prints some information about missing configuration entries to the local terminal.

    Params:
        missingEntries = A `string[][string]` associative array of dynamic
            `string[]` arrays, keyed by configuration section name strings.
            These arrays contain missing settings.
        binaryPath = The program's `args[0]`.
        configFile = (Relative) path of the configuration file.
 +/
void notifyAboutMissingSettings(const string[][string] missingEntries,
    const string binaryPath,
    const string configFile)
{
    import kameloso.common : expandTags, logger;
    import std.conv : text;
    import std.path : baseName;

    logger.log("Your configuration file is missing the following settings:");

    foreach (immutable section, const sectionEntries; missingEntries)
    {
        enum missingPattern = "...under <l>[<i>%s<l>]<t>: %-(<i>%s%|<t>, %)";
        logger.tracef(missingPattern.expandTags, section, sectionEntries);
    }

    enum pattern = "Use <i>%s --save<l> to regenerate the file, " ~
        "updating it with all available configuration. [<i>%s<l>]";
    logger.logf(pattern.expandTags, binaryPath.baseName, configFile);
    logger.warning("Mind that any comments and/or sections belonging to unbuilt plugins will be removed.");
    logger.trace();
}


// notifyAboutIncompleteConfiguration
/++
    Displays an error if the configuration is *incomplete*, e.g. missing crucial information.

    It assumes such information is missing, and that the check has been done at
    the calling site.

    Params:
        configFile = Full path to the configuration file.
        binaryPath = Full path to the current binary.
 +/
void notifyAboutIncompleteConfiguration(const string configFile, const string binaryPath)
{
    import kameloso.common : expandTags, logger;
    import std.file : exists;
    import std.path : baseName;

    logger.info("No administrators nor home channels configured!");

    if (configFile.exists)
    {
        enum pattern = "Edit <i>%s<l> and make sure it has at least one of the following:";
        logger.logf(pattern.expandTags, configFile);
        giveConfigurationMinimalInstructions();
    }
    else
    {
        enum pattern = "Use <i>%s --save<l> to generate a configuration file.";
        logger.logf(pattern.expandTags, binaryPath.baseName);
    }

    logger.trace();
}


// applyDefaults
/++
    Completes a client's, server's and bot's member fields. Empty members are
    given values from compile-time defaults.

    Nickname, user, GECOS/"real name", server address and server port are
    required. If there is no nickname, generate a random one. For any other empty values,
    update them with relevant such from [kameloso.constants.KamelosoDefaults|KamelosoDefaults]
    (and [kameloso.constants.KamelosoDefaultIntegers|KamelosoDefaultIntegers]).

    Params:
        client = Reference to the [dialect.defs.IRCClient|IRCClient] to complete.
        server = Reference to the [dialect.defs.IRCServer|IRCServer] to complete.
        bot = Reference to the [kameloso.kameloso.IRCBot|IRCBot] to complete.
 +/
void applyDefaults(ref IRCClient client, ref IRCServer server, ref IRCBot bot)
out (; (client.nickname.length), "Empty client nickname")
out (; (client.user.length), "Empty client username")
out (; (client.realName.length), "Empty client GECOS/real name")
out (; (server.address.length), "Empty server address")
out (; (server.port != 0), "Server port of 0")
out (; (bot.quitReason.length), "Empty bot quit reason")
out (; (bot.partReason.length), "Empty bot part reason")
{
    import kameloso.constants : KamelosoDefaults, KamelosoDefaultIntegers;

    // If no client.nickname set, generate a random guest name.
    if (!client.nickname.length)
    {
        import std.format : format;
        import std.random : uniform;

        client.nickname = "guest%03d".format(uniform(0, 1000));
        bot.hasGuestNickname = true;
    }

    // If no client.user set, inherit from [kameloso.constants.KamelosoDefaults|KamelosoDefaults].
    if (!client.user.length)
    {
        client.user = KamelosoDefaults.user;
    }

    // If no client.realName set, inherit.
    if (!client.realName.length)
    {
        client.realName = KamelosoDefaults.realName;
    }

    // If no server.address set, inherit.
    if (!server.address.length)
    {
        server.address = KamelosoDefaults.serverAddress;
    }

    // Ditto but [kameloso.constants.KamelosoDefaultIntegers|KamelosoDefaultIntegers].
    if (server.port == 0)
    {
        server.port = KamelosoDefaultIntegers.port;
    }

    if (!bot.quitReason.length)
    {
        bot.quitReason = KamelosoDefaults.quitReason;
    }

    if (!bot.partReason.length)
    {
        bot.partReason = KamelosoDefaults.partReason;
    }
}

///
unittest
{
    import kameloso.constants : KamelosoDefaults, KamelosoDefaultIntegers;
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
    assert((client.user == KamelosoDefaults.user), client.user);
    assert(!client.ident.length, client.ident);
    assert((client.realName == KamelosoDefaults.realName), client.realName);
    assert((server.address == KamelosoDefaults.serverAddress), server.address);
    assert((server.port == KamelosoDefaultIntegers.port), server.port.text);
    assert((bot.quitReason == KamelosoDefaults.quitReason), bot.quitReason);
    assert((bot.partReason == KamelosoDefaults.partReason), bot.partReason);

    client.nickname = string.init;
    applyDefaults(client, server, bot);

    assert(client.nickname.length, client.nickname);
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
    /// The name of the configuration file the exception refers to.
    string filename;

    /++
        Create a new [ConfigurationFileReadFailureException], without attaching
        a filename.
     +/
    this(const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [ConfigurationFileReadFailureException], attaching a
        filename.
     +/
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


private import lu.traits : isStruct;
private import std.meta : allSatisfy;

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
        missingEntries = Out reference of an associative array of string arrays
            of expected configuration entries that were missing.
        invalidEntries = Out reference of an associative array of string arrays
            of unexpected configuration entries that did not belong.
        things = Reference variadic list of things to set values of, according
            to the text in the configuration file.
 +/
void readConfigInto(T...)
    (const string configFile,
    out string[][string] missingEntries,
    out string[][string] invalidEntries,
    ref T things)
if (allSatisfy!(isStruct, T))
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
if (allSatisfy!(isStruct, T))
{
    // Use two variables to satisfy -preview=dip1021
    string[][string] ignore1;
    string[][string] ignore2;
    return configFile.readConfigInto(ignore1, ignore2, things);
}

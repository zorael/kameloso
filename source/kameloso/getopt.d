/++
 +  Basic command-line argument-handling.
 +
 +  Employs the standard `std.getopt` to read arguments from the command line
 +  to construct and populate instances of the structs needed for the bot to
 +  function, like `dialect.defs.IRCClient`, `dialect.defs.IRCServer`,
 +  `kameloso.common.IRCBot` and `kameloso.common.CoreSettings`.
 +/
module kameloso.getopt;

private:

import kameloso.common : CoreSettings, IRCBot, Kameloso;
import dialect.defs : IRCClient, IRCServer;
import lu.common : Next;
import std.getopt : GetoptResult;
import std.typecons : Flag, No, Yes;

version(linux)
{
    version = XDG;
}
else version(FreeBSD)
{
    version = XDG;
}

@safe:


// printHelp
/++
 +  Prints the `getopt` "helpWanted" help table to screen.
 +
 +  Merely leverages `std.getopt.defaultGetoptPrinter` for the printing.
 +
 +  Example:
 +  ---
 +  auto results = args.getopt(
 +      "n|nickname",   "Bot nickname", &nickname,
 +      "s|server",     "Server",       &server,
 +      // ...
 +  );
 +
 +  if (results.helpWanted)
 +  {
 +      printHelp(results);
 +  }
 +  ---
 +
 +  Params:
 +      results = Results from a `std.getopt.getopt` call, usually with `.helpWanted` true.
 +      monochrome = Whether or not terminal colours should be used.
 +      brightTerminal = Whether or not the terminal has a bright background
 +          and colours should be adjusted to suit.
 +/
void printHelp(GetoptResult results,
    const Flag!"monochrome" monochrome,
    const Flag!"brightTerminal" brightTerminal) @system
{
    import kameloso.common : printVersionInfo;
    import std.stdio : writeln;

    string pre, post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground, colour;

        if (!monochrome)
        {
            enum headertintColourBright = TerminalForeground.black.colour.idup;
            enum headertintColourDark = TerminalForeground.white.colour.idup;
            enum defaulttintColour = TerminalForeground.default_.colour.idup;
            pre = brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;
        }
    }

    printVersionInfo(pre, post);
    writeln();

    string headline = "Command-line arguments available:\n";

    version(Colours)
    {
        if (!monochrome)
        {
            import kameloso.terminal : TerminalForeground, colour;

            immutable headlineTint = brightTerminal ?
                TerminalForeground.green : TerminalForeground.lightgreen;
            headline = headline.colour(headlineTint);
        }
    }

    import std.getopt : defaultGetoptPrinter;
    defaultGetoptPrinter(headline, results.options);
    writeln();
    writeln("A dash (-) clears, so -C- translates to no channels, -A- to no account name, etc.");
    writeln();
}


// writeConfig
/++
 +  Writes configuration to file, verbosely.
 +
 +  The filename is read from `kameloso.common.settings`.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      client = Reference to the current `dialect.defs.IRCClient`.
 +      server = Reference to the current `dialect.defs.IRCServer`.
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      customSettings = const string array to all the custom settings set
 +          via `getopt`, to apply to things before saving to disk.
 +      giveInstructions = Whether or not to give instructions to edit the
 +          generated file and supply admins and/or home channels.
 +/
void writeConfig(ref Kameloso instance, ref IRCClient client, ref IRCServer server,
    ref IRCBot bot, const string[] customSettings,
    const Flag!"giveInstructions" giveInstructions = Yes.giveInstructions) @system
{
    import kameloso.common : Tint, logger, printVersionInfo;
    import kameloso.config : writeConfigurationFile;
    import kameloso.constants : KamelosoDefaultStrings;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    // --writeconfig was passed; write configuration to file and quit

    string post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground;

        if (!instance.settings.monochrome)
        {
            import kameloso.terminal : colour;

            enum defaulttintColour = TerminalForeground.default_.colour.idup;
            post = defaulttintColour;
        }
    }

    printVersionInfo(Tint.log, post);
    writeln();

    // If we don't initialise the plugins there'll be no plugins array
    string[][string] ignore;
    instance.initPlugins(customSettings, ignore, ignore);

    // Take the opportunity to set a default quit reason. We can't do this in
    // applyDefaults because it's a perfectly valid use-case not to have a quit
    // string, and having it there would enforce the default string if none present.
    if (!instance.bot.quitReason.length) instance.bot.quitReason = KamelosoDefaultStrings.quitReason;

    printObjects(client, instance.bot, server, instance.connSettings, instance.settings);

    instance.writeConfigurationFile(instance.settings.configFile);

    logger.logf("Configuration written to %s%s", Tint.info, instance.settings.configFile);

    if (!instance.bot.admins.length && !instance.bot.homeChannels.length && giveInstructions)
    {
        import kameloso.config : complainAboutIncompleteConfiguration;

        logger.trace("---");
        logger.log("Edit it and make sure it contains at least one of the following:");
        complainAboutIncompleteConfiguration();
    }
}


// printSettings
/++
 +  Prints the core settings and all plugins' settings to screen.
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      customSettings = const string array to all the custom settings set
 +          via `getopt`, to apply to things before saving to disk.
 +      monochrome = Whether or not terminal colours should be used.
 +      brightTerminal = Whether or not the terminal has a bright background
 +          and colours should be adjusted to suit.
 +/
void printSettings(ref Kameloso instance, const string[] customSettings,
    const Flag!"monochrome" monochrome,
    const Flag!"brightTerminal" brightTerminal) @system
{
    import kameloso.common : printVersionInfo;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    string pre, post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground, colour;

        if (!monochrome)
        {
            enum headertintColourBright = TerminalForeground.black.colour.idup;
            enum headertintColourDark = TerminalForeground.white.colour.idup;
            enum defaulttintColour = TerminalForeground.default_.colour.idup;
            pre = brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;
        }
    }

    printVersionInfo(pre, post);
    writeln();

    printObjects!(No.all)(instance.parser.client, instance.bot,
        instance.parser.server, instance.connSettings, instance.settings);

    string[][string] ignore;
    instance.initPlugins(customSettings, ignore, ignore);

    foreach (plugin; instance.plugins) plugin.printSettings();
}


public:


// handleGetopt
/++
 +  Read command-line options and apply them over values previously read from
 +  the configuration file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded defaults.
 +
 +  Example:
 +  ---
 +  Kameloso instance;
 +  Next next = instance.handleGetopt(args);
 +
 +  if (next == Next.returnSuccess) return 0;
 +  // ...
 +  ---
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`.
 +      args = The `string[]` args the program was called with.
 +      customSettings = Out array of custom settings to apply on top of
 +          the settings read from the configuration file.
 +
 +  Returns:
 +      `lu.common.Next.continue_` or `lu.common.Next.returnSuccess`
 +      depending on whether the arguments chosen mean the program should
 +      proceed or not.
 +
 +  Throws:
 +      `std.getopt.GetOptException` if an unknown flag is passed.
 +/
Next handleGetopt(ref Kameloso instance, string[] args, out string[] customSettings) @system
{
    import kameloso.common : Tint, printVersionInfo;
    import kameloso.config : applyDefaults, readConfigInto;
    import std.format : format;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout, writeln;

    scope(exit) if (instance.settings.flush) stdout.flush();

    bool shouldWriteConfig;
    bool shouldOpenEditor;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldAppendToArrays;

    string[] inputGuestChannels;
    string[] inputHomeChannels;
    string[] inputAdmins;

    arraySep = ",";

    with (instance)
    {
        /+
            Call getopt on args once and look for any specified configuration files
            so we know what to read. As such it has to be done before the
            `readConfigInto`  call. Then call getopt on the rest.
            Include "c|config" in the normal getopt to have it automatically
            included in the --help text.
         +/

        // Can be const
        auto argsDup = args.dup;
        const configFileResults = getopt(argsDup,
            config.caseSensitive,
            config.bundling,
            config.passThrough,
            "c|config", &settings.configFile,
            "monochrome", &settings.monochrome,
        );

        // Set Tint.monochrome manually so setSyntax below is properly (un-)tinted
        Tint.monochrome = settings.monochrome;

        string[][string] missing;
        string[][string] invalid;

        settings.configFile.readConfigInto(missing, invalid,
            parser.client, bot, parser.server, connSettings, settings);
        applyDefaults(parser.client, parser.server, bot);

        immutable setSyntax = "%splugin%s.%1$soption%2$s=%1$ssetting%2$s"
            .format(Tint.info, Tint.reset);

        // Cannot be const
        auto results = getopt(args,
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Nickname",
                            &parser.client.nickname,
            "s|server",     "Server address [%s%s%s]"
                            .format(Tint.info, parser.server.address, Tint.reset),
                            &parser.server.address,
            "P|port",       "Server port [%s%d%s]"
                            .format(Tint.info, parser.server.port, Tint.reset),
                            &parser.server.port,
            "6|ipv6",       "Use IPv6 when available [%s%s%s]"
                            .format(Tint.info, connSettings.ipv6, Tint.reset),
                            &connSettings.ipv6,
            "ssl",          "Use SSL connections [%s%s%s]"
                            .format(Tint.info, connSettings.ssl, Tint.reset),
                            &connSettings.ssl,
            "A|account",    "Services account name",
                            &bot.account,
            "p|password",   "Services account password",
                            &bot.password,
            "pass",         "Registration pass",
                            &bot.pass,
            "admins",       "Administrators' services accounts, comma-separated",
                            &inputAdmins,
            "H|homeChannels","Home channels to operate in, comma-separated " ~
                            "(escape or enquote any octothorpe " ~
                            Tint.info ~ '#' ~ Tint.reset ~ "s)",
                            &inputHomeChannels,
            "homes",        "^",
                            &inputHomeChannels,
            "C|guestChannels","Non-home channels to idle in, comma-separated (ditto)",
                            &inputGuestChannels,
            "channels",     "^",
                            &inputGuestChannels,
            "a|append",     "Append input home channels, guest channels and " ~
                            "admins instead of overriding",
                            &shouldAppendToArrays,
            "hideOutgoing", "Hide outgoing messages",
                            &settings.hideOutgoing,
            "hide",         "^",
                            &settings.hideOutgoing,
            "settings",     "Show all plugins' settings",
                            &shouldShowSettings,
            "show",         "^",
                            &shouldShowSettings,
            "bright",       "Adjust colours for bright terminal backgrounds",
                            &settings.brightTerminal,
            "brightTerminal", "^",
                            &settings.brightTerminal,
            "monochrome",   "Use monochrome output",
                            &settings.monochrome,
            "set",          "Manually change a setting (syntax: --set " ~ setSyntax ~ ')',
                            &customSettings,
            "c|config",     "Specify a different configuration file [%s%s%s]"
                            .format(Tint.info, settings.configFile, Tint.reset),
                            &settings.configFile,
            "r|resourceDir","Specify a different resource directory [%s%s%s]"
                            .format(Tint.info, settings.resourceDirectory, Tint.reset),
                            &settings.resourceDirectory,
            /*"privateKey",   "Path to private key file, used to authenticate some SSL connections",
                            &connSettings.privateKeyFile,
            "cert",         "Path to certificate file, ditto",
                            &connSettings.certFile,
            "cacert",       "Path to %scacert.pem%s certificate bundle, or equivalent"
                            .format(Tint.info, Tint.reset),
                            &connSettings.caBundleFile,*/
            "summary",      "Show a connection summary on program exit",
                            &settings.exitSummary,
            "force",        "Force connect (skips some sanity checks)",
                            &settings.force,
            "flush",        "Flush screen output after each write to it. " ~
                            "(Use this if the screen only occasionally updates.)",
                            &settings.flush,
            "w|writeconfig","Write configuration to file",
                            &shouldWriteConfig,
            "save",         "^",
                            &shouldWriteConfig,
            "init",         "^",
                            &shouldWriteConfig,
            "edit",         "Open the configuration file in a text editor " ~
                            "(or the default application used to open " ~ Tint.log ~
                            "*.conf" ~ Tint.trace ~ " files on your system",
                            &shouldOpenEditor,
            "version",      "Show version information",
                            &shouldShowVersion,
        );

        if (shouldShowVersion)
        {
            // --version was passed; show version info and quit
            printVersionInfo();
            return Next.returnSuccess;
        }
        else if (configFileResults.helpWanted)
        {
            // --help|-h was passed; show the help table and quit
            printHelp(results,
                (instance.settings.monochrome ? Yes.monochrome : No.monochrome),
                (instance.settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal));
            return Next.returnSuccess;
        }

        // Reinitialise the logger with new settings
        import kameloso.common : initLogger;
        initLogger((settings.monochrome ? Yes.monochrome : No.monochrome),
            (settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal),
            (settings.flush ? Yes.flush : No.flush));

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

        // Strip channel whitespace and make lowercase
        import lu.string : stripped;
        import std.algorithm.iteration : map, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.uni : toLower;

        bot.guestChannels = bot.guestChannels
            .map!(channelName => channelName.stripped.toLower)
            .array
            .sort
            .uniq
            .array;

        bot.homeChannels = bot.homeChannels
            .map!(channelName => channelName.stripped.toLower)
            .array
            .sort
            .uniq
            .array;

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
        if (shouldWriteConfig || shouldOpenEditor)
        {
            // --writeconfig and/or --edit was passed; defer to manageConfigFile
            manageConfigFile(instance, shouldWriteConfig, shouldOpenEditor, customSettings);
            return Next.returnSuccess;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            printSettings(instance, customSettings,
                (instance.settings.monochrome ? Yes.monochrome : No.monochrome),
                (instance.settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal));
            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}


// manageConfigFile
/++
 +  Writes and/or edits the configuration file. Broken out into a separate
 +  function to lower size of `handleGetopt`.
 +
 +  bool parameters instead of `std.typecons.Flag`s to work with getopt bools.
 +
 +  Params:
 +      instance = The current `kameloso.common.Kameloso` instance.
 +      shouldWriteConfig = Writing to the configuration file was requested.
 +      shouldOpenEditor = Opening the configuration file in an editor was requested.
 +      customSettings = Custom settings supplied at the command line, to be
 +          passed to `writeConfig` when writing to the configuration file.
 +
 +  Throws:
 +      `object.Exception` on unexpected platforms where we did not know how to
 +      open the configuration file in a text editor.
 +/
void manageConfigFile(ref Kameloso instance, const bool shouldWriteConfig,
    const bool shouldOpenEditor, ref string[] customSettings) @system
{
    /++
     +  Opens up the configuration file in a text editor.
     +/
    void openEditor()
    {
        import std.process : execute;

        // Let exceptions (ProcessExceptions) fall through and get caught
        // by `kameloso.kameloso.tryGetopt`.

        version(XDG)
        {
            immutable command = [ "xdg-open", instance.settings.configFile ];
            execute(command);
        }
        else version (OSX)
        {
            immutable command = [ "open", instance.settings.configFile ];
            execute(command);
        }
        else version (Windows)
        {
            immutable command = [ "explorer", instance.settings.configFile ];
            execute(command);
        }
        else
        {
            throw new Exception("Unexpected platform");
        }
    }

    if (shouldWriteConfig)
    {
        // --writeconfig was passed; write configuration to file and quit
        writeConfig(instance, instance.parser.client, instance.parser.server,
            instance.bot, customSettings);

        if (shouldOpenEditor)
        {
            // Additionally --edit was passed, so edit the file after writing to it
            openEditor();
        }
    }

    if (shouldOpenEditor)
    {
        import std.file : exists;

        // --edit as passed, so open up a text editor before exiting

        if (!instance.settings.configFile.exists)
        {
            // No config file exists to open up, so create one first
            writeConfig(instance, instance.parser.client, instance.parser.server,
                instance.bot, customSettings, No.giveInstructions);
        }

        import kameloso.common : Tint, logger;

        logger.logf("Attempting to open %s%s%s in a text editor ...",
            Tint.info, instance.settings.configFile, Tint.log);

        openEditor();
    }

    import std.stdio : writeln;
    writeln();  // pad slightly, for cosmetics
}

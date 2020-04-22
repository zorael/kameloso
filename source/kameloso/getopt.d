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
import std.typecons : No, Yes;

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
 +/
void printHelp(GetoptResult results) @system
{
    import kameloso.common : printVersionInfo, settings;
    import std.stdio : writeln;

    string pre, post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground, colour;

        if (!settings.monochrome)
        {
            enum headertintColourBright = TerminalForeground.black.colour.idup;
            enum headertintColourDark = TerminalForeground.white.colour.idup;
            enum defaulttintColour = TerminalForeground.default_.colour.idup;
            pre = settings.brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;
        }
    }

    printVersionInfo(pre, post);
    writeln();

    string headline = "Command-line arguments available:\n";

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.terminal : TerminalForeground, colour;

            immutable headlineTint = settings.brightTerminal ?
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
 +/
void writeConfig(ref Kameloso instance, ref IRCClient client, ref IRCServer server,
    ref IRCBot bot, const string[] customSettings) @system
{
    import kameloso.common : Tint, logger, printVersionInfo, settings;
    import kameloso.config : writeConfigurationFile;
    import kameloso.constants : KamelosoDefaultStrings;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    // --writeconfig was passed; write configuration to file and quit

    string post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground;

        if (!settings.monochrome)
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
    // string, and havig it there would enforce the default string if none present.
    if (!instance.bot.quitReason.length) instance.bot.quitReason = KamelosoDefaultStrings.quitReason;

    printObjects(client, instance.bot, server, settings);

    instance.writeConfigurationFile(settings.configFile);

    logger.logf("Configuration written to %s%s\n", Tint.info, settings.configFile);

    if (!instance.bot.admins.length && !instance.bot.homeChannels.length)
    {
        import kameloso.config : complainAboutIncompleteConfiguration;
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
 +/
void printSettings(ref Kameloso instance, const string[] customSettings) @system
{
    import kameloso.common : printVersionInfo, settings;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    string pre, post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground, colour;

        if (!settings.monochrome)
        {
            enum headertintColourBright = TerminalForeground.black.colour.idup;
            enum headertintColourDark = TerminalForeground.white.colour.idup;
            enum defaulttintColour = TerminalForeground.default_.colour.idup;
            pre = settings.brightTerminal ? headertintColourBright : headertintColourDark;
            post = defaulttintColour;
        }
    }

    printVersionInfo(pre, post);
    writeln();

    printObjects!(No.printAll)(instance.parser.client, instance.bot, instance.parser.server, settings);

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
    import kameloso.common : printVersionInfo;
    import kameloso.config : applyDefaults, readConfigInto;
    import std.format : format;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout, writeln;

    scope(exit) if (instance.settings.flush) stdout.flush();

    bool shouldWriteConfig;
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
        const configFileResults = getopt(args,
            config.caseSensitive,
            config.bundling,
            config.passThrough,
            "c|config", &settings.configFile,
        );

        string[][string] missing;
        string[][string] invalid;

        settings.configFile.readConfigInto(missing, invalid,
            parser.client, bot, parser.server, settings);
        applyDefaults(parser.client, parser.server);

        // Cannot be const
        auto results = getopt(args,
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Nickname",
                            &parser.client.nickname,
            "s|server",     "Server address [%s]".format(parser.server.address),
                            &parser.server.address,
            "P|port",       "Server port [%d]".format(parser.server.port),
                            &parser.server.port,
            "6|ipv6",       "Use IPv6 when available [%s]".format(settings.ipv6),
                            &settings.ipv6,
            "A|account",    "Services account name",
                            &bot.account,
            "p|password",   "Services account password",
                            &bot.password,
            "pass",         "Registration pass",
                            &bot.pass,
            "admins",       "Administrators' services accounts, comma-separated",
                            &inputAdmins,
            "H|homeChannels","Home channels to operate in, comma-separated " ~
                            "(escape or enquote any octothorpe #s)",
                            &inputHomeChannels,
            "C|guestChannels","Non-home channels to idle in, comma-separated (ditto)",
                            &inputGuestChannels,
            "a|append",     "Append input home channels, guest channels and " ~
                            "admins instead of overriding",
                            &shouldAppendToArrays,
            "hideOutgoing", "Hide outgoing messages",
                            &settings.hideOutgoing,
            "hide",         &settings.hideOutgoing,
            "settings",     "Show all plugins' settings",
                            &shouldShowSettings,
            "show",         &shouldShowSettings,
            "bright",       "Adjust colours for bright terminal backgrounds",
                            &settings.brightTerminal,
            "brightTerminal",&settings.brightTerminal,
            "monochrome",   "Use monochrome output",
                            &settings.monochrome,
            "set",          "Manually change a setting (syntax: --set plugin.option=setting)",
                            &customSettings,
            "c|config",     "Specify a different configuration file [%s]"
                            .format(settings.configFile),
                            &settings.configFile,
            "r|resourceDir","Specify a different resource directory [%s]"
                            .format(settings.resourceDirectory),
                            &settings.resourceDirectory,
            "summary",      "Show a connection summary on program exit",
                            &settings.exitSummary,
            "force",        "Force connect (skips some sanity checks)",
                            &settings.force,
            "flush",        "Flush screen output after each write to it. " ~
                            "(Use this if the screen only occasionally updates.)",
                            &settings.flush,
            "w|writeconfig","Write configuration to file",
                            &shouldWriteConfig,
            "save",         &shouldWriteConfig,
            "init",         &shouldWriteConfig,
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
            printHelp(results);
            return Next.returnSuccess;
        }

        // Reinitialise the logger with new settings
        import kameloso.common : initLogger;
        initLogger(settings.monochrome, settings.brightTerminal, settings.flush);

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
        if (shouldWriteConfig)
        {
            // --writeconfig was passed; write configuration to file and quit
            writeConfig(instance, parser.client, parser.server, bot, customSettings);
            return Next.returnSuccess;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            printSettings(instance, customSettings);
            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}

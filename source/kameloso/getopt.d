/++
 +  Basic command-line argument-handling.
 +
 +  We employ the standard `std.getopt` to read arguments from the command line,
 +  and then use `lu.meld` to construct instances of the structs needed for the
 +  bot to function, like `dialect.defs.IRCClient`, `kameloso.common.IRCBot` and
 +  `kameloso.common.CoreSettings`.
 +
 +  Special care has to be taken with bools, as they have no unset state; only
 +  `true` or `false`. To ensure melding works we manually parse the arguments
 +  string after `std.getopt.getopt`, with `adjustGetopt`. It's a hack but it works.
 +
 +  See_Also:
 +      `lu.meld`
 +/
module kameloso.getopt;

import kameloso.common : CoreSettings, IRCBot, Kameloso;
import dialect.defs : IRCClient, IRCServer;
import lu.common : Next;
import std.typecons : No, Yes;

@safe:

private:

import std.getopt : GetoptResult;

// printHelp
/++
 +  Prints the `getopt` `helpWanted` help table to screen.
 +
 +  Merely leverages `defaultGetoptPrinter` for the printing.
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
            enum headertintColourBright = TerminalForeground.black.colour;
            enum headertintColourDark = TerminalForeground.white.colour;
            enum defaulttintColour = TerminalForeground.default_.colour;
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
 +      customSettings = Reference string array to all the custom settings set
 +          via `getopt`, to apply to things before saving to disk.
 +
 +  Returns:
 +      `kameloso.common.Next.returnSuccess` so the caller knows to return and exit.
 +/
Next writeConfig(ref Kameloso instance, ref IRCClient client, ref IRCServer server,
    ref IRCBot bot, ref string[] customSettings) @system
{
    import kameloso.common : logger, printVersionInfo, settings, writeConfigurationFile;
    import kameloso.constants : KamelosoDefaultStrings;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    // --writeconfig was passed; write configuration to file and quit

    string logtint, infotint, post;

    version(Colours)
    {
        import kameloso.terminal : TerminalForeground;

        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            import kameloso.terminal : colour;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            enum defaulttintColour = TerminalForeground.default_.colour;
            post = defaulttintColour;
        }
    }

    printVersionInfo(logtint, post);
    writeln();

    // If we don't initialise the plugins there'll be no plugins array
    instance.initPlugins(customSettings);

    // Take the opportunity to set a default quit reason. We can't do this in
    // applyDefaults because it's a perfectly valid use-case not to have a quit
    // string, and havig it there would enforce the default string if none present.
    if (!instance.bot.quitReason.length) instance.bot.quitReason = KamelosoDefaultStrings.quitReason;

    printObjects(client, instance.bot, server, settings);

    instance.writeConfigurationFile(settings.configFile);

    logger.logf("Configuration written to %s%s\n", infotint, settings.configFile);

    if (!instance.bot.admins.length && !instance.bot.homes.length)
    {
        import kameloso.common : complainAboutIncompleteConfiguration;
        logger.log("Edit it and make sure it contains at least one of the following:");
        complainAboutIncompleteConfiguration();
    }

    return Next.returnSuccess;
}


public:


// handleGetopt
/++
 +  Read command-line options and merge them with those in the configuration file.
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
 +      `kameloso.common.Next.continue_` or `kameloso.common.Next.returnSuccess`
 +      depending on whether the arguments chosen mean the program should
 +      proceed or not.
 +
 +  Throws:
 +      `std.getopt.GetOptException` if an unkown flag is passed.
 +/
Next handleGetopt(ref Kameloso instance, string[] args, out string[] customSettings) @system
{
    import kameloso.common : applyDefaults, printVersionInfo, settings;
    import lu.serialisation : readConfigInto;
    import std.format : format;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout, writeln;

    scope(exit) if (settings.flush) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldAppendChannels;

    string[] inputChannels;
    string[] inputHomes;

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

        settings.configFile.readConfigInto(parser.client, bot, parser.server, settings);
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
                            &bot.admins,
            "H|homes",      "Home channels to operate in, comma-separated " ~
                            "(escape or enquote any octothorpe #s)",
                            &inputHomes,
            "C|channels",   "Non-home channels to idle in, comma-separated (ditto)",
                            &inputChannels,
            "a|append",     "Append input homes and channels instead of overriding",
                            &shouldAppendChannels,
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
        if (shouldAppendChannels)
        {
            if (inputHomes.length) bot.homes ~= inputHomes;
            if (inputChannels.length) bot.channels ~= inputChannels;
        }
        else
        {
            if (inputHomes.length) bot.homes = inputHomes;
            if (inputChannels.length) bot.channels = inputChannels;
        }

        // Strip channel whitespace and make lowercase
        import lu.string : stripped;
        import std.algorithm.iteration : map;
        import std.array : array;
        import std.uni : toLower;

        bot.channels = bot.channels
            .map!(channelName => channelName.stripped.toLower)
            .array;
        bot.homes = bot.homes
            .map!(channelName => channelName.stripped.toLower)
            .array;

        // Clear entries that are dashes
        import lu.objmanip : zeroMembers;

        zeroMembers!"-"(parser.client);
        zeroMembers!"-"(bot);

        // Handle showstopper arguments (that display something and then exits)
        if (shouldWriteConfig)
        {
            // --writeconfig was passed; write configuration to file and quit
            return writeConfig(instance, parser.client, parser.server, bot, customSettings);
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            import kameloso.printing : printObjects;

            string pre, post;

            version(Colours)
            {
                import kameloso.terminal : TerminalForeground, colour;

                if (!settings.monochrome)
                {
                    enum headertintColourBright = TerminalForeground.black.colour;
                    enum headertintColourDark = TerminalForeground.white.colour;
                    enum defaulttintColour = TerminalForeground.default_.colour;
                    pre = settings.brightTerminal ? headertintColourBright : headertintColourDark;
                    post = defaulttintColour;
                }
            }

            printVersionInfo(pre, post);
            writeln();

            printObjects!(No.printAll)(parser.client, bot, parser.server, settings);

            instance.initPlugins(customSettings);

            foreach (plugin; instance.plugins) plugin.printSettings();

            return Next.returnSuccess;
        }

        return Next.continue_;
    }
}

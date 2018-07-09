/++
 +  Basic command-line argument-handling.
 +/
module kameloso.getopt;

import kameloso.common : CoreSettings, Client;
import kameloso.ircdefs : IRCBot;
import std.typecons : Flag, No, Yes;

@safe:

private:


// meldSettingsFromFile
/++
 +  Read `kameloso.common.CoreSettings` and `kameloso.ircdefs.IRCBot` from file
 +  into temporaries, then meld them into the real ones, into which the
 +  command-line arguments will have been applied.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  CoreSettings settings;
 +
 +  meldSettingsFromFile(bot, settings);
 +  ---
 +
 +  Params:
 +      bot = Reference `kameloso.ircdefs.IRCBot` to apply changes to.
 +      setttings = Reference `kameloso.common.CoreSettings` to apply changes
 +          to.
 +/
void meldSettingsFromFile(ref IRCBot bot, ref CoreSettings settings)
{
    import kameloso.config : readConfigInto;
    import kameloso.meld : meldInto;

    IRCBot tempBot;
    CoreSettings tempSettings;

    // These arguments are by reference.
    settings.configFile.readConfigInto(tempBot, tempBot.server, tempSettings);

    bot.meldInto!(Yes.overwrite)(tempBot);
    settings.meldInto!(Yes.overwrite)(tempSettings);

    bot = tempBot;
    settings = tempSettings;
}


public:


// handleGetopt
/++
 +  Read command-line options and merge them with those in the configuration
 +  file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded
 +  defaults.
 +
 +  Example:
 +  ---
 +  Client client;
 +  Flag!"quit" quit = client.handleGetopt(args);
 +
 +  if (quit) return 0;
 +  // ...
 +  ---
 +
 +  Params:
 +      client = Reference to the current `kameloso.common.Client`.
 +      args = The `string[]` args the program was called with.
 +      customSettings = Refernce array of custom settings to apply on top of
 +          the settings read from the configuration file.
 +
 +  Returns:
 +      `Yes.quit` or `No.quit` depending on whether the arguments chosen mean
 +      the program should proceed or not.
 +/
Flag!"quit" handleGetopt(ref Client client, string[] args, ref string[] customSettings) @system
{
    import kameloso.bash : BashForeground;
    import kameloso.common : initLogger, printObjects, printVersionInfo, settings;
    import std.format : format;
    import std.getopt;
    import std.stdio : stdout, writeln;

    version(Cygwin_)
    scope(exit) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;
    bool shouldAppendChannels;

    bool monochromeFromArgs;
    bool monochromeWasSet;
    bool brightTerminalFromArgs;
    bool brightTerminalWasSet;

    string[] inputChannels;
    string[] inputHomes;

    void boolWrapper(const string setting, const string value)
    {
        import std.conv : to;

        /+  Due to how melding works, bools need a hack to be able to overwrite
            a command-line false over a config file true.
            These are the only getopt bools currently. +/

        if (setting == "monochrome")
        {
            monochromeFromArgs = value.to!bool;
            monochromeWasSet = true;
        }
        else if (setting == "bright")
        {
            brightTerminalFromArgs = value.to!bool;
            brightTerminalWasSet = true;
        }
        else
        {
            assert(0);
        }
    }

    arraySep = ",";

    with (client)
    with (client.parser)
    {
        auto results = args.getopt(
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Bot nickname", &bot.nickname,
            "s|server",     "Server address", &bot.server.address,
            "P|port",       "Server port", &bot.server.port,
            "A|account",    "Services account login name, if applicable", &bot.authLogin,
            "auth",         &bot.authLogin,
            "p|password",   "Services account password", &bot.authPassword,
            "authpassword", &bot.authPassword,
            "pass",         "Registration password (not auth or services)", &bot.pass,
            "admins",       "Services accounts of the bot's administrators", &bot.admins,
            "H|homes",      "Home channels to operate in, comma-separated " ~
                            "(remember to escape or enquote the octothorpe #s!)", &inputHomes,
            "C|channels",   "Non-home channels to idle in, comma-separated (ditto)", &inputChannels,
            "a",            "Append input homes and channels instead of overriding", &shouldAppendChannels,
            "settings",     "Show all plugins' settings", &shouldShowSettings,
            "show",         &shouldShowSettings,
            "bright",       "Bright terminal colour setting",
                            &boolWrapper,
            "monochrome",   "Use monochrome output", &boolWrapper,
            "set",          "Manually change a setting (--set plugin.option=setting)", &customSettings,
            "asserts",      "[DEBUG] Parse an IRC event string and generate an assert block",
                            &shouldGenerateAsserts,
            "gen",          &shouldGenerateAsserts,
            "c|config",     "Read configuration from file (default %s)"
                                .format(CoreSettings.init.configFile), &settings.configFile,
            "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
            "writeconf",    &shouldWriteConfig,
            "version",      "Show version information", &shouldShowVersion,
        );

        meldSettingsFromFile(bot, settings);

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

        // Clear entries that are dashes.
        import kameloso.objmanip : zeroMembers;
        zeroMembers!"-"(bot);

        client.parser.bot = bot;

        if (monochromeWasSet) settings.monochrome = monochromeFromArgs;
        if (brightTerminalWasSet) settings.brightTerminal = brightTerminalFromArgs;

        // Give common.d a copy of CoreSettings for printObject. FIXME
        static import kameloso.common;
        kameloso.common.settings = settings;

        // We know CoreSettings now so reinitialise the logger
        initLogger(settings.monochrome, settings.brightTerminal);

        if (results.helpWanted)
        {
            // --help|-h was passed; show the help table and quit

            BashForeground headerTint = BashForeground.default_;

            version (Colours)
            {
                if (!settings.monochrome)
                {
                    headerTint = settings.brightTerminal ?
                        BashForeground.black : BashForeground.white;
                }
            }

            printVersionInfo(headerTint);
            writeln();

            string headline = "Command-line arguments available:\n";

            version (Colours)
            {
                import kameloso.bash : colour;

                if (!settings.monochrome)
                {
                    immutable headlineTint = settings.brightTerminal ?
                        BashForeground.green : BashForeground.lightgreen;
                    headline = headline.colour(headlineTint);
                }
            }

            defaultGetoptPrinter(headline, results.options);
            writeln();
            return Yes.quit;
        }

        if (shouldShowVersion)
        {
            // --version was passed; show info and quit
            printVersionInfo();
            return Yes.quit;
        }

        if (shouldWriteConfig)
        {
            import kameloso.common : logger, writeConfigurationFile;

            // --writeconfig was passed; write configuration to file and quit
            printVersionInfo(BashForeground.white);
            writeln();

            logger.info("Writing configuration to ", settings.configFile);
            writeln();

            // If we don't initialise the plugins there'll be no plugins array
            initPlugins(customSettings);

            client.writeConfigurationFile(settings.configFile);

            // Reload saved file
            meldSettingsFromFile(bot, settings);

            printObjects(bot, bot.server, settings);

            return Yes.quit;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            printVersionInfo(BashForeground.white);
            writeln();

            printObjects!(No.printAll)(bot, bot.server, settings);

            initPlugins(customSettings);

            foreach (plugin; plugins) plugin.printSettings();

            return Yes.quit;
        }

        if (shouldGenerateAsserts)
        {
            import kameloso.common : logger, printObject;
            import kameloso.debugging : generateAsserts;
            import kameloso.irc : IRCParseException;

            // --gen|--generate was passed, enter assert generation
            try client.generateAsserts();
            catch (const IRCParseException e)
            {
                logger.error(e.msg);
                printObject(e.event);
            }

            return Yes.quit;
        }

        return No.quit;
    }
}

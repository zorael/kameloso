module kameloso.getopt;

import kameloso.common : CoreSettings, Client;
import kameloso.ircdefs : IRCBot;
import std.typecons : Flag, No, Yes;

import std.stdio;

private:


// meldSettingsFromFile
/++
 +  Read core settings, and IRCBot from file into temporaries, then meld them
 +  into the real ones into which the command-line arguments wil have been
 +  applied.
 +
 +  Params:
 +      ref bot = the IRCBot bot apply all changes to.
 +      ref setttings = the core settings to apply changes to.
 +
 +  ------------
 +  IRCBot bot;
 +  CoreSettings settings;
 +
 +  meldSettingsFromFile(bot, settings);
 +  ------------
 +/
void meldSettingsFromFile(ref IRCBot bot, ref CoreSettings settings)
{
    import kameloso.common : meldInto;
    import kameloso.config : readConfigInto;

    IRCBot botFromConfig;
    CoreSettings settingsFromConfig;

    // These arguments are by reference.
    settings.configFile.readConfigInto(botFromConfig,
        botFromConfig.server, settingsFromConfig);

    botFromConfig.meldInto(bot);
    settingsFromConfig.meldInto(settings);
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
 +  Params:
 +      The string[] args the program was called with.
 +
 +  Returns:
 +      Yes.quit or no depending on whether the arguments chosen mean the
 +      program should proceed or not.
 +
 +  ------------
 +  Client client;
 +  Flag!"quit" quit = client.handleGetopt(args);
 +
 +  if (quit) return 0;
 +  // ...
 +  ------------
 +/
Flag!"quit" handleGetopt(ref Client client, string[] args, ref string[] customSettings)
{
    import kameloso.bash : BashForeground, colour;
    import kameloso.common : initLogger, printObjects, printVersionInfo;
    import std.format : format;
    import std.getopt;

    version(Cygwin_)
    scope(exit) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;

    arraySep = ",";

    with (client)
    {
        auto results = args.getopt(
            config.caseSensitive,
            "n|nickname",    "Bot nickname", &bot.nickname,
            "u|user",        "Username when registering onto server (not nickname)",
                &bot.user,
            "i|ident",       "IDENT string", &bot.ident,
            "pass",          "Registration password (not auth or nick services)",
                &bot.pass,
            "a|auth",        "Services account login name, if applicable",
                &bot.authLogin,
            "account",       &bot.authLogin,
            "p|authpassword","Services account password", &bot.authPassword,
            "password",      &bot.authPassword,
            "m|master",      "Services account of the bot's master, who gets " ~
                             "access to administrative functions", &bot.master,
            "H|home",        "Home channels to operate in, comma-separated" ~
                            " (remember to escape or enquote the #s!)", &bot.homes,
            "C|channel",     "Non-home channels to idle in, comma-separated" ~
                            " (ditto)", &bot.channels,
            "s|server",      "Server address", &bot.server.address,
            "P|port",        "Server port", &bot.server.port,
            "settings",      "Show all plugins' settings", &shouldShowSettings,
            "c|config",      "Read configuration from file (default %s)"
                                .format(CoreSettings.init.configFile), &settings.configFile,
            "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
            "writeconf",     &shouldWriteConfig,
            "version",       "Show version info", &shouldShowVersion,
            "generateAsserts","(DEBUG) Parse an IRC event string and generate an assert block",
                             &shouldGenerateAsserts,
            "gen",           &shouldGenerateAsserts,
            "bright",        "Bright terminal colour setting (BETA)",
                             &settings.brightTerminal,
            "set",           "Manually change a setting (--set plugin.option=setting)",
                             &customSettings,
        );

        meldSettingsFromFile(bot, settings);
        client.parser.bot = bot;

        // Give common.d a copy of CoreSettings for printObject. FIXME
        static import kameloso.common;
        kameloso.common.settings = settings;

        // We know CoreSettings now so reinitialise the logger
        initLogger(settings.monochrome, settings.brightTerminal);

        if (results.helpWanted)
        {
            // --help|-h was passed; show the help table and quit

            BashForeground headerTint;

            version (Colours)
            {
                if (!settings.monochrome)
                {
                    headerTint = settings.brightTerminal ?
                        BashForeground.black : BashForeground.white;
                }
                else
                {
                    headerTint = BashForeground.default_;
                }
            }
            else
            {
                headerTint = BashForeground.default_;
            }

            printVersionInfo(headerTint);
            writeln();

            string headline = "Command-line arguments available:\n";

            version (Colours)
            {
                immutable headlineTint = settings.brightTerminal ?
                    BashForeground.green : BashForeground.lightgreen;
                headline = headline.colour(headlineTint);
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

            logger.info("Writing configuration to ", settings.configFile);
            writeln();

            // If we don't initialise the plugins there'll be no plugins array
            initPlugins();

            printObjects(bot, bot.server, settings);

            foreach (plugin; plugins)
            {
                // Not all plugins with configuration is important enough to list, so
                // not all will have something to present()
                plugin.present();
            }

            client.writeConfigurationFile(settings.configFile);
            return Yes.quit;
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            printVersionInfo(BashForeground.white);
            writeln();

            // FIXME: Hardcoded width
            enum width = 18;
            printObjects!width(bot, bot.server, settings);

            initPlugins();
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

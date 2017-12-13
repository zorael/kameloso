module kameloso.getopt;

import kameloso.common : CoreSettings, Client, logger;
import kameloso.irc : IRCBot;
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


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Params:
 +      filename = the string filename of the file to write to.
 +
 +  ------------
 +  Client client;
 +  client.writeConfigurationFile(client.settings.configFile);
 +  ------------
 +/
void writeConfigurationFile(ref Client client, const string filename)
{
    import kameloso.common : printObjects;
    import kameloso.config : justifiedConfigurationText, serialise, writeToDisk;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(512);

    with (client)
    {
        sink.serialise(bot, bot.server, settings);

        printObjects(bot, bot.server, settings);

        foreach (plugin; plugins)
        {
            plugin.addToConfig(sink);
            // Not all plugins with configuration is important enough to list, so
            // not all will have something to present()
            plugin.present();
        }

        immutable justified = sink.data.justifiedConfigurationText;
        writeToDisk!(Yes.addBanner)(filename, justified);
    }
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
Flag!"quit" handleGetopt(ref Client client, string[] args)
{
    import kameloso.bash : BashForeground, colour;
    import kameloso.common : initLogger, printVersionInfo;
    import std.format : format;
    import std.getopt;

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
            "a|auth",        "Auth service login name, if applicable",
                &bot.authLogin,
            "p|authpassword","Auth service password", &bot.authPassword,
            "m|master",      "Auth login of the bot's master, who gets " ~
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
            // --writeconfig was passed; write configuration to file and quit
            printVersionInfo(BashForeground.white);

            logger.info("Writing configuration to ", settings.configFile);
            writeln();

            // If we don't initialise the plugins there'll be no plugins array
            initPlugins();

            client.writeConfigurationFile(settings.configFile);
            return Yes.quit;
        }

        if (shouldShowSettings)
        {
            import kameloso.common : printObjects;

            // --settings was passed, show all options and quit
            printVersionInfo(BashForeground.white);
            writeln();

            // FIXME: Hardcoded width
            printObjects!18(bot, bot.server, settings);

            initPlugins();
            foreach (plugin; plugins) plugin.printSettings();

            return Yes.quit;
        }

        if (shouldGenerateAsserts)
        {
            import kameloso.debugging : generateAsserts;

            // --gen|--generate was passed, enter assert generation
            client.generateAsserts();
            return Yes.quit;
        }

        return No.quit;
    }
}

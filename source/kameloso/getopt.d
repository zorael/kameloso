/++
 +  Basic command-line argument-handling.
 +/
module kameloso.getopt;

import kameloso.common : CoreSettings, IRCBot, Next;
import kameloso.irc : Client;
import std.typecons : Flag, No, Yes;

@safe:

private:


// meldSettingsFromFile
/++
 +  Read `kameloso.common.CoreSettings` and `kameloso.irc.Client` from file into
 +  temporaries, then meld them into the real ones, into which the command-line
 +  arguments will have been applied.
 +
 +  Example:
 +  ---
 +  Client client;
 +  CoreSettings settings;
 +
 +  meldSettingsFromFile(client, settings);
 +  ---
 +
 +  Params:
 +      client = Reference `kameloso.irc.Client` to apply changes to.
 +      setttings = Reference `kameloso.common.CoreSettings` to apply changes
 +          to.
 +/
void meldSettingsFromFile(ref Client client, ref CoreSettings settings)
{
    import kameloso.config : readConfigInto;
    import kameloso.meld : MeldingStrategy, meldInto;

    Client tempClient;
    CoreSettings tempSettings;

    // These arguments are by reference.
    // 1. Read arguments into client
    // 2. Read settings into temporary client
    // 3. Meld arguments *into* temporary client, overwriting
    // 4. Inherit temporary client into client
    settings.configFile.readConfigInto(tempClient, tempClient.server, tempSettings);

    client.meldInto!(MeldingStrategy.aggressive)(tempClient);
    settings.meldInto!(MeldingStrategy.aggressive)(tempSettings);

    client = tempClient;
    settings = tempSettings;
}


// ajustGetopt
/++
 +  Adjust values set by getopt, by looking for setting strings in the `args`
 +  `string[]` and manually overriding melded values with them.
 +
 +  The way we meld settings is weak against false settings when they are also
 +  the default values of a member. There's no way to tell apart an unset bool
 +  an unset bool from a false one. They will be overwritten by any true value
 +  from the configuration file.
 +
 +  As such, manually parse a backup `args` and look for some passed strings,
 +  then override the variable that was set thus accordingly.
 +
 +  Params:
 +      args = Arguments passed to the program upon invocation.
 +      option = String option in long `--long` or short `-s` form, including
 +          dashes, with an equals sign between option name and value if
 +          applicable (in all cases except bools).
 +      rest = Remaining `args` and `option` s to call recursively.
 +/
void adjustGetopt(T, Rest...)(const string[] args, const string option, T* ptr, Rest rest)
{
    import kameloso.string : beginsWith, contains;
    import std.algorithm.iteration : filter;

    static assert((!Rest.length || (Rest.length % 2 == 0)),
        "adjustGetopt must be called with string option, value pointer pairs");

    foreach (immutable arg; args.filter!(word => word.beginsWith(option)))
    {
        string slice = arg;  // mutable

        if (arg.contains('='))
        {
            import kameloso.string : nom;
            import std.conv : to;

            immutable realWord = slice.nom('=');
            if (realWord != option) continue;
            *ptr = slice.to!T;
        }
        else static if (is(T == bool))
        {
            if (arg != option) continue;
            *ptr = true;
        }
        else
        {
            import std.getopt : GetOptException;
            import std.format : format;
            throw new GetOptException("No %s value passed to %s".format(T.stringof, option));
        }
    }

    static if (rest.length)
    {
        return adjustGetopt(args, rest);
    }
}

///
unittest
{
    string[] args =
    [
        "./kameloso", "--monochrome",
        "--server=irc.freenode.net",
        //"--nickname", "kameloso"  // Not supported under the current design
    ];

    struct S
    {
        bool monochrome;
        string server;
        string nickname;
    }

    S s;

    args.adjustGetopt(
        //"--nickname", &s.nickname,
        "--server", &s.server,
        "--monochrome", &s.monochrome,
    );

    assert(s.monochrome);
    assert((s.server == "irc.freenode.net"), s.server);
    //assert((s.nickname == "kameloso"), s.nickname);
}


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
 +      results = Results from a `getopt` call, usually with `.helpWanted` true.
 +
 +  Returns:
 +      `Next.returnSuccess` to make sure the calling function returns.
 +/
import std.getopt : GetoptResult;
Next printHelp(GetoptResult results) @system
{
    import kameloso.common : printVersionInfo, settings;
    import std.stdio : writeln;

    string pre, post;

    version(Colours)
    {
        import kameloso.bash : BashForeground, colour;

        if (!settings.monochrome)
        {
            immutable headertint = settings.brightTerminal ? BashForeground.black : BashForeground.white;
            immutable defaulttint = BashForeground.default_;
            pre = headertint.colour;
            post = defaulttint.colour;
        }
    }

    printVersionInfo(pre, post);
    writeln();

    string headline = "Command-line arguments available:\n";

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.bash : BashForeground, colour;

            immutable headlineTint = settings.brightTerminal ? BashForeground.green : BashForeground.lightgreen;
            headline = headline.colour(headlineTint);
        }
    }

    import std.getopt : defaultGetoptPrinter;
    defaultGetoptPrinter(headline, results.options);
    writeln();
    writeln("A dash (-) clears, so -C- translates to no channels, -A- to no account, etc.");
    writeln();
    return Next.returnSuccess;
}


// writeConfig
/++
 +  Writes configuration to file, verbosely.
 +
 +  The filename is read from `kameloso.common.settings`.
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      client = Reference to the current `kameloso.irc.Client`.
 +      customSettings = Reference string array to all the custom settings set
 +          via `getopt`, to apply to things before saving to disk.
 +
 +  Returns:
 +      `Next.returnSuccess` so the caller knows to return and exit.
 +/
Next writeConfig(ref IRCBot bot, ref Client client, ref string[] customSettings) @system
{
    import kameloso.common : logger, printVersionInfo, settings, writeConfigurationFile;
    import kameloso.printing : printObjects;
    import std.stdio : writeln;

    // --writeconfig was passed; write configuration to file and quit

    string logtint, infotint, post;

    version(Colours)
    {
        import kameloso.bash : BashForeground;

        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;
            import kameloso.bash : colour;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
            immutable defaulttint = BashForeground.default_;
            post = defaulttint.colour;
        }
    }

    printVersionInfo(logtint, post);
    writeln();

    // If we don't initialise the plugins there'll be no plugins array
    bot.initPlugins(customSettings);

    bot.writeConfigurationFile(settings.configFile);

    // Reload saved file
    meldSettingsFromFile(client, settings);

    printObjects(client, client.server, settings);

    logger.logf("Configuration written to %s%s", infotint, settings.configFile);

    if (!client.admins.length && !client.homes.length)
    {
        import kameloso.common : complainAboutIncompleteConfiguration;
        logger.log("Edit it and make sure it has entries for at least one of the following:");
        complainAboutIncompleteConfiguration();
    }

    return Next.returnSuccess;
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
 +  IRCBot bot;
 +  Next next = bot.handleGetopt(args);
 +
 +  if (next == Next.returnSuccess) return 0;
 +  // ...
 +  ---
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      args = The `string[]` args the program was called with.
 +      customSettings = Refernce array of custom settings to apply on top of
 +          the settings read from the configuration file.
 +
 +  Returns:
 +      `Next.continue_` or `Next.returnSuccess` depending on whether the
 +      arguments chosen mean the program should proceed or not.
 +/
Next handleGetopt(ref IRCBot bot, string[] args, ref string[] customSettings) @system
{
    import kameloso.common : printVersionInfo, settings;
    import std.format : format;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout, writeln;

    version(Cygwin_)
    scope(exit) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;
    bool shouldAppendChannels;

    string[] inputChannels;
    string[] inputHomes;

    debug
    {
        enum genDescription = "[DEBUG] Parse an IRC event string and generate an assert block";
    }
    else
    {
        enum genDescription = "(Unavailable in non-debug builds)";
    }

    immutable argsBackup = args.idup;

    arraySep = ",";

    with (bot.parser)
    {
        auto results = args.getopt(
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Bot nickname",
                            &client.nickname,
            "s|server",     "Server address",
                            &client.server.address,
            "P|port",       "Server port",
                            &client.server.port,
            "6|ipv6",       "Use IPv6 when available",
                            &settings.ipv6,
            "A|account",    "Services account login name, if applicable",
                            &client.authLogin,
            "auth",         &client.authLogin,
            "p|password",   "Services account password",
                            &client.authPassword,
            "authPassword", &client.authPassword,
            "pass",         "Registration password (not auth or services)",
                            &client.pass,
            "admins",       "Services accounts of the bot's administrators",
                            &client.admins,
            "H|homes",      "Home channels to operate in, comma-separated " ~
                            "(remember to escape or enquote the octothorpe #s!)",
                            &inputHomes,
            "C|channels",   "Non-home channels to idle in, comma-separated (ditto)",
                            &inputChannels,
            "a",            "Append input homes and channels instead of overriding",
                            &shouldAppendChannels,
            "hideOutgoing", "Hide outgoing messages",
                            &settings.hideOutgoing,
            "hide",         &settings.hideOutgoing,
            "settings",     "Show all plugins' settings",
                            &shouldShowSettings,
            "show",         &shouldShowSettings,
            "bright",       "Bright terminal colour setting",
                            &settings.brightTerminal,
            "brightTerminal", &settings.brightTerminal,
            "monochrome",   "Use monochrome output",
                            &settings.monochrome,
            "set",          "Manually change a setting (--set plugin.option=setting)",
                            &customSettings,
            "asserts",      genDescription,
                            &shouldGenerateAsserts,
            "gen",          &shouldGenerateAsserts,
            "c|config",     "Specify a different configuration file [%s]"
                            .format(settings.configFile),
                            &settings.configFile,
            "r|resourceDir","Specify a different resource directory [%s]"
                            .format(settings.resourceDirectory),
                            &settings.resourceDirectory,
            "w|writeconfig","Write configuration to file",
                            &shouldWriteConfig,
            "writeconf",    &shouldWriteConfig,
            "init",         &shouldWriteConfig,
            "version",      "Show version information",
                            &shouldShowVersion,
        );

        /+
            1. Populate `client` and `settings` with getopt (above)
            2. Meld with settings from file
            3. Adjust members `monochrome` and `brightTerminal` to counter the
               fact that melding doesn't work well with bools that don't have
               an "unset" state
            4. Reinitialise the logger with new settings
         +/

        meldSettingsFromFile(client, settings);
        adjustGetopt(argsBackup,
            "--bright", &settings.brightTerminal,
            "--brightTerminal", &settings.brightTerminal,
            "--monochrome", &settings.monochrome,
        );

        import kameloso.common : initLogger;
        initLogger(settings.monochrome, settings.brightTerminal);

        // 5. Give common.d a copy of `settings` for `printObject`
        static import kameloso.common;
        kameloso.common.settings = settings;

        // 6. Maybe show help
        if (results.helpWanted)
        {
            // --help|-h was passed; show the help table and quit
            return printHelp(results);
        }

        // 7. Manually override or append channels, depending on `shouldAppendChannels`
        if (shouldAppendChannels)
        {
            if (inputHomes.length) client.homes ~= inputHomes;
            if (inputChannels.length) client.channels ~= inputChannels;
        }
        else
        {
            if (inputHomes.length) client.homes = inputHomes;
            if (inputChannels.length) client.channels = inputChannels;
        }

        // 8. Clear entries that are dashes
        import kameloso.objmanip : zeroMembers;
        zeroMembers!"-"(client);

        // 7. `client` finished; inherit into `client`
        bot.parser.client = client;

        // 9. Handle showstopper arguments (that display something and then exits)
        if (shouldShowVersion)
        {
            // --version was passed; show info and quit
            printVersionInfo();
            return Next.returnSuccess;
        }

        if (shouldWriteConfig)
        {
            // --writeconfig was passed; write configuration to file and quit
            return writeConfig(bot, client, customSettings);
        }

        if (shouldShowSettings)
        {
            // --settings was passed, show all options and quit
            import kameloso.printing : printObjects;

            string pre, post;

            version(Colours)
            {
                import kameloso.bash : BashForeground, colour;

                if (!settings.monochrome)
                {
                    immutable headertint = settings.brightTerminal ? BashForeground.black : BashForeground.white;
                    immutable defaulttint = BashForeground.default_;
                    pre = headertint.colour;
                    post = defaulttint.colour;
                }
            }

            printVersionInfo(pre, post);
            writeln();

            printObjects!(No.printAll)(client, client.server, settings);

            bot.initPlugins(customSettings);

            foreach (plugin; bot.plugins) plugin.printSettings();

            return Next.returnSuccess;
        }

        debug if (shouldGenerateAsserts)
        {
            // --gen|--generate was passed, enter assert generation
            import kameloso.debugging : generateAsserts;
            bot.generateAsserts();
            return Next.returnSuccess;
        }

        // No showstopper arguments passed; return and continue connecting
        return Next.continue_;
    }
}

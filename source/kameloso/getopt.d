/++
 +  Basic command-line argument-handling.
 +/
module kameloso.getopt;

import kameloso.common : CoreSettings, IRCBot, Kameloso;
import dialect.defs : IRCClient;
import lu.common : Next;
import std.typecons : No, Yes;

@safe:

private:


// meldSettingsFromFile
/++
 +  Read `kameloso.common.CoreSettings` and `dialect.defs.IRCClient` from file
 +  into temporaries, then meld them into the real ones, into which the
 +  command-line arguments will have been applied.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCBot bot;
 +  CoreSettings settings;
 +
 +  meldSettingsFromFile(client, bot, settings);
 +  ---
 +
 +  Params:
 +      client = Reference `dialect.defs.IRCClient` to apply changes to.
 +      bot = Reference `kameloso.common.IRCBot` to apply changes to.
 +      settings = Reference `kameloso.common.CoreSettings` to apply changes to.
 +/
void meldSettingsFromFile(ref IRCClient client, ref IRCBot bot, ref CoreSettings settings)
{
    import lu.meld : MeldingStrategy, meldInto;
    import lu.serialisation : readConfigInto;

    IRCClient tempClient;
    IRCBot tempBot;
    CoreSettings tempSettings;

    // These arguments are by reference.
    // 1. Read arguments into client
    // 2. Read settings into temporary client
    // 3. Meld arguments *into* temporary client, overwriting
    // 4. Inherit temporary client into client
    settings.configFile.readConfigInto(tempClient, tempBot, tempClient.server, tempSettings);

    client.meldInto!(MeldingStrategy.aggressive)(tempClient);
    bot.meldInto!(MeldingStrategy.aggressive)(tempBot);
    settings.meldInto!(MeldingStrategy.aggressive)(tempSettings);

    client = tempClient;
    bot = tempBot;
    settings = tempSettings;
}


// adjustGetopt
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
 +      ptr = Pointer to the value to modify.
 +      rest = Remaining `args` and `option` s to call recursively.
 +
 +  Throws: `std.getopt.GetOptException` if no value of type T was passed to
 +      option taking type T.
 +/
void adjustGetopt(T, Rest...)(const string[] args, const string option, T* ptr, Rest rest)
{
    import lu.string : beginsWith, contains;
    import std.algorithm.iteration : filter;

    static assert((!Rest.length || (Rest.length % 2 == 0)),
        "adjustGetopt must be called with string option, value pointer pairs");

    foreach (immutable arg; args.filter!(word => word.beginsWith(option)))
    {
        string slice = arg;  // mutable

        if (arg.contains('='))
        {
            import lu.string : nom;

            immutable realWord = slice.nom('=');
            if (realWord != option) continue;

            static if (is(T == enum))
            {
                import lu.conv : Enum;
                *ptr = Enum!T.fromString(slice);
            }
            else
            {
                import std.conv : to;
                *ptr = slice.to!T;
            }
        }
        else static if (is(T == bool))
        {
            if (arg != option) continue;
            *ptr = true;
        }
        else
        {
            import std.format : format;
            import std.getopt : GetOptException;
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
        "--banana=def",
    ];

    struct S
    {
        enum E { abc, def, ghi, }
        bool monochrome;
        string server;
        string nickname;
        E banana;
    }

    S s;

    args.adjustGetopt(
        //"--nickname", s.nickname,
        "--server", &s.server,
        "--monochrome", &s.monochrome,
        "--banana", &s.banana,
    );

    import lu.conv : Enum;

    assert(s.monochrome);
    assert((s.server == "irc.freenode.net"), s.server);
    assert((s.banana == S.E.def), Enum!(S.E).toString(s.banana));
    //assert((s.nickname == "kameloso"), s.nickname);
}


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
 +      bot = Reference to the current `kameloso.common.IRCBot`.
 +      customSettings = Reference string array to all the custom settings set
 +          via `getopt`, to apply to things before saving to disk.
 +
 +  Returns:
 +      `kameloso.common.Next.returnSuccess` so the caller knows to return and exit.
 +/
Next writeConfig(ref Kameloso instance, ref IRCClient client, ref IRCBot bot,
    ref string[] customSettings) @system
{
    import kameloso.common : logger, completeClient, printVersionInfo,
        settings, writeConfigurationFile;
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

    // Fill out some empty fields
    completeClient(client);

    import kameloso.constants : KamelosoDefaultStrings;
    if (!instance.bot.quitReason.length) instance.bot.quitReason = KamelosoDefaultStrings.quitReason;

    instance.writeConfigurationFile(settings.configFile);

    // Reload saved file
    meldSettingsFromFile(client, bot, settings);

    printObjects(client, instance.bot, client.server, settings);

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
 +      customSettings = Reference array of custom settings to apply on top of
 +          the settings read from the configuration file.
 +
 +  Returns:
 +      `kameloso.common.Next.continue_` or `kameloso.common.Next.returnSuccess`
 +      depending on whether the arguments chosen mean the program should
 +      proceed or not.
 +
 +  Throws:
 +      `std.getopt.GetOptException` if `--asserts`/`--gen` is passed in non-debug builds.
 +/
Next handleGetopt(ref Kameloso instance, string[] args, ref string[] customSettings) @system
{
    import kameloso.common : completeClient, printVersionInfo, settings;
    import std.format : format;
    import std.getopt : arraySep, config, getopt;
    import std.stdio : stdout, writeln;

    scope(exit) if (settings.flush) stdout.flush();

    bool shouldWriteConfig;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldGenerateAsserts;
    bool shouldAppendChannels;

    string[] inputChannels;
    string[] inputHomes;

    version(AssertsGeneration)
    {
        enum genDescription = "Parse an IRC event string and generate an assert block";
    }
    else
    {
        enum genDescription = "(Unavailable in non-dev builds)";
    }

    immutable argsBackup = args.idup;

    arraySep = ",";

    with (instance)
    {
        auto results = args.getopt(
            config.caseSensitive,
            config.bundling,
            "n|nickname",   "Nickname",
                            &parser.client.nickname,
            "s|server",     "Server address [%s]".format(parser.client.server.address),
                            &parser.client.server.address,
            "P|port",       "Server port [%d]".format(parser.client.server.port),
                            &parser.client.server.port,
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
            "force",        "Force connect (skips some sanity checks)",
                            &settings.force,
            "w|writeconfig","Write configuration to file",
                            &shouldWriteConfig,
            "save",         &shouldWriteConfig,
            "init",         &shouldWriteConfig,
            "asserts",      genDescription,
                            &shouldGenerateAsserts,
            "gen",          &shouldGenerateAsserts,
            "version",      "Show version information",
                            &shouldShowVersion,
        );

        if (shouldShowVersion)
        {
            // --version was passed; show version info and quit
            printVersionInfo();
            return Next.returnSuccess;
        }
        else if (results.helpWanted)
        {
            // --help|-h was passed; show the help table and quit
            printHelp(results);
            return Next.returnSuccess;
        }

        /+
            1. Populate `client` and `settings` with getopt (above)
            2. Meld with settings from file
            3. Adjust members `monochrome` and `brightTerminal` to counter the
               fact that melding doesn't work well with bools that don't have
               an "unset"/null state
            4. Reinitialise the logger with new settings
         +/

        meldSettingsFromFile(parser.client, instance.bot, settings);
        completeClient(parser.client);
        adjustGetopt(argsBackup,
            "--bright", &settings.brightTerminal,
            "--brightTerminal", &settings.brightTerminal,
            "--monochrome", &settings.monochrome,
        );

        import kameloso.common : initLogger;
        initLogger(settings.monochrome, settings.brightTerminal, settings.flush);

        // 5. Give common.d a copy of `settings`, for `printObject` and for plugins
        static import kameloso.common;
        kameloso.common.settings = settings;

        // 6. Manually override or append channels, depending on `shouldAppendChannels`
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

        // 6a. Strip whitespace
        import lu.string : stripped;
        import std.algorithm.iteration : map;
        import std.array : array;

        bot.channels = bot.channels.map!((ch) => ch.stripped).array;
        bot.homes = bot.homes.map!((ch) => ch.stripped).array;

        // 7. Clear entries that are dashes
        import lu.objmanip : zeroMembers;
        zeroMembers!"-"(parser.client);
        zeroMembers!"-"(bot);

        // 8. Make channels lowercase
        import std.algorithm.iteration : map;
        import std.array : array;
        import std.uni : toLower;

        bot.homes = bot.homes
            .map!(channelName => channelName.toLower)
            .array;

        bot.channels = bot.channels
            .map!(channelName => channelName.toLower)
            .array;

        // 9. Handle showstopper arguments (that display something and then exits)
        if (shouldWriteConfig)
        {
            // --writeconfig was passed; write configuration to file and quit
            return writeConfig(instance, parser.client, bot, customSettings);
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

            printObjects!(No.printAll)(parser.client, bot, parser.client.server, settings);

            instance.initPlugins(customSettings);

            foreach (plugin; instance.plugins) plugin.printSettings();

            return Next.returnSuccess;
        }

        if (shouldGenerateAsserts)
        {
            version(AssertsGeneration)
            {
                // --gen|--generate was passed, enter assert generation
                import kameloso.debugging : generateAsserts;
                instance.generateAsserts();
                return Next.returnSuccess;
            }
            else
            {
                import std.getopt : GetOptException;
                throw new GetOptException("--asserts is disabled in non-dev builds");
            }
        }

        return Next.continue_;
    }
}

/++
    Functionality related to configuration; verifying it, correcting it,
    reading it from/writing it to disk, and parsing it from command-line arguments.

    Employs the standard [std.getopt] to read arguments from the command line
    to construct and populate instances of the structs needed for the bot to
    function, like [dialect.defs.IRCClient|IRCClient], [dialect.defs.IRCServer|IRCServer]
    and [kameloso.pods.IRCBot|IRCBot].

    See_Also:
        [kameloso.kameloso],
        [kameloso.main],
        [kameloso.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.config;

private:

import kameloso.kameloso : Kameloso;
import kameloso.common : logger;
import kameloso.pods : IRCBot;
import dialect.defs : IRCClient, IRCServer;
import std.getopt : GetoptResult;

@safe:


// printHelp
/++
    Prints the [std.getopt.getopt|getopt] "helpWanted" help table to screen.

    Example:
    ---
    auto results = args.getopt(
        "n|nickname",   "Bot nickname", &nickname,
        "s|server",     "Server",       &server,
        // ...
    );

    if (results.helpWanted)
    {
        printHelp(results);
    }
    ---

    Params:
        results = Results from a [std.getopt.getopt|getopt] call.
 +/
void printHelp(GetoptResult results)
{
    import std.array : Appender;
    import std.getopt : Option;
    import std.stdio : writeln;

    // Copied from std.getopt
    static void customGetoptFormatter(Sink)
        (auto ref Sink sink,
        const Option[] opt,
        const string pattern /*= "%*s %*s%*s%s\n"*/)
    {
        import std.algorithm.comparison : min, max;
        import std.format : formattedWrite;

        size_t ls, ll;

        foreach (it; opt)
        {
            ls = max(ls, it.optShort.length);
            ll = max(ll, it.optLong.length);
        }

        foreach (it; opt)
        {
            sink.formattedWrite(pattern, ls, it.optShort, ll, it.optLong, it.help);
        }
    }

    enum pattern = "%*s  %*s %s\n";

    Appender!(char[]) sink;
    sink.reserve(4096);  // ~2398

    sink.put('\n');
    customGetoptFormatter(sink, results.options, pattern);
    sink.put("\nA dash (-) clears, so -C- translates to no channels, -A- to no account name, etc.\n");

    writeln(sink[]);
}


// verboselyWriteConfig
/++
    Writes configuration to file, verbosely.

    This is called if `--save` was passed.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        client = Reference to the current [dialect.defs.IRCClient|IRCClient].
        server = Reference to the current [dialect.defs.IRCServer|IRCServer].
        bot = Reference to the current [kameloso.pods.IRCBot|IRCBot].
        giveInstructions = Whether or not to give instructions to edit the
            generated file and supply admins and/or home channels.
 +/
void verboselyWriteConfig(
    scope Kameloso instance,
    ref IRCClient client,
    ref IRCServer server,
    ref IRCBot bot,
    const bool giveInstructions = true) @system
{
    import kameloso.common : logger;
    static import kameloso.common;

    if (!instance.coreSettings.headless)
    {
        import kameloso.misc : printVersionInfo;
        import std.stdio : stdout, writeln;

        printVersionInfo();
        writeln();
        if (instance.coreSettings.flush) stdout.flush();
    }

    // If we don't instantiate the plugins there'll be no plugins array
    instance.instantiatePlugins();
    writeConfigurationFile(instance, instance.coreSettings.configFile);

    if (!instance.coreSettings.headless)
    {
        import kameloso.prettyprint : prettyprint;
        import kameloso.string : doublyBackslashed;
        import std.file : exists;

        prettyprint(client, instance.bot, server, instance.connSettings, *instance.coreSettings);
        enum pattern = "Configuration written to <i>%s";
        logger.logf(pattern, instance.coreSettings.configFile.doublyBackslashed);

        if (!instance.bot.admins.length && !instance.bot.homeChannels.length && giveInstructions)
        {
            logger.trace();
            logger.log("Edit it and make sure it contains at least one of the following:");
            giveConfigurationMinimalInstructions();
        }

        immutable shouldGiveBrightTerminalHint =
            instance.coreSettings.colours &&
            !instance.coreSettings.brightTerminal &&
            !instance.coreSettings.configFile.exists;

        if (shouldGiveBrightTerminalHint)
        {
            logger.trace();
            giveBrightTerminalHint(alsoAboutConfigSetting: true);
        }
    }
}


// printSettings
/++
    Prints the core settings and all plugins' settings to screen.

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void printSettings(scope Kameloso instance) @system
{
    import kameloso.misc : printVersionInfo;
    import kameloso.prettyprint : prettyprint;
    import std.stdio : stdout, writeln;
    import std.typecons : Flag, No, Yes;

    printVersionInfo();
    writeln();

    prettyprint!(No.all)
        (instance.parser.client,
        instance.bot,
        instance.parser.server,
        instance.connSettings,
        *instance.coreSettings);

    instance.instantiatePlugins();

    foreach (plugin; instance.plugins) plugin.printSettings();

    if (instance.coreSettings.flush) stdout.flush();
}


// manageConfigFile
/++
    Writes and/or edits the configuration file. Broken out into a separate
    function to lower the size of [handleGetopt].

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
        shouldWriteConfig = Writing to the configuration file was explicitly
            requested or implicitly by changing some setting via getopt.
        shouldOpenTerminalEditor = Opening the configuration file in a
            terminal text editor was requested.
        shouldOpenGraphicalEditor = Opening the configuration file in a
            graphical text editor was requested.
        force = (Windows) If set, uses `explorer.exe` as the graphical editor,
            otherwise uses `notepad.exe`.
 +/
void manageConfigFile(
    scope Kameloso instance,
    const bool shouldWriteConfig,
    const bool shouldOpenTerminalEditor,
    const bool shouldOpenGraphicalEditor,
    const bool force) @system
{
    import kameloso.string : doublyBackslashed;
    import std.file : exists;

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
            version(Windows)
            {
                enum message = "Missing <l>%EDITOR%</> environment variable; cannot guess editor.";
            }
            else version(Posix)
            {
                enum message = "Missing <l>$EDITOR</> environment variable; cannot guess editor.";
            }
            else
            {
                static assert(0, "Unsupported platform, please file a bug.");
            }

            logger.error(message);
            return;
        }

        enum pattern = "Attempting to open <i>%s</> with <i>%s</>...";
        logger.logf(pattern, instance.coreSettings.configFile.doublyBackslashed, editor.doublyBackslashed);

        immutable string[2] command = [ editor, instance.coreSettings.configFile ];
        spawnProcess(command[]).wait;
    }

    /++
        Opens up the configuration file in a graphical text editor.

        Params:
            giveInstructions = Whether or not to give instructions to edit the
                generated file and supply admins and/or home channels.
     +/
    void openGraphicalEditor(const bool giveInstructions)
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
                instance.coreSettings.force ||
                environment.get("DISPLAY", string.init).length ||
                environment.get("WAYLAND_DISPLAY", string.init).length;

            if (!isGraphicalEnvironment)
            {
                enum message = "No graphical environment appears to be running; cannot open editor.";
                logger.error(message);
                return;
            }
        }
        else version(Windows)
        {
            immutable editor = force ? "explorer.exe" : "notepad.exe";
        }
        else
        {
            static assert(0, "Unsupported platform, please file a bug.");
        }

        // Let exceptions (ProcessExceptions) fall through and get caught
        // by [kameloso.main.tryGetopt].

        enum pattern = "Attempting to open <i>%s</> in a graphical text editor...";
        logger.logf(pattern, instance.coreSettings.configFile.doublyBackslashed);

        if (!instance.bot.admins.length && !instance.bot.homeChannels.length && giveInstructions)
        {
            logger.trace();
            logger.log("Make sure it contains at least one of the following:");
            giveConfigurationMinimalInstructions();
        }

        immutable string[2] command =
        [
            editor,
            instance.coreSettings.configFile,
        ];

        execute(command[]);
    }

    /+
        Write config if...
        * --save was passed
        * a setting was changed via getopt (also passes shouldWriteConfig: true)
        * the config file doesn't exist
     +/

    immutable configFileExists = instance.coreSettings.configFile.exists;

    if (shouldWriteConfig || !configFileExists)
    {
        immutable giveInstructions =
            !configFileExists &&
            //!shouldOpenTerminalEditor &&
            !shouldOpenGraphicalEditor;

        verboselyWriteConfig(
            instance,
            instance.parser.client,
            instance.parser.server,
            instance.bot,
            giveInstructions: giveInstructions);
    }

    if (!instance.coreSettings.headless && (shouldOpenTerminalEditor || shouldOpenGraphicalEditor))
    {
        // If instructions were given, add an extra linebreak to make it prettier
        if (!configFileExists) logger.trace();

        // --edit or --gedit was passed, so open up an appropriate editor
        if (shouldOpenTerminalEditor)
        {
            openTerminalEditor();
        }
        else /*if (shouldOpenGraphicalEditor)*/
        {
            openGraphicalEditor(giveInstructions: !configFileExists);
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
    sink.serialise(client, server, coreSettings);
    immutable configText = sink[].justifiedEntryValueText;
    writeToDisk("kameloso.conf", configText, addBanner: true);
    ---

    Params:
        filename = Filename of file to write to.
        configurationText = Content to write to file.
        addBanner = Whether or not to add the "kameloso bot" banner at the head of the file.
 +/
void writeToDisk(
    const string filename,
    const string configurationText,
    const bool addBanner = true)
{
    import std.file : mkdirRecurse;
    import std.path : dirName;
    import std.stdio : File;

    immutable dir = filename.dirName;
    mkdirRecurse(dir);

    auto file = File(filename, "w");

    if (addBanner)
    {
        import kameloso.constants : KamelosoInfo;
        import std.datetime.systime : Clock;
        import core.time : Duration;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = Duration.zero;

        enum pattern = "# kameloso v%s configuration file (%d-%02d-%02d %02d:%02d:%02d)\n";
        file.writefln(
            pattern,
            cast(string) KamelosoInfo.version_,
            timestamp.year,
            cast(uint) timestamp.month,
            timestamp.day,
            timestamp.hour,
            timestamp.minute,
            timestamp.second);
    }

    file.writeln(configurationText);
}


// giveConfigurationMinimalInstructions
/++
    Displays a hint on how to complete a minimal configuration file.

    It assumes that the bot's [kameloso.pods.IRCBot.admins|IRCBot.admins] and
    [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels] are both empty.
    (Else it should not have been called.)
 +/
void giveConfigurationMinimalInstructions()
{
    enum adminPattern = "<i>*</> one or more <i>admins</> who get administrative control over the bot.";
    enum homePattern = "<i>*</> one or more <i>homeChannels</> in which to operate.";
    logger.trace(adminPattern);
    logger.trace(homePattern);
}


// flatten
/++
    Flattens a dynamic array of strings by splitting elements containing more
    than one value (as separated by a separator string) into separate elements.

    Params:
        arr = A dynamic `string[]` array.
        separator = Separator, defaults to a space string (" ").

    Returns:
        A new array, with any elements previously containing more than one
        `separator`-separated entries now in separate elements.
 +/
auto flatten(const string[] arr, const string separator = " ")
{
    import lu.string : stripped;
    import std.algorithm.iteration : filter, joiner, map, splitter;
    import std.array : array;

    auto toReturn = arr
        .map!(elem => elem.splitter(separator))
        .joiner
        .map!(elem => elem.stripped)
        .filter!(elem => elem.length)
        .array;

    return toReturn;
}

///
unittest
{
    import std.conv : to;

    {
        auto arr = [ "a", "b", "c d e   ", "f" ];
        arr = flatten(arr);
        assert((arr == [ "a", "b", "c", "d", "e", "f" ]), arr.to!string);
    }
    {
        auto arr = [ "a", "b", "c,d,e,,,", "f" ];
        arr = flatten(arr, ",");
        assert((arr == [ "a", "b", "c", "d", "e", "f" ]), arr.to!string);
    }
    {
        auto arr = [ "a", "b", "c dhonk  e ", "f" ];
        arr = flatten(arr, "honk");
        assert((arr == [ "a", "b", "c d", "e", "f" ]), arr.to!string);
    }
    {
        auto arr = [ "a", "b", "c" ];
        arr = flatten(arr);
        assert((arr == [ "a", "b", "c" ]), arr.to!string);
    }
}


// resolveFlagString
/++
    Resolves a string to a boolean value.

    Params:
        input = String to resolve.
        colours = Reference to a boolean to set. Must not be an out-reference.
 +/
void resolveFlagString(const string input, ref bool output) @system
{
    switch (input)
    {
        case "auto":
        case "tty":
        case "if-tty":
            import kameloso.terminal : isTerminal;
            output = isTerminal;
            break;

        case "always":
        case "yes":
        case "force":
        case "true":  // Not a valid value, but we'll accept it anyway
            output = true;
            break;

        case "never":
        case "no":
        case "none":
        case "false":  // as above
            output = false;
            break;

        case string.init:
            break;

        default:
            throw new FlagStringException("Bad flag string", value: input);
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
    Next next = handleGetopt(instance);

    if (next == Next.returnSuccess) return 0;
    // ...
    ---

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.

    Returns:
        [lu.misc.Next.continue_|Next.continue_] or
        [lu.misc.Next.returnSuccess|Next.returnSuccess] depending on whether
        the arguments chosen mean the program should proceed or not.

    Throws:
        [std.getopt.GetOptException|GetOptException] if an unknown flag is passed.
 +/
auto handleGetopt(scope Kameloso instance) @system
{
    import kameloso.configreader : readConfigInto;
    import kameloso.logger : KamelosoLogger;
    import kameloso.misc : printVersionInfo;
    import kameloso.plugins : applyCustomSettings;
    import kameloso.terminal : applyTerminalOverrides;
    import lu.misc : Next;
    import lu.objmanip : replaceMembers;
    static import kameloso.common;
    static import std.getopt;

    bool shouldWriteConfig;
    bool shouldOpenTerminalEditor;
    bool shouldOpenGraphicalEditor;
    bool shouldShowVersion;
    bool shouldShowSettings;
    bool shouldAppendToArrays;
    bool noop;

    // Windows-only but must be declared regardless of platform
    bool shouldDownloadOpenSSL;
    bool shouldDownloadCacert;
    bool shouldDownloadOpenSSL1_1;

    // Likewise but version `TwitchSupport`
    bool shouldSetupTwitch;

    string[] inputGuestChannels;
    string[] inputHomeChannels;
    string[] channelOverride;
    string[] inputAdmins;

    string colourString;
    string nothing;

    std.getopt.arraySep = ",";

    /+
        Call getopt on (a copy of) args once and look for any specified configuration files
        so we know what to read. As such it has to be done before the
        [kameloso.configreader.readConfigInto] call. Then call getopt on the rest later.
        Include "c|config" in the normal getopt to have it automatically
        included in the --help text.
     +/

    // Results can be const
    auto args = instance.args.dup;
    const configFileResults = std.getopt.getopt(args,
        std.getopt.config.caseSensitive,
        std.getopt.config.bundling,
        std.getopt.config.passThrough,
        "c|config", &instance.coreSettings.configFile,
        "version", &shouldShowVersion);

    if (shouldShowVersion)
    {
        // --version was passed; show version info and quit
        printVersionInfo(colours: false);
        return Next.returnSuccess;
    }

    // Ignore invalid/missing entries here, report them when initialising plugins
    instance.coreSettings.configFile.readConfigInto(
        instance.parser.client,
        instance.bot,
        instance.parser.server,
        instance.connSettings,
        *instance.coreSettings);

    applyDefaults(instance);
    applyTerminalOverrides(instance.coreSettings.flush, instance.coreSettings.colours);

    /+
        Call getopt once more just to get values for colour and the Twitch
        --setup-twitch. Catching --setup-twitch here means we can override
        its defaults with the main getopt call.

        Also catch --get-openssl-1_1 here, as it should be hidden.
     +/
    cast(void) std.getopt.getopt(args,
        std.getopt.config.caseSensitive,
        std.getopt.config.bundling,
        std.getopt.config.passThrough,
        "colour", &colourString,
        "color", &colourString,
        "setup-twitch", &shouldSetupTwitch,
        "get-openssl-1_1", &shouldDownloadOpenSSL1_1,
        "internal-num-reexecs", &instance.transient.numReexecs,
        "internal-channel-override", &channelOverride);

    if (colourString.length)
    {
        immutable valueBefore = instance.coreSettings.colours;
        resolveFlagString(colourString, instance.coreSettings.colours);  // throws on failure
        immutable valueAfter = instance.coreSettings.colours;

        if (valueBefore != valueAfter)
        {
            // Colours were probably disabled, so reinitialise the logger
            destroy(kameloso.common.logger);
            kameloso.common.logger = new KamelosoLogger(*instance.coreSettings);
        }
    }

    /++
        Call getopt in a nested function so we can call it both to merely
        parse for settings and to format the help listing.
     +/
    auto callGetopt(/*const*/ string[] theseArgs, const bool quiet)
    {
        import kameloso.logger : LogLevel;
        import kameloso.terminal.colours.tags : expandTags;
        import std.conv : text, to;
        import std.format : format;
        import std.path : extension;
        import std.process : environment;
        import std.random : uniform;
        import std.range : repeat;

        immutable setSyntax = quiet ? string.init :
            "<i>--set plugin</>.<i>setting</>=<i>value</>".expandTags(LogLevel.off);

        immutable nickname = quiet ? string.init :
            instance.parser.client.nickname.length ? instance.parser.client.nickname : "<random>";

        immutable sslText = quiet ? string.init :
            instance.connSettings.ssl ?
                "true" :
                instance.coreSettings.force ?
                    "false" :
                    "inferred by port";

        immutable passwordMask = quiet ? string.init :
            instance.bot.password.length ?
                '*'.repeat(uniform(6, 10)).to!string :
                string.init;

        immutable passMask = quiet ? string.init :
            instance.bot.pass.length ?
                '*'.repeat(uniform(6, 10)).to!string :
                string.init;

        immutable editorCommand = quiet ? string.init :
            environment.get("EDITOR", string.init);

        immutable editorVariableValue = quiet ? string.init :
            editorCommand.length ?
                " [<i>%s</>]".expandTags(LogLevel.off).format(editorCommand) :
                string.init;

        auto formatNum(const size_t num)
        {
            return (quiet || (num == 0)) ? string.init :
                " (<i>%d</>)".expandTags(LogLevel.off).format(num);
        }

        void appendCustomSetting(const string _, const string setting)
        {
            instance.customSettings ~= setting;
        }

        version(Windows)
        {
            enum getOpenSSLString = "Download OpenSSL for Windows";
            enum getCacertString = "Download a <i>cacert.pem</> certificate " ~
                "bundle (implies <i>--save</>)";
        }
        else
        {
            enum getOpenSSLString = "(Windows only)";
            enum getCacertString = getOpenSSLString;
        }

        immutable configFileExtension = instance.coreSettings.configFile.extension;
        immutable defaultGeditProgramString =
            "[<i>the default application used to open <l>*" ~
                configFileExtension ~ "<i> files on your system</>]";

        version(Windows)
        {
            immutable geditProgramString = instance.coreSettings.force ?
                defaultGeditProgramString :
                "[<i>notepad.exe</>]";
        }
        else
        {
            alias geditProgramString = defaultGeditProgramString;
        }

        version(TwitchSupport)
        {
            enum setupTwitchString = "Set up a basic Twitch connection";
        }
        else
        {
            enum setupTwitchString = "(Requires Twitch support)";
        }

        version(Windows)
        {
            enum editorMessage = "Open the configuration file in a *terminal* text editor " ~
                "(or the application defined in the <i>%EDITOR%</> environment variable)";
        }
        else
        {
            enum editorMessage = "Open the configuration file in a *terminal* text editor " ~
                "(or the application defined in the <i>$EDITOR</> environment variable)";
        }

        return std.getopt.getopt(theseArgs,
            std.getopt.config.caseSensitive,
            std.getopt.config.bundling,
            "n|nickname",
                quiet ? string.init :
                    "Nickname [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(nickname),
                &instance.parser.client.nickname,
            "s|server",
                quiet ? string.init :
                    "Server address [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.parser.server.address),
                &instance.parser.server.address,
            "P|port",
                quiet ? string.init :
                    "Server port [<i>%d</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.parser.server.port),
                &instance.parser.server.port,
            "6|ipv6",
                quiet ? string.init :
                    "Use IPv6 where available [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.connSettings.ipv6),
                &instance.connSettings.ipv6,
            "ssl",
                quiet ? string.init :
                    "Attempt SSL connection [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(sslText),
                &instance.connSettings.ssl,
            "A|account",
                quiet ? string.init :
                    "Services account name" ~
                        (instance.bot.account.length ?
                            " [<i>%s</>]"
                                .expandTags(LogLevel.off)
                                .format(instance.bot.account) :
                            string.init),
                &instance.bot.account,
            "p|password",
                quiet ? string.init :
                    "Services account password" ~
                        (instance.bot.password.length ?
                            " [<i>%s</>]"
                                .expandTags(LogLevel.off)
                                .format(passwordMask) :
                            string.init),
                &instance.bot.password,
            "pass",
                quiet ? string.init :
                    "Registration pass" ~
                        (instance.bot.pass.length ?
                            " [<i>%s</>]"
                                .expandTags(LogLevel.off)
                                .format(passMask) :
                            string.init),
                &instance.bot.pass,
            "admins",
                quiet ? string.init :
                    "Administrators' services accounts, comma-separated" ~
                        formatNum(instance.bot.admins.length),
                &inputAdmins,
            "H|homeChannels",
                quiet ? string.init :
                    text(("Home channels to operate in, comma-separated " ~
                        "(escape or enquote any octothorpe <i>#</>s)").expandTags(LogLevel.off),
                        formatNum(instance.bot.homeChannels.length)),
                &inputHomeChannels,
            "C|guestChannels",
                quiet ? string.init :
                    "Non-home channels to idle in, comma-separated (ditto)" ~
                        formatNum(instance.bot.guestChannels.length),
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
                        .expandTags(LogLevel.off)
                        .format(instance.coreSettings.brightTerminal),
                &instance.coreSettings.brightTerminal,
            "color",
                quiet ? string.init :
                    "Use colours in terminal output (<i>auto</>|<i>always</>|<i>never</>)"
                        .expandTags(LogLevel.off),
                    &nothing,
            /*"colour",
                quiet ? string.init :
                    "(Alias to <i>--color</>)"
                        .expandTags(LogLevel.off),
                    &nothing,*/
            "set",
                quiet ? string.init :
                    text("Manually change a setting (syntax: ", setSyntax, ')'),
                &appendCustomSetting,
            "c|config",
                quiet ? string.init :
                    "Specify a different configuration file [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.coreSettings.configFile),
                //&settings.configFile,  // already handled
                &noop,
            "r|resourceDir",
                quiet ? string.init :
                    "Specify a different resource directory [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.coreSettings.resourceDirectory),
                &instance.coreSettings.resourceDirectory,
            /+"receiveTimeout",
                quiet ? string.init :
                    ("Socket receive timeout in milliseconds; lower numbers " ~
                        "improve worse-case responsiveness of outgoing messages [<i>%d</>]")
                            .expandTags(LogLevel.off)
                            .format(instance.connSettings.receiveTimeout),
                &instance.connSettings.receiveTimeout,
            "privateKey",
                quiet ? string.init :
                    "Path to private key file, used to authenticate some SSL connections",
                &instance.connSettings.privateKeyFile,
            "cert",
                quiet ? string.init :
                    "Path to certificate file, ditto",
                &instance.connSettings.certFile,+/
            "cacert",
                quiet ? string.init :
                    "Path to <i>cacert.pem</> certificate bundle, or equivalent"
                        .expandTags(LogLevel.off),
                &instance.connSettings.caBundleFile,
            "get-openssl",
                quiet ? string.init :
                    getOpenSSLString,
                &shouldDownloadOpenSSL,
            "get-cacert",
                quiet ? string.init :
                    getCacertString
                        .expandTags(LogLevel.off),
                &shouldDownloadCacert,
            "setup-twitch",
                quiet ? string.init :
                    setupTwitchString,
                //&shouldSetupTwitch,
                &noop,
            "numeric",
                quiet ? string.init :
                    "Use numeric output of addresses",
                &instance.coreSettings.numericAddresses,
            "summary",
                quiet ? string.init :
                    "Show a connection summary on program exit [<i>%s</>]"
                        .expandTags(LogLevel.off)
                        .format(instance.coreSettings.exitSummary),
                &instance.coreSettings.exitSummary,
            "force",
                quiet ? string.init :
                    "Force connect (skips some checks)",
                &instance.coreSettings.force,
            "flush",
                quiet ? string.init :
                    "Set terminal mode to flush screen output after each line written to it. " ~
                        "(Use this if the screen only occasionally updates)",
                &instance.coreSettings.flush,
            "save",
                quiet ? string.init :
                    "Write configuration to file",
                &shouldWriteConfig,
            "edit",
                quiet ? string.init :
                    editorMessage.expandTags(LogLevel.off) ~ editorVariableValue,
                &shouldOpenTerminalEditor,
            "gedit",
                quiet ? string.init :
                    ("Open the configuration file in a *graphical* text editor " ~ geditProgramString)
                        .expandTags(LogLevel.off),
                &shouldOpenGraphicalEditor,
            "headless",
                quiet ? string.init :
                    "Headless mode, disabling all terminal output",
                &instance.coreSettings.headless,
            "version",
                quiet ? string.init :
                    "Show version information",
                &shouldShowVersion,
        );
    }

    const backupClient = instance.parser.client;
    auto backupServer = instance.parser.server;  // cannot opEqual const IRCServer with mutable
    const backupBot = instance.bot;

    version(TwitchSupport)
    {
        if (shouldSetupTwitch)
        {
            // Do this early to allow for manual overrides with --server etc
            instance.parser.server.address = "irc.chat.twitch.tv";
            instance.parser.server.port = 6697;
            instance.parser.client.nickname = "doesntmatter";
            instance.parser.client.user = "ignored";
            instance.parser.client.realName = "likewise";
            shouldWriteConfig = true;
            shouldOpenGraphicalEditor = true;

            version(Windows)
            {
                shouldDownloadOpenSSL = true;
                shouldDownloadCacert = true;
            }
        }
    }

    // No need to catch the return value, only used for --help
    cast(void) callGetopt(args, quiet: true);

    cast(void) applyCustomSettings(
        null,
        *instance.coreSettings,
        instance.customSettings,
        toPluginsOnly: false);  // include settings

    // Save the user from themselves. (A receive timeout of 0 breaks all sorts of things.)
    if (instance.connSettings.receiveTimeout == 0)
    {
        import kameloso.constants : Timeout;
        instance.connSettings.receiveTimeout = Timeout.Integers.receiveMsecs;
    }

    // Reinitialise the logger with new settings
    destroy(kameloso.common.logger);
    kameloso.common.logger = new KamelosoLogger(*instance.coreSettings);

    // Support channels and admins being separated by spaces (mirror config file behaviour)
    if (inputHomeChannels.length) inputHomeChannels = flatten(inputHomeChannels);
    if (inputGuestChannels.length) inputGuestChannels = flatten(inputGuestChannels);
    if (inputAdmins.length) inputAdmins = flatten(inputAdmins);

    // Manually override or append channels, depending on `shouldAppendChannels`
    if (shouldAppendToArrays)
    {
        static auto hasClearingDash(const string[] arr)
        {
            return (arr.length == 1) && (arr[0] == "-");
        }

        if (inputHomeChannels.length)
        {
            if (hasClearingDash(inputHomeChannels))
            {
                instance.bot.homeChannels = null;
            }
            else
            {
                instance.bot.homeChannels ~= inputHomeChannels;
            }
        }

        if (inputGuestChannels.length)
        {
            if (hasClearingDash(inputGuestChannels))
            {
                instance.bot.guestChannels = null;
            }
            else
            {
                instance.bot.guestChannels ~= inputGuestChannels;
            }
        }

        if (inputAdmins.length)
        {
            if (hasClearingDash(inputAdmins))
            {
                instance.bot.admins = null;
            }
            else
            {
                instance.bot.admins ~= inputAdmins;
            }
        }
    }
    else
    {
        if (inputHomeChannels.length) instance.bot.homeChannels = inputHomeChannels;
        if (inputGuestChannels.length) instance.bot.guestChannels = inputGuestChannels;
        if (inputAdmins.length) instance.bot.admins = inputAdmins;
    }

    if (channelOverride.length) instance.bot.channelOverride = flatten(channelOverride);

    if (!instance.coreSettings.force)
    {
        /++
            Strip channel whitespace and make lowercase.
         +/
        static void stripAndLower(ref string[] channels)
        {
            import lu.string : stripped;
            import std.algorithm.iteration : map, uniq;
            import std.algorithm.sorting : sort;
            import std.array : array;
            import std.uni : toLower;

            if (!channels.length) return;

            channels = channels
                .map!(channelName => channelName.stripped.toLower)
                .array
                .sort
                .uniq
                .array;
        }

        stripAndLower(instance.bot.homeChannels);
        stripAndLower(instance.bot.guestChannels);
        stripAndLower(instance.bot.channelOverride);
    }

    // Remove duplicate channels (where a home is also featured as a guest channel)
    size_t[] duplicates;

    foreach (immutable channelName; instance.bot.homeChannels)
    {
        import std.algorithm.searching : countUntil;
        immutable chanIndex = instance.bot.guestChannels.countUntil(channelName);
        if (chanIndex != -1) duplicates ~= chanIndex;
    }

    foreach_reverse (immutable chanIndex; duplicates)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        instance.bot.guestChannels = instance.bot.guestChannels.remove!(SwapStrategy.unstable)(chanIndex);
    }

    // Clear entries that are dashes
    instance.parser.client.replaceMembers("-");
    instance.bot.replaceMembers("-");

    // Handle showstopper arguments (that display something and then exits)
    if (configFileResults.helpWanted)
    {
        // --help|-h was passed, show the help table and quit
        // It's okay to reuse args, it's probably empty save for arg0
        // and we just want the help listing

        if (!instance.coreSettings.headless)
        {
            import std.stdio : stdout;
            printVersionInfo();
            printHelp(callGetopt(args, quiet: false));
            if (instance.coreSettings.flush) stdout.flush();
        }

        return Next.returnSuccess;
    }

    version(Windows)
    {
        if (shouldDownloadCacert || shouldDownloadOpenSSL || shouldDownloadOpenSSL1_1)
        {
            import kameloso.constants : MagicErrorStrings;
            import kameloso.ssldownloads : downloadWindowsSSL;
            import std.stdio : writeln;

            if (shouldSetupTwitch)
            {
                logger.log("== <w>Twitch setup</> ==");
                logger.trace("This will download <l>OpenSSL</> and a <l>cacert.pem</> certificate bundle file.");
                logger.trace(cast(string) MagicErrorStrings.visitWikiOneliner);
                logger.trace();
                logger.trace("Setup will resume after installation finishes.");
                logger.trace();
            }

            immutable settingsTouched = downloadWindowsSSL(
                instance,
                shouldDownloadCacert: shouldDownloadCacert,
                shouldDownloadOpenSSL: (shouldDownloadOpenSSL || shouldDownloadOpenSSL1_1),
                shouldDownloadOpenSSL1_1: shouldDownloadOpenSSL1_1);

            if (*instance.abort) return Next.returnFailure;

            if (settingsTouched)
            {
                shouldWriteConfig = true;
            }
            else
            {
                if (!shouldWriteConfig) return Next.returnSuccess;
            }

            // Add an empty line as distance to start screen
            writeln();
        }
    }

    if (shouldWriteConfig || shouldOpenTerminalEditor || shouldOpenGraphicalEditor)
    {
        // --save and/or --edit was passed; defer to manageConfigFile
        // (or --setup-twitch)
        // Also pass `shouldWriteConfig: true` if something was changed via getopt
        shouldWriteConfig =
            shouldWriteConfig ||
            instance.customSettings.length ||
            (instance.parser.client != backupClient) ||
            (instance.parser.server != backupServer) ||
            (instance.bot != backupBot);

        manageConfigFile(
            instance,
            shouldWriteConfig: shouldWriteConfig,
            shouldOpenTerminalEditor: shouldOpenTerminalEditor,
            shouldOpenGraphicalEditor: shouldOpenGraphicalEditor,
            force: instance.coreSettings.force);

        return Next.returnSuccess;
    }

    if (shouldShowSettings)
    {
        // --settings was passed, show all options and quit
        if (!instance.coreSettings.headless) printSettings(instance);
        return Next.returnSuccess;
    }

    return Next.continue_;
}


// writeConfigurationFile
/++
    Writes all settings to the configuration filename passed.

    It gathers configuration text from all plugins before formatting it into
    nice columns, then writes it all in one go.

    Additionally gives some empty settings default values.

    Example:
    ---
    Kameloso instance;
    writeConfigurationFile(instance, instance.coreSettings.configFile);
    ---

    Params:
        instance = Reference to the current [kameloso.kameloso.Kameloso|Kameloso],
            with all its plugins and settings.
        filename = String filename of the file to write to.
 +/
void writeConfigurationFile(
    scope Kameloso instance,
    const string filename) @system
{
    import kameloso.platform : rbd = resourceBaseDirectory;
    import lu.serialisation : justifiedEntryValueText, serialise;
    import lu.string : encode64;
    import std.algorithm.searching : startsWith;
    import std.array : Appender;
    import std.exception : assumeUnique;
    import std.file : exists;
    import std.path : buildNormalizedPath, expandTilde;

    Appender!(char[]) sink;
    sink.reserve(4096);  // ~3325

    // Only make some changes if we're creating a new file
    if (!filename.exists)
    {
        import kameloso.constants : KamelosoDefaults;

        if (!instance.bot.quitReason.length)
        {
            // Set the quit reason here and nowhere else.
            instance.bot.quitReason = KamelosoDefaults.quitReason;
        }

        if (!instance.coreSettings.prefix.length)
        {
            // Only set the prefix if we're creating a new file, to allow for empty prefixes
            instance.coreSettings.prefix = KamelosoDefaults.prefix;
        }
    }

    // Base64-encode passwords if they're not already encoded
    // --force opts out
    if (!instance.coreSettings.force)
    {
        if (instance.bot.password.length && !instance.bot.password.startsWith("base64:"))
        {
            instance.bot.password = "base64:" ~ encode64(instance.bot.password);
        }

        if (instance.bot.pass.length && !instance.bot.pass.startsWith("base64:"))
        {
            instance.bot.pass = "base64:" ~ encode64(instance.bot.pass);
        }
    }

    // Copied from kameloso.main.resolvePaths
    version(Windows)
    {
        import std.string : replace;
        immutable escapedServerDirName = instance.parser.server.address.replace(':', '_');
    }
    else version(Posix)
    {
        immutable escapedServerDirName = instance.parser.server.address;
    }
    else
    {
        static assert(0, "Unsupported platform, please file a bug.");
    }

    immutable defaultResourceHomeDir = buildNormalizedPath(rbd, "kameloso");
    immutable defaultFullServerResourceDir = escapedServerDirName.length ?
        buildNormalizedPath(
            defaultResourceHomeDir,
            "server",
            escapedServerDirName) :
        string.init;

    string settingsResourceDirSnapshot = instance.coreSettings.resourceDirectory.expandTilde();  // mutable

    if (settingsResourceDirSnapshot == defaultResourceHomeDir)
    {
        settingsResourceDirSnapshot = defaultFullServerResourceDir;
    }

    if (!instance.coreSettings.force &&
        (settingsResourceDirSnapshot == defaultFullServerResourceDir))
    {
        // If the resource directory is the default (unset),
        // or if it is what would be automatically inferred, write it out as empty
        instance.coreSettings.resourceDirectory = string.init;
    }

    sink.serialise(
        instance.parser.client,
        instance.bot,
        instance.parser.server,
        instance.connSettings,
        *instance.coreSettings);
    sink.put('\n');

    foreach (immutable i, plugin; instance.plugins)
    {
        immutable addedSomething = plugin.serialiseConfigInto(sink);

        if (addedSomething && (i+1 < instance.plugins.length))
        {
            sink.put('\n');
        }
    }

    immutable justified = sink[].assumeUnique().justifiedEntryValueText;
    writeToDisk(filename, justified, addBanner: true);

    // Restore resource dir in case we aren't exiting
    instance.coreSettings.resourceDirectory = settingsResourceDirSnapshot;
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
void notifyAboutMissingSettings(
    const string[][string] missingEntries,
    const string binaryPath,
    const string configFile)
{
    import kameloso.string : doublyBackslashed;
    import std.conv : text;
    import std.path : baseName;

    logger.log("Your configuration file is missing the following settings:");

    foreach (immutable section, const sectionEntries; missingEntries)
    {
        enum missingPattern = "...under <l>[<i>%s<l>]</>: %-(<i>%s%|</>, %)";
        logger.tracef(missingPattern, section, sectionEntries);
    }

    enum pattern = "Use <i>%s --save</> to regenerate the file, " ~
        "updating it with all available configuration. [<i>%s</>]";
    logger.trace();
    logger.tracef(pattern, binaryPath.baseName, configFile.doublyBackslashed);
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
void notifyAboutIncompleteConfiguration(
    const string configFile,
    const string binaryPath)
{
    import kameloso.string : doublyBackslashed;
    import std.file : exists;
    import std.path : baseName;

    logger.warning("No administrators nor home channels configured!");
    logger.trace();

    if (configFile.exists)
    {
        enum pattern = "Edit <i>%s</> and make sure it has at least one of the following:";
        logger.logf(pattern, configFile.doublyBackslashed);
        giveConfigurationMinimalInstructions();
    }
    else
    {
        enum pattern = "Use <i>%s --save</> to generate a configuration file.";
        logger.logf(pattern, binaryPath.baseName);
    }

    logger.trace();
}


// giveBrightTerminalHint
/++
    Display a hint about the existence of the `--bright` getopt flag.

    Params:
        alsoAboutConfigSetting = Whether or not to also give a hint about the
            possibility of saving the setting to
            [kameloso.pods.CoreSettings.brightTerminal|CoreSettings.brightTerminal].
 +/
void giveBrightTerminalHint(const bool alsoAboutConfigSetting = false)
{
    // Don't highlight the getopt flags as they might be difficult to read
    enum brightPattern = "If text is difficult to read (e.g. white on white), " ~
        "try running the program with --bright or --color=never.";
    logger.trace(brightPattern);

    if (alsoAboutConfigSetting)
    {
        // As above
        enum configPattern = "The setting will be made persistent if you pass it " ~
            "at the same time as --save.";
        logger.trace(configPattern);
    }
}


// applyDefaults
/++
    Completes a client's, a server's and a bot's member fields. Empty members are
    given values from compile-time defaults.

    Nickname, user, GECOS/"real name", server address and server port are
    required. If there is no nickname, generate a random one. For any other empty values,
    update them with relevant such from [kameloso.constants.KamelosoDefaults|KamelosoDefaults]
    (and [kameloso.constants.KamelosoDefaultIntegers|KamelosoDefaultIntegers]).

    Params:
        instance = The current [kameloso.kameloso.Kameloso|Kameloso] instance.
 +/
void applyDefaults(scope Kameloso instance)
out (; (instance.parser.client.nickname.length), "Empty client nickname")
out (; (instance.parser.client.user.length), "Empty client username")
out (; (instance.parser.client.realName.length), "Empty client GECOS/real name")
out (; (instance.parser.server.address.length), "Empty server address")
out (; (instance.parser.server.port != 0), "Server port of 0")
out (; (instance.bot.quitReason.length), "Empty bot quit reason")
out (; (instance.bot.partReason.length), "Empty bot part reason")
//out (; (instance.coreSettings.prefix.length), "Empty prefix")
{
    import kameloso.constants : KamelosoDefaults, KamelosoDefaultIntegers;

    // If no client.nickname set, generate a random guest name.
    if (!instance.parser.client.nickname.length)
    {
        import std.format : format;
        import std.random : uniform;

        enum pattern = "guest%03d";
        instance.parser.client.nickname = pattern.format(uniform(0, 1000));
        instance.bot.hasGuestNickname = true;
    }

    // If no client.user set, inherit from KamelosoDefaults.
    if (!instance.parser.client.user.length)
    {
        instance.parser.client.user = KamelosoDefaults.user;
    }

    // If no client.realName set, inherit.
    if (!instance.parser.client.realName.length)
    {
        instance.parser.client.realName = KamelosoDefaults.realName;
    }

    // If no server.address set, inherit.
    if (!instance.parser.server.address.length)
    {
        instance.parser.server.address = KamelosoDefaults.serverAddress;
    }

    // As above but KamelosoDefaultIntegers.
    if (instance.parser.server.port == 0)
    {
        instance.parser.server.port = KamelosoDefaultIntegers.port;
    }

    if (!instance.bot.quitReason.length)
    {
        instance.bot.quitReason = KamelosoDefaults.quitReason;
    }

    if (!instance.bot.partReason.length)
    {
        instance.bot.partReason = KamelosoDefaults.partReason;
    }

    /*if (!instance.coreSettings.prefix.length)
    {
        instance.coreSettings.prefix = KamelosoDefaults.prefix;
    }*/
}

///
unittest
{
    import kameloso.constants : KamelosoDefaults, KamelosoDefaultIntegers;
    import std.conv : to;

    scope instance = new Kameloso;

    with (instance.parser)
    {
        assert(!client.nickname.length, client.nickname);
        assert(!client.user.length, client.user);
        assert(!client.ident.length, client.ident);
        assert(!client.realName.length, client.realName);
        assert(!server.address, server.address);
        assert((server.port == 0), server.port.to!string);

        applyDefaults(instance);

        assert(client.nickname.length);
        assert((client.user == KamelosoDefaults.user), client.user);
        assert(!client.ident.length, client.ident);
        assert((client.realName == KamelosoDefaults.realName), client.realName);
        assert((server.address == KamelosoDefaults.serverAddress), server.address);
        assert((server.port == KamelosoDefaultIntegers.port), server.port.to!string);
        assert((instance.bot.quitReason == KamelosoDefaults.quitReason), instance.bot.quitReason);
        assert((instance.bot.partReason == KamelosoDefaults.partReason), instance.bot.partReason);

        client.nickname = string.init;
        applyDefaults(instance);

        assert(client.nickname.length, client.nickname);
    }
}


// FlagStringException
/++
    Exception thrown when a flag argument is not one of the expected values.

    It is a normal [object.Exception|Exception] but with an attached value string.
 +/
final class FlagStringException : Exception
{
@safe:
    /++
        The value that was given as a flag argument.
     +/
    string value;

    /++
        Create a new [FlagStringException], without attaching a value.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }

    /++
        Create a new [FlagStringException], attaching a value.
     +/
    this(
        const string message,
        const string value,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.value = value;
        super(message, file, line, nextInChain);
    }
}

/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

import dialect.defs : IRCClient, IRCServer;
import lu.uda;

import core.time : Duration, seconds;

import std.experimental.logger : Logger;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(Colours)
{
    private import kameloso.terminal : TerminalForeground;
}

@safe:

version(unittest)
shared static this()
{
    import kameloso.logger : KamelosoLogger;

    // This is technically before settings have been read...
    logger = new KamelosoLogger;
}


// logger
/++
 +  Instance of a `kameloso.logger.KamelosoLogger`, providing timestamped and
 +  coloured logging.
 +
 +  The member functions to use are `log`, `trace`, `info`, `warning`, `error`,
 +  and `fatal`. It is not global, so instantiate a thread-local
 +  `std.experimental.logger.Logger` if threading.
 +
 +  Having this here is unfortunate; ideally plugins should not use variables
 +  from other modules, but unsure of any way to fix this other than to have
 +  each plugin keep their own `std.experimental.logger.Logger`.
 +/
Logger logger;


// initLogger
/++
 +  Initialises the `kameloso.logger.KamelosoLogger` logger for use in this thread.
 +
 +  It needs to be separately instantiated per thread.
 +
 +  Example:
 +  ---
 +  initLogger(settings.monochrome, settings.brightTerminal, settings.flush);
 +  ---
 +
 +  Params:
 +      monochrome = Whether the terminal is set to monochrome or not.
 +      bright = Whether the terminal has a bright background or not.
 +      flush = Whether or not to flush stdout after finishing writing to it.
 +/
void initLogger(const bool monochrome = settings.monochrome,
    const bool bright = settings.brightTerminal,
    const bool flush = settings.flush)
out (; (logger !is null), "Failed to initialise logger")
do
{
    import kameloso.logger : KamelosoLogger;
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome, bright, flush);
}


// settings
/++
 +  A `CoreSettings` struct global, housing certain runtime settings.
 +
 +  This will be accessed from other parts of the program, via
 +  `kameloso.common.settings`, so they know to use monochrome output or not.
 +  It is a problem that needs solving.
 +/
__gshared CoreSettings settings;


// CoreSettings
/++
 +  Aggregate struct containing runtime bot setting variables.
 +
 +  Kept inside one struct, they're nicely gathered and easy to pass around.
 +  Some defaults are hardcoded here.
 +/
struct CoreSettings
{
    version(Colours)
    {
        bool monochrome = false;  /// Logger monochrome setting.
    }
    else
    {
        bool monochrome = true;  /// Non-colours version defaults to true.
    }

    /// Flag denoting whether or not the program should reconnect after disconnect.
    bool reconnectOnFailure = true;

    /// Flag denoting that the terminal has a bright background.
    bool brightTerminal = false;

    /// Whether to connect to IPv6 addresses or not.
    bool ipv6 = true;

    /// Whether to print outgoing messages or not.
    bool hideOutgoing = false;

    /// Whether to add colours to outgoing messages or not.
    bool colouredOutgoing = true;

    /// Flag denoting that we should save to file on exit.
    bool saveOnExit = false;

    /// Whether to endlessly connect or whether to give up after a while.
    bool endlesslyConnect = true;

    /// Character(s) that prefix a bot chat command.
    @Quoted string prefix = "!";

    @Unconfigurable
    @Hidden
    {
        string configFile;  /// Main configuration file.
        string resourceDirectory;  /// Path to resource directory.
        string configDirectory;  /// Path to configuration directory.
        bool force;  /// Whether or not to force connecting.
        bool flush;  /// Whether or not to flush stdout after writing to it.
    }
}


// IRCBot
/++
 +  Aggregate of information relevant for an IRC *bot* that goes beyond what is
 +  needed for a mere IRC *client*.
 +/
struct IRCBot
{
    /// Username to use as services account login name.
    string account;

    @Hidden
    @CannotContainComments
    {
        /// Password for services account.
        string password;

        /// Login `PASS`, different from `SASL` and services.
        string pass;

        /// Default reason given when quitting without specifying one.
        string quitReason;
    }

    @Separator(",")
    @Separator(" ")
    {
        /// The nickname services accounts of *administrators*, in a bot-like context.
        string[] admins;

        /// List of homes, in a bot-like context.
        @CannotContainComments
        string[] homes;

        /// Currently inhabited non-home channels.
        @CannotContainComments
        string[] channels;
    }
}


// Kameloso
/++
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct Kameloso
{
    import kameloso.common : OutgoingLine;
    import kameloso.constants : BufferSize;
    import kameloso.plugins.common : IRCPlugin;
    import dialect.parsing : IRCParser;
    import lu.common : Buffer;
    import lu.net : Connection;

    import std.datetime.systime : SysTime;

    // Throttle
    /++
     +  Aggregate of values and state needed to throttle messages without
     +  polluting namespace too much.
     +/
    private struct Throttle
    {
        /// Graph constant modifier (inclination, MUST be negative).
        enum k = -1.2;

        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        double increment = 1.0;

        /++
         +  Burst limit; how many messages*increment can be sent initially
         +  before throttling kicks in.
         +/
        double burst = 3.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);
    }

    /// The socket we use to connect to the server.
    Connection conn;

    /++
     +  A runtime array of all plugins. We iterate these when we have finished
     +  parsing an `dialect.defs.IRCEvent`, and call the relevant event
     +  handlers of each.
     +/
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    long[string] previousWhoisTimestamps;

    /// Parser instance.
    IRCParser parser;

    /// IRC bot values.
    IRCBot bot;

    /// Values and state needed to throttle sending messages.
    Throttle throttle;

    /++
     +  When this is set by signal handlers, the program should exit. Other
     +  parts of the program will be monitoring it.
     +/
    __gshared bool* abort;

    /++
     +  Buffer of outgoing message strings.
     +
     +  The buffer size is "how many string pointers", now how many bytes. So
     +  we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, BufferSize.outbuffer) outbuffer;

    /++
     +  Buffer of outgoing priority message strings.
     +
     +  The buffer size is "how many string pointers", now how many bytes. So
     +  we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, BufferSize.priorityBuffer) priorityBuffer;

    version(TwitchSupport)
    {
        /++
         +  Buffer of outgoing fast message strings.
         +
         +  The buffer size is "how many string pointers", now how many bytes. So
         +  we can comfortably keep it arbitrarily high.
         +/
        Buffer!(OutgoingLine, BufferSize.outbuffer*2) fastbuffer;
    }

    /// Never copy this.
    @disable this(this);


    // throttleline
    /++
     +  Takes one or more lines from the passed buffer and sends them to the server.
     +
     +  Sends to the server in a throttled fashion, based on a simple
     +  `y = k*x + m` graph.
     +
     +  This is so we don't get kicked by the server for spamming, if a lot of
     +  lines are to be sent at once.
     +
     +  Params:
     +      Buffer = Buffer type, generally `Buffer`.
     +      buffer = `Buffer` instance.
     +      onlyIncrement = Whether or not to send anything or just do a dry run,
     +          incrementing the graph by `throttle.increment`.
     +      sendFaster = On Twitch, whether or not we should throttle less and
     +          send messages faster. Useful in some situations when rate-limiting
     +          is more lax.
     +
     +  Returns:
     +      The time remaining until the next message may be sent, so that we
     +      can reschedule the next server read timeout to happen earlier.
     +/
    double throttleline(Buffer)(ref Buffer buffer,
        const Flag!"onlyIncrement" onlyIncrement = No.onlyIncrement,
        const Flag!"sendFaster" sendFaster = No.sendFaster)
    {
        with (throttle)
        {
            import std.datetime.systime : Clock;

            immutable now = Clock.currTime;
            if (t0 == SysTime.init) t0 = now;

            version(TwitchSupport)
            {
                import dialect.defs : IRCServer;

                double k = throttle.k;
                double burst = throttle.burst;

                if (parser.server.daemon == IRCServer.Daemon.twitch)
                {
                    if (sendFaster)
                    {
                        // FIXME: Tweak numbers.
                        k = -3.0;
                        burst = 10.0;
                    }
                    else
                    {
                        k = -1.0;
                        burst = 1.0;
                    }
                }
            }

            while (!buffer.empty || onlyIncrement)
            {
                double x = (now - t0).total!"msecs"/1000.0;
                double y = k * x + m;

                if (y < 0.0)
                {
                    t0 = now;
                    x = 0.0;
                    y = 0.0;
                    m = 0.0;
                }

                if (y >= burst)
                {
                    x = (now - t0).total!"msecs"/1000.0;
                    y = k*x + m;
                    return y;
                }

                m = y + increment;
                t0 = now;

                if (onlyIncrement) break;

                if (!buffer.front.quiet)
                {
                    version(Colours)
                    {
                        import kameloso.irccolours : mapEffects;
                        logger.trace("--> ", buffer.front.line.mapEffects);
                    }
                    else
                    {
                        import kameloso.irccolours : stripEffects;
                        logger.trace("--> ", buffer.front.line.stripEffects);
                    }
                }

                conn.sendline(buffer.front.line);
                buffer.popFront();
            }

            return 0.0;
        }
    }


    // initPlugins
    /++
     +  Resets and *minimally* initialises all plugins.
     +
     +  It only initialises them to the point where they're aware of their
     +  settings, and not far enough to have loaded any resources.
     +
     +  Params:
     +      customSettings = String array of custom settings to apply to plugins
     +          in addition to those read from the configuration file.
     +
     +  Returns:
     +      An associative array of `string[]`s of invalid configuration entries,
     +      keyed by `string` plugin names.
     +
     +  Throws:
     +      `kameloso.plugins.common.IRCPluginSettingsException` on failure to apply custom settings.
     +/
    string[][string] initPlugins(string[] customSettings) @system
    {
        import kameloso.plugins : EnabledPlugins;
        import kameloso.plugins.common : IRCPluginState, applyCustomSettings;
        import std.concurrency : thisTid;
        import std.datetime.systime : Clock;

        teardownPlugins();

        IRCPluginState state;
        state.client = parser.client;
        state.server = parser.server;
        state.bot = this.bot;
        state.mainThread = thisTid;
        immutable now = Clock.currTime.toUnixTime;

        plugins.reserve(EnabledPlugins.length);

        // Instantiate all plugin types in `kameloso.plugins.package.EnabledPlugins`
        foreach (Plugin; EnabledPlugins)
        {
            plugins ~= new Plugin(state);
        }

        string[][string] allInvalidEntries;

        foreach (plugin; plugins)
        {
            auto theseInvalidEntries = plugin.deserialiseConfigFrom(settings.configFile);

            if (theseInvalidEntries.length)
            {
                import lu.meld : meldInto;
                theseInvalidEntries.meldInto(allInvalidEntries);
            }

            if (plugin.state.nextPeriodical == 0)
            {
                import kameloso.constants : Timeout;

                // Schedule first periodical in `Timeout.initialPeriodical` for
                // plugins that don't set a timestamp themselves in `initialise`
                plugin.state.nextPeriodical = now + Timeout.initialPeriodical;
            }
        }

        immutable allCustomSuccess = plugins.applyCustomSettings(customSettings);

        if (!allCustomSuccess)
        {
            import kameloso.plugins.common : IRCPluginSettingsException;
            throw new IRCPluginSettingsException("Some custom plugin settings could not be applied.");
        }

        return allInvalidEntries;
    }


    // initPluginResources
    /++
     +  Initialises all plugins' resource files.
     +
     +  This merely calls `kameloso.plugins.common.IRCPlugin.initResources()` on
     +  each plugin.
     +/
    void initPluginResources() @system
    {
        foreach (plugin; plugins)
        {
            plugin.initResources();
        }
    }


    // teardownPlugins
    /++
     +  Tears down all plugins, deinitialising them and having them save their
     +  settings for a clean shutdown.
     +
     +  Think of it as a plugin destructor.
     +/
    void teardownPlugins() @system
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;

            try
            {
                plugin.teardown();

                if (plugin.state.botUpdated)
                {
                    plugin.state.botUpdated = false;
                    propagateBot(plugin.state.bot);
                }

                if (plugin.state.clientUpdated)
                {
                    plugin.state.clientUpdated = false;
                    propagateClient(parser.client);
                }

                if (plugin.state.serverUpdated)
                {
                    plugin.state.serverUpdated = false;
                    propagateServer(parser.server);
                }
            }
            catch (ErrnoException e)
            {
                import core.stdc.errno : ENOENT;
                import std.file : exists;
                import std.path : dirName;

                if ((e.errno == ENOENT) && !settings.resourceDirectory.dirName.exists)
                {
                    // The resource directory hasn't been created, don't panic
                }
                else
                {
                    logger.warningf("ErrnoException when tearing down %s: %s",
                        plugin.name, e.msg);
                    version(PrintStacktraces) logger.trace(e.info);
                }
            }
            catch (Exception e)
            {
                logger.warningf("Exception when tearing down %s: %s", plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e.toString);
            }
        }

        // Zero out old plugins array
        plugins.length = 0;
    }


    // startPlugins
    /++
     +  *start* all plugins, loading any resources they may want.
     +
     +  This has to happen after `initPlugins` or there will not be any plugins
     +  in the `plugins` array to start.
     +/
    void startPlugins() @system
    {
        foreach (plugin; plugins)
        {
            plugin.start();

            if (plugin.state.botUpdated)
            {
                // start changed the bot; propagate
                plugin.state.botUpdated = false;
                propagateBot(plugin.state.bot);
            }

            if (plugin.state.clientUpdated)
            {
                // start changed the client; propagate
                plugin.state.clientUpdated = false;
                propagateClient(plugin.state.client);
            }

            if (plugin.state.serverUpdated)
            {
                // start changed the server; propagate
                plugin.state.serverUpdated = false;
                propagateServer(plugin.state.server);
            }
        }
    }


    // propagateClient
    /++
     +  Takes a `dialect.defs.IRCClient` and passes it out to all plugins.
     +
     +  This is called when a change to the client has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      client = `dialect.defs.IRCClient` to propagate to all plugins.
     +/
    void propagateClient(IRCClient client) pure nothrow @nogc
    {
        parser.client = client;

        foreach (plugin; plugins)
        {
            plugin.state.client = client;
        }
    }


    // propagateServer
    /++
     +  Takes a `dialect.defs.IRCServer` and passes it out to all plugins.
     +
     +  This is called when a change to the server has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      server = `dialect.defs.IRCServer` to propagate to all plugins.
     +/
    void propagateServer(IRCServer server) pure nothrow @nogc
    {
        parser.server = server;

        foreach (plugin; plugins)
        {
            plugin.state.server = server;
        }
    }


    // propagateBot
    /++
     +  Takes a `kameloso.common.IRCBot` and passes it out to all plugins.
     +
     +  This is called when a change to the bot has occurred and we want to
     +  update all plugins to have a current copy of it.
     +
     +  Params:
     +      bot = `kameloso.common.IRCBot` to propagate to all plugins.
     +/
    void propagateBot(IRCBot bot) pure nothrow @nogc
    {
        this.bot = bot;

        foreach (plugin; plugins)
        {
            plugin.state.bot = bot;
        }
    }


    // ConnectionHistoryEntry
    /++
     +  A record of a successful connection.
     +/
    struct ConnectionHistoryEntry
    {
        /// UNIX time when a conection was established.
        long startTime;

        /// UNIX time when a connection was lost.
        long stopTime;
    }

    /// History records of established connections this execution run.
    ConnectionHistoryEntry[] connectionHistory;
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, with the
 +  passed colouring.
 +
 +  Example:
 +  ---
 +  printVersionInfo(TerminalForeground.white);
 +  ---
 +
 +  Params:
 +      colourCode = Terminal foreground colour to display the text in.
 +/
version(Colours)
void printVersionInfo(TerminalForeground colourCode) @system
{
    import kameloso.terminal : colour;

    enum fgDefault = TerminalForeground.default_.colour;
    return printVersionInfo(colourCode.colour, fgDefault);
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, optionally
 +  with passed colouring in string format.
 +
 +  Overload that does not rely on `kameloso.terminal.TerminalForeground` being available, yet
 +  takes the necessary parameters to allow the other overload to reuse this one.
 +
 +  Example:
 +  ---
 +  printVersionInfo();
 +  ---
 +
 +  Params:
 +      pre = String to preface the line with, usually a colour code string.
 +      post = String to end the line with, usually a resetting code string.
 +/
void printVersionInfo(const string pre = string.init, const string post = string.init) @system
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : stdout, writefln;

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);

    if (settings.flush) stdout.flush();
}


// writeConfigurationFile
/++
 +  Write all settings to the configuration filename passed.
 +
 +  It gathers configuration text from all plugins before formatting it into
 +  nice columns, then writes it all in one go.
 +
 +  Example:
 +  ---
 +  Kameloso instance;
 +  instance.writeConfigurationFile(instance.settings.configFile);
 +  ---
 +
 +  Params:
 +      instance = Reference to the current `Kameloso`, with all its settings.
 +      filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref Kameloso instance, const string filename) @system
{
    import lu.serialisation : justifiedConfigurationText, serialise;
    import lu.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(4096);  // ~2234

    with (instance)
    {
        if (bot.password.length && !bot.password.beginsWith("base64:"))
        {
            bot.password = "base64:" ~ encode64(bot.password);
        }

        sink.serialise(parser.client, bot, parser.server, settings);

        foreach (plugin; instance.plugins)
        {
            plugin.serialiseConfigInto(sink);
        }

        immutable justified = sink.data.justifiedConfigurationText;
        writeToDisk(filename, justified, Yes.addBanner);
    }
}


// writeToDisk
/++
 +  Saves the passed configuration text to disk, with the given filename.
 +
 +  Optionally add the `kameloso` version banner at the head of it.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +  sink.serialise(client, server, settings);
 +  immutable configText = sink.data.justifiedConfigurationText;
 +  writeToDisk("kameloso.conf", configText, Yes.addBanner);
 +  ---
 +
 +  Params:
 +      filename = Filename of file to write to.
 +      configurationText = Content to write to file.
 +      banner = Whether or not to add the "*kameloso bot*" banner at the head of the file.
 +/
void writeToDisk(const string filename, const string configurationText,
    Flag!"addBanner" banner = Yes.addBanner)
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
        import core.time : msecs;
        import std.datetime.systime : Clock;

        auto timestamp = Clock.currTime;
        timestamp.fracSecs = 0.msecs;

        file.writefln("# kameloso v%s configuration file (%s)\n",
            cast(string)KamelosoInfo.version_, timestamp);
    }

    file.writeln(configurationText);
}


// complainAboutIncompleteConfiguration
/++
 +  Displays an error on how to complete a minimal configuration file.
 +
 +  It assumes that the client's `admins` and `homes` are both empty.
 +
 +  Used in both `kameloso.getopt` and `kameloso.kameloso.kamelosoMain`,
 +  so place it here.
 +/
void complainAboutIncompleteConfiguration() @system
{
    string infotint, logtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            infotint = (cast(KamelosoLogger)logger).infotint;
            logtint = (cast(KamelosoLogger)logger).logtint;
        }
    }

    logger.logf("...one or more %sadmins%s who get administrative control over the bot.", infotint, logtint);
    logger.logf("...one or more %shomes%s in which to operate.", infotint, logtint);
}


/+
    Version identifier that catches non-OSX Posix platforms.
    We need it to version code for freedesktop.org-aware environments.
 +/
version(linux)
{
    version = XDG;
}
else version(FreeBSD)
{
    version = XDG;
}


// defaultConfigurationPrefix
/++
 +  Divines the default configuration file directory, depending on what platform
 +  we're currently running.
 +
 +  On Linux it defaults to `$XDG_CONFIG_HOME/kameloso` and falls back to
 +  `~/.config/kameloso` if no `$XDG_CONFIG_HOME` environment variable present.
 +
 +  On OSX it defaults to `$HOME/Library/Application Support/kameloso`.
 +
 +  On Windows it defaults to `%LOCALAPPDATA%\\Local\\kameloso`.
 +
 +  Returns:
 +      A string path to the default configuration file.
 +/
auto defaultConfigurationPrefix()
{
    import std.path : buildNormalizedPath;
    import std.process : environment;

    version(XDG)
    {
        import std.path : expandTilde;
        enum defaultDir = "~/.config";
        return buildNormalizedPath(environment.get("XDG_CONFIG_HOME", defaultDir),
            "kameloso").expandTilde;
    }
    else version(OSX)
    {
        return buildNormalizedPath(environment["HOME"], "Library",
            "Application Support", "kameloso");
    }
    else version(Windows)
    {
        // Blindly assume %LOCALAPPDATA% is defined
        return buildNormalizedPath(environment["LOCALAPPDATA"], "kameloso");
    }
    else
    {
        pragma(msg, "Unsupported platform? Cannot divine default config file path.");
        pragma(msg, "Configuration file will be placed in the working directory.");
        return "kameloso.conf";
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    immutable df = defaultConfigurationPrefix;

    version(XDG)
    {
        import std.process : environment;

        environment["XDG_CONFIG_HOME"] = "/tmp";
        immutable dfTmp = defaultConfigurationPrefix;
        assert((dfTmp == "/tmp/kameloso"), dfTmp);

        environment.remove("XDG_CONFIG_HOME");
        immutable dfWithout = defaultConfigurationPrefix;
        assert(dfWithout.endsWith("/.config/kameloso"), dfWithout);
    }
    else version(OSX)
    {
        assert(df.endsWith("Library/Application Support/kameloso"), df);
    }
    else version(Windows)
    {
        assert(df.endsWith("\\Local\\kameloso"), df);
    }
}


// defaultResourcePrefix
/++
 +  Divines the default resource base directory, depending on what platform
 +  we're currently running.
 +
 +  On Posix it defaults to `$XDG_DATA_HOME/kameloso` and falls back to
 +  `~/.local/share/kameloso` if no `XDG_DATA_HOME` environment variable present.
 +
 +  On Windows it defaults to `%LOCALAPPDATA%\\Local\\kameloso`.
 +
 +  Returns:
 +      A string path to the default resource directory.
 +/
auto defaultResourcePrefix()
{
    import std.path : buildNormalizedPath;
    import std.process : environment;

    version(XDG)
    {
        import std.path : expandTilde;
        enum defaultDir = "~/.local/share";
        return buildNormalizedPath(environment.get("XDG_DATA_HOME", defaultDir),
            "kameloso").expandTilde;
    }
    else version(OSX)
    {
        return buildNormalizedPath(environment["HOME"], "Library",
            "Application Support", "kameloso");
    }
    else version(Windows)
    {
        // Blindly assume %LOCALAPPDATA% is defined
        return buildNormalizedPath(environment["LOCALAPPDATA"], "kameloso");
    }
    else
    {
        pragma(msg, "Unsupported platform? Cannot divine default resource prefix.");
        pragma(msg, "Resource files will be placed in the working directory.");
        return ".";
    }
}

///
unittest
{
    import std.algorithm.searching : endsWith;

    version(XDG)
    {
        import lu.string : beginsWith;
        import std.process : environment;

        environment["XDG_DATA_HOME"] = "/tmp";
        string df = defaultResourcePrefix;
        assert((df == "/tmp/kameloso"), df);

        environment.remove("XDG_DATA_HOME");
        df = defaultResourcePrefix;
        assert(df.beginsWith("/home/") && df.endsWith("/.local/share/kameloso"));
    }
    else version(OSX)
    {
        immutable df = defaultResourcePrefix;
        assert(df.endsWith("Library/Application Support/kameloso"), df);
    }
    else version(Windows)
    {
        immutable df = defaultResourcePrefix;
        assert(df.endsWith("\\Local\\kameloso"), df);
    }
}


// applyDefaults
/++
 +  Completes a client's member fields with values needed to connect.
 +
 +  Nickname, user, IDENT, GECOS/"real name", server address and server port are
 +  required. If there is no nickname, generate a random one, then just update
 +  the other members to have the same value (if they're empty) OR with values
 +  stored in `kameloso.constants.KamelosoDefaultStrings`.
 +
 +  Params:
 +      client = Reference to the `dialect.defs.IRCClient` to complete.
 +      server = Reference to the `dialect.defs.IRCServer` to complete.
 +/
void applyDefaults(ref IRCClient client, ref IRCServer server)
out (; (client.nickname.length), "Empty client nickname")
out (; (client.user.length), "Empty client username")
out (; (client.ident.length), "Empty client ident")
out (; (client.realName.length), "Empty client GECOS/real name")
out (; (server.address.length), "Empty server address")
out (; (server.port != 0), "Server port of 0")
do
{
    import kameloso.constants : KamelosoDefaultIntegers, KamelosoDefaultStrings;

    // If no client.nickname set, generate a random guest name.
    if (!client.nickname.length)
    {
        import std.format : format;
        import std.random : uniform;

        client.nickname = "guest%03d".format(uniform(0, 1000));
    }

    // If no client.user set, inherit from `kameloso.constants.KamelosoDefaultStrings`.
    if (!client.user.length)
    {
        client.user = KamelosoDefaultStrings.user;
    }

    // If no client.ident set, inherit.
    if (!client.ident.length)
    {
        client.ident = KamelosoDefaultStrings.ident;
    }

    // If no client.realName set, inherit.
    if (!client.realName.length)
    {
        client.realName = KamelosoDefaultStrings.realName;
    }

    // If no server.address set, inherit.
    if (!server.address.length)
    {
        server.address = KamelosoDefaultStrings.serverAddress;
    }

    // Ditto but `kameloso.constants.KamelosoDefaultIntegers`.
    if (server.port == 0)
    {
        server.port = KamelosoDefaultIntegers.port;
    }
}

///
unittest
{
    import kameloso.constants : KamelosoDefaultIntegers, KamelosoDefaultStrings;
    import std.conv : text;

    IRCClient client;
    IRCServer server;

    assert(!client.nickname.length, client.nickname);
    assert(!client.user.length, client.user);
    assert(!client.ident.length, client.ident);
    assert(!client.realName.length, client.realName);
    assert(!server.address, server.address);
    assert((server.port == 0), server.port.text);

    applyDefaults(client, server);

    assert(client.nickname.length);
    assert((client.user == KamelosoDefaultStrings.user), client.user);
    assert((client.ident == KamelosoDefaultStrings.ident), client.ident);
    assert((client.realName == KamelosoDefaultStrings.realName), client.realName);
    assert((server.address == KamelosoDefaultStrings.serverAddress), server.address);
    assert((server.port == KamelosoDefaultIntegers.port), server.port.text);

    client.nickname = string.init;
    applyDefaults(client, server);

    assert(client.nickname.length, client.nickname);
}


// getPlatform
/++
 +  Returns the string of the name of the current platform, adjusted to include
 +  `cygwin` as an alternative next to `win32` and `win64`, as well as embedded
 +  terminal consoles like in Visual Studio Code.
 +
 +  Returns:
 +      String name of the current platform.
 +/
auto getPlatform()
{
    import std.conv : text;
    import std.process : environment;
    import std.system : os;

    enum osName = os.text;

    version(Windows)
    {
        import std.process : execute;

        immutable term = environment.get("TERM", string.init);

        if (term.length)
        {
            try
            {
                // Get the uname and strip the newline
                immutable uname = execute([ "uname", "-o" ]).output;
                return uname.length ? uname[0..$-1] : osName;
            }
            catch (Exception e)
            {
                return osName;
            }
        }
        else
        {
            return osName;
        }
    }
    else
    {
        return environment.get("TERM_PROGRAM", osName);
    }
}


// printStacktrace
/++
 +  Prints the current stacktrace to the terminal.
 +
 +  This is so we can get the stacktrace even outside a thrown Exception.
 +/
version(PrintStacktraces)
void printStacktrace() @system
{
    import core.runtime : defaultTraceHandler;
    import std.stdio : writeln;

    writeln(defaultTraceHandler);
}


// OutgoingLine
/++
 +  A string to be sent to the IRC server, along with whether or not the message
 +  should be sent quietly or if it should be displayed in the terminal.
 +/
struct OutgoingLine
{
    /// String line to send.
    string line;

    /// Whether or not this message should be sent quietly or verbosely.
    bool quiet;

    /// Constructor.
    this(const string line, const bool quiet = false)
    {
        this.line = line;
        this.quiet = quiet;
    }
}


// findURLs
/++
 +  Finds URLs in a string, returning an array of them.
 +
 +  Replacement for regex matching using much less memory when compiling
 +  (around ~300mb).
 +
 +  To consider: does this need a `dstring`?
 +
 +  Example:
 +  ---
 +  // Replaces the following:
 +  // enum stephenhay = `\bhttps?://[^\s/$.?#].[^\s]*`;
 +  // static urlRegex = ctRegex!stephenhay;
 +
 +  string[] urls = findURL("blah https://google.com http://facebook.com httpx://wefpokwe");
 +  assert(urls.length == 2);
 +  ---
 +
 +  Params:
 +      line = String line to examine and find URLs in.
 +
 +  Returns:
 +      A `string[]` array of found URLs. These include fragment identifiers.
 +/
string[] findURLs(const string line) @safe pure
{
    import lu.string : contains, nom, strippedRight;
    import std.string : indexOf;
    import std.typecons : Flag, No, Yes;

    enum wordBoundaryTokens = ".,!?:";

    string[] hits;
    string slice = line;  // mutable

    ptrdiff_t httpPos = slice.indexOf("http");

    while (httpPos != -1)
    {
        if ((httpPos > 0) && (slice[httpPos-1] != ' '))
        {
            // Run-on http address (character before the 'h')
            slice = slice[httpPos+4..$];
            httpPos = slice.indexOf("http");
            continue;
        }

        slice = slice[httpPos..$];

        if (slice.length < 11)
        {
            // Too short, minimum is "http://a.se".length
            break;
        }
        else if ((slice[4] != ':') && (slice[4] != 's'))
        {
            // Not http or https, something else
            // But could still be another link after this
            slice = slice[5..$];
            httpPos = slice.indexOf("http");
            continue;
        }
        else if (!slice[8..$].contains('.'))
        {
            break;
        }
        else if (!slice.contains(' ') &&
            (slice[10..$].contains("http://") ||
            slice[10..$].contains("https://")))
        {
            // There is a second URL in the middle of this one
            break;
        }

        // nom until the next space if there is one, otherwise just inherit slice
        // Also strip away common punctuation
        hits ~= slice.nom!(Yes.inherit)(' ').strippedRight(wordBoundaryTokens);
        httpPos = slice.indexOf("http");
    }

    return hits;
}

///
unittest
{
    import std.conv : text;

    {
        const urls = findURLs("http://google.com");
        assert((urls.length == 1), urls.text);
        assert((urls[0] == "http://google.com"), urls[0]);
    }
    {
        const urls = findURLs("blah https://a.com http://b.com shttps://c https://d.asdf.asdf.asdf        ");
        assert((urls.length == 3), urls.text);
        assert((urls == [ "https://a.com", "http://b.com", "https://d.asdf.asdf.asdf" ]), urls.text);
    }
    {
        const urls = findURLs("http:// http://asdf https:// asdfhttpasdf http");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("http://a.sehttp://a.shttp://a.http://http:");
        assert(!urls.length, urls.text);
    }
    {
        const urls = findURLs("blahblah https://motorbörsen.se blhblah");
        assert(urls.length, urls.text);
    }
    {
        // Let dlang-requests attempt complex URLs, don't validate more than necessary
        const urls = findURLs("blahblah https://高所恐怖症。co.jp blhblah");
        assert(urls.length, urls.text);
    }
    {
        const urls = findURLs("nyaa is now at https://nyaa.si, https://nyaa.si? " ~
            "https://nyaa.si. https://nyaa.si! and you should use it https://nyaa.si:");

        foreach (immutable url; urls)
        {
            assert((url == "https://nyaa.si"), url);
        }
    }
    {
        const urls = findURLs("https://google.se httpx://google.se https://google.se");
        assert((urls == [ "https://google.se", "https://google.se" ]), urls.text);
    }
}

/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

import lu.core.uda;
import dialect.defs : IRCClient;

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
        bool monochrome = true;  /// Mainly version Windows.
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
    bool endlesslyConnect = false;

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
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct IRCBot
{
    import kameloso.common : OutgoingLine;
    import lu.common : Buffer;
    import lu.net : Connection;
    import kameloso.constants : BufferSize;
    import dialect.parsing : IRCParser;
    import kameloso.plugins.common : IRCPlugin;

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

                if (parser.client.server.daemon == IRCServer.Daemon.twitch)
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
                import lu.core.meld : meldInto;
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

                if (plugin.state.client.updated)
                {
                    parser.client = plugin.state.client;
                    propagateClient(parser.client);
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

            if (plugin.state.client.updated)
            {
                // start changed the client; propagate
                parser.client = plugin.state.client;
                parser.client.updated = false; // all plugins' state.client will be overwritten with this
                propagateClient(parser.client);
            }
        }
    }


    // propagateClient
    /++
     +  Takes a client and passes it out to all plugins.
     +
     +  This is called when a change to the client has occurred and we want to
     +  update all plugins to have an updated copy of it.
     +
     +  Params:
     +      client = `dialect.defs.IRCClient` to propagate to all plugins.
     +/
    void propagateClient(IRCClient client) pure nothrow @nogc
    {
        foreach (plugin; plugins)
        {
            plugin.state.client = client;
        }
    }
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
 +  IRCBot bot;
 +  bot.writeConfigurationFile(bot.settings.configFile);
 +  ---
 +
 +  Params:
 +      bot = Reference to the current `IRCBot`, with all its settings.
 +      filename = String filename of the file to write to.
 +/
void writeConfigurationFile(ref IRCBot bot, const string filename) @system
{
    import lu.serialisation : justifiedConfigurationText, serialise;
    import lu.core.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(4096);  // ~2234

    with (bot.parser)
    {
        if (client.password.length && !client.password.beginsWith("base64:"))
        {
            client.password = "base64:" ~ encode64(client.password);
        }

        sink.serialise(client, client.server, settings);

        foreach (plugin; bot.plugins)
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
 +  sink.serialise(client, client.server, settings);
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
        import lu.core.string : beginsWith;
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


// completeClient
/++
 +  Completes a client's member fields with values needed to connect.
 +
 +  Nickname, user, ident and GECOS/"real name" is required. If there is no
 +  nickname, generate a random one, then just update the other members to have
 +  the same value (if they're empty).
 +
 +  Params:
 +      client = Reference to the `dialect.defs.IRCClient` to complete.
 +/
void completeClient(ref IRCClient client)
out (; (client.nickname.length), "Empty client nickname")
out (; (client.user.length), "Empty client usern ame")
out (; (client.ident.length), "Empty client ident")
out (; (client.realName.length), "Empty client GECOS/real name")
do
{
    // If no client.nickname set, generate a random guest name.
    if (!client.nickname.length)
    {
        import std.format : format;
        import std.random : uniform;

        client.nickname = "guest%03d".format(uniform(0, 1000));
    }

    // If no client.user set, inherit client.nickname into it.
    if (!client.user.length)
    {
        client.user = client.nickname;
    }

    // If no client.ident set, ditto.
    if (!client.ident.length)
    {
        client.ident = client.nickname;
    }

    // If no client.realName set, ditto.
    if (!client.realName.length)
    {
        client.realName = client.nickname;
    }
}

///
unittest
{
    IRCClient client;

    assert(!client.nickname.length, client.nickname);
    assert(!client.user.length, client.user);
    assert(!client.ident.length, client.ident);
    assert(!client.realName.length, client.realName);

    completeClient(client);

    assert(client.nickname.length);
    assert((client.user == client.nickname), client.user);
    assert((client.ident == client.ident), client.ident);
    assert((client.realName == client.realName), client.realName);

    client.user = string.init;
    completeClient(client);

    assert((client.user == client.nickname), client.user);
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

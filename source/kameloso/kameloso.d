/++
    Module for the main `Kameloso` instance struct and its settings structs.
 +/
module kameloso.kameloso;

private:

import std.typecons : Flag, No, Yes;

public:


// Kameloso
/++
    State needed for the kameloso bot, aggregated in a struct for easier passing
    by reference.
 +/
struct Kameloso
{
private:
    import kameloso.common : OutgoingLine, logger;
    import kameloso.constants : BufferSize;
    import kameloso.plugins.common.core : IRCPlugin;
    import dialect.defs : IRCClient, IRCServer;
    import dialect.parsing : IRCParser;
    import lu.container : Buffer;
    import lu.net : Connection;
    import std.datetime.systime : SysTime;


    // Throttle
    /++
        Aggregate of values and state needed to throttle outgoing messages.
     +/
    static struct Throttle
    {
        /// Graph constant modifier (inclination, MUST be negative).
        enum k = -1.2;

        static assert((k < 0), "Throttle graph constant must be negative");

        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        double increment = 1.0;

        /++
            Burst limit; how many messages*increment can be sent initially
            before throttling kicks in.
         +/
        double burst = 3.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);
    }

public:
    /++
        The `lu.net.Connection` that houses and wraps the socket we use to connect
        to, write to and read from the server.
     +/
    Connection conn;

    /++
        A runtime array of all plugins. We iterate these when we have finished
        parsing an `dialect.defs.IRCEvent`, and call the relevant event
        handlers of each.
     +/
    IRCPlugin[] plugins;

    /++
        The root copy of the program-wide settings.
     +/
    CoreSettings settings;

    /++
        Settings relating to the connection between the bot and the IRC server.
     +/
    ConnectionSettings connSettings;

    /++
        An associative array o fwhen a nickname was last issued a WHOIS query for,
        UNIX timestamps by nickname key, for hysteresis and rate-limiting.
     +/
    long[string] previousWhoisTimestamps;

    /// Parser instance.
    IRCParser parser;

    /// IRC bot values and state.
    IRCBot bot;

    /// Values and state needed to throttle sending messages.
    Throttle throttle;

    /++
        When this is set by signal handlers, the program should exit. Other
        parts of the program will be monitoring it.
     +/
    bool* abort;

    /++
        When this is set, the main loop should print a connection summary upon
        the next iteration. It is transient.
     +/
    bool wantLiveSummary;

    /++
        Buffer of outgoing message strings.

        The buffer size is "how many string pointers", now how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) outbuffer;

    /++
        Buffer of outgoing background message strings.

        The buffer size is "how many string pointers", now how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) backgroundBuffer;

    /++
        Buffer of outgoing priority message strings.

        The buffer size is "how many string pointers", now how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) priorityBuffer;

    version(TwitchSupport)
    {
        /++
            Buffer of outgoing fast message strings, used on Twitch servers.

            The buffer size is "how many string pointers", now how many bytes. So
            we can comfortably keep it arbitrarily high.
         +/
        Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer*2) fastbuffer;
    }

    /// Never copy this.
    @disable this(this);


    // throttleline
    /++
        Takes one or more lines from the passed buffer and sends them to the server.

        Sends to the server in a throttled fashion, based on a simple
        `y = k*x + m` graph.

        This is so we don't get kicked by the server for spamming, if a lot of
        lines are to be sent at once.

        Params:
            Buffer = Buffer type, generally `lu.container.Buffer`.
            buffer = Buffer instance.
            dryRun = Whether or not to send anything or just do a dry run,
                incrementing the graph by `Throttle.increment`.
            sendFaster = On Twitch, whether or not we should throttle less and
                send messages faster. Useful in some situations when rate-limiting
                is more lax.

        Returns:
            The time remaining until the next message may be sent, so that we
            can reschedule the next server read timeout to happen earlier.
     +/
    double throttleline(Buffer)(ref Buffer buffer,
        const Flag!"dryRun" dryRun = No.dryRun,
        const Flag!"sendFaster" sendFaster = No.sendFaster) @system
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

            while (!buffer.empty || dryRun)
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

                if (dryRun) break;

                if (!buffer.front.quiet)
                {
                    bool printed;

                    version(Colours)
                    {
                        if (!settings.monochrome)
                        {
                            import kameloso.irccolours : mapEffects;
                            logger.trace("--> ", buffer.front.line.mapEffects);
                            printed = true;
                        }
                    }

                    if (!printed)
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
        Resets and *minimally* initialises all plugins.

        It only initialises them to the point where they're aware of their
        settings, and not far enough to have loaded any resources.

        Params:
            customSettings = String array of custom settings to apply to plugins
                in addition to those read from the configuration file.
            missingEntries = Out reference of an associative array of string arrays
                of expected configuration entries that were missing.
            invalidEntries = Out reference of an associative array of string arrays
                of unexpected configuration entries that did not belong.

        Throws:
            `kameloso.plugins.common.IRCPluginSettingsException` on failure to apply custom settings.
     +/
    void initPlugins(const string[] customSettings,
        out string[][string] missingEntries,
        out string[][string] invalidEntries) @system
    {
        import kameloso.plugins : PluginModules;
        import kameloso.plugins.common : applyCustomSettings;
        import kameloso.plugins.common.core : IRCPluginState;
        import std.concurrency : thisTid;

        teardownPlugins();

        IRCPluginState state;
        state.client = parser.client;
        state.server = parser.server;
        state.bot = this.bot;
        state.mainThread = thisTid;
        state.settings = settings;
        state.connSettings = connSettings;
        state.abort = abort;

        // Instantiate all plugin classes found when introspecting the modules
        // listed in the `kameloso.plugins.PluginModules` AliasSeq.

        plugins.reserve(PluginModules.length);

        foreach (immutable moduleName; PluginModules)
        {
            static assert(__traits(compiles, { mixin("import ", moduleName, ";"); }),
                "Plugin module `" ~ moduleName ~ "` is missing or fails to compile");

            mixin("import pluginModule = ", moduleName, ";");

            foreach (member; __traits(allMembers, pluginModule))
            {
                static if (is(__traits(getMember, pluginModule, member) == class))
                {
                    alias Class = __traits(getMember, pluginModule, member);

                    static if (is(Class : IRCPlugin))
                    {
                        static if (__traits(compiles, new Class(state)))
                        {
                            plugins ~= new Class(state);
                        }
                        else
                        {
                            import std.format : format;
                            static assert(0, "`%s.%s` constructor does not compile"
                                .format(moduleName, Class.stringof));
                        }
                    }
                }
            }
        }

        foreach (plugin; plugins)
        {
            import lu.meld : meldInto;

            string[][string] theseMissingEntries;
            string[][string] theseInvalidEntries;

            plugin.deserialiseConfigFrom(settings.configFile,
                theseMissingEntries, theseInvalidEntries);

            if (theseMissingEntries.length)
            {
                theseMissingEntries.meldInto(missingEntries);
            }

            if (theseInvalidEntries.length)
            {
                theseInvalidEntries.meldInto(invalidEntries);
            }
        }

        immutable allCustomSuccess = plugins.applyCustomSettings(customSettings, settings);

        if (!allCustomSuccess)
        {
            import kameloso.plugins.common : IRCPluginSettingsException;
            throw new IRCPluginSettingsException("Some custom plugin settings could not be applied.");
        }
    }


    // initPlugins
    /++
        Resets and *minimally* initialises all plugins. Merely wraps the other
        `initPlugins` overload and distinguishes itself from it by not taking
        the two `string[][string]` out parameters it does.

        Params:
            customSettings = String array of custom settings to apply to plugins
                in addition to those read from the configuration file.
     +/
    void initPlugins(const string[] customSettings) @system
    {
        string[][string] ignore;
        return initPlugins(customSettings, ignore, ignore);
    }


    // initPluginResources
    /++
        Initialises all plugins' resource files.

        This merely calls `kameloso.plugins.common.core.IRCPlugin.initResources` on
        each plugin.
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
        Tears down all plugins, deinitialising them and having them save their
        settings for a clean shutdown. Calls module-level `teardown` functions.

        Think of it as a plugin destructor.
     +/
    void teardownPlugins() @system
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;
            import core.memory : GC;

            try
            {
                plugin.teardown();
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
                version(PrintStacktraces) logger.trace(e);
            }

            destroy(plugin);
            GC.free(&plugin);
        }

        // Zero out old plugins array
        plugins = typeof(plugins).init;
    }


    // startPlugins
    /++
        Start all plugins, loading any resources they may want and calling any
        module-level `start` functions.

        This has to happen after `initPlugins` or there will not be any plugins
        in the `plugins` array.
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

            if (plugin.state.settingsUpdated)
            {
                // Something changed the settings; propagate
                plugin.state.settingsUpdated = false;
                propagateSettings(plugin.state.settings);
            }
        }
    }


    // propagateClient
    /++
        Takes an `dialect.defs.IRCClient` and passes it out to all plugins.

        This is called when a change to the client has occurred and we want to
        update all plugins to have a current copy of it.

        Params:
            client = `dialect.defs.IRCClient` to propagate to all plugins.
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
        Takes an `dialect.defs.IRCServer` and passes it out to all plugins.

        This is called when a change to the server has occurred and we want to
        update all plugins to have a current copy of it.

        Params:
            server = `dialect.defs.IRCServer` to propagate to all plugins.
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
        Takes an `kameloso.kameloso.IRCBot` and passes it out to all plugins.

        This is called when a change to the bot has occurred and we want to
        update all plugins to have a current copy of it.

        Params:
            bot = `kameloso.kameloso.IRCBot` to propagate to all plugins.
     +/
    void propagateBot(IRCBot bot) pure nothrow @nogc
    {
        this.bot = bot;

        foreach (plugin; plugins)
        {
            plugin.state.bot = bot;
        }
    }


    // propagateSettings
    /++
        Takes a `kameloso.kameloso.CoreSettings` and passes it out to all plugins.

        This is called when a change to the bot has occurred and we want to
        update all plugins to have a current copy of it.

        Params:
            settings = `kameloso.kameloso.CoreSettings` to propagate to all plugins.
     +/
    void propagateSettings(CoreSettings settings) nothrow @nogc
    {
        // Inherit the changes ourselves
        this.settings = settings;

        foreach (plugin; plugins)
        {
            plugin.state.settings = settings;
        }
    }


    // ConnectionHistoryEntry
    /++
        A record of a successful connection.
     +/
    static struct ConnectionHistoryEntry
    {
        /// UNIX time when this connection was established.
        long startTime;

        /// UNIX time when this connection was lost.
        long stopTime;

        /// How many events fired during this connection.
        long numEvents;

        /// How many bytses were read during this connection.
        long bytesReceived;
    }

    /// History records of established connections this execution run.
    ConnectionHistoryEntry[] connectionHistory;
}


// CoreSettings
/++
    Aggregate struct containing runtime bot setting variables.

    Kept inside one struct, they're nicely gathered and easy to pass around.
    Some defaults are hardcoded here.
 +/
struct CoreSettings
{
private:
    import lu.uda : CannotContainComments, Hidden, Quoted, Unserialisable;

public:
    version(Colours)
    {
        bool monochrome = false;  /// Logger monochrome setting.
    }
    else
    {
        bool monochrome = true;  /// Non-colours version defaults to true.
    }

    /// Flag denoting that the terminal has a bright background.
    bool brightTerminal = false;

    /// Flag denoting that usermasks should be used instead of accounts to authenticate users.
    bool preferHostmasks = false;

    /// Whether or not to hide outgoing messages, not printing them to screen.
    bool hideOutgoing = false;

    /// Whether or not to add colours to outgoing messages.
    bool colouredOutgoing = true;

    /// Flag denoting that we should save configuration changes to file on exit.
    bool saveOnExit = false;

    /// Whether or not to display a connection summary on program exit.
    bool exitSummary = false;

    /++
        Whether to eagerly and exhaustively WHOIS all participants in home channels,
        or to do a just-in-time lookup when needed.
     +/
    bool eagerLookups = false;

    /++
        Character(s) that prefix a bot chat command.

        These decide what bot commands will look like; "!" for "!command",
        "~" for "~command", "." for ".command", etc. It can be any string and
        not just one character.
     +/
    @Quoted string prefix = "!";

    @Unserialisable
    @Hidden
    {
        string configFile;  /// Main configuration file.
        string resourceDirectory;  /// Path to resource directory.
        string configDirectory;  /// Path to configuration directory.
        bool force;  /// Whether or not to force connecting, skipping some sanity checks.
        bool flush;  /// Whether or not to explicitly set stdout to flush after writing a linebreak to it.
    }
}


// ConnectionSettings
/++
    Aggregate of values used in the connection between the bot and the IRC server.
 +/
struct ConnectionSettings
{
private:
    import lu.uda : CannotContainComments;

public:
    /// Flag denoting whether or not the program should reconnect after disconnect.
    bool reconnectOnFailure = true;

    /// Whether to endlessly connect or whether to give up after a while.
    bool endlesslyConnect = true;

    /// Whether to connect to IPv6 addresses or only use IPv4 ones.
    bool ipv6 = true;

    /// Path to private (`.pem`) key file, used in SSL connections.
    @CannotContainComments string privateKeyFile;

    /// Path to certificate (`.pem`) file.
    @CannotContainComments string certFile;

    /// Path to certificate bundle `cacert.pem` file or equivalent.
    @CannotContainComments string caBundleFile;

    /// Whether or not to attempt an SSL connection.
    bool ssl = false;
}


// IRCBot
/++
    Aggregate of information relevant for an IRC *bot* that goes beyond what is
    needed for a mere IRC *client*.
 +/
struct IRCBot
{
private:
    import lu.uda : CannotContainComments, Hidden, Separator;

public:
    /// Username to use as services account login name.
    string account;

    @Hidden
    @CannotContainComments
    {
        /// Password for services account.
        string password;

        /// Login `PASS`, different from `SASL` and services.
        string pass;

        /// Default reason given when quitting and not specifying a reason text.
        string quitReason;

        /// Default reason given when parting a channel and not specifying a reason text.
        string partReason;
    }

    @Separator(",")
    @Separator(" ")
    {
        /// The nickname services accounts of administrators, in a bot-like context.
        string[] admins;

        /// List of home channels for the bot to operate in.
        @CannotContainComments
        string[] homeChannels;

        @Hidden
        deprecated("Use `homeChannels` instead")
        alias homes = homeChannels;

        /// Currently inhabited non-home guest channels.
        @CannotContainComments
        string[] guestChannels;

        @Hidden
        deprecated("Use `guestChannels` instead")
        alias channels = guestChannels;
    }
}

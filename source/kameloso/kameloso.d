/++
    Module for the main [Kameloso] instance struct and its settings structs.
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
    import kameloso.net : Connection;
    import kameloso.plugins.common.core : IRCPlugin;
    import dialect.defs : IRCClient, IRCServer;
    import dialect.parsing : IRCParser;
    import lu.container : Buffer;
    import std.datetime.systime : SysTime;

    // Throttle
    /++
        Aggregate of values and state needed to throttle outgoing messages.
     +/
    static struct Throttle
    {
        /// Origo of x-axis (last sent message).
        SysTime t0;

        /// y at t0 (ergo y at x = 0, weight at last sent message).
        double m = 0.0;

        /// Increment to y on sent message.
        enum increment = 1.0;

        /// Don't copy this, just keep one instance.
        @disable this(this);

        /// Resets the throttle values in-place.
        void reset()
        {
            t0 = SysTime.init;
            m = 0.0;
        }
    }

    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Private value.
     +/
    uint privateConnectionID;

public:
    /++
        The [kameloso.net.Connection|Connection] that houses and wraps the socket
        we use to connect to, write to and read from the server.
     +/
    Connection conn;

    /++
        A runtime array of all plugins. We iterate these when we have finished
        parsing an [dialect.defs.IRCEvent|IRCEvent], and call the relevant event
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

    /++
        Buffer of outgoing message strings to be sent immediately.

        The buffer size is "how many string pointers", now how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) immediateBuffer;

    version(TwitchSupport)
    {
        /++
            Buffer of outgoing fast message strings, used on Twitch servers.

            The buffer size is "how many string pointers", now how many bytes. So
            we can comfortably keep it arbitrarily high.
         +/
        Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer*2) fastbuffer;
    }

    /++
        Associative array of string arrays of expected configuration entries
        that were missing.
     +/
    string[][string] missingConfigurationEntries;

    /++
        Associative array of string arrays of unexpected configuration entries
        that did not belong.
     +/
    string[][string] invalidConfigurationEntries;

    /++
        Custom settings specfied at the command line with the `--set` parameter.
     +/
    string[] customSettings;

    /// Never copy this.
    @disable this(this);

    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Accessor.

        Returns:
            The numeric ID of the current connection.
     +/
    pragma(inline, true)
    auto connectionID()
    {
        return privateConnectionID;
    }

    /++
        Generates a new connection ID.

        Don't include the number 0, or it may collide with the default value of `static uint`.
     +/
    void generateNewConnectionID() @safe
    {
        import std.random : uniform;
        privateConnectionID = uniform(1, 1001);
    }

    // throttleline
    /++
        Takes one or more lines from the passed buffer and sends them to the server.

        Sends to the server in a throttled fashion, based on a simple
        `y = k*x + m` graph.

        This is so we don't get kicked by the server for spamming, if a lot of
        lines are to be sent at once.

        Params:
            Buffer = Buffer type, generally [lu.container.Buffer].
            buffer = Buffer instance.
            dryRun = Whether or not to send anything or just do a dry run,
                incrementing the graph by [Throttle.increment].
            sendFaster = On Twitch, whether or not we should throttle less and
                send messages faster. Useful in some situations when rate-limiting
                is more lax.
            immediate = Whether or not the line should just be sent straight away,
                ignoring throttling.

        Returns:
            The time remaining until the next message may be sent, so that we
            can reschedule the next server read timeout to happen earlier.
     +/
    double throttleline(Buffer)
        (ref Buffer buffer,
        const Flag!"dryRun" dryRun = No.dryRun,
        const Flag!"sendFaster" sendFaster = No.sendFaster,
        const Flag!"immediate" immediate = No.immediate) @system
    {
        import std.datetime.systime : Clock;

        alias t = throttle;

        immutable now = Clock.currTime;
        if (t.t0 == SysTime.init) t.t0 = now;

        double k = -connSettings.messageRate;
        double burst = connSettings.messageBurst;

        version(TwitchSupport)
        {
            import dialect.defs : IRCServer;

            if (parser.server.daemon == IRCServer.Daemon.twitch)
            {
                import kameloso.constants : ConnectionDefaultFloats;

                if (sendFaster)
                {
                    k = -ConnectionDefaultFloats.messageRateTwitchFast;
                    burst = ConnectionDefaultFloats.messageBurstTwitchFast;
                }
                else
                {
                    k = -ConnectionDefaultFloats.messageRateTwitchSlow;
                    burst = ConnectionDefaultFloats.messageBurstTwitchSlow;
                }
            }
        }

        while (!buffer.empty || dryRun)
        {
            if (!immediate)
            {
                double x = (now - t.t0).total!"msecs"/1000.0;
                double y = k * x + t.m;

                if (y < 0.0)
                {
                    t.t0 = now;
                    x = 0.0;
                    y = 0.0;
                    t.m = 0.0;
                }

                if (y >= burst)
                {
                    x = (now - t.t0).total!"msecs"/1000.0;
                    y = k*x + t.m;
                    return y;
                }

                t.m = y + t.increment;
                t.t0 = now;
            }

            if (dryRun) break;

            if (settings.trace || !buffer.front.quiet)
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


    // initPlugins
    /++
        Resets and *minimally* initialises all plugins.

        It only initialises them to the point where they're aware of their
        settings, and not far enough to have loaded any resources.

        Throws:
            [kameloso.plugins.common.misc.IRCPluginSettingsException|IRCPluginSettingsException]
            on failure to apply custom settings.
     +/
    void initPlugins() @system
    {
        import kameloso.plugins : PluginModules;
        import kameloso.plugins.common.core : IRCPluginHook, IRCPluginState;
        import kameloso.plugins.common.misc : applyCustomSettings;
        import lu.traits : getSymbolsByUDA;
        import std.concurrency : thisTid;

        teardownPlugins();

        auto state = IRCPluginState(this.connectionID);
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
            static if (is(typeof(moduleName) : string) && moduleName.length)
            {
                static if (__traits(compiles, { mixin("alias thisModule = " ~ moduleName ~ ".base;"); }))
                {
                    static if (!__traits(compiles, { mixin("import " ~ moduleName ~ ".base;"); }))
                    {
                        import std.format : format;
                        enum pattern = "Plugin module `%s.base` (inferred from listing `%1$s`" ~
                            "in `plugins/package.d`) fails to compile";
                        static assert(0, pattern.format(moduleName));
                    }

                    mixin("import pluginModule = " ~ moduleName ~ ".base;");
                }
                else
                {
                    static if (!__traits(compiles, { mixin("import " ~ moduleName ~ ";"); }))
                    {
                        import std.format : format;
                        enum pattern = "Plugin module `%s` (listed in `plugins/package.d`) fails to compile";
                        static assert(0, pattern.format(moduleName));
                    }

                    mixin("import pluginModule = " ~ moduleName ~ ";");
                }

                foreach (Plugin; getSymbolsByUDA!(pluginModule, IRCPluginHook))
                {
                    static if (__traits(compiles, new Plugin(state)))
                    {
                        plugins ~= new Plugin(state);
                    }
                    else
                    {
                        import std.format : format;
                        enum pattern = "`%s.%s` constructor does not compile";
                        static assert(0, pattern.format(moduleName, Class.stringof));
                    }
                }
            }
            else
            {
                import std.conv : text;
                static assert(0, text("Invalid `PluginModules` entry in `plugins/package.d`: `",
                    moduleName, '`'));
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
                theseMissingEntries.meldInto(this.missingConfigurationEntries);
            }

            if (theseInvalidEntries.length)
            {
                theseInvalidEntries.meldInto(this.invalidConfigurationEntries);
            }
        }

        immutable allCustomSuccess = plugins.applyCustomSettings(this.customSettings, settings);

        if (!allCustomSuccess)
        {
            import kameloso.plugins.common.misc : IRCPluginSettingsException;
            throw new IRCPluginSettingsException("Some custom plugin settings could not be applied.");
        }
    }


    // initPluginResources
    /++
        Initialises all plugins' resource files.

        This merely calls
        [kameloso.plugins.common.core.IRCPlugin.initResources|IRCPlugin.initResources]
        on each plugin.
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

        Don't teardown disabled plugins as they may not have been initialised fully.
     +/
    void teardownPlugins() @system
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;
            import core.memory : GC;

            if (!plugin.isEnabled) continue;

            try
            {
                plugin.teardown();
            }
            catch (ErrnoException e)
            {
                import std.file : exists;
                import std.path : dirName;
                import core.stdc.errno : ENOENT;

                if ((e.errno == ENOENT) && !settings.resourceDirectory.dirName.exists)
                {
                    // The resource directory hasn't been created, don't panic
                }
                else
                {
                    enum pattern = "ErrnoException when tearing down <l>%s</>: <l>%s";
                    logger.warningf(pattern, plugin.name, e.msg);
                    version(PrintStacktraces) logger.trace(e.info);
                }
            }
            catch (Exception e)
            {
                enum pattern = "Exception when tearing down <l>%s</>: <l>%s";
                logger.warningf(pattern, plugin.name, e.msg);
                version(PrintStacktraces) logger.trace(e);
            }

            destroy(plugin);
            GC.free(&plugin);
        }

        // Zero out old plugins array
        plugins = null;
    }


    // setupPlugins
    /++
        Sets up all plugins, calling any module-level `setup` functions.

        This has to happen after [initPlugins] or there will not be any plugins
        in the [plugins] array.

        Don't setup disabled plugins.
     +/
    void setupPlugins() @system
    {
        foreach (plugin; plugins)
        {
            if (!plugin.isEnabled) continue;

            plugin.setup();
            checkPluginForUpdates(plugin);
        }
    }


    // startPlugins
    /++
        Starts all plugins by calling any module-level `start` functions.

        This happens after connection has been established.

        Don't start disabled plugins.
     +/
    void startPlugins() @system
    {
        foreach (plugin; plugins)
        {
            if (!plugin.isEnabled) continue;

            plugin.start();
            checkPluginForUpdates(plugin);
        }
    }


    // checkPluginForUpdates
    /++
        Propagates updated bots, clients, servers and/or settings, to `this`,
        [parser], and to all plugins.

        Params:
            plugin = The plugin whose
                [kameloso.plugins.common.core.IRCPluginState|IRCPluginState]s
                member structs to inspect for updates.
     +/
    void checkPluginForUpdates(IRCPlugin plugin)
    {
        alias Update = typeof(plugin.state.updates);

        if (plugin.state.updates & Update.bot)
        {
            // Something changed the bot; propagate
            plugin.state.updates ^= Update.bot;
            propagate(plugin.state.bot);
        }

        if (plugin.state.updates & Update.client)
        {
            // Something changed the client; propagate
            plugin.state.updates ^= Update.client;
            propagate(plugin.state.client);
        }

        if (plugin.state.updates & Update.server)
        {
            // Something changed the server; propagate
            plugin.state.updates ^= Update.server;
            propagate(plugin.state.server);
        }

        if (plugin.state.updates & Update.settings)
        {
            static import kameloso.common;

            // Something changed the settings; propagate
            plugin.state.updates ^= Update.settings;
            propagate(plugin.state.settings);
            this.settings = plugin.state.settings;

            // This shouldn't be necessary since kameloso.common.settings points to this.settings
            //*kameloso.common.settings = plugin.state.settings;
        }

        assert((plugin.state.updates == Update.nothing),
            "`IRCPluginState.updates` was not reset after checking and propagation");
    }


    // propagate
    /++
        Propgates an updated struct, to `this`, [parser], and to each plugins'
        [kameloso.plugins.common.core.IRCPluginState|IRCPluginState]s, overwriting
        existing such.

        Params:
            thing = Struct object to propagate.
     +/
    //pragma(inline, true)
    void propagate(Thing)(Thing thing) pure nothrow @nogc
    if (is(Thing == struct))
    {
        import std.meta : AliasSeq;

        aliasloop:
        foreach (ref sym; AliasSeq!(this, parser))
        {
            foreach (immutable i, ref member; sym.tupleof)
            {
                alias T = typeof(sym.tupleof[i]);

                static if (is(T == Thing))
                {
                    sym.tupleof[i] = thing;
                    continue aliasloop;
                }
            }
        }

        pluginloop:
        foreach (plugin; plugins)
        {
            foreach (immutable i, ref member; plugin.state.tupleof)
            {
                alias T = typeof(plugin.state.tupleof[i]);

                static if (is(T == Thing))
                {
                    plugin.state.tupleof[i] = thing;
                    continue pluginloop;
                }
            }
        }
    }


    // propagateWhoisTimestamp
    /++
        Propagates a single update to the the [previousWhoisTimestamps]
        associative array to all plugins.

        Params:
            nickname = Nickname whose WHOIS timestamp to propagate.
            now = UNIX WHOIS timestamp.
     +/
    void propagateWhoisTimestamp(const string nickname, const long now) pure
    {
        foreach (plugin; plugins)
        {
            plugin.state.previousWhoisTimestamps[nickname] = now;
        }
    }


    // propagateWhoisTimestamps
    /++
        Propagates the [previousWhoisTimestamps] associative array to all plugins.

        Makes a copy of it before passing it onwards; this way, plugins cannot
        modify the original.
     +/
    void propagateWhoisTimestamps() pure
    {
        auto copy = previousWhoisTimestamps.dup;  // mutable

        foreach (plugin; plugins)
        {
            plugin.state.previousWhoisTimestamps = copy;
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
        ulong bytesReceived;
    }

    /// History records of established connections this execution run.
    ConnectionHistoryEntry[] connectionHistory;

    /// Set when the Socket read timeout was requested to be shortened.
    bool wantReceiveTimeoutShortened;

    version(TwitchSupport)
    {
        /++
            Set when an [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME]
            event was encountered.
         +/
        bool sawWelcome;
    }
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

    @Hidden
    {
        /++
            Whether to eagerly and exhaustively WHOIS all participants in home channels,
            or to do a just-in-time lookup when needed.
         +/
        bool eagerLookups = false;

        /++
            Whether or not to be "headless", disabling all terminal output.
         +/
        bool headless;
    }

    /++
        Path to resource directory.
     +/
    @Hidden
    @CannotContainComments
    string resourceDirectory;

    /++
        Character(s) that prefix a bot chat command.

        These decide what bot commands will look like; "!" for "!command",
        "~" for "~command", "." for ".command", etc. It can be any string and
        not just one character.
     +/
    @Quoted string prefix = "!";

    @Unserialisable
    {
        /++
            Main configuration file.
         +/
        string configFile;

        /++
            Path to configuration directory.
         +/
        string configDirectory;

        /++
            Whether or not to force connecting, skipping some sanity checks.
         +/
        bool force;

        /++
            Whether or not to explicitly set stdout to flush after writing a linebreak to it.
         +/
        bool flush;

        /++
            Whether or not *all* outgoing messages should be echoed to the terminal.
         +/
        bool trace;

        /++
            Whether to print addresses as IPs or as hostnames (where applicable).
         +/
        bool numericAddresses;
    }
}


// ConnectionSettings
/++
    Aggregate of values used in the connection between the bot and the IRC server.
 +/
struct ConnectionSettings
{
private:
    import kameloso.constants : ConnectionDefaultFloats, Timeout;
    import lu.uda : CannotContainComments, Hidden;

public:
    /// Whether to connect to IPv6 addresses or only use IPv4 ones.
    bool ipv6 = true;

    @CannotContainComments
    @Hidden
    {
        /// Path to private (`.pem`) key file, used in SSL connections.
        string privateKeyFile;

        /// Path to certificate (`.pem`) file.
        string certFile;

        /// Path to certificate bundle `cacert.pem` file or equivalent.
        string caBundleFile;
    }

    /// Whether or not to attempt an SSL connection.
    bool ssl = false;

    @Hidden
    {
        /// Socket receive timeout in milliseconds (how often to check for concurrency messages).
        uint receiveTimeout = Timeout.receiveMsecs;

        /// How many messages to send per second, maximum.
        double messageRate = ConnectionDefaultFloats.messageRate;

        /// How many messages to immediately send in one go, before throttling kicks in.
        double messageBurst = ConnectionDefaultFloats.messageBurst;
    }
}


// IRCBot
/++
    Aggregate of information relevant for an IRC *bot* that goes beyond what is
    needed for a mere IRC *client*.
 +/
struct IRCBot
{
private:
    import lu.uda : CannotContainComments, Hidden, Separator, Unserialisable;

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

        /// Currently inhabited non-home guest channels.
        @CannotContainComments
        string[] guestChannels;
    }

    /++
        Whether or not we connected without an explicit nickname, and a random
        guest such was generated.
     +/
    @Unserialisable bool hasGuestNickname;
}

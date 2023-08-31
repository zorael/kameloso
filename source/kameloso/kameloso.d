/++
    Module for the main [Kameloso] instance struct.

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
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
    import kameloso.pods : ConnectionSettings, CoreSettings, IRCBot;
    import dialect.defs : IRCClient, IRCServer;
    import dialect.parsing : IRCParser;
    import lu.container : Buffer;
    import std.algorithm.comparison : among;
    import core.time : MonoTime;

    // Throttle
    /++
        Aggregate of values and state needed to throttle outgoing messages.
     +/
    static struct Throttle
    {
        // t0
        /++
            Origo of x-axis (last sent message).
         +/
        MonoTime t0;

        // m
        /++
            y at t0 (ergo y at x = 0, weight at last sent message).
         +/
        double m = 0.0;

        // bump
        /++
            By how much to bump y on sent message.
         +/
        enum bump = 1.0;

        // this(this)
        /++
            Don't copy this, just keep one instance.
         +/
        @disable this(this);

        // reset
        /++
            Resets the throttle values in-place.
         +/
        void reset()
        {
            // No need to reset t0, it will just exceed burst on next throttleline
            m = 0.0;
        }
    }

    // State
    /++
        Transient state bool flags, aggregated in a struct.
     +/
    static struct StateFlags
    {
        // wantReceiveTimeoutShortened
        /++
            Set when the Socket read timeout was requested to be shortened.
         +/
        bool wantReceiveTimeoutShortened;

        // wantLiveSummary
        /++
            When this is set, the main loop should print a connection summary upon
            the next iteration.
         +/
        bool wantLiveSummary;

        // askedToReconnect
        /++
            Set when the server asked us to reconnect (by way of a
            [dialect.defs.IRCEvent.Type.RECONNECT|RECONNECT] event).
         +/
        bool askedToReconnect;

        // quitMessageSent
        /++
            Set when we have sent a QUIT message to the server.
         +/
        bool quitMessageSent;

        // askedToReexec
        /++
            Set when the user explicitly asked to re-exec in the middle of a session.
         +/
        bool askedToReexec;

        version(TwitchSupport)
        {
            // sawWelcome
            /++
                Set when an [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME]
                event was encountered.
             +/
            bool sawWelcome;
        }
    }

    // _connectionID
    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Private value.
     +/
    uint _connectionID;

public:
    // ctor
    /++
        Constructor taking an [args] string array.
     +/
    this(string[] args) pure @safe nothrow @nogc
    {
        this.args = args;
    }

    // flags
    /++
        Transient state flags of this [Kameloso] instance.
     +/
    StateFlags flags;

    // args
    /++
        Command-line arguments passed to the program.
     +/
    string[] args;

    // conn
    /++
        The [kameloso.net.Connection|Connection] that houses and wraps the socket
        we use to connect to, write to and read from the server.
     +/
    Connection conn;

    // plugins
    /++
        A runtime array of all plugins. We iterate these when we have finished
        parsing an [dialect.defs.IRCEvent|IRCEvent], and call the relevant event
        handlers of each.
     +/
    IRCPlugin[] plugins;

    // settings
    /++
        The root copy of the program-wide settings.
     +/
    CoreSettings settings;

    // connSettings
    /++
        Settings relating to the connection between the bot and the IRC server.
     +/
    ConnectionSettings connSettings;

    // previousWhoisTimestamps
    /++
        An associative array o fwhen a nickname was last issued a WHOIS query for,
        UNIX timestamps by nickname key, for hysteresis and rate-limiting.
     +/
    long[string] previousWhoisTimestamps;

    // parser
    /++
        Parser instance.
     +/
    IRCParser parser;

    // bot
    /++
        IRC bot values and state.
     +/
    IRCBot bot;

    // throttle
    /++
        Values and state needed to throttle sending messages.
     +/
    Throttle throttle;

    // abort
    /++
        When this is set by signal handlers, the program should exit. Other
        parts of the program will be monitoring it.
     +/
    Flag!"abort"* abort;

    // outbuffer
    /++
        Buffer of outgoing message strings.

        The buffer size is "how many string pointers", not how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) outbuffer;

    // backgroundBuffer
    /++
        Buffer of outgoing background message strings.

        The buffer size is "how many string pointers", not how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) backgroundBuffer;

    // priorityBuffer
    /++
        Buffer of outgoing priority message strings.

        The buffer size is "how many string pointers", not how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) priorityBuffer;

    // immediateBuffer
    /++
        Buffer of outgoing message strings to be sent immediately.

        The buffer size is "how many string pointers", not how many bytes. So
        we can comfortably keep it arbitrarily high.
     +/
    Buffer!(OutgoingLine, No.dynamic, BufferSize.priorityBuffer) immediateBuffer;

    version(TwitchSupport)
    {
        // fastbuffer
        /++
            Buffer of outgoing fast message strings, used on Twitch servers.

            The buffer size is "how many string pointers", not how many bytes. So
            we can comfortably keep it arbitrarily high.
         +/
        Buffer!(OutgoingLine, No.dynamic, BufferSize.outbuffer) fastbuffer;
    }

    // missingConfigurationEntries
    /++
        Associative array of string arrays of expected configuration entries
        that were missing.
     +/
    string[][string] missingConfigurationEntries;

    // invalidConfigurationEntries
    /++
        Associative array of string arrays of unexpected configuration entries
        that did not belong.
     +/
    string[][string] invalidConfigurationEntries;

    // customSettings
    /++
        Custom settings specified at the command line with the `--set` parameter.
     +/
    string[] customSettings;

    version(Callgrind)
    {
        // callgrindRunning
        /++
            Flag to keep record of whether or not the program is run under the
            Callgrind profiler.

            Assume it is until proven otherwise.
         +/
        bool callgrindRunning = true;
    }

    // this(this)
    /++
        Never copy this.
     +/
    @disable this(this);

    // connectionID
    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Accessor.

        Returns:
            The numeric ID of the current connection.
     +/
    pragma(inline, true)
    auto connectionID() const
    {
        return _connectionID;
    }

    // generateNewConnectionID
    /++
        Generates a new connection ID.

        Don't include the number 0, or it may collide with the default value of `static uint`.
     +/
    void generateNewConnectionID() @safe
    {
        import std.random : uniform;

        synchronized //()
        {
            immutable previous = _connectionID;

            do
            {
                _connectionID = uniform(1, uint.max);
            }
            while (_connectionID == previous);
        }
    }

    // throttleline
    /++
        Takes one or more lines from the passed buffer and sends them to the server.

        Sends to the server in a throttled fashion, based on a simple
        `y = k*x + m` graph.

        This is so we don't get kicked by the server for spamming, if a lot of
        lines are to be sent at once.

        Params:
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
    auto throttleline(Buffer)
        (ref Buffer buffer,
        const Flag!"dryRun" dryRun = No.dryRun,
        const Flag!"sendFaster" sendFaster = No.sendFaster,
        const Flag!"immediate" immediate = No.immediate)
    {
        import core.time : MonoTime;

        alias t = throttle;

        immutable now = MonoTime.currTime;
        double k = connSettings.messageRate;
        double burst = connSettings.messageBurst;

        version(TwitchSupport)
        {
            if (parser.server.daemon == IRCServer.Daemon.twitch)
            {
                import kameloso.constants : ConnectionDefaultFloats;

                if (sendFaster)
                {
                    k = ConnectionDefaultFloats.messageRateTwitchFast;
                    burst = ConnectionDefaultFloats.messageBurstTwitchFast;
                }
                else
                {
                    k = ConnectionDefaultFloats.messageRateTwitchSlow;
                    burst = ConnectionDefaultFloats.messageBurstTwitchSlow;
                }
            }
        }

        while (!buffer.empty || dryRun)
        {
            if (!immediate)
            {
                /// Position on x-axis; how many msecs have passed since last message was sent
                immutable x = (now - t.t0).total!"msecs"/1000.0;
                /// Value of point on line
                immutable y = k*x + t.m;

                if (y > burst)
                {
                    t.t0 = now;
                    t.m = burst;
                    // Drop down
                }
                else if (y < 0.0)
                {
                    // Not yet time, delay
                    return -y/k;
                }

                // Record as sent and drop down to actually send
                t.m -= Throttle.bump;
            }

            if (dryRun) break;

            if (!settings.headless && (settings.trace || !buffer.front.quiet))
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

    // instantiatePlugins
    /++
        Instantiates and *minimally* initialises all plugins.

        It only initialises them to the point where they're aware of their
        settings, and not far enough to have loaded any resources.

        Throws:
            [kameloso.plugins.common.misc.IRCPluginSettingsException|IRCPluginSettingsException]
            on failure to apply custom settings.
     +/
    void instantiatePlugins() @system
    in (!this.plugins.length, "Tried to instantiate plugins but the array was not empty")
    {
        import kameloso.plugins.common.core : IRCPluginState;
        import kameloso.plugins.common.misc : applyCustomSettings;
        import std.concurrency : thisTid;
        static import kameloso.plugins;

        teardownPlugins();

        auto state = IRCPluginState(this.connectionID);
        state.client = parser.client;
        state.server = parser.server;
        state.bot = this.bot;
        state.mainThread = thisTid;
        state.settings = settings;
        state.connSettings = connSettings;
        state.abort = abort;

        // Leverage kameloso.plugins.instantiatePlugins to construct all plugins.
        this.plugins = kameloso.plugins.instantiatePlugins(state);

        foreach (plugin; plugins)
        {
            import lu.meld : meldInto;

            string[][string] theseMissingEntries;
            string[][string] theseInvalidEntries;

            plugin.deserialiseConfigFrom(
                settings.configFile,
                theseMissingEntries,
                theseInvalidEntries);

            if (theseMissingEntries.length)
            {
                theseMissingEntries.meldInto(this.missingConfigurationEntries);
            }

            if (theseInvalidEntries.length)
            {
                theseInvalidEntries.meldInto(this.invalidConfigurationEntries);
            }
        }

        immutable allCustomSuccess = applyCustomSettings(plugins, this.customSettings, this.settings);

        if (!allCustomSuccess)
        {
            import kameloso.plugins.common.misc : IRCPluginSettingsException;
            throw new IRCPluginSettingsException("Some custom plugin settings could not be applied.");
        }
    }

    // issuePluginCallImpl
    /++
        Issues a call to all plugins, where such a call is one of "setup",
        "start", "initResources" or "reload". This invokes their module-level
        functions of the same name, where available.

        In the case of "initResources", the call does not care whether the
        plugins are enabled, but in all other cases they are skipped if so.

        Params:
            call = String name of call to issue to all plugins.
     +/
    private void issuePluginCallImpl(string call)()
    if (call.among!("setup", "reload", "initResources"))
    {
        foreach (plugin; this.plugins)
        {
            static if (call != "initResources")
            {
                // Always init resources, even if the plugin is disabled
                if (!plugin.isEnabled) continue;
            }

            mixin("plugin." ~ call ~ "();");
            checkPluginForUpdates(plugin);
        }
    }

    // setupPlugins
    /++
        Sets up all plugins, calling any module-level `setup` functions.
        This happens after connection has been established.

        This merely calls
        [kameloso.plugins.common.core.IRCPlugin.setupIRCPlugin.setup]
        on each plugin.

        Don't setup disabled plugins.
     +/
    alias setupPlugins = issuePluginCallImpl!"setup";

    // initPluginResources
    /++
        Initialises all plugins' resource files.

        This merely calls
        [kameloso.plugins.common.core.IRCPlugin.initResources|IRCPlugin.initResources]
        on each plugin.
     +/
    alias initPluginResources = issuePluginCallImpl!"initResources";

    // reloadPlugins
    /++
        Reloads all plugins by calling any module-level `reload` functions.

        This merely calls
        [kameloso.plugins.common.core.IRCPlugin.reload|IRCPlugin.reload]
        on each plugin.

        What this actually does is up to the plugins.
     +/
    alias reloadPlugins = issuePluginCallImpl!"reload";

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

        foreach (ref plugin; plugins)
        {
            import std.exception : ErrnoException;
            import core.thread : Fiber;

            if (!plugin.isEnabled) continue;

            try
            {
                plugin.teardown();

                foreach (scheduledFiber; plugin.state.scheduledFibers)
                {
                    // All Fibers should be at HOLD state but be conservative
                    if (scheduledFiber.fiber.state != Fiber.State.EXEC)
                    {
                        destroy(scheduledFiber.fiber);
                        scheduledFiber.fiber = null;
                    }
                }

                plugin.state.scheduledFibers = null;

                foreach (scheduledDelegate; plugin.state.scheduledDelegates)
                {
                    destroy(scheduledDelegate.dg);
                    scheduledDelegate.dg = null;
                }

                plugin.state.scheduledDelegates = null;

                foreach (immutable type, ref fibersForType; plugin.state.awaitingFibers)
                {
                    foreach (fiber; fibersForType)
                    {
                        // As above
                        if (fiber.state != Fiber.State.EXEC)
                        {
                            destroy(fiber);
                            fiber = null;
                        }
                    }
                }

                plugin.state.awaitingFibers = null;

                foreach (immutable type, ref dgsForType; plugin.state.awaitingDelegates)
                {
                    foreach (ref dg; dgsForType)
                    {
                        destroy(dg);
                        dg = null;
                    }
                }

                plugin.state.awaitingDelegates = null;
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
            plugin = null;   // needs ref
        }

        // Zero out old plugins array
        plugins = null;
    }

    // initialisePlugins
    /++
        Initialises all plugins, calling any module-level `.initialise` functions.

        This merely calls
        [kameloso.plugins.common.core.IRCPlugin.initialise|IRCPlugin.initialise]
        on each plugin.

        If any plugin fails to initialise, it will have thrown and something up
        the call stack will catch it.

        Don't use an in-contract to enforce `plugins.length`, as not having any
        plugins is technically a valid use-case (even if it's a fairly pointless one).
     +/
    void initialisePlugins() @system
    //in (this.plugins.length, "Tried to initialise plugins but there were no plugins instantiated")
    {
        foreach (plugin; this.plugins)
        {
            plugin.initialise();
            if (*this.abort) return;
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

        if (*this.abort) return;

        if (plugin.state.updates == Update.nothing) return;

        if (plugin.state.updates & Update.bot)
        {
            // Something changed the bot; propagate
            plugin.state.updates &= ~Update.bot;
            propagate(plugin.state.bot);
        }

        if (plugin.state.updates & Update.client)
        {
            // Something changed the client; propagate
            plugin.state.updates &= ~Update.client;
            propagate(plugin.state.client);
        }

        if (plugin.state.updates & Update.server)
        {
            // Something changed the server; propagate
            plugin.state.updates &= ~Update.server;
            propagate(plugin.state.server);
        }

        if (plugin.state.updates & Update.settings)
        {
            // Something changed the settings; propagate
            plugin.state.updates &= ~Update.settings;
            propagate(plugin.state.settings);
            this.settings = plugin.state.settings;

            // This shouldn't be necessary since kameloso.common.settings points to this.settings
            //*kameloso.common.settings = plugin.state.settings;
        }

        assert((plugin.state.updates == Update.nothing),
            "`IRCPluginState.updates` was not reset after checking and propagating");
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

        foreach (ref sym; AliasSeq!(this, parser))
        {
            foreach (immutable i, ref member; sym.tupleof)
            {
                alias T = typeof(sym.tupleof[i]);

                static if (is(T == Thing))
                {
                    sym.tupleof[i] = thing;
                    break;
                }
            }
        }

        foreach (plugin; plugins)
        {
            foreach (immutable i, ref member; plugin.state.tupleof)
            {
                alias T = typeof(plugin.state.tupleof[i]);

                static if (is(T == Thing))
                {
                    plugin.state.tupleof[i] = thing;
                    break;
                }
            }
        }
    }

    // ConnectionHistoryEntry
    /++
        A record of a successful connection.
     +/
    static struct ConnectionHistoryEntry
    {
        /++
            UNIX time when this connection was established.
         +/
        long startTime;

        /++
            UNIX time when this connection was lost.
         +/
        long stopTime;

        /++
            How many events fired during this connection.
         +/
        long numEvents;

        /++
            How many bytses were read during this connection.
         +/
        ulong bytesReceived;
    }

    // connectionHistory
    /++
        History records of established connections this execution run.
     +/
    ConnectionHistoryEntry[] connectionHistory;
}

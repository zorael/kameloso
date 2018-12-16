/++
 +  Common functions used throughout the program, generic enough to be used in
 +  several places, not fitting into any specific one.
 +/
module kameloso.common;

import kameloso.uda;

import core.time : Duration;

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
 +  and `fatal`. It is not global, so instantiate a thread-local `Logger` if threading.
 +
 +  Having this here is unfortunate; ideally plugins should not use variables
 +  from other modules, but unsure of any way to fix this other than to have
 +  each plugin keep their own `Logger`.
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
 +  initLogger(settings.monochrome, settings.brightTerminal);
 +  ---
 +
 +  Params:
 +      monochrome = Whether the terminal is set to monochrome or not.
 +      bright = Whether the terminal has a bright background or not.
 +/
void initLogger(const bool monochrome = settings.monochrome,
    const bool bright = settings.brightTerminal)
{
    import kameloso.logger : KamelosoLogger;
    import std.experimental.logger : LogLevel;

    logger = new KamelosoLogger(LogLevel.all, monochrome, bright);
}


// settings
/++
 +  A `CoreSettings` struct global, housing certain runtime settings.
 +
 +  This will be accessed from other parts of the program, via
 +  `kameloso.common.settings`, so they know to use monochrome output or not. It
 +  is a problem that needs solving.
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
    string prefix = "!";

    @Unconfigurable
    @Hidden
    {
        string configFile;  /// Main configuration file.
        string resourceDirectory;  /// Path to resource directory.
        string configDirectory;  /// Path to configuration directory.
        bool force;  /// Whether or not to force connecting.
    }
}


// scopeguard
/++
 +  Generates a string mixin of *scopeguards*.
 +
 +  This is a convenience function to automate basic
 +  `scope(exit|success|failure)` messages, as well as a custom "entry" message.
 +  Which scope to guard is passed by ORing the states.
 +
 +  Example:
 +  ---
 +  mixin(scopeguard(entry|exit));
 +  ---
 +
 +  Params:
 +      states = Bitmask of which states to guard.
 +      scopeName = Optional scope name to print. If none is supplied, the
 +          current function name will be used.
 +
 +  Returns:
 +      One or more scopeguards in string form. Mix them in to use.
 +/
string scopeguard(const ubyte states = exit, const string scopeName = string.init)
{
    import std.array : Appender;
    import std.format : format;
    import std.uni : toLower;

    Appender!string app;

    string scopeString(const string state)
    {
        if (scopeName.length)
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    logger.infof("[%2$s] %3$s");
                }
            }.format(state.toLower, state, scopeName);
        }
        else
        {
            return
            q{
                // scopeguard mixin
                scope(%1$s)
                {
                    import std.string : indexOf;
                    enum __%2$sdotPos  = __FUNCTION__.indexOf('.');
                    enum __%2$sfunName = __FUNCTION__[(__%2$sdotPos+1)..$];
                    logger.infof("[%%s] %2$s", __%2$sfunName);
                }
            }.format(state.toLower, state);
        }
    }

    string entryString(const string state)
    {
        if (scopeName.length)
        {
            return
            q{
                logger.infof("[%s] %s");
            }.format(scopeName, state);
        }
        else
        {
            return
            q{
                import std.string : indexOf;
                enum __%1$sdotPos  = __FUNCTION__.indexOf('.');
                enum __%1$sfunName = __FUNCTION__[(__%1$sdotPos+1)..$];
                logger.infof("[%%s] %1$s", __%1$sfunName);
            }.format(state);
        }
    }

    if (states & entry)   app.put(entryString("entry"));
    if (states & exit)    app.put(scopeString("exit"));
    if (states & success) app.put(scopeString("success"));
    if (states & failure) app.put(scopeString("FAILURE"));

    return app.data;
}

/++
 +  Bitflags used in combination with the `scopeguard` function, to generate
 +  *scopeguard* mixins.
 +/
enum : ubyte
{
    entry   = 1 << 0,  /// On entry of function.
    exit    = 1 << 1,  /// On exit of function.
    success = 1 << 2,  /// On successful exit of function.
    failure = 1 << 3,  /// On thrown exception or error in function.
}


// getMultipleOf
/++
 +  Given a number, calculate the largest multiple of `n` needed to reach that number.
 +
 +  It rounds up, and if supplied `Yes.alwaysOneUp` it will always overshoot.
 +  This is good for when calculating format pattern widths.
 +
 +  Example:
 +  ---
 +  immutable width = 16.getMultipleOf(4);
 +  assert(width == 16);
 +  immutable width2 = 16.getMultipleOf!(Yes.oneUp)(4);
 +  assert(width2 == 20);
 +  ---
 +
 +  Params:
 +      oneUp = Whether or not to always overshoot.
 +      num = Number to reach.
 +      n = Base value to find a multiplier for.
 +
 +  Returns:
 +      The multiple of `n` that reaches and possibly overshoots `num`.
 +/
uint getMultipleOf(Flag!"alwaysOneUp" oneUp = No.alwaysOneUp, Number)
    (const Number num, const int n)
{
    assert((n > 0), "Cannot get multiple of 0 or negatives");
    assert((num >= 0), "Cannot get multiples for a negative number");

    if (num == 0) return 0;

    if (num == n)
    {
        static if (oneUp) return (n * 2);
        else
        {
            return n;
        }
    }

    immutable frac = (num / double(n));
    immutable floor_ = cast(uint)frac;

    static if (oneUp)
    {
        immutable mod = (floor_ + 1);
    }
    else
    {
        immutable mod = (floor_ == frac) ? floor_ : (floor_ + 1);
    }

    return (mod * n);
}

///
unittest
{
    import std.conv : text;

    immutable n1 = 15.getMultipleOf(4);
    assert((n1 == 16), n1.text);

    immutable n2 = 16.getMultipleOf!(Yes.alwaysOneUp)(4);
    assert((n2 == 20), n2.text);

    immutable n3 = 16.getMultipleOf(4);
    assert((n3 == 16), n3.text);
    immutable n4 = 0.getMultipleOf(5);
    assert((n4 == 0), n4.text);

    immutable n5 = 1.getMultipleOf(1);
    assert((n5 == 1), n5.text);

    immutable n6 = 1.getMultipleOf!(Yes.alwaysOneUp)(1);
    assert((n6 == 2), n6.text);
}


@system:


// IRCBot
/++
 +  State needed for the kameloso bot, aggregated in a struct for easier passing
 +  by reference.
 +/
struct IRCBot
{
    import kameloso.connection : Connection;
    import kameloso.irc.common : IRCClient;
    import kameloso.irc.parsing : IRCParser;
    import kameloso.plugins.common : IRCPlugin;

    import std.datetime.systime : SysTime;

    // ThrottleValues
    /++
     +  Aggregate of values and state needed to throttle messages without
     +  polluting namespace too much.
     +/
    private struct ThrottleValues
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
     +  parsing an `kameloso.irc.defs.IRCEvent`, and call the relevant event
     +  handlers of each.
     +/
    IRCPlugin[] plugins;

    /// When a nickname was called `WHOIS` on, for hysteresis.
    long[string] previousWhoisTimestamps;

    /// Parser instance.
    IRCParser parser;

    /// Values and state needed to throttle sending messages.
    ThrottleValues throttling;

    /++
     +  When this is set by signal handlers, the program should exit. Other
     +  parts of the program will be monitoring it.
     +/
    __gshared bool* abort;

    /// Never copy this.
    @disable this(this);


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
     +/
    string[][string] initPlugins(string[] customSettings)
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

        plugins.reserve(EnabledPlugins.length + 4);

        // Instantiate all plugin types in the `EnabledPlugins` `AliasSeq` in
        // `kameloso.plugins.package`
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
                import kameloso.meld : meldInto;
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

        plugins.applyCustomSettings(customSettings);

        return allInvalidEntries;
    }


    // initPluginResources
    /++
     +  Initialises all plugins' resource files.
     +
     +  This merely calls `kameloso.plugins.common.IRCPlugin.initResources()` on
     +  each plugin.
     +/
    void initPluginResources()
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
    void teardownPlugins()
    {
        if (!plugins.length) return;

        foreach (plugin; plugins)
        {
            import std.exception : ErrnoException;

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
                }
            }
            catch (const Exception e)
            {
                logger.warningf("Exception when tearing down %s: %s", plugin.name, e.msg);
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
    void startPlugins()
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
     +      client = `kameloso.irc.common.IRCClient` to propagate to all plugins.
     +/
    void propagateClient(IRCClient client) pure nothrow @nogc @safe
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
void printVersionInfo(TerminalForeground colourCode)
{
    import kameloso.terminal : colour;
    return printVersionInfo(colourCode.colour, TerminalForeground.default_.colour);
}


// printVersionInfo
/++
 +  Prints out the bot banner with the version number and GitHub URL, optionally
 +  with passed colouring in string format.
 +
 +  Overload that does not rely on `TerminalForeground` being available, yet
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
void printVersionInfo(const string pre = string.init, const string post = string.init)
{
    import kameloso.constants : KamelosoInfo;
    import std.stdio : stdout, writefln;

    writefln("%skameloso IRC bot v%s, built %s\n$ git clone %s.git%s",
        pre,
        cast(string)KamelosoInfo.version_,
        cast(string)KamelosoInfo.built,
        cast(string)KamelosoInfo.source,
        post);

    version(FlushStdout) stdout.flush();
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
void writeConfigurationFile(ref IRCBot bot, const string filename)
{
    import kameloso.config : justifiedConfigurationText, serialise, writeToDisk;
    import kameloso.string : beginsWith, encode64;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(1536);  // ~1097

    with (bot)
    with (bot.parser)
    {
        if (client.authPassword.length && !client.authPassword.beginsWith("base64:"))
        {
            client.authPassword = "base64:" ~ encode64(client.authPassword);
        }

        sink.serialise(client, client.server, settings);

        foreach (plugin; plugins)
        {
            plugin.serialiseConfigInto(sink);
        }

        immutable justified = sink.data.justifiedConfigurationText;
        writeToDisk(filename, justified, Yes.addBanner);
    }
}


// Labeled
/++
 +  Labels an item by wrapping it in a struct with an `id` field.
 +
 +  Access to the `thing` is passed on by use of `alias this` proxying, so this
 +  will transparently act like the original `thing` in most cases. The original
 +  object can be accessed via the `thing` member when it doesn't.
 +
 +  Params:
 +      Thing = The type to embed and label.
 +      Label = The type to embed as label.
 +      disableThis = Whether or not to disable copying of the resulting struct.
 +/
struct Labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
{
public:
    /// The wrapped item.
    Thing thing;

    /// The label applied to the wrapped item.
    Label id;

    /// Create a new `Labeled` struct with the passed `id` identifier.
    this(Thing thing, Label id) pure nothrow @nogc @safe
    {
        this.thing = thing;
        this.id = id;
    }

    static if (disableThis)
    {
        /// Never copy this.
        @disable this(this);
    }

    /// Transparently proxy all `Thing`-related calls to `thing`.
    alias thing this;
}

///
unittest
{
    struct Foo
    {
        bool b = true;

        bool wefpok() @property
        {
            return false;
        }
    }

    Foo foo;
    Foo bar;

    Labeled!(Foo,int)[] arr;

    arr ~= labeled(foo, 1);
    arr ~= labeled(bar, 2);

    assert(arr[0].id == 1);
    assert(arr[1].id == 2);

    assert(arr[0].b);
    assert(!arr[1].wefpok);
}


// labeled
/++
 +  Convenience function to create a `Labeled` struct while inferring the
 +  template parameters from the runtime arguments.
 +
 +  Example:
 +  ---
 +  Foo foo;
 +  auto namedFoo = labeled(foo, "hello world");
 +
 +  Foo bar;
 +  auto numberedBar = labeled(bar, 42);
 +  ---
 +
 +  Params:
 +      disableThis = Whether or not to disable copying of the resulting struct.
 +      thing = Object to wrap.
 +      label = Label ID to apply to the wrapped item.
 +
 +  Returns:
 +      The passed object, wrapped and labeled with the supplied ID.
 +/
auto labeled(Thing, Label, Flag!"disableThis" disableThis = No.disableThis)
    (Thing thing, Label label) pure nothrow @nogc @safe
{
    import std.traits : Unqual;
    return Labeled!(Unqual!Thing, Unqual!Label, disableThis)(thing, label);
}

///
unittest
{
    auto foo = labeled("FOO", "foo");
    assert(is(typeof(foo) == Labeled!(string, string)));

    assert(foo.thing == "FOO");
    assert(foo.id == "foo");
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English) language.
 +
 +  Write the result to a passed output range `sink`.
 +
 +  Example:
 +  ---
 +  Appender!string sink;
 +
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = sink.timeSince(duration);
 +  ---
 +
 +  Params:
 +      abbreviate = Whether or not to abbreviate the output, using `h` instead
 +          of `hours`, `m` instead of `minutes`, etc.
 +      sink = Output buffer sink to write to.
 +      duration = A period of time.
 +/
void timeSince(Flag!"abbreviate" abbreviate = No.abbreviate, Sink)
    (auto ref Sink sink, const Duration duration) pure
if (isOutputRange!(Sink, string))
{
    import kameloso.string : plurality;
    import std.format : formattedWrite;

    int days, hours, minutes, seconds;
    duration.split!("days", "hours", "minutes", "seconds")(days, hours, minutes, seconds);

    if (days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%dd", days);
        }
        else
        {
            sink.formattedWrite("%d %s", days, days.plurality("day", "days"));
        }
    }

    if (hours)
    {
        static if (abbreviate)
        {
            if (days) sink.put(' ');
            sink.formattedWrite("%dh", hours);
        }
        else
        {
            if (days)
            {
                if (minutes) sink.put(", ");
                else sink.put("and ");
            }
            sink.formattedWrite("%d %s", hours, hours.plurality("hour", "hours"));
        }
    }

    if (minutes)
    {
        static if (abbreviate)
        {
            if (hours) sink.put(' ');
            sink.formattedWrite("%dm", minutes);
        }
        else
        {
            if (hours) sink.put(" and ");
            sink.formattedWrite("%d %s", minutes, minutes.plurality("minute", "minutes"));
        }
    }

    if (!minutes && !hours && !days)
    {
        static if (abbreviate)
        {
            sink.formattedWrite("%ds", seconds);
        }
        else
        {
            sink.formattedWrite("%d %s", seconds, seconds.plurality("second", "seconds"));
        }
    }
}

///
unittest
{
    import core.time : msecs, seconds;
    import std.array : Appender;

    Appender!(char[]) sink;
    sink.reserve(64);  // workaround for formattedWrite < 2.076

    {
        immutable dur = 0.seconds;
        sink.timeSince(dur);
        assert((sink.data == "0 seconds"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "0s"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3_141_519_265.msecs;
        sink.timeSince(dur);
        assert((sink.data == "36 days, 8 hours and 38 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "36d 8h 38m"), sink.data);
        sink.clear();
    }

    {
        immutable dur = 3599.seconds;
        sink.timeSince(dur);
        assert((sink.data == "59 minutes"), sink.data);
        sink.clear();
        sink.timeSince!(Yes.abbreviate)(dur);
        assert((sink.data == "59m"), sink.data);
        sink.clear();
    }
}


// timeSince
/++
 +  Express how much time has passed in a `Duration`, in natural (English) language.
 +
 +  Returns the result as a string.
 +
 +  Example:
 +  ---
 +  const then = Clock.currTime;
 +  Thread.sleep(1.seconds);
 +  const now = Clock.currTime;
 +
 +  const duration = (now - then);
 +  immutable inEnglish = timeSince(duration);
 +  ---
 +
 +  Params:
 +      abbreviate = Whether or not to abbreviate the output, using `h` instead
 +          of `hours`, `m` instead of `minutes`, etc.
 +      duration = A period of time.
 +
 +  Returns:
 +      A string with the passed duration expressed in natural English language.
 +/
string timeSince(Flag!"abbreviate" abbreviate = No.abbreviate)(const Duration duration)
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(50);
    sink.timeSince!abbreviate(duration);
    return sink.data;
}

///
unittest
{
    import core.time : seconds;

    {
        immutable dur = 789_383.seconds;  // 1 week, 2 days, 3 hours, 16 minutes, and 23 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "9 days, 3 hours and 16 minutes"), since);
        assert((abbrev == "9d 3h 16m"), abbrev);
    }

    {
        immutable dur = 3_620.seconds;  // 1 hour and 20 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 hour"), since);
        assert((abbrev == "1h"), abbrev);
    }

    {
        immutable dur = 30.seconds;  // 30 secs
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "30 seconds"), since);
        assert((abbrev == "30s"), abbrev);
    }

    {
        immutable dur = 1.seconds;
        immutable since = dur.timeSince;
        immutable abbrev = dur.timeSince!(Yes.abbreviate);
        assert((since == "1 second"), since);
        assert((abbrev == "1s"), abbrev);
    }
}


// complainAboutIncompleteConfiguration
/++
 +  Displays an error on how to complete a minimal configuration file.
 +
 +  It assumes that the client's `admins` and `homes` are both empty.
 +
 +  Used in both `kameloso.getopt` and `kameloso.main`, so place it here.
 +/
void complainAboutIncompleteConfiguration()
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


// Next
/++
 +  Enum of flags carrying the meaning of "what to do next".
 +/
enum Next
{
    continue_,     /// Keep doing whatever is being done.
    retry,         /// Halt what's being done and give it another attempt.
    returnSuccess, /// Exit or abort with a positive return value.
    returnFailure, /// Exit or abort with a negative return value.
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
string defaultConfigurationPrefix()
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
string defaultResourcePrefix()
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
        import kameloso.string : beginsWith;
        import std.process : environment;

        environment["XDG_DATA_HOME"] = "/tmp";
        string df = defaultResourcePrefix;
        assert((df == "/tmp/kameloso"), df);

        environment.remove("XDG_DATA_HOME");
        df = defaultResourcePrefix;
        assert(df.beginsWith("/home/") && df.endsWith("/.local/share/kameloso"));
    }
    else version (OSX)
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


// ReturnValueException
/++
 +  Exception, to be thrown when an executed command returns an error value.
 +
 +  It is a normal `Exception` but with an attached command and return value.
 +/
final class ReturnValueException : Exception
{
@safe:
    /// The command run.
    string command;

    /// The value returned.
    int retval;

    /// Create a new `ReturnValueException`, without attaching anything.
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /// Create a new `ReturnValueException`, attaching a command.
    this(const string message, const string command, const string file = __FILE__,
        const size_t line = __LINE__) pure
    {
        this.command = command;
        super(message, file, line);
    }

    /// Create a new `ReturnValueException`, attaching a command and a returned value.
    this(const string message, const string command, const int retval,
        const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.command = command;
        this.retval = retval;
        super(message, file, line);
    }
}


// FileExistsException
/++
 +  Exception, to be thrown when attempting to create a file or directory and
 +  finding that one already exists with the same name.
 +
 +  It is a normal `Exception` but with an attached filename string.
 +/
final class FileExistsException : Exception
{
@safe:
    /// The name of the file.
    string filename;

    /// Create a new `FileExistsException`, without attaching a filename.
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /// Create a new `FileExistsException`, attaching a filename.
    this(const string message, const string filename, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.filename = filename;
        super(message, file, line);
    }
}


// FileTypeMismatchException
/++
 +  Exception, to be thrown when attempting to access a file or directory and
 +  finding that something with the that name exists, but is of an unexpected type.
 +
 +  It is a normal `Exception` but with an embedded filename string, and an uint
 +  representing the existing file's type (file, directory, symlink, ...).
 +/
final class FileTypeMismatchException : Exception
{
@safe:
    /// The filename of the non-FIFO.
    string filename;

    /// File attributes.
    ushort attrs;

    /// Create a new `FileTypeMismatchException`, without embedding a filename.
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /// Create a new `FileTypeMismatchException`, embedding a filename.
    this(const string message, const string filename, const ushort attrs,
        const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.filename = filename;
        this.attrs = attrs;
        super(message, file, line);
    }
}

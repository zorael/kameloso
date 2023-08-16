/++
    The is not a plugin by itself but contains code common to all plugins,
    without which they will *not* function.

    See_Also:
        [kameloso.plugins.common.core]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.misc;

private:

import kameloso.plugins.common.core;
import kameloso.common : logger;
import kameloso.pods : CoreSettings;
import dialect.defs;
import std.typecons : Flag, No, Yes;

public:


// applyCustomSettings
/++
    Changes a setting of a plugin, given both the names of the plugin and the
    setting, in string form.

    This merely iterates the passed `plugins` and calls their
    [kameloso.plugins.common.core.IRCPlugin.setMemberByName|IRCPlugin.setMemberByName]
    methods.

    Params:
        plugins = Array of all [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]s.
        customSettings = Array of custom settings to apply to plugins' own
            setting, in the string forms of "`plugin.setting=value`".
        copyOfSettings = A copy of the program-wide [kameloso.pods.CoreSettings|CoreSettings].

    Returns:
        `true` if no setting name mismatches occurred, `false` if it did.

    See_Also:
        [lu.objmanip.setSettingByName]
 +/
auto applyCustomSettings(
    IRCPlugin[] plugins,
    const string[] customSettings,
    CoreSettings copyOfSettings)
{
    import lu.objmanip : SetMemberException;
    import lu.string : advancePast;
    import std.conv : ConvException;
    import std.string : indexOf;

    bool noErrors = true;

    top:
    foreach (immutable line; customSettings)
    {
        if (line.indexOf('.') == -1)
        {
            enum pattern = `Bad <l>plugin</>.<l>setting</>=<l>value</> format. (<l>%s</>)`;
            logger.warningf(pattern, line);
            noErrors = false;
            continue;
        }

        string slice = line;  // mutable
        immutable pluginstring = slice.advancePast(".");
        immutable setting = slice.advancePast('=', Yes.inherit);
        immutable value = slice;

        try
        {
            if (pluginstring == "core")
            {
                import kameloso.common : logger;
                import kameloso.logger : KamelosoLogger;
                import lu.objmanip : setMemberByName;
                import std.algorithm.comparison : among;
                static import kameloso.common;

                immutable success = slice.length ?
                    copyOfSettings.setMemberByName(setting, value) :
                    copyOfSettings.setMemberByName(setting, true);

                if (!success)
                {
                    enum pattern = "No such <l>core</> setting: <l>%s";
                    logger.warningf(pattern, setting);
                    noErrors = false;
                }
                else
                {
                    if (setting.among!("monochrome", "brightTerminal", "headless", "flush"))
                    {
                        logger = new KamelosoLogger(copyOfSettings);
                    }

                    *kameloso.common.settings = copyOfSettings;

                    foreach (plugin; plugins)
                    {
                        plugin.state.settings = copyOfSettings;

                        // No need to flag as updated when we update here manually
                        //plugin.state.updates |= typeof(plugin.state.updates).settings;
                    }
                }
                continue top;
            }
            else
            {
                foreach (plugin; plugins)
                {
                    if (plugin.name != pluginstring) continue;

                    immutable success = plugin.setSettingByName(
                        setting,
                        value.length ? value : "true");

                    if (!success)
                    {
                        enum pattern = "No such <l>%s</> plugin setting: <l>%s";
                        logger.warningf(pattern, pluginstring, setting);
                        noErrors = false;
                    }
                    continue top;
                }
            }

            // If we're here, the loop was never continued --> unknown plugin
            enum pattern = "Invalid plugin: <l>%s";
            logger.warningf(pattern, pluginstring);
            noErrors = false;
            // Drop down, try next
        }
        catch (SetMemberException e)
        {
            enum pattern = "Failed to set <l>%s</>.<l>%s</>: " ~
                "it requires a value and none was supplied.";
            logger.warningf(pattern, pluginstring, setting);
            version(PrintStacktraces) logger.trace(e.info);
            noErrors = false;
            // Drop down, try next
        }
        catch (ConvException e)
        {
            enum pattern = `Invalid value for <l>%s</>.<l>%s</>: "<l>%s</>" <t>(%s)`;
            logger.warningf(pattern, pluginstring, setting, value, e.msg);
            noErrors = false;
            // Drop down, try next
        }
        continue top;
    }

    return noErrors;
}

///
unittest
{
    @Settings static struct MyPluginSettings
    {
        @Enabler bool enabled;

        string s;
        int i;
        float f;
        bool b;
        double d;
    }

    static final class MyPlugin : IRCPlugin
    {
        MyPluginSettings myPluginSettings;

        override string name() const
        {
            return "myplugin";
        }

        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    IRCPlugin plugin = new MyPlugin(state);

    auto newSettings =
    [
        `myplugin.s="abc def ghi"`,
        "myplugin.i=42",
        "myplugin.f=3.14",
        "myplugin.b=true",
        "myplugin.d=99.99",
    ];

    cast(void)applyCustomSettings([ plugin ], newSettings, state.settings);

    const ps = (cast(MyPlugin)plugin).myPluginSettings;

    static if (__VERSION__ >= 2091)
    {
        import std.math : isClose;
    }
    else
    {
        import std.math : isClose = approxEqual;
    }

    import std.conv : to;

    assert((ps.s == "abc def ghi"), ps.s);
    assert((ps.i == 42), ps.i.to!string);
    assert(isClose(ps.f, 3.14f), ps.f.to!string);
    assert(ps.b);
    assert(isClose(ps.d, 99.99), ps.d.to!string);
}


// IRCPluginSettingsException
/++
    Exception thrown when an IRC plugin failed to have its settings set.

    A normal [object.Exception|Exception], which only differs in the sense that
    we can deduce what went wrong by its type.
 +/
final class IRCPluginSettingsException : Exception
{
    /++
        Wraps normal Exception constructors.
     +/
    this(
        const string message,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// IRCPluginInitialisationException
/++
    Exception thrown when an IRC plugin failed to initialise itself or its resources.

    A normal [object.Exception|Exception], with a plugin name and optionally the
    name of a malformed resource file embedded.
 +/
final class IRCPluginInitialisationException : Exception
{
    /++
        Name of throwing plugin.
     +/
    string pluginName;

    /++
        Optional name of a malformed file.
     +/
    string malformedFilename;

    /++
        Constructs an [IRCPluginInitialisationException], embedding a plugin name
        and the name of a malformed resource file.
     +/
    this(
        const string message,
        const string pluginName,
        const string malformedFilename,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.pluginName = pluginName;
        this.malformedFilename = malformedFilename;
        super(message, file, line, nextInChain);
    }

    /++
        Constructs an [IRCPluginInitialisationException], embedding a plugin name.
     +/
    this(
        const string message,
        const string pluginName,
        const string file = __FILE__,
        const size_t line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        this.pluginName = pluginName;
        super(message, file, line, nextInChain);
    }
}


// catchUser
/++
    Catch an [dialect.defs.IRCUser|IRCUser], saving it to the
    [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users] array.

    If a user already exists, meld the new information into the old one.

    Params:
        plugin = Current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].
        newUser = The [dialect.defs.IRCUser|IRCUser] to catch.
 +/
void catchUser(IRCPlugin plugin, const IRCUser newUser) @safe
{
    if (!newUser.nickname.length) return;

    if (auto user = newUser.nickname in plugin.state.users)
    {
        import lu.meld : meldInto;
        newUser.meldInto(*user);
    }
    else
    {
        plugin.state.users[newUser.nickname] = newUser;
    }
}


// enqueue
/++
    Construct and enqueue a function replay in the plugin's queue of such.

    The main loop will catch up on it and issue WHOIS queries as necessary, then
    replay the event upon receiving the results.

    Params:
        plugin = Subclass [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] to
            replay the function pointer `fun` with as first argument.
        event = [dialect.defs.IRCEvent|IRCEvent] to queue up to replay.
        permissionsRequired = Permissions level to match the results from the WHOIS query with.
        inFiber = Whether or not the function should be called from within a Fiber.
        fun = Function/delegate pointer to call when the results return.
        caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(Plugin, Fun)
    (Plugin plugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    const bool inFiber,
    Fun fun,
    const string caller = __FUNCTION__)
in ((event != IRCEvent.init), "Tried to `enqueue` with an init IRCEvent")
in ((fun !is null), "Tried to `enqueue` with a null function pointer")
{
    import std.traits : isSomeFunction;

    static assert (isSomeFunction!Fun, "Tried to `enqueue` with a non-function function parameter");

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            version(TwitchWarnings)
            {
                import kameloso.common : logger;

                logger.warning(caller, " tried to WHOIS on Twitch");

                version(IncludeHeavyStuff)
                {
                    import kameloso.printing : printObject;
                    printObject(event);
                }

                version(PrintStacktraces)
                {
                    import kameloso.common: printStacktrace;
                    printStacktrace();
                }
            }
            return;
        }
    }

    immutable user = event.sender.isServer ? event.target : event.sender;
    assert(user.nickname.length, "Bad user derived in `enqueue` (no nickname)");

    version(ExplainReplay)
    {
        import std.algorithm.searching : startsWith;
        immutable callerSlice = caller.startsWith("kameloso.plugins.") ?
            caller[17..$] :
            caller;
    }

    if (const previousWhoisTimestamp = user.nickname in plugin.state.previousWhoisTimestamps)
    {
        import kameloso.constants : Timeout;
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime.toUnixTime;
        immutable delta = (now - *previousWhoisTimestamp);

        if ((delta < Timeout.whoisRetry) && (delta > Timeout.whoisGracePeriod))
        {
            version(ExplainReplay)
            {
                enum pattern = "<i>%s</> plugin <w>NOT</> queueing an event to be replayed " ~
                    "on behalf of <i>%s</>; delta time <i>%d</> is too recent";
                logger.logf(pattern, plugin.name, callerSlice, delta);
            }
            return;
        }
    }

    version(ExplainReplay)
    {
        enum pattern = "<i>%s</> plugin queueing an event to be replayed on behalf of <i>%s";
        logger.logf(pattern, plugin.name, callerSlice);
    }

    plugin.state.pendingReplays[user.nickname] ~=
        replay(plugin, event, fun, permissionsRequired, inFiber, caller);
    plugin.state.hasPendingReplays = true;
}


// replay
/++
    Convenience function that returns a [kameloso.plugins.common.core.Replay] of
    the right type, *with* a subclass plugin reference attached.

    Params:
        plugin = Subclass [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] to
            call the function pointer `fun` with as first argument, when the
            WHOIS results return.
        event = [dialect.defs.IRCEvent|IRCEvent] that instigated the WHOIS lookup.
        fun = Function/delegate pointer to call upon receiving the results.
        permissionsRequired = The permissions level policy to apply to the WHOIS results.
        inFiber = Whether or not the function should be called from within a Fiber.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A [kameloso.plugins.common.core.Replay|Replay] with template parameters
        inferred from the arguments passed to this function.

    See_Also:
        [kameloso.plugins.common.core.Replay|Replay]
 +/
auto replay(Plugin, Fun)
    (Plugin plugin,
    const /*ref*/ IRCEvent event,
    Fun fun,
    const Permissions permissionsRequired,
    const bool inFiber,
    const string caller = __FUNCTION__)
{
    void replayDg(Replay replay)
    {
        import lu.conv : Enum;
        import std.algorithm.searching : startsWith;

        version(ExplainReplay)
        void explainReplay()
        {
            immutable caller = replay.caller.startsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s</> replaying <i>%s</>-level event (invoking <i>%s</>) " ~
                "based on WHOIS results; user <i>%s</> is <i>%s</> class";
            logger.logf(pattern,
                plugin.name,
                Enum!Permissions.toString(replay.permissionsRequired),
                caller,
                replay.event.sender.nickname,
                Enum!(IRCUser.Class).toString(replay.event.sender.class_));
        }

        version(ExplainReplay)
        void explainRefuse()
        {
            immutable caller = replay.caller.startsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s</> plugin <w>NOT</> replaying <i>%s</>-level event " ~
                "(which would have invoked <i>%s</>) " ~
                "based on WHOIS results: user <i>%s</> is <i>%s</> class";
            logger.logf(pattern,
                plugin.name,
                Enum!Permissions.toString(replay.permissionsRequired),
                caller,
                replay.event.sender.nickname,
                Enum!(IRCUser.Class).toString(replay.event.sender.class_));
        }

        with (Permissions)
        final switch (permissionsRequired)
        {
        case admin:
            if (replay.event.sender.class_ >= IRCUser.Class.admin)
            {
                goto case ignore;
            }
            break;

        case staff:
            if (replay.event.sender.class_ >= IRCUser.Class.staff)
            {
                goto case ignore;
            }
            break;

        case operator:
            if (replay.event.sender.class_ >= IRCUser.Class.operator)
            {
                goto case ignore;
            }
            break;

        case elevated:
            if (replay.event.sender.class_ >= IRCUser.Class.elevated)
            {
                goto case ignore;
            }
            break;

        case whitelist:
            if (replay.event.sender.class_ >= IRCUser.Class.whitelist)
            {
                goto case ignore;
            }
            break;

        case registered:
            if (replay.event.sender.account.length)
            {
                goto case ignore;
            }
            break;

        case anyone:
            if (replay.event.sender.class_ >= IRCUser.Class.anyone)
            {
                goto case ignore;
            }

            // event.sender.class_ is Class.blacklist here (or unset)
            // Do nothing and drop down
            break;

        case ignore:
            version(ExplainReplay) explainReplay();

            void call()
            {
                import lu.traits : TakesParams;
                import std.traits : arity;

                static if (
                    TakesParams!(fun, Plugin, IRCEvent) ||
                    TakesParams!(fun, IRCPlugin, IRCEvent))
                {
                    fun(plugin, replay.event);
                }
                else static if (
                    TakesParams!(fun, Plugin) ||
                    TakesParams!(fun, IRCPlugin))
                {
                    fun(plugin);
                }
                else static if (
                    TakesParams!(fun, IRCEvent))
                {
                    fun(replay.event);
                }
                else static if (arity!fun == 0)
                {
                    fun();
                }
                else
                {
                    // onEventImpl.call should already have statically asserted all
                    // event handlers are of the types above
                    enum message = "Failed to cover all event handler function signature cases";
                    static assert(0, message);
                }
            }

            if (inFiber)
            {
                import kameloso.constants : BufferSize;
                import kameloso.thread : CarryingFiber;
                import core.thread : Fiber;

                auto fiber = new CarryingFiber!IRCEvent(
                    &call,
                    BufferSize.fiberStack);
                fiber.payload = replay.event;
                fiber.call();

                if (fiber.state == Fiber.State.TERM)
                {
                    // Ended immediately, so just destroy
                    destroy(fiber);
                    fiber = null;
                }
            }
            else
            {
                call();
            }

            return;
        }

        version(ExplainReplay) explainRefuse();
    }

    return Replay(&replayDg, event, permissionsRequired, caller);
}


// rehashUsers
/++
    Rehashes a plugin's users, both the ones in the
    [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
    associative array and the ones in each [dialect.defs.IRCChannel.users] associative arrays.

    This optimises lookup and should be done every so often.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].
        channelName = Optional name of the channel to rehash for. If none given
            it will rehash the main
            [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
            associative array instead.
 +/
void rehashUsers(IRCPlugin plugin, const string channelName = string.init)
{
    if (!channelName.length)
    {
        plugin.state.users.rehash();
    }
    else if (auto channel = channelName in plugin.state.channels)
    {
        // created in `onChannelAwarenessSelfjoin`
        channel.users.rehash();
    }
}


// nameOf
/++
    Returns either the nickname or the display name of a user, depending on whether the
    display name is known or not.

    If not version `TwitchSupport` then it always returns the nickname.

    Params:
        user = [dialect.defs.IRCUser|IRCUser] to examine.

    Returns:
        The nickname of the user if there is no alias known, else the alias.
 +/
pragma(inline, true)
auto nameOf(const IRCUser user) pure @safe nothrow @nogc
{
    version(TwitchSupport)
    {
        return user.displayName.length ? user.displayName : user.nickname;
    }
    else
    {
        return user.nickname;
    }
}

///
unittest
{
    version(TwitchSupport)
    {
        {
            IRCUser user;
            user.nickname = "joe";
            user.displayName = "Joe";
            assert(nameOf(user) == "Joe");
        }
        {
            IRCUser user;
            user.nickname = "joe";
            assert(nameOf(user) == "joe");
        }
    }
    {
        IRCUser user;
        user.nickname = "joe";
        assert(nameOf(user) == "joe");
    }
}


// nameOf
/++
    Returns either the nickname or the display name of a user, depending on whether the
    display name is known or not. Overload that looks up the passed nickname in
    the passed plugin's `users` associative array of [dialect.defs.IRCUser|IRCUser]s.

    If not version `TwitchSupport` then it always returns the nickname.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin], whatever it is.
        specified = The name of a user to look up.

    Returns:
        The nickname of the user if there is no alias known, else the alias.
 +/
auto nameOf(const IRCPlugin plugin, const string specified) pure @safe nothrow @nogc
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            import std.algorithm.searching : startsWith;

            immutable nickname = specified.startsWith('@') ?
                specified[1..$] :
                specified;

            if (const user = nickname in plugin.state.users)
            {
                return nameOf(*user);
            }
        }
    }

    return specified;
}


// idOf
/++
    Returns either the nickname or the account of a user, depending on whether
    the account is known.

    Params:
        user = [dialect.defs.IRCUser|IRCUser] to examine.

    Returns:
        The nickname or account of the passed user.
 +/
pragma(inline, true)
auto idOf(const IRCUser user) pure @safe nothrow @nogc
in (user.nickname.length, "Tried to get `idOf` a user with an empty nickname")
{
    return user.account.length ? user.account : user.nickname;
}


// idOf
/++
    Returns either the nickname or the account of a user, depending on whether
    the account is known. Overload that looks up the passed nickname in
    the passed plugin's `users` associative array of [dialect.defs.IRCUser|IRCUser]s.

    Merely wraps [getUser] with [idOf].

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin], whatever it is.
        nickname = The name of a user to look up.

    Returns:
        The nickname or account of the passed user, or the passed nickname if
        nothing was found.

    See_Also:
        [getUser]
 +/
auto idOf(IRCPlugin plugin, const string nickname)
{
    immutable user = getUser(plugin, nickname);
    return idOf(user);
}

///
unittest
{
    final class MyPlugin : IRCPlugin
    {
        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    IRCPlugin plugin = new MyPlugin(state);

    IRCUser newUser;
    newUser.nickname = "nickname";
    plugin.state.users["nickname"] = newUser;

    immutable nickname = idOf(plugin, "nickname");
    assert((nickname == "nickname"), nickname);

    plugin.state.users["nickname"].account = "account";
    immutable account = idOf(plugin, "nickname");
    assert((account == "account"), account);
}


// getUser
/++
    Retrieves an [dialect.defs.IRCUser|IRCUser] from the passed plugin's `users`
    associative array. If none exists, returns a minimally viable
    [dialect.defs.IRCUser|IRCUser] with the passed nickname as its only value.

    On Twitch, if no user was found, it additionally tries to look up the passed
    nickname as if it was a display name.

    Params:
        plugin = The current [kameloso.plugins.common.core.IRCPlugin|IRCPlugin], whatever it is.
        specified = The name of a user to look up.

    Returns:
        An [dialect.defs.IRCUser|IRCUser] that matches the passed nickname, from the
        passed plugin's arrays. A minimally viable [dialect.defs.IRCUser|IRCUser] if
        none was found.
 +/
auto getUser(IRCPlugin plugin, const string specified)
{
    version(TwitchSupport)
    {
        import std.algorithm.searching : startsWith;

        immutable isTwitch = (plugin.state.server.daemon == IRCServer.Daemon.twitch);
        immutable nickname = (isTwitch && specified.startsWith('@')) ?
            specified[1..$] :
            specified;
    }
    else
    {
        alias nickname = specified;
    }

    if (auto user = nickname in plugin.state.users)
    {
        return *user;
    }

    version(TwitchSupport)
    {
        if (isTwitch)
        {
            foreach (user; plugin.state.users)
            {
                if (user.displayName == nickname)
                {
                    return user;
                }
            }

            // No match, populate a new user and return it
            IRCUser user;
            user.nickname = nickname;
            user.account = nickname;
            user.class_ = IRCUser.Class.registered;
            //user.displayName = nickname;
            return user;
        }
    }

    IRCUser user;
    user.nickname = nickname;
    return user;
}

///
unittest
{
    final class MyPlugin : IRCPlugin
    {
        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    IRCPlugin plugin = new MyPlugin(state);

    IRCUser newUser;
    newUser.nickname = "nickname";
    newUser.displayName = "NickName";
    plugin.state.users["nickname"] = newUser;

    immutable sameUser = getUser(plugin, "nickname");
    assert(newUser == sameUser);

    version(TwitchSupport)
    {
        plugin.state.server.daemon = IRCServer.Daemon.twitch;
        immutable sameAgain = getUser(plugin, "NickName");
        assert(newUser == sameAgain);
    }
}


// pluginFileBaseName
/++
    Returns a meaningful basename of a plugin filename.

    This is preferred over use of [std.path.baseName] because some plugins are
    nested in their own directories. The basename of `plugins/twitch/base.d` is
    `base.d`, much like that of `plugins/printer/base.d` is.

    With this we get `twitch/base.d` and `printer/base.d` instead, while still
    getting `oneliners.d`.

    Params:
        filename = Full path to a plugin file.

    Returns:
        A meaningful basename of the passed filename.
 +/
auto pluginFileBaseName(const string filename)
in (filename.length, "Empty plugin filename passed to `pluginFileBaseName`")
{
    return pluginFilenameSlicerImpl(filename, No.getPluginName);
}

///
unittest
{
    {
        version(Posix) enum filename = "plugins/oneliners.d";
        else /*version(Windows)*/ enum filename = "plugins\\oneliners.d";
        immutable expected = "oneliners.d";
        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix)
        {
            enum filename = "plugins/twitch/base.d";
            immutable expected = "twitch/base.d";
        }
        else /*version(Windows)*/
        {
            enum filename = "plugins\\twitch\\base.d";
            immutable expected = "twitch\\base.d";
        }

        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/counters.d";
        else /*version(Windows)*/ enum filename = "plugins\\counters.d";
        immutable expected = "counters.d";
        immutable actual = pluginFileBaseName(filename);
        assert((expected == actual), actual);
    }
}


// pluginNameOfFilename
/++
    Returns the name of a plugin based on its filename.

    This is preferred over slicing [std.path.baseName] because some plugins are
    nested in their own directories. The basename of `plugins/twitch/base.d` is
    `base.d`, much like that of `plugins/printer/base.d` is.

    With this we get `twitch` and `printer` instead, while still getting `oneliners`.

    Params:
        filename = Full path to a plugin file.

    Returns:
        The name of the plugin, based on its filename.
 +/
auto pluginNameOfFilename(const string filename)
in (filename.length, "Empty plugin filename passed to `pluginNameOfFilename`")
{
    return pluginFilenameSlicerImpl(filename, Yes.getPluginName);
}

///
unittest
{
    {
        version(Posix) enum filename = "plugins/oneliners.d";
        else /*version(Windows)*/ enum filename = "plugins\\oneliners.d";
        immutable expected = "oneliners";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/twitch/base.d";
        else /*version(Windows)*/ enum filename = "plugins\\twitch\\base.d";
        immutable expected = "twitch";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
    {
        version(Posix) enum filename = "plugins/counters.d";
        else /*version(Windows)*/ enum filename = "plugins\\counters.d";
        immutable expected = "counters";
        immutable actual = pluginNameOfFilename(filename);
        assert((expected == actual), actual);
    }
}


// pluginFilenameSlicerImpl
/++
    Implementation function, code shared between [pluginFileBaseName] and
    [pluginNameOfFilename].

    Params:
        filename = Full path to a plugin file.
        getPluginName = Whether we want the plugin name or the plugin file "basename".

    Returns:
        The name of the plugin or its "basename", based on its filename and the
        `getPluginName` parameter.
 +/
private auto pluginFilenameSlicerImpl(const string filename, const Flag!"getPluginName" getPluginName)
in (filename.length, "Empty plugin filename passed to `pluginFilenameSlicerImpl`")
{
    import std.path : dirSeparator;
    import std.string : indexOf;

    string slice = filename;  // mutable
    size_t pos = slice.indexOf(dirSeparator);

    while (pos != -1)
    {
        if (slice[pos+1..$] == "base.d")
        {
            return getPluginName ? slice[0..pos] : slice;
        }
        slice = slice[pos+1..$];
        pos = slice.indexOf(dirSeparator);
    }

    return getPluginName ? slice[0..$-2] : slice;
}

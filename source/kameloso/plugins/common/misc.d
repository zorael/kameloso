/++
    The is not a plugin by itself but contains code common to all plugins,
    without which they will *not* function.

    See_Also:
        [kameloso.plugins.common.core|plugins.common.core]
 +/
module kameloso.plugins.common.misc;

private:

import kameloso.kameloso : CoreSettings;
import kameloso.plugins.common.core;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;

public:


// applyCustomSettings
/++
    Changes a setting of a plugin, given both the names of the plugin and the
    setting, in string form.

    This merely iterates the passed `plugins` and calls their
    [kameloso.plugins.common.core.IRCPlugin.setSettingByName|IRCPlugin.setSettingByName]
    methods.

    Params:
        plugins = Array of all [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]s.
        customSettings = Array of custom settings to apply to plugins' own
            setting, in the string forms of "`plugin.setting=value`".
        copyOfSettings = A copy of the program-wide [kameloso.kameloso.CoreSettings|CoreSettings].

    Returns:
        `true` if no setting name mismatches occurred, `false` if it did.

    See_Also:
        [lu.objmanip.setSettingByName]
 +/
bool applyCustomSettings(IRCPlugin[] plugins,
    const string[] customSettings,
    CoreSettings copyOfSettings)
{
    import kameloso.common : Tint, expandTags, logger;
    import lu.string : contains, nom;
    import std.conv : ConvException;

    bool noErrors = true;

    top:
    foreach (immutable line; customSettings)
    {
        if (!line.contains!(Yes.decode)('.'))
        {
            enum pattern = `Bad <l>plugin<w>.<l>setting<w>=<l>value<w> format. (<l>%s<w>)`;
            logger.warningf(pattern.expandTags, line);
            noErrors = false;
            continue;
        }

        string slice = line;  // mutable
        string pluginstring = slice.nom!(Yes.decode)(".");  // mutable
        immutable setting = slice.nom!(Yes.inherit, Yes.decode)('=');
        immutable value = slice;

        if (pluginstring == "core")
        {
            import kameloso.common : initLogger;
            import lu.objmanip : SetMemberException, setMemberByName;

            try
            {
                immutable success = slice.length ?
                    copyOfSettings.setMemberByName(setting, value) :
                    copyOfSettings.setMemberByName(setting, true);

                if (!success)
                {
                    enum pattern = "No such <l>core<w> setting: <l>%s";
                    logger.warningf(pattern.expandTags, setting);
                    noErrors = false;
                }
                else
                {
                    if ((setting == "monochrome") || (setting == "brightTerminal"))
                    {
                        initLogger(
                            cast(Flag!"monochrome")copyOfSettings.monochrome,
                            cast(Flag!"brightTerminal")copyOfSettings.brightTerminal,
                            cast(Flag!"headless")copyOfSettings.headless);
                    }

                    foreach (plugin; plugins)
                    {
                        plugin.state.settings = copyOfSettings;
                        plugin.state.updates |= typeof(plugin.state.updates).settings;
                    }
                }
            }
            catch (SetMemberException e)
            {
                enum pattern = "Failed to set <l>core<w>.<l>%s<w>: " ~
                    "it requires a value and none was supplied.";
                logger.warningf(pattern.expandTags, setting);
                version(PrintStacktraces) logger.trace(e.info);
                noErrors = false;
            }
            catch (ConvException e)
            {
                enum pattern = `Invalid value for <l>core<w>.<l>%s<w>: "<l>%s<w>"`;
                logger.warningf(pattern.expandTags, setting, value);
                noErrors = false;
            }

            continue top;
        }
        else
        {
            if (pluginstring == "twitch") pluginstring = "twitchbot";

            foreach (plugin; plugins)
            {
                if (plugin.name != pluginstring) continue;

                try
                {
                    immutable success = plugin.setSettingByName(setting,
                        value.length ? value : "true");

                    if (!success)
                    {
                        enum pattern = "No such <l>%s<w> plugin setting: <l>%s";
                        logger.warningf(pattern.expandTags, pluginstring, setting);
                        noErrors = false;
                    }
                }
                catch (ConvException e)
                {
                    enum pattern = `Invalid value for <l>%s<w>.<l>%s<w>: "<l>%s<w>"`;
                    logger.warningf(pattern.expandTags, pluginstring, setting, value);
                    noErrors = false;

                    //version(PrintStacktraces) logger.trace(e.info);
                }

                continue top;
            }
        }

        logger.warning("Invalid plugin: ", Tint.log, pluginstring);
        noErrors = false;
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

        override string name() @property const
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

    import std.conv : text;

    assert((ps.s == "abc def ghi"), ps.s);
    assert((ps.i == 42), ps.i.text);
    assert(isClose(ps.f, 3.14f), ps.f.text);
    assert(ps.b);
    assert(isClose(ps.d, 99.99), ps.d.text);
}


// IRCPluginSettingsException
/++
    Exception thrown when an IRC plugin failed to have its settings set.

    A normal [object.Exception|Exception], which only differs in the sense that
    we can deduce what went wrong by its type.
 +/
final class IRCPluginSettingsException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message,
        const string file = __FILE__,
        const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// IRCPluginInitialisationException
/++
    Exception thrown when an IRC plugin failed to initialise itself or its resources.

    A normal [object.Exception|Exception], which only differs in the sense that
    we can deduce what went wrong by its type.
 +/
final class IRCPluginInitialisationException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message,
        const string file = __FILE__,
        const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
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
        fun = Function/delegate pointer to call when the results return.
        caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(Plugin, Fun)
    (Plugin plugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fun fun,
    const string caller = __FUNCTION__)
in ((event != IRCEvent.init), "Tried to `enqueue` with an init IRCEvent")
in ((fun !is null), "Tried to `enqueue` with a null function pointer")
{
    import std.traits : isSomeFunction;

    static assert (isSomeFunction!Fun, "Tried to `enqueue` with a non-function function");

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            version(TwitchWarnings)
            {
                import kameloso.common : logger;
                import kameloso.printing : printObject;

                logger.warning(caller, " tried to WHOIS on Twitch");
                printObject(event);

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
        import kameloso.common : expandTags, logger;
        import lu.string : beginsWith;

        immutable callerSlice = caller.beginsWith("kameloso.plugins.") ?
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
                enum pattern = "<i>%s<l> plugin <w>NOT<l> queueing an event to be replayed " ~
                    "on behalf of <i>%s<l>; delta time <i>%d<l> is too recent";
                logger.logf(pattern.expandTags, plugin.name, callerSlice, delta);
            }
            return;
        }
    }

    version(ExplainReplay)
    {
        enum pattern = "<i>%s<l> plugin queueing an event to be replayed on behalf of <i>%s";
        logger.logf(pattern.expandTags, plugin.name, callerSlice);
    }

    plugin.state.pendingReplays[user.nickname] ~=
        replay(plugin, event, fun, permissionsRequired, caller);
    plugin.state.hasPendingReplays = true;
}


// replay
/++
    Convenience function that returns a [ReplayImpl] of the right type,
    *with* a subclass plugin reference attached.

    Params:
        plugin = Subclass [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] to
            call the function pointer `fun` with as first argument, when the
            WHOIS results return.
        event = [dialect.defs.IRCEvent|IRCEvent] that instigated the WHOIS lookup.
        fun = Function/delegate pointer to call upon receiving the results.
        permissionsRequired = The permissions level policy to apply to the WHOIS results.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A [Replay] with template parameters inferred from the arguments
        passed to this function.

    See_Also:
        [kameloso.plugins.common.core.Replay|Replay]
 +/
Replay replay(Plugin, Fun)(Plugin plugin, const ref IRCEvent event,
    Fun fun, const Permissions permissionsRequired, const string caller = __FUNCTION__)
{
    void dg(Replay replay)
    {
        import kameloso.common : expandTags, logger;
        import lu.conv : Enum;
        import lu.string : beginsWith;

        version(ExplainReplay)
        void explainReplay()
        {
            immutable caller = replay.caller.beginsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s<l> replaying <i>%s<l>-level event (invoking <i>%s<l>) " ~
                "based on WHOIS results; user <i>%s<l> is <i>%s<l> class";
            logger.logf(pattern.expandTags,
                plugin.name,
                Enum!Permissions.toString(replay.permissionsRequired),
                caller,
                replay.event.sender.nickname,
                Enum!(IRCUser.Class).toString(replay.event.sender.class_));
        }

        version(ExplainReplay)
        void explainRefuse()
        {
            immutable caller = replay.caller.beginsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s<l> plugin <w>NOT<l> replaying <i>%s<l>-level event " ~
                "(which would have invoked <i>%s<l>) " ~
                "based on WHOIS results: user <i>%s<l> is <i>%s<l> class";
            logger.logf(pattern.expandTags,
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

            import lu.traits : TakesParams;
            import std.traits : arity;

            version(ExplainReplay) explainReplay();

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
                static assert(0);
            }
            return;
        }

        version(ExplainReplay) explainRefuse();
    }

    return Replay(&dg, event, permissionsRequired, caller);
}


// rehashUsers
/++
    Rehashes a plugin's users, both the ones in the
    [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
    associative array and the ones in each [dialect.defs.IRCChannel.users] associative arrays.

    This optimises lookup and should be done every so often,

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
        plugin.state.users = plugin.state.users.rehash();
    }
    else if (auto channel = channelName in plugin.state.channels)
    {
        // created in `onChannelAwarenessSelfjoin`
        channel.users = channel.users.rehash();
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
string nameOf(const IRCUser user) pure @safe nothrow @nogc
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
        nickname = The name of a user to look up.

    Returns:
        The nickname of the user if there is no alias known, else the alias.
 +/
string nameOf(const IRCPlugin plugin, const string nickname) pure @safe nothrow @nogc
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            if (const user = nickname in plugin.state.users)
            {
                return nameOf(*user);
            }
        }
    }

    return nickname;
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
string idOf(const IRCUser user) pure @safe nothrow @nogc
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
        nickname = The name of a user to look up.

    Returns:
        An [dialect.defs.IRCUser|IRCUser] that matches the passed nickname, from the
        passed plugin's arrays. A minimally viable [dialect.defs.IRCUser|IRCUser] if
        none was found.
 +/
auto getUser(IRCPlugin plugin, const string nickname)
{
    if (const user = nickname in plugin.state.users)
    {
        return *user;
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            foreach (const user; plugin.state.users)
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


// EventURLs
/++
    A struct imitating a [std.typecons.Tuple], used to communicate the
    need for a Webtitles lookup.

    We shave off a few megabytes of required compilation memory by making it a
    struct instead of a tuple.
 +/
version(WithWebtitlesPlugin)
version(WithTwitchBotPlugin)
struct EventURLs
{
    /// The [dialect.defs.IRCEvent|IRCEvent] that should trigger a Webtitles lookup.
    IRCEvent event;

    /// The URLs discovered inside [dialect.defs.IRCEvent.content|IRCEvent.content].
    string[] urls;
}

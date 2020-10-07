/++
    The is not a plugin by itself but contains code common to all plugins,
    without which they will *not* function.

    It is mandatory if you plan to use any form of plugin. Indeed, the very
    definition of an `kameloso.plugins.common.core.IRCPlugin` is in here.
 +/
module kameloso.plugins.common.base;

private:

import kameloso.kameloso;
import kameloso.plugins.common.core;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;


public static import kameloso.plugins.common.core;

deprecated("Import from `kameloso.plugins.common.core` directly instead")
{
    /// Deprecated alias to `kameloso.plugins.common.core.IRCPluginState`.
    alias IRCPluginState = kameloso.plugins.common.core.IRCPluginState;
}

public:


// applyCustomSettings
/++
    Changes a setting of a plugin, given both the names of the plugin and the
    setting, in string form.

    This merely iterates the passed `plugins` and calls their `setSettingByName` methods.

    Params:
        plugins = Array of all `kameloso.plugins.common.core.IRCPlugin`s.
        customSettings = Array of custom settings to apply to plugins' own
            setting, in the string forms of "`plugin.setting=value`".
        copyOfSettings = A copy of the program-wide `kameloso.kameloso.CoreSettings`.

    Returns:
        `true` if no setting name mismatches occurred, `false` if it did.

    See_Also:
        lu.objmanip.setSettingByName
 +/
bool applyCustomSettings(IRCPlugin[] plugins, const string[] customSettings,
    CoreSettings copyOfSettings)
{
    import kameloso.common : Tint, logger;
    import lu.string : contains, nom;
    import std.conv : ConvException;

    bool noErrors = true;

    top:
    foreach (immutable line; customSettings)
    {
        if (!line.contains!(Yes.decode)('.'))
        {
            logger.warningf(`Bad %splugin%s.%1$ssetting%2$s=%1$svalue%2$s format. (%1$s%3$s%2$s)`,
                Tint.log, Tint.warning, line);
            noErrors = false;
            continue;
        }

        import std.uni : toLower;

        string slice = line;  // mutable
        immutable pluginstring = slice.nom!(Yes.decode)(".").toLower;
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
                    logger.warningf("No such %score%s setting: %1$s%3$s",
                        Tint.log, Tint.warning, setting);
                    noErrors = false;
                }
                else
                {
                    if ((setting == "monochrome") || (setting == "brightTerminal"))
                    {
                        initLogger((copyOfSettings.monochrome ? Yes.monochrome : No.monochrome),
                            (copyOfSettings.brightTerminal ? Yes.brightTerminal : No.brightTerminal));
                    }

                    foreach (plugin; plugins)
                    {
                        plugin.state.settings = copyOfSettings;
                        plugin.state.settingsUpdated = true;
                    }
                }
            }
            catch (SetMemberException e)
            {
                logger.warningf("Failed to set %score%s.%1$s%3$s%2$s: " ~
                    "it requires a value and none was supplied",
                    Tint.log, Tint.warning, setting);
                version(PrintStacktraces) logger.trace(e.info);
                noErrors = false;
            }
            catch (ConvException e)
            {
                logger.warningf(`Invalid value for %score%s.%1$s%3$s%2$s: "%1$s%4$s%2$s"`,
                    Tint.log, Tint.warning, setting, value);
                noErrors = false;
            }

            continue top;
        }
        else
        {
            foreach (plugin; plugins)
            {
                if (plugin.name != pluginstring) continue;

                try
                {
                    immutable success = plugin.setSettingByName(setting,
                        value.length ? value : "true");

                    if (!success)
                    {
                        logger.warningf("No such %s%s%s plugin setting: %1$s%4$s",
                            Tint.log, pluginstring, Tint.warning, setting);
                        noErrors = false;
                    }
                }
                catch (ConvException e)
                {
                    logger.warningf(`Invalid value for %s%s%s.%1$s%4$s%3$s: "%1$s%5$s%3$s"`,
                        Tint.log, pluginstring, Tint.warning, setting, value);
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
version(WithPlugins)
unittest
{
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

    import std.conv : text;
    import std.math : approxEqual;

    assert((ps.s == "abc def ghi"), ps.s);
    assert((ps.i == 42), ps.i.text);
    assert(ps.f.approxEqual(3.14f), ps.f.text);
    assert(ps.b);
    assert(ps.d.approxEqual(99.99), ps.d.text);
}

version(WithPlugins)
version(unittest)
{
    // These need to be module-level.

    @Settings private struct MyPluginSettings
    {
        @Enabler bool enabled;

        string s;
        int i;
        float f;
        bool b;
        double d;
    }

    private final class MyPlugin : IRCPlugin
    {
        MyPluginSettings myPluginSettings;

        override string name() @property const
        {
            return "myplugin";
        }

        mixin IRCPluginImpl;
    }
}


// IRCPluginSettingsException
/++
    Exception thrown when an IRC plugin failed to have its settings set.

    A normal `object.Exception`, which only differs in the sense that we can deduce
    what went wrong by its type.
 +/
final class IRCPluginSettingsException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message, const string file = __FILE__, const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// catchUser
/++
    Catch an `dialect.defs.IRCUser`, saving it to the `kameloso.plugins.common.core.IRCPlugin`'s
    `kameloso.plugins.common.core.IRCPluginState.users` array.

    If a user already exists, meld the new information into the old one.

    Params:
        plugin = Current `kameloso.plugins.common.core.IRCPlugin`.
        newUser = The `dialect.defs.IRCUser` to catch.
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
        plugin = Current `kameloso.plugins.common.core.IRCPlugin` as a base class.
        subPlugin = Subclass `kameloso.plugins.common.core.IRCPlugin` to replay the
            function pointer `fn` with as first argument.
        event = `dialect.defs.IRCEvent` to queue up to replay.
        privilegeLevel = Privilege level to match the results from the WHOIS query with.
        fn = Function/delegate pointer to call when the results return.
        caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(SubPlugin, Fn)(IRCPlugin plugin, SubPlugin subPlugin, const ref IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn, const string caller = __FUNCTION__)
in ((event != IRCEvent.init), "Tried to `enqueue` with an init IRCEvent")
in ((fn !is null), "Tried to `enqueue` with a null function pointer")
{
    import std.traits : isSomeFunction;

    static assert (isSomeFunction!Fn, "Tried to `enqueue` with a non-function function");

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            version(TwitchWarnings)
            {
                import kameloso.common : logger, printStacktrace;
                import kameloso.printing : printObject;

                logger.warning(caller, " tried to WHOIS on Twitch");
                printObject(event);
                version(PrintStacktraces) printStacktrace();
            }
            return;
        }
    }

    immutable user = event.sender.isServer ? event.target : event.sender;
    assert(user.nickname.length, "Bad user derived in `enqueue` (no nickname)");

    static if (is(SubPlugin == typeof(null)))
    {
        plugin.state.replays[user.nickname] ~=
            replay(event, privilegeLevel, fn, caller);
    }
    else
    {
        plugin.state.replays[user.nickname] ~=
            replay(subPlugin, event, privilegeLevel, fn, caller);
    }

    plugin.state.hasReplays = true;
}


// enqueue
/++
    Construct and enqueue a function replay in the plugin's queue of such.
    Overload that does not take an `kameloso.plugins.common.core.IRCPlugin` subclass parameter.

    The main loop will catch up on it and issue WHOIS queries as necessary, then
    replay the event upon receiving the results.

    Params:
        plugin = Current `kameloso.plugins.common.core.IRCPlugin` as a base class.
        event = `dialect.defs.IRCEvent` to queue up to replay.
        privilegeLevel = Privilege level to match the results from the WHOIS query with.
        fn = Function/delegate pointer to call when the results return.
        caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(Fn)(IRCPlugin plugin, const ref IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn, const string caller = __FUNCTION__)
{
    return enqueue(plugin, null, event, privilegeLevel, fn, caller);
}


/// Compatibility alias to `enqueue`.
deprecated("Use `enqueue` instead")
alias doWhois = enqueue;


// repeat
/++
    Queues a `core.thread.fiber.Fiber` (actually a `kameloso.thread.CarryingFiber`
    with a `Repeat` payload) to repeat a passed `kameloso.plugins.common.Replay` from the
    context of the main loop after postprocessing the event once more.

    Params:
        plugin = The current `kameloso.plugins.common.core.IRCPlugin`.
        dg = Delegate/function pointer to wrap the `core.thread.fiber.Fiber` around.
        replay = The `kameloso.plugins.common.core.Replay` to repeat.
 +/
void repeat(Dg)(IRCPlugin plugin, Dg dg, Replay replay)
if (isSomeFunction!Dg)
in ((dg !is null), "Tried to queue a repeat with a null delegate pointer")
in ((replay.event != IRCEvent.init), "Tried to queue a repeat of an init `Replay`")
{
    import kameloso.thread : CarryingFiber;
    plugin.state.repeats ~= Repeat(new CarryingFiber!Repeat(dg, 32_768), replay);
}


/// Compatibility alias of `repeat`.
deprecated("Use `repeat` instead")
alias queueToReplay = repeat;


// rehashUsers
/++
    Rehashes a plugin's users, both the ones in the `kameloso.plugins.common.core.IRCPluginState.users`
    associative array and the ones in each `dialect.defs.IRCChannel.users` associative arrays.

    This optimises lookup and should be done every so often,

    Params:
        plugin = The current `kameloso.plugins.common.core.IRCPlugin`.
        channelName = Optional name of the channel to rehash for. If none given
            it will rehash the main `kameloso.plugins.common.core.IRCPluginState.users`
            associative array instead.
 +/
void rehashUsers(IRCPlugin plugin, const string channelName = string.init)
{
    if (!channelName.length)
    {
        plugin.state.users.rehash();
    }
    else
    {
        foreach (ref channel; plugin.state.channels)
        {
            if (channelName != channel.name) continue;
            channel.users.rehash();
        }
    }
}


// nameOf
/++
    Returns either the nickname or the display name of a user, depending on whether the
    display name is known or not.

    If not version `TwitchSupport` then it always returns the nickname.

    Params:
        user = `dialect.defs.IRCUser` to examine.

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
    the passed plugin's `users` associative array of `dialect.defs.IRCUser`s.

    If not version `TwitchSupport` then it always returns the nickname.

    Params:
        plugin = The current `kameloso.plugins.common.core.IRCPlugin`, whatever it is.
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
        user = `dialect.defs.IRCUser` to examine.

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
    the passed plugin's `users` associative array of `dialect.defs.IRCUser`s.

    Merely wraps `getUser` with `idOf`.

    Params:
        plugin = The current `kameloso.plugins.common.core.IRCPlugin`, whatever it is.
        nickname = The name of a user to look up.

    Returns:
        The nickname or account of the passed user, or the passed nickname if
        nothing was found.

    See_Also:
        getUser
 +/
string idOf()(IRCPlugin plugin, const string nickname) pure @safe /*nothrow*/ @nogc
{
    immutable user = getUser(plugin, nickname);
    return idOf(user);
}

///
version(WithPlugins)
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
    Retrieves an `dialect.defs.IRCUser` from the passed plugin's `users`
    associative array. If none exists, returns a minimally viable `dialect.defs.IRCUser`
    with the passed nickname as its only value.

    On Twitch, if no user was found, it additionally tries to look up the passed
    nickname as if it was a display name.

    Params:
        plugin = The current `kameloso.plugins.common.core.IRCPlugin`, whatever it is.
        nickname = The name of a user to look up.

    Returns:
        An `dialect.defs.IRCUser` that matches the passed nickname, from the
        passed plugin's arrays. A minimally viable `dialect.defs.IRCUser` if
        none was found.
 +/
IRCUser getUser()(IRCPlugin plugin, const string nickname) pure @safe /*nothrow*/ @nogc
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
version(WithPlugins)
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
    A struct imitating a `std.typecons.Tuple`, used to communicate the
    need for a Webtitles lookup.

    We shave off a few megabytes of required compilation memory by making it a
    struct instead of a tuple.
 +/
version(WithWebtitlesPlugin)
version(WithTwitchBotPlugin)
struct EventURLs
{
    /// The `dialect.defs.IRCEvent` that should trigger a Webtitles lookup.
    IRCEvent event;

    /// The URLs discovered inside `event.content`.
    string[] urls;
}

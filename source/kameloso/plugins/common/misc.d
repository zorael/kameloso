/++
    The is not a plugin by itself but contains code common to all plugins,
    without which they will *not* function.

    See_Also:
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.misc;

private:

import kameloso.plugins.common;
import kameloso.common : logger;
import kameloso.pods : CoreSettings;
import dialect.defs;

public:


// applyCustomSettings
/++
    Changes a setting of a plugin, given both the names of the plugin and the
    setting, in string form.

    This merely iterates the passed `plugins` and calls their
    [kameloso.plugins.common.IRCPlugin.setMemberByName|IRCPlugin.setMemberByName]
    methods.

    Params:
        plugins = Array of all [kameloso.plugins.common.IRCPlugin|IRCPlugin]s.
        coreSettings = Pointer to a [kameloso.pods.CoreSettings|CoreSettings] struct.
        customSettings = Array of custom settings to apply to plugins' own
            setting, in the string forms of "`plugin.setting=value`".
        toPluginsOnly = Whether to apply settings to the core settings struct
            as well, or only to the plugins.

    Returns:
        `true` if no setting name mismatches occurred, `false` if it did.

    See_Also:
        [lu.objmanip.setSettingByName]
 +/
auto applyCustomSettings(
    IRCPlugin[] plugins,
    ref CoreSettings coreSettings,
    const string[] customSettings,
    const bool toPluginsOnly)
{
    import lu.objmanip : SetMemberException;
    import lu.string : advancePast;
    import std.algorithm.searching : canFind;
    import std.conv : ConvException;

    bool allSuccess = true;

    top:
    foreach (immutable line; customSettings)
    {
        if (!line.canFind('.'))
        {
            enum pattern = `Bad <l>plugin</>.<l>setting</>=<l>value</> format. (<l>%s</>)`;
            logger.warningf(pattern, line);
            allSuccess = false;
            continue;
        }

        string slice = line;  // mutable
        immutable pluginstring = slice.advancePast(".");
        immutable setting = slice.advancePast('=', inherit: true);
        alias value = slice;

        try
        {
            if (pluginstring == "core")
            {
                import kameloso.common : logger;
                import kameloso.logger : KamelosoLogger;
                import lu.objmanip : setMemberByName;
                import std.algorithm.comparison : among;

                if (toPluginsOnly) continue top;

                immutable success = value.length ?
                    coreSettings.setMemberByName(setting, value) :
                    coreSettings.setMemberByName(setting, true);

                if (!success)
                {
                    enum pattern = `No such <l>core</> setting: "<l>%s</>"`;
                    logger.warningf(pattern, setting);
                    allSuccess = false;
                }
                else
                {
                    if (setting.among!
                        ("colour",
                        "color",
                        "brightTerminal",
                        "headless",
                        "flush"))
                    {
                        logger = new KamelosoLogger(coreSettings);
                    }

                    foreach (plugin; plugins)
                    {
                        plugin.state.coreSettings = coreSettings;

                        // No need to flag as updated when we update here manually
                        //plugin.state.updates |= typeof(plugin.state.updates).coreSettings;
                    }
                }
                continue top;
            }
            else if (!plugins.length)
            {
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
                        enum pattern = `No such <l>%s</> plugin setting: "<l>%s</>"`;
                        logger.warningf(pattern, pluginstring, setting);
                        allSuccess = false;
                    }
                    continue top;
                }
            }

            // If we're here, the loop was never continued --> unknown plugin
            enum pattern = `Invalid plugin: "<l>%s</>"`;
            logger.warningf(pattern, pluginstring);
            allSuccess = false;
            // Drop down, try next
        }
        catch (SetMemberException e)
        {
            enum pattern = "Failed to set <l>%s</>.<l>%s</>: " ~
                "it requires a value and none was supplied.";
            logger.warningf(pattern, pluginstring, setting);
            version(PrintStacktraces) logger.trace(e.info);
            allSuccess = false;
            // Drop down, try next
        }
        catch (ConvException e)
        {
            enum pattern = `Invalid value for <l>%s</>.<l>%s</>: "<l>%s</>" <t>(%s)`;
            logger.warningf(pattern, pluginstring, setting, value, e.msg);
            allSuccess = false;
            // Drop down, try next
        }
        continue top;
    }

    return allSuccess;
}

///
unittest
{
    import std.conv : to;
    import std.math : isClose;

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

        override string name(const bool _, const bool __) const
        {
            return "myplugin";
        }

        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    IRCPlugin plugin = new MyPlugin(state);
    CoreSettings coreSettings;

    auto newSettings =
    [
        `myplugin.s="abc def ghi"`,
        "myplugin.i=42",
        "myplugin.f=3.14",
        "myplugin.b=true",
        "myplugin.d=99.99",
    ];

    cast(void)applyCustomSettings(
        [ plugin ],
        coreSettings: coreSettings,
        customSettings: newSettings,
        toPluginsOnly: true);

    const ps = (cast(MyPlugin)plugin).myPluginSettings;

    assert((ps.s == "abc def ghi"), ps.s);
    assert((ps.i == 42), ps.i.to!string);
    assert(ps.f.isClose(3.14f), ps.f.to!string);
    assert(ps.b);
    assert(ps.d.isClose(99.99), ps.d.to!string);
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
    [kameloso.plugins.common.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.common.IRCPluginState.users|IRCPluginState.users] array.

    If a user already exists, meld the new information into the old one.

    Params:
        plugin = Current [kameloso.plugins.common.IRCPlugin|IRCPlugin].
        newUser = The [dialect.defs.IRCUser|IRCUser] to catch.
 +/
void catchUser(IRCPlugin plugin, const IRCUser newUser) @system
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
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin], whatever it is.
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
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin], whatever it is.
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
        plugin = The current [kameloso.plugins.common.IRCPlugin|IRCPlugin], whatever it is.
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
            foreach (const user; plugin.state.users.aaOf)
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
            user.class_ = IRCUser.Class.anyone;
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
    return pluginFilenameSlicerImpl(filename, getPluginName: false);
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
    return pluginFilenameSlicerImpl(filename, getPluginName: true);
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
private auto pluginFilenameSlicerImpl(const string filename, const bool getPluginName)
in (filename.length, "Empty plugin filename passed to `pluginFilenameSlicerImpl`")
{
    import std.path : dirSeparator;
    import std.string : indexOf;

    string slice = filename;  // mutable
    size_t separatorPos = slice.indexOf(dirSeparator);

    while (separatorPos != -1)
    {
        if (slice[separatorPos+1..$] == "base.d")
        {
            return getPluginName ? slice[0..separatorPos] : slice;
        }

        slice = slice[separatorPos+1..$];
        separatorPos = slice.indexOf(dirSeparator);
    }

    return getPluginName ? slice[0..$-2] : slice;
}

/++
    This module contains common functions and types used by all plugins.

    See_Also:
        [kameloso.plugins],
        [kameloso.plugins.common.scheduling],
        [kameloso.plugins.common.mixins],
        [kameloso.plugins.common.mixins.awareness]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common;

private:

import kameloso.plugins;
import kameloso.common : logger;
import kameloso.pods : CoreSettings;
import dialect.defs;

public:


// catchUser
/++
    Catch an [dialect.defs.IRCUser|IRCUser], saving it to the
    [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users] array.

    If a user already exists, meld the new information into the old one.

    Params:
        plugin = Current [kameloso.plugins.IRCPlugin|IRCPlugin].
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
        plugin = The current [kameloso.plugins.IRCPlugin|IRCPlugin], whatever it is.
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
        plugin = The current [kameloso.plugins.IRCPlugin|IRCPlugin], whatever it is.
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
        plugin = The current [kameloso.plugins.IRCPlugin|IRCPlugin], whatever it is.
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
    nested in their own directories. The basename of `plugins/twitch/package.d` is
    `package.d`, much like that of `plugins/printer/package.d` is.

    With this we get `twitch/package.d` and `printer/package.d` instead, while still
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
            enum filename = "plugins/twitch/package.d";
            immutable expected = "twitch/package.d";
        }
        else /*version(Windows)*/
        {
            enum filename = "plugins\\twitch\\package.d";
            immutable expected = "twitch\\package.d";
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
        version(Posix) enum filename = "plugins/twitch/package.d";
        else /*version(Windows)*/ enum filename = "plugins\\twitch\\package.d";
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
    ptrdiff_t separatorPos = slice.indexOf(dirSeparator);

    while (separatorPos != -1)
    {
        if (slice[separatorPos+1..$] == "package.d")
        {
            return getPluginName ? slice[0..separatorPos] : slice;
        }

        slice = slice[separatorPos+1..$];
        separatorPos = slice.indexOf(dirSeparator);
    }

    return getPluginName ? slice[0..$-2] : slice;
}

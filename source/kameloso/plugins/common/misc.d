
module kameloso.plugins.common.misc;

private:

import kameloso.kameloso : CoreSettings;
import kameloso.plugins.common.core;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;

public:

bool applyCustomSettings(IRCPlugin[] plugins,
    const string[] customSettings,
    CoreSettings copyOfSettings)
{
    return true;
}

final class IRCPluginSettingsException : Exception
{
    this(const string message,
        const string file = __FILE__,
        const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}

final class IRCPluginInitialisationException : Exception
{
    this(const string message,
        const string file = __FILE__,
        const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}

void catchUser(IRCPlugin plugin, const IRCUser newUser) @safe {}

void enqueue(SubPlugin, Fn)
    (IRCPlugin plugin,
    SubPlugin subPlugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__)
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

    static if (is(SubPlugin == typeof(null)))
    {
        plugin.state.replays[user.nickname] ~=
            replay(event, permissionsRequired, fn, caller);
    }
    else
    {
        plugin.state.replays[user.nickname] ~=
            replay(subPlugin, event, permissionsRequired, fn, caller);
    }

    plugin.state.hasReplays = true;
}

void enqueue(Fn)
    (IRCPlugin plugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__)
{}

void repeat(Dg)(IRCPlugin plugin, Dg dg, Replay replay)
if (isSomeFunction!Dg)
in ((dg !is null), "Tried to queue a repeat with a null delegate pointer")
in ((replay.event != IRCEvent.init), "Tried to queue a repeat of an init `Replay`")
{}

void rehashUsers(IRCPlugin plugin, const string channelName = string.init) {}

pragma(inline, true)
string nameOf(const IRCUser user) pure @safe nothrow @nogc
{
    return string.init;
}

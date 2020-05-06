/++
 +  The is not a plugin by itself but contains code common to all plugins,
 +  without which they will *not* function.
 +
 +  It is mandatory if you plan to use any form of plugin. Indeed, the very
 +  definition of an `IRCPlugin` is in here.
 +/
module kameloso.plugins.common;

private:

import kameloso.plugins.core;
import kameloso.common : CoreSettings;
import dialect.defs;
import core.thread : Fiber;
import std.typecons : Flag, No, Yes;

/+
    Publicly import `kameloso.plugins.core.IRCPluginState` for compatibility
    (since it used to be housed here)
 +/
public import kameloso.plugins.core : IRCPluginState;

//version = TwitchWarnings;
//version = ExplainRepeat;

public:


// applyCustomSettings
/++
 +  Changes a setting of a plugin, given both the names of the plugin and the
 +  setting, in string form.
 +
 +  This merely iterates the passed `plugins` and calls their `setSettingByName` methods.
 +
 +  Params:
 +      plugins = Array of all `IRCPlugin`s.
 +      customSettings = Array of custom settings to apply to plugins' own
 +          setting, in the string forms of "`plugin.setting=value`".
 +      copyOfSettings = A copy of the program-wide `kameloso.common.CoreSettings`.
 +
 +  Returns:
 +      `true` if no setting name mismatches occurred, `false` if it did.
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
                            (copyOfSettings.brightTerminal ? Yes.brightTerminal : No.brightTerminal),
                            (copyOfSettings.flush ? Yes.flush : No.flush));
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

    applyCustomSettings([ plugin ], newSettings, state.settings);

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
 +  Exception thrown when an IRC plugin failed to have its settings set.
 +
 +  A normal `object.Exception`, which only differs in the sense that we can deduce
 +  what went wrong by its type.
 +/
final class IRCPluginSettingsException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message, const string file = __FILE__, const int line = __LINE__)
    {
        super(message, file, line);
    }
}


// MessagingProxy
/++
 +  Mixin to give shorthands to the functions in `kameloso.messaging`, for
 +  easier use when in a `with (plugin) { /* ... */ }` scope.
 +
 +  This merely makes it possible to use commands like
 +  `raw("PING :irc.freenode.net")` without having to import
 +  `kameloso.messaging` and include the thread ID of the main thread in every
 +  call of the functions.
 +
 +  Params:
 +      debug_ = Whether or not to include debugging output.
 +      module_ = String name of the mixing-in module; generally leave as-is.
 +/
version(WithPlugins)
mixin template MessagingProxy(Flag!"debug_" debug_ = No.debug_, string module_ = __MODULE__)
{
private:
    static import kameloso.messaging;
    static import kameloso.common;
    import std.typecons : Flag, No, Yes;

    /// Symbol needed for the mixin constraints to work.
    enum mixinSentinel = true;

    // Use a custom constraint to force the scope to be an IRCPlugin
    static if (!is(__traits(parent, mixinSentinel) : IRCPlugin))
    {
        import lu.traits : CategoryName;
        import std.format : format;

        alias messagingParent = __traits(parent, mixinSentinel);
        alias messagingParentInfo = CategoryName!messagingParent;

        enum pattern = "%s `%s` mixes in `%s` but it is only supposed to be " ~
            "mixed into an `IRCPlugin` subclass";
        static assert(0, pattern.format(messagingParentInfo.type,
            messagingParentInfo.fqn, "MessagingProxy"));
    }

    static if (__traits(compiles, this.hasMessagingProxy))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("MessagingProxy", typeof(this).stringof));
    }
    else
    {
        private enum hasMessagingProxy = true;
    }

    pragma(inline):

    // chan
    /++
     +  Sends a channel message.
     +/
    void chan(Flag!"priority" priority = No.priority)
        (const string channel, const string content,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.chan!priority(state, channel, content,
            No.quiet, No.background, caller);
    }


    // query
    /++
     +  Sends a private query message to a user.
     +/
    void query(Flag!"priority" priority = No.priority)
        (const string nickname, const string content,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.query!priority(state, nickname, content,
            No.quiet, No.background, caller);
    }


    // privmsg
    /++
     +  Sends either a channel message or a private query message depending on
     +  the arguments passed to it.
     +
     +  This reflects how channel messages and private messages are both the
     +  underlying same type; `dialect.defs.IRCEvent.Type.PRIVMSG`.
     +/
    void privmsg(Flag!"priority" priority = No.priority)(const string channel,
        const string nickname, const string content,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.privmsg!priority(state, channel, nickname, content,
            No.quiet, No.background, caller);
    }


    // emote
    /++
     +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
     +/
    void emote(Flag!"priority" priority = No.priority)
        (const string emoteTarget, const string content,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.emote!priority(state, emoteTarget, content,
            No.quiet, No.background, caller);
    }


    // mode
    /++
     +  Sets a channel mode.
     +
     +  This includes modes that pertain to a user in the context of a channel, like bans.
     +/
    void mode(Flag!"priority" priority = No.priority)(const string channel,
        const string modes, const string content = string.init)
    {
        return kameloso.messaging.mode!priority(state, channel, modes, content);
    }


    // topic
    /++
     +  Sets the topic of a channel.
     +/
    void topic(Flag!"priority" priority = No.priority)
        (const string channel, const string content,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.topic!priority(state, channel, content,
            No.quiet, No.background, caller);
    }


    // invite
    /++
     +  Invites a user to a channel.
     +/
    void invite(Flag!"priority" priority = No.priority)
        (const string channel, const string nickname,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.invite!priority(state, channel, nickname,
            No.quiet, No.background, caller);
    }


    // join
    /++
     +  Joins a channel.
     +/
    void join(Flag!"priority" priority = No.priority)
        (const string channel, const string key = string.init)
    {
        return kameloso.messaging.join!priority(state, channel, key);
    }


    // kick
    /++
     +  Kicks a user from a channel.
     +/
    void kick(Flag!"priority" priority = No.priority)(const string channel,
        const string nickname, const string reason = string.init,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.kick!priority(state, channel, nickname, reason,
            No.quiet, No.background, caller);
    }


    // part
    /++
     +  Leaves a channel.
     +/
    void part(Flag!"priority" priority = No.priority)(const string channel,
        const string reason = string.init,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.part!priority(state, channel, reason,
            No.quiet, No.background, caller);
    }


    // quit
    /++
     +  Disconnects from the server, optionally with a quit reason.
     +/
    void quit(Flag!"priority" priority = No.priority)(const string reason = string.init)
    {
        return kameloso.messaging.quit!priority(state, reason);
    }


    // whois
    /++
     +  Queries the server for WHOIS information about a user.
     +/
    void whois(Flag!"priority" priority = No.priority)(const string nickname,
        const Flag!"force" force = No.force, const Flag!"background" background = No.background,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.whois!priority(state, nickname, force,
            No.quiet, background, caller);
    }

    // raw
    /++
     +  Sends text to the server, verbatim.
     +
     +  This is used to send messages of types for which there exist no helper
     +  functions.
     +/
    void raw(Flag!"priority" priority = No.priority)(const string line,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.raw!priority(state, line,
            No.quiet, No.background, caller);
    }


    // immediate
    /++
     +  Sends raw text to the server, verbatim, bypassing all queues and
     +  throttling delays.
     +/
    void immediate(const string line)
    {
        return kameloso.messaging.immediate(state, line);
    }

    import std.range : only;
    import std.format : format;

    /+
     +  Generates the functions `askToWriteln`, `askToTrace`, `askToLog`,
     +  `askToInfo`, `askToWarning`, and `askToError`,
     +/
    static foreach (immutable verb; only("Writeln", "Trace", "Log",
        "Info", "Warn", "Warning", "Error"))
    {
        /++
         +  Generated `askToVerb` function. Asks the main thread to output text
         +  to the local terminal.
         +
         +  No need for any annotation; `kameloso.messaging.askToOutputImpl` is
         +  `@system` and nothing else.
         +/
        mixin("void askTo%s(const string line)
        {
            return kameloso.messaging.askTo%1$s(state, line);
        }".format(verb));
    }
}

///
unittest
{
    class MyPlugin : IRCPlugin
    {
        mixin MessagingProxy;
        mixin IRCPluginImpl;
    }

    IRCPluginState state;
    MyPlugin plugin = new MyPlugin(state);

    with (plugin)
    {
        // The below calls will fail in-contracts, so don't call them.
        // Just generate the code so we know they compile.
        if (plugin !is null) return;

        chan(string.init, string.init);
        query(string.init, string.init);
        privmsg(string.init, string.init, string.init);
        emote(string.init, string.init);
        mode(string.init, string.init, string.init);
        topic(string.init, string.init);
        invite(string.init, string.init);
        join(string.init, string.init);
        kick(string.init, string.init, string.init);
        part(string.init, string.init);
        quit(string.init);
        whois(string.init, Yes.force, No.background);
        raw(string.init);
        immediate(string.init);
        askToWriteln(string.init);
        askToTrace(string.init);
        askToLog(string.init);
        askToInfo(string.init);
        askToWarn(string.init);
        askToWarning(string.init);
        askToError(string.init);
    }
}


// Repeater
/++
 +  Implements queueing of events to repeat.
 +
 +  This allows us to deal with triggers both in `dialect.defs.IRCEvent.Type.RPL_WHOISACCOUNT`
 +  and `dialect.defs.IRCEvent.Type.ERR_UNKNOWNCOMMAND` while keeping the code
 +  in one place.
 +
 +  Params:
 +      debug_ = Whether or not to print debug output to the terminal.
 +/
version(WithPlugins)
mixin template Repeater(Flag!"debug_" debug_ = No.debug_, string module_ = __MODULE__)
{
    import lu.traits : MixinConstraints, MixinScope;
    import std.conv : text;
    import std.traits : isSomeFunction;

    mixin MixinConstraints!(MixinScope.function_, "Repeater");

    static if (__traits(compiles, hasRepeater))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("Repeater", __FUNCTION__));
    }
    else
    {
        private enum hasRepeater = true;
    }

    static if (__traits(compiles, plugin))
    {
        alias context = plugin;
        enum contextName = "plugin";
    }
    else static if (__traits(compiles, service))
    {
        alias context = service;
        enum contextName = "service";
    }
    else
    {
        static assert(0, "`Repeater` should be mixed into the context " ~
            "of an event handler. (Could not access variables named neither " ~
            "`plugin` nor `service` from within `" ~ __FUNCTION__ ~ "`)");
    }

    private enum replayVariableName = text("_kamelosoReplay", hashOf(__FUNCTION__) % 100);
    mixin("Replay " ~ replayVariableName ~ ';');


    // explainRepeat
    /++
     +  Verbosely explains a repeat, including what `PrivilegeLevel` and
     +  `dialect.defs.IRCUser.Class` were involved.
     +
     +  Gated behind version `ExplainRepeat`.
     +/
    version(ExplainRepeat)
    void explainRepeat(const IRCUser user)
    {
        import kameloso.common : Tint, logger;
        import lu.conv : Enum;

        logger.logf("%s%s%s %s repeating %1$s%5$s%3$s-level event " ~
            "based on WHOIS results (user is %1$s%6$s%3$s class)",
            Tint.info, context.name, Tint.log, contextName,
            Enum!PrivilegeLevel.toString(mixin(replayVariableName).privilegeLevel),
            Enum!(IRCUser.Class).toString(user.class_));
    }


    // repeaterDelegate
    /++
     +  Delegate to call from inside a `kameloso.thread.CarryingFiber`.
     +/
    void repeaterDelegate()
    {
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!Repeat)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != thisFiber.payload.init),
            "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

        Replay replay = mixin(replayVariableName);
        replay.event = thisFiber.payload.event;

        with (PrivilegeLevel)
        final switch (replay.privilegeLevel)
        {
        case admin:
            if (replay.event.sender.class_ >= IRCUser.Class.admin)
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

            // replay.event.sender.class_ is Class.blacklist here (or unset)
            // Do nothing an drop down
            break;

        case ignore:
            version(ExplainRepeat) explainRepeat(replay.event.sender);
            replay.trigger();
            break;
        }
    }

    /++
     +  Queues the delegate `repeaterDelegate` with the passed `Replay`
     +  attached to it.
     +/
    void repeat(Replay replay)
    {
        import kameloso.plugins.common : repeat;

        mixin(replayVariableName) = replay;
        context.repeat(&repeaterDelegate, replay.event);
    }

    /// Compatibility alias of `repeat`.
    deprecated("Use `repeat` instead")
    alias queueToReplay = repeat;
}


// catchUser
/++
 +  Catch an `dialect.defs.IRCUser`, saving it to the `IRCPlugin`'s
 +  `IRCPluginState.users` array.
 +
 +  If a user already exists, meld the new information into the old one.
 +
 +  Params:
 +      plugin = Current `IRCPlugin`.
 +      newUser = The `dialect.defs.IRCUser` to catch.
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
 +  Construct and enqueue a function replay in the plugin's queue of such.
 +
 +  The main loop will catch up on it and issue WHOIS queries as necessary, then
 +  replay the event upon receiving the results.
 +
 +  Params:
 +      plugin = Current `IRCPlugin` as a base class.
 +      subPlugin = Subclass `IRCPlugin` to replay the function pointer `fn` with
 +          as first argument.
 +      event = `dialect.defs.IRCEvent` to queue up to replay.
 +      privilegeLevel = Privilege level to match the results from the WHOIS query with.
 +      fn = Function/delegate pointer to call when the results return.
 +      caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(SubPlugin, Fn)(IRCPlugin plugin, SubPlugin subPlugin, const IRCEvent event,
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
}


// enqueue
/++
 +  Construct and enqueue a function replay in the plugin's queue of such.
 +  Overload that does not take an `IRCPlugin` subclass parameter.
 +
 +  The main loop will catch up on it and issue WHOIS queries as necessary, then
 +  replay the event upon receiving the results.
 +
 +  Params:
 +      plugin = Current `IRCPlugin` as a base class.
 +      event = `dialect.defs.IRCEvent` to queue up to replay.
 +      privilegeLevel = Privilege level to match the results from the WHOIS query with.
 +      fn = Function/delegate pointer to call when the results return.
 +      caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(Fn)(IRCPlugin plugin, const IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn, const string caller = __FUNCTION__)
{
    return enqueue(plugin, null, event, privilegeLevel, fn, caller);
}


/// Compatibility alias to `enqueue`.
deprecated("Use `enqueue` instead")
alias doWhois = enqueue;


// repeat
/++
 +  Queues a `core.thread.fiber.Fiber` (actually a `kameloso.thread.CarryingFiber`
 +  with a `Repeat` payload) to repeat a passed `dialect.defs.IRCEvent` from the
 +  context of the main loop after postprocessing the event once more.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      dg = Delegate/function pointer to wrap the `core.thread.fiber.Fiber` around.
 +      event = The `dialect.defs.IRCEvent` to repeat.
 +/
void repeat(Dg)(IRCPlugin plugin, Dg dg, const IRCEvent event)
if (isSomeFunction!Dg)
in ((dg !is null), "Tried to queue a repeat with a null delegate pointer")
in ((event != IRCEvent.init), "Tried to queue a repeat with an init IRCEvent")
{
    import kameloso.thread : CarryingFiber;
    plugin.state.repeats ~= Repeat(new CarryingFiber!Repeat(dg, 32_768), event);
}


/// Compatibility alias of `repeat`.
deprecated("Use `repeat` instead")
alias queueToReplay = repeat;


// rehashUsers
/++
 +  Rehashes a plugin's users, both the ones in the `IRCPluginState.users`
 +  associative array and the ones in each `dialect.defs.IRCChannel.users` associative arrays.
 +
 +  This optimises lookup and should be done every so often,
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      channelName = Optional name of the channel to rehash for. If none given
 +          it will rehash the main `IRCPluginState.users` associative array instead.
 +/
void rehashUsers(IRCPlugin plugin, const string channelName = string.init)
{
    if (!channelName.length)
    {
        plugin.state.users.rehash();
    }

    foreach (ref channel; plugin.state.channels)
    {
        if (channelName.length && (channelName != channel.name)) continue;
        channel.users.rehash();
    }
}


// delay
/++
 +  Queues a `core.thread.fiber.Fiber` to be called at a point `duration`
 +  seconds or milliseconds later, by appending it to the `plugin`'s
 +  `IRCPluginState.scheduledFibers`.
 +
 +  Updates the `IRCPluginState.nextFiberTimestamp` timestamp so that the
 +  main loop knows when to next process the array of `kameloso.thread.ScheduledFiber`s.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to enqueue to be executed at a later point in time.
 +      duration = Amount of time to delay the `fiber`.
 +      msecs = Whether `duration` is in milliseconds or seconds.
 +/
void delay(IRCPlugin plugin, Fiber fiber, const long duration,
    const Flag!"msecs" msecs = No.msecs)
in ((fiber !is null), "Tried to delay a null Fiber")
{
    import kameloso.thread : ScheduledFiber;
    import std.datetime.systime : Clock;

    immutable time = Clock.currStdTime + (msecs ?
        (duration * 10_000) :  // hnsecs -> msecs
        (duration * 10_000_000));  // hnsecs -> seconds
    plugin.state.scheduledFibers ~= ScheduledFiber(fiber, time);

    plugin.state.updateNextFiberTimestamp();
}


// delay
/++
 +  Queues a `core.thread.fiber.Fiber` to be called at a point `duration`
 +  seconds or milliseconds later, by appending it to the `plugin`'s
 +  `IRCPluginState.scheduledFibers`.
 +  Overload that implicitly queues `core.thread.fiber.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      duration = Amount of time to delay the implicit fiber in the current context.
 +      msecs = Whether `period` is in milliseconds or seconds.
 +      yield = Whether or not to immediately yield the Fiber.
 +/
void delay(IRCPlugin plugin, const long duration, const Flag!"msecs" msecs = No.msecs,
    const Flag!"yield" yield = No.yield)
{
    delay(plugin, Fiber.getThis, duration, msecs);
    if (yield) Fiber.yield();
}


// delay
/++
 +  Queues a `core.thread.fiber.Fiber` to be called at a point `duration`
 +  seconds later, by appending it to the `plugin`'s `IRCPluginState.scheduledFibers`.
 +  Implicitly queues `core.thread.fiber.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      duration = Amount of time to delay the implicit fiber in the current context.
 +      yield = Whether or not to immediately yield the Fiber.
 +/
void delay(IRCPlugin plugin, const long duration, const Flag!"yield" yield)
{
    delay(plugin, Fiber.getThis, duration, No.msecs);
    if (yield) Fiber.yield();
}


// removeDelayedFiber
/++
 +  Removes a `core.thread.fiber.Fiber` from being called at any point later.
 +
 +  Updates the `nextFiberTimestamp` UNIX timestamp so that the main loop knows
 +  when to process the array of `core.thread.fiber.Fiber`s.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to dequeue from being executed at a later point in time.
 +/
void removeDelayedFiber(IRCPlugin plugin, Fiber fiber)
in ((fiber !is null), "Tried to remove a delayed null Fiber")
{
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;

    size_t[] toRemove;

    foreach (immutable i, scheduledFiber; plugin.state.scheduledFibers)
    {
        if (scheduledFiber.fiber is fiber)
        {
            toRemove ~= i;
        }
    }

    if (!toRemove.length) return;

    foreach_reverse (immutable i; toRemove)
    {
        plugin.state.scheduledFibers = plugin.state.scheduledFibers
            .remove!(SwapStrategy.unstable)(i);
    }

    plugin.state.updateNextFiberTimestamp();
}


// removeDelayedFiber
/++
 +  Removes a `core.thread.fiber.Fiber` from being called at any point later.
 +
 +  Overload that implicitly removes `core.thread.fiber.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +/
void removeDelayedFiber(IRCPlugin plugin)
{
    return plugin.removeDelayedFiber(Fiber.getThis);
}


// await
/++
 +  Queues a `core.thread.fiber.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to enqueue to be executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      type = The kind of `dialect.defs.IRCEvent` that should trigger the
 +          passed awaiting fiber.
 +/
void await(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= fiber;
}


// await
/++
 +  Queues a `core.thread.fiber.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `core.thread.fiber.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      type = The kind of `dialect.defs.IRCEvent` that should trigger this
 +          implicit awaiting fiber (in the current context).
 +      yield = Whether or not to immediately yield the Fiber.
 +/
void await(IRCPlugin plugin, const IRCEvent.Type type,
    const Flag!"yield" yield = No.yield)
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    if (yield) Fiber.yield();
}


// await
/++
 +  Queues a `core.thread.fiber.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to enqueue to be executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          the passed awaiting fiber, in an array with elements of type
 +          `dialect.defs.IRCEvent.Type`.
 +/
void await(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= fiber;
    }
}


// await
/++
 +  Queues a `core.thread.fiber.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `core.thread.fiber.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          this implicit awaiting fiber (in the current context), in an array
 +          with elements of type `dialect.defs.IRCEvent.Type`.
 +      yield = Whether or not to immediately yield the Fiber.
 +/
void await(IRCPlugin plugin, const IRCEvent.Type[] types,
    const Flag!"yield" yield = No.yield)
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    }

    if (yield) Fiber.yield();
}


// awaitEvent
/++
 +  Compatibility alias of `await`.
 +/
deprecated("Use `await` instead")
alias awaitEvent = await;


// awaitEvents
/++
 +  Compatibility alias of `await`.
 +/
deprecated("Use `await` instead")
alias awaitEvents = await;


// unawait
/++
 +  Dequeues a `core.thread.fiber.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to dequeue from being executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      type = The kind of `dialect.defs.IRCEvent` that would trigger the
 +          passed awaiting fiber.
 +/
void unawait(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
in ((fiber !is null), "Tried to unlist a null Fiber from awaiting events")
in ((type != IRCEvent.Type.UNSET), "Tried to unlist a Fiber from awaiting `IRCEvent.Type.UNSET`")
{
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;

    void removeFiberForType(const IRCEvent.Type type)
    {
        foreach (immutable i, awaitingFiber; plugin.state.awaitingFibers[type])
        {
            if (awaitingFiber is fiber)
            {
                plugin.state.awaitingFibers[type] = plugin.state.awaitingFibers[type]
                    .remove!(SwapStrategy.unstable)(i);
                break;
            }
        }
    }

    if (type == IRCEvent.Type.ANY)
    {
        import std.traits : EnumMembers;

        static immutable allTypes = [ EnumMembers!(IRCEvent.Type) ];

        foreach (immutable thisType; allTypes)
        {
            removeFiberForType(thisType);
        }
    }
    else
    {
        removeFiberForType(type);
    }
}


// unawait
/++
 +  Dequeues a `core.thread.fiber.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type. Overload that implicitly dequeues
 +  `core.thread.fiber.Fiber.getThis`.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      type = The kind of `dialect.defs.IRCEvent` that would trigger this
 +          implicit awaiting fiber (in the current context).
 +/
void unawait(IRCPlugin plugin, const IRCEvent.Type type)
{
    return unawait(plugin, Fiber.getThis, type);
}


// unawait
/++
 +  Dequeues a `core.thread.fiber.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.fiber.Fiber` to dequeue from being executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          the passed awaiting fiber, in an array with elements of type
 +          `dialect.defs.IRCEvent.Type`.
 +/
void unawait(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        unawait(plugin, fiber, type);
    }
}


// unawait
/++
 +  Dequeues a `core.thread.fiber.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types. Overload that implicitly dequeues
 +  `core.thread.fiber.Fiber.getThis`.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          this implicit awaiting fiber (in the current context), in an array
 +          with elements of type `dialect.defs.IRCEvent.Type`.
 +/
void unawait(IRCPlugin plugin, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        unawait(plugin, Fiber.getThis, type);
    }
}


// unlistFiberAwaitingEvent
/++
 +  Compatibility alias of `unawait`.
 +/
deprecated("Use `unawait` instead")
alias unlistFiberAwaitingEvent = unawait;


// unawait
/++
 +  Compatibility alias of `unawait`.
 +/
deprecated("Use `unawait` instead")
alias unlistFiberAwaitingEvents = unawait;


private import std.traits : isSomeFunction;

// WHOISFiberDelegate
/++
 +  Functionality for catching WHOIS results and calling passed function aliases
 +  with the resulting account information that was divined from it, in the form
 +  of the actual `dialect.defs.IRCEvent`, the target
 +  `dialect.defs.IRCUser` within it, the user's `account` field, or merely
 +  alone as an arity-0 function.
 +
 +  The mixed in function to call is named `enqueueAndWHOIS`. It will construct
 +  the Fiber, enqueue it as awaiting the proper IRCEvent types, and issue the
 +  WHOIS query.
 +
 +  Example:
 +  ---
 +  void onSuccess(const IRCEvent successEvent) { /* ... */ }
 +  void onFailure(const IRCUser failureUser) { /* .. */ }
 +
 +  mixin WHOISFiberDelegate!(onSuccess, onFailure);
 +
 +  enqueueAndWHOIS(specifiedNickname);
 +  ---
 +
 +  Params:
 +      onSuccess = Function alias to call when successfully having received
 +          account information from the server's WHOIS response.
 +      onFailure = Function alias to call when the server didn't respond with
 +          account information, or when the user is offline.
 +      alwaysLookup = Whether or not to always issue a WHOIS query, even if
 +          the requested user's account is already known.
 +/
mixin template WHOISFiberDelegate(alias onSuccess, alias onFailure = null,
    Flag!"alwaysLookup" alwaysLookup = No.alwaysLookup)
if (isSomeFunction!onSuccess && (is(typeof(onFailure) == typeof(null)) || isSomeFunction!onFailure))
{
    import lu.traits : MixinConstraints, MixinScope;
    import std.conv : text;

    mixin MixinConstraints!(MixinScope.function_, "WHOISFiberDelegate");

    static if (__traits(compiles, hasWHOISFiber))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("WHOISFiberDelegate", __FUNCTION__));
    }
    else
    {
        private enum hasWHOISFiber = true;
    }

    static if (__traits(compiles, plugin))
    {
        alias context = plugin;
    }
    else static if (__traits(compiles, service))
    {
        alias context = service;
    }
    else
    {
        static assert(0, "`WHOISFiberDelegate` should be mixed into the context " ~
            "of an event handler. (Could not access variables named neither " ~
            "`plugin` nor `service` from within `" ~ __FUNCTION__ ~ "`)");
    }


    // carriedVariable
    /++
     +  Nickname being looked up, stored outside of any separate function to make
     +  it available to all of them.
     +
     +  Randomly generated name so as not to accidentally collide with the
     +  mixing in site.
     +/
    private enum carriedVariableName = text("_kamelosoCarriedNickname", hashOf(__FUNCTION__) % 100);
    mixin("string " ~ carriedVariableName ~ ';');


    /++
     +  Event types that we may encounter as responses to WHOIS queries.
     +/
    static immutable IRCEvent.Type[6] whoisEventTypes =
    [
        IRCEvent.Type.RPL_WHOISUSER,
        IRCEvent.Type.RPL_WHOISACCOUNT,
        IRCEvent.Type.RPL_WHOISREGNICK,
        IRCEvent.Type.RPL_ENDOFWHOIS,
        IRCEvent.Type.ERR_NOSUCHNICK,
        IRCEvent.Type.ERR_UNKNOWNCOMMAND,
    ];


    // whoisFiberDelegate
    /++
     +  Reusable mixin that catches WHOIS results.
     +/
    void whoisFiberDelegate()
    {
        import kameloso.thread : CarryingFiber;
        import dialect.common : toLowerCase;
        import dialect.defs : IRCEvent, IRCUser;
        import lu.conv : Enum;
        import lu.traits : TakesParams;
        import std.algorithm.searching : canFind;
        import std.meta : AliasSeq;
        import std.traits : arity;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != IRCEvent.init),
            "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

        immutable whoisEvent = thisFiber.payload;

        assert(whoisEventTypes[].canFind(whoisEvent.type),
            "WHOIS Fiber delegate was invoked with an unexpected event type: " ~
            "`IRCEvent.Type." ~ Enum!(IRCEvent.Type).toString(whoisEvent.type) ~'`');

        /++
         +  Invoke `onSuccess`.
         +/
        void callOnSuccess()
        {
            static if (TakesParams!(onSuccess, AliasSeq!IRCEvent))
            {
                return onSuccess(whoisEvent);
            }
            else static if (TakesParams!(onSuccess, AliasSeq!IRCUser))
            {
                return onSuccess(whoisEvent.target);
            }
            else static if (TakesParams!(onSuccess, AliasSeq!string))
            {
                return onSuccess(whoisEvent.target.account);
            }
            else static if (arity!onSuccess == 0)
            {
                return onSuccess();
            }
            else
            {
                import std.format : format;

                enum pattern = "Unsupported signature of success function/delegate " ~
                    "alias passed to mixin `WHOISFiberDelegate` in `%s`: `%s %s`";
                static assert(0, pattern.format(__FUNCTION__,
                    typeof(onSuccess).stringof, __traits(identifier, onSuccess)));
            }
        }

        /++
         +  Invoke `onFailure`, if it's available.
         +/
        void callOnFailure()
        {
            static if (!is(typeof(onFailure) == typeof(null)))
            {
                static if (TakesParams!(onFailure, AliasSeq!IRCEvent))
                {
                    return onFailure(whoisEvent);
                }
                else static if (TakesParams!(onFailure, AliasSeq!IRCUser))
                {
                    return onFailure(whoisEvent.target);
                }
                else static if (TakesParams!(onFailure, AliasSeq!string))
                {
                    // Never called when using hostmasks
                    return onFailure(whoisEvent.target.account);
                }
                else static if (arity!onFailure == 0)
                {
                    return onFailure();
                }
                else
                {
                    import std.format : format;

                    enum pattern = "Unsupported signature of failure function/delegate " ~
                        "alias passed to mixin `WHOISFiberDelegate` in `%s`: `%s %s`";
                    static assert(0, pattern.format(__FUNCTION__,
                        typeof(onFailure).stringof, __traits(identifier, onFailure)));
                }
            }
        }

        if (whoisEvent.type == IRCEvent.Type.ERR_UNKNOWNCOMMAND)
        {
            if (!whoisEvent.aux.length || (whoisEvent.aux == "WHOIS"))
            {
                // WHOIS query failed due to unknown command.
                // Some flavours of ERR_UNKNOWNCOMMAND don't say what the
                // command was, so we'll have to assume it's the right one.
                // Return and end Fiber.
                return callOnFailure();
            }
            else
            {
                // Wrong unknown command; await a new one
                Fiber.yield();
                return whoisFiberDelegate();  // Recurse
            }
        }

        immutable m = plugin.state.server.caseMapping;

        if (toLowerCase(mixin(carriedVariableName), m) !=
            whoisEvent.target.nickname.toLowerCase(m))
        {
            // Wrong WHOIS; await a new one
            Fiber.yield();
            return whoisFiberDelegate();  // Recurse
        }

        import kameloso.plugins.common : unawait;

        // Clean up awaiting fiber entries on exit, just to be neat.
        scope(exit) unawait(context, thisFiber, whoisEventTypes[]);

        with (IRCEvent.Type)
        switch (whoisEvent.type)
        {
        case RPL_WHOISACCOUNT:
        case RPL_WHOISREGNICK:
            return callOnSuccess();

        case RPL_WHOISUSER:
            if (context.state.settings.preferHostmasks)
            {
                return callOnSuccess();
            }
            else
            {
                // We're not interested in RPL_WHOISUSER if we're not in hostmasks mode
                Fiber.yield();
                return whoisFiberDelegate();  // Recurse
            }

        case RPL_ENDOFWHOIS:
        case ERR_NOSUCHNICK:
        //case ERR_UNKNOWNCOMMAND:  // Already handled above
            return callOnFailure();

        default:
            assert(0, "Unexpected WHOIS event type encountered in `whoisFiberDelegate`");
        }
    }


    // enqueueAndWHOIS
    /++
     +  Constructs a `kameloso.thread.CarryingFiber` carrying a `dialect.defs.IRCEvent`
     +  and enqueues it into the `kameloso.plugins.core.IRCPluginState.awaitingFibers`
     +  associative array, then issues a WHOIS query (unless overridden via
     +  the `issueWhois` parameter).
     +
     +  Params:
     +      nickname = Nickname of the user the enqueueing event relates to.
     +      issueWhois = Whether to actually issue WHOIS queries at all or just enqueue.
     +      background = Whether or not to issue queries as low-priority background messages.
     +
     +  Throws:
     +      `object.Exception` if a success of failure function was to trigger
     +      in an impossible scenario, such as on WHOIS results on Twitch.
     +/
    void enqueueAndWHOIS(const string nickname,
        const Flag!"issueWhois" issueWhois = Yes.issueWhois,
        const Flag!"background" background = No.background)
    {
        import kameloso.messaging : whois;
        import kameloso.thread : CarryingFiber;
        import lu.string : contains, nom;
        import lu.traits : TakesParams;
        import std.meta : AliasSeq;
        import std.traits : arity;
        import std.typecons : Flag, No, Yes;
        import core.thread : Fiber;

        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Define Twitch queries as always succeeding, since WHOIS isn't applicable

                version(TwitchWarnings)
                {
                    import kameloso.common : logger, printStacktrace;
                    logger.warning("Tried to enqueue and WHOIS on Twitch");
                    version(PrintStacktraces) printStacktrace();
                }

                static if (__traits(compiles, .hasUserAwareness))
                {
                    if (const user = nickname in context.state.users)
                    {
                        static if (TakesParams!(onSuccess, AliasSeq!IRCEvent))
                        {
                            // Can't WHOIS on Twitch
                            throw new Exception("Tried to enqueue a `" ~
                                typeof(onSuccess).stringof ~ " onSuccess` function " ~
                                "when on Twitch (can't WHOIS)");
                        }
                        else static if (TakesParams!(onSuccess, AliasSeq!IRCUser))
                        {
                            return onSuccess(*user);
                        }
                        else static if (TakesParams!(onSuccess, AliasSeq!string))
                        {
                            return onSuccess(user.account);
                        }
                        else static if (arity!onSuccess == 0)
                        {
                            return onSuccess();
                        }
                        else
                        {
                            // Will already have asserted previously
                        }
                    }
                }

                static if (TakesParams!(onSuccess, AliasSeq!IRCEvent) ||
                    TakesParams!(onSuccess, AliasSeq!IRCUser))
                {
                    // Can't WHOIS on Twitch
                    throw new Exception("Tried to enqueue a `" ~
                        typeof(onSuccess).stringof ~ " onSuccess` function " ~
                        "when on Twitch without `UserAwareness` (can't WHOIS)");
                }
                else static if (TakesParams!(onSuccess, AliasSeq!string))
                {
                    return onSuccess(nickname);
                }
                else static if (arity!onSuccess == 0)
                {
                    return onSuccess();
                }
                else
                {
                    // Will already have asserted previously
                }
            }
        }

        static if (!alwaysLookup && __traits(compiles, .hasUserAwareness))
        {
            if (const user = nickname in context.state.users)
            {
                if (user.account.length)
                {
                    static if (TakesParams!(onSuccess, AliasSeq!IRCEvent))
                    {
                        // No can do, drop down and WHOIS
                    }
                    else static if (TakesParams!(onSuccess, AliasSeq!IRCUser))
                    {
                        return onSuccess(*user);
                    }
                    else static if (TakesParams!(onSuccess, AliasSeq!string))
                    {
                        return onSuccess(user.account);
                    }
                    else static if (arity!onSuccess == 0)
                    {
                        return onSuccess();
                    }
                    else
                    {
                        // Will already have asserted previously
                    }
                }
            }
        }

        import kameloso.plugins.common : await;

        Fiber fiber = new CarryingFiber!IRCEvent(&whoisFiberDelegate, 32_768);
        await(context, fiber, whoisEventTypes[]);

        string slice = nickname;

        immutable nicknamePart = slice.contains('!') ?
            slice.nom('!') :
            slice;

        if (issueWhois)
        {
            if (background)
            {
                // Need Yes.force to not miss events
                whois(context.state, nicknamePart, Yes.force, Yes.quiet, Yes.background);
            }
            else
            {
                // Ditto
                whois!(Yes.priority)(context.state, nicknamePart, Yes.force, Yes.quiet);
            }
        }

        mixin(carriedVariableName) = nicknamePart;
    }
}


// nameOf
/++
 +  Returns either the nickname or the display name of a user, depending on whether the
 +  display name is known or not.
 +
 +  If not version `TwitchSupport` then it always returns the nickname.
 +
 +  Params:
 +      user = `dialect.defs.IRCUser` to examine.
 +
 +  Returns:
 +      The nickname of the user if there is no alias known, else the alias.
 +/
pragma(inline)
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
 +  Returns either the nickname or the display name of a user, depending on whether the
 +  display name is known or not. Overload that looks up the passed nickname in
 +  the passed plugin's `users` associative array of `dialect.defs.IRCUser`s.
 +
 +  If not version `TwitchSupport` then it always returns the nickname.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`, whatever it is.
 +      nickname = The name of a user to look up.
 +
 +  Returns:
 +      The nickname of the user if there is no alias known, else the alias.
 +/
pragma(inline)
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
 +  Returns either the nickname or the account of a user, depending on whether
 +  the account is known.
 +
 +  Params:
 +      user = `dialect.defs.IRCUser` to examine.
 +
 +  Returns:
 +
 +/
pragma(inline)
string idOf(const IRCUser user) pure @safe nothrow @nogc
in (user.nickname.length, "Tried to get `idOf` a user with an empty nickname")
{
    return user.account.length ? user.account : user.nickname;
}


// idOf
/++
 +  Returns either the nickname or the account of a user, depending on whether
 +  the account is known. Overload that looks up the passed nickname in
 +  the passed plugin's `users` associative array of `dialect.defs.IRCUser`s.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`, whatever it is.
 +      nickname = The name of a user to look up.
 +
 +  Returns:
 +
 +/
pragma(inline)
string idOf(IRCPlugin plugin, const string nickname) pure @safe nothrow @nogc
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            return nickname;
        }
    }

    if (const user = nickname in plugin.state.users)
    {
        return idOf(*user);
    }
    else
    {
        return nickname;
    }
}

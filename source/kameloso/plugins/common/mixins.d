/++
    The section of `kameloso.plugins.common` that involves mixins.

    This was all in one `plugins/common.d` file that just grew too big.
 +/
module kameloso.plugins.common.mixins;

version(WithPlugins):

private:

import kameloso.plugins.common;
import dialect.defs;
import std.traits : isSomeFunction;
import std.typecons : Flag, No, Yes;

public:


// WHOISFiberDelegate
/++
    Functionality for catching WHOIS results and calling passed function aliases
    with the resulting account information that was divined from it, in the form
    of the actual `dialect.defs.IRCEvent`, the target
    `dialect.defs.IRCUser` within it, the user's `account` field, or merely
    alone as an arity-0 function.

    The mixed in function to call is named `enqueueAndWHOIS`. It will construct
    the Fiber, enqueue it as awaiting the proper IRCEvent types, and issue the
    WHOIS query.

    Example:
    ---
    void onSuccess(const ref IRCEvent successEvent) { /* ... */ }
    void onFailure(const IRCUser failureUser) { /* .. */ }

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specifiedNickname);
    ---

    Params:
        onSuccess = Function alias to call when successfully having received
            account information from the server's WHOIS response.
        onFailure = Function alias to call when the server didn't respond with
            account information, or when the user is offline.
        alwaysLookup = Whether or not to always issue a WHOIS query, even if
            the requested user's account is already known.
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

    static if (!alwaysLookup && !__traits(compiles, .hasUserAwareness))
    {
        pragma(msg, "Warning: " ~ __FUNCTION__ ~ " mixes in `WHOISFiberDelegate` " ~
            "but its parent module does not mix in `UserAwareness`");
    }


    // _kamelosoCarriedNickname
    /++
        Nickname being looked up, stored outside of any separate function to make
        it available to all of them.
     +/
    string _kamelosoCarriedNickname;


    /++
        Event types that we may encounter as responses to WHOIS queries.
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
        Reusable mixin that catches WHOIS results.
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
            Invoke `onSuccess`.
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
            Invoke `onFailure`, if it's available.
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

        if (toLowerCase(_kamelosoCarriedNickname, m) !=
            whoisEvent.target.nickname.toLowerCase(m))
        {
            // Wrong WHOIS; await a new one
            Fiber.yield();
            return whoisFiberDelegate();  // Recurse
        }

        import kameloso.plugins.common.delayawait : unawait;

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
        Constructs a `kameloso.thread.CarryingFiber` carrying a `dialect.defs.IRCEvent`
        and enqueues it into the `kameloso.plugins.common.core.IRCPluginState.awaitingFibers`
        associative array, then issues a WHOIS query (unless overridden via
        the `issueWhois` parameter).

        Params:
            nickname = Nickname of the user the enqueueing event relates to.
            issueWhois = Whether to actually issue WHOIS queries at all or just enqueue.
            background = Whether or not to issue queries as low-priority background messages.

        Throws:
            `object.Exception` if a success of failure function was to trigger
            in an impossible scenario, such as on WHOIS results on Twitch.
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

        import kameloso.plugins.common.delayawait : await;

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

        _kamelosoCarriedNickname = nicknamePart;
    }
}


// MessagingProxy
/++
    Mixin to give shorthands to the functions in `kameloso.messaging`, for
    easier use when in a `with (plugin) { /* ... */ }` scope.

    This merely makes it possible to use commands like
    `raw("PING :irc.freenode.net")` without having to import
    `kameloso.messaging` and include the thread ID of the main thread in every
    call of the functions.

    Params:
        debug_ = Whether or not to include debugging output.
        module_ = String name of the mixing-in module; generally leave as-is.
 +/
version(WithPlugins)
mixin template MessagingProxy(Flag!"debug_" debug_ = No.debug_, string module_ = __MODULE__)
{
private:
    static import kameloso.messaging;
    static import kameloso.common;
    import kameloso.plugins.common.core : IRCPlugin;
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

    pragma(inline, true);

    // chan
    /++
        Sends a channel message.
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
        Sends a private query message to a user.
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
        Sends either a channel message or a private query message depending on
        the arguments passed to it.

        This reflects how channel messages and private messages are both the
        underlying same type; `dialect.defs.IRCEvent.Type.PRIVMSG`.
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
        Sends an `ACTION` "emote" to the supplied target (nickname or channel).
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
        Sets a channel mode.

        This includes modes that pertain to a user in the context of a channel, like bans.
     +/
    void mode(Flag!"priority" priority = No.priority)(const string channel,
        const string modes, const string content = string.init)
    {
        return kameloso.messaging.mode!priority(state, channel, modes, content);
    }


    // topic
    /++
        Sets the topic of a channel.
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
        Invites a user to a channel.
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
        Joins a channel.
     +/
    void join(Flag!"priority" priority = No.priority)
        (const string channel, const string key = string.init)
    {
        return kameloso.messaging.join!priority(state, channel, key);
    }


    // kick
    /++
        Kicks a user from a channel.
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
        Leaves a channel.
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
        Disconnects from the server, optionally with a quit reason.
     +/
    void quit(Flag!"priority" priority = No.priority)(const string reason = string.init)
    {
        return kameloso.messaging.quit!priority(state, reason);
    }


    // whois
    /++
        Queries the server for WHOIS information about a user.
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
        Sends text to the server, verbatim.

        This is used to send messages of types for which there exist no helper
        functions.
     +/
    void raw(Flag!"priority" priority = No.priority)(const string line,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.raw!priority(state, line,
            No.quiet, No.background, caller);
    }


    // immediate
    /++
        Sends raw text to the server, verbatim, bypassing all queues and
        throttling delays.
     +/
    void immediate(const string line)
    {
        return kameloso.messaging.immediate(state, line);
    }

    import std.format : format;
    import std.meta : AliasSeq;

    /+
        Generates the functions `askToWriteln`, `askToTrace`, `askToLog`,
        `askToInfo`, `askToWarning`, and `askToError`,
     +/
    static foreach (immutable verb; AliasSeq!("Writeln", "Trace", "Log",
        "Info", "Warn", "Warning", "Error"))
    {
        /++
            Generated `askToVerb` function. Asks the main thread to output text
            to the local terminal.

            No need for any annotation; `kameloso.messaging.askToOutputImpl` is
            `@system` and nothing else.
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
    import kameloso.plugins.common.core;

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
    Implements queueing of events to repeat.

    This allows us to deal with triggers both in `dialect.defs.IRCEvent.Type.RPL_WHOISACCOUNT`
    and `dialect.defs.IRCEvent.Type.ERR_UNKNOWNCOMMAND` while keeping the code
    in one place.

    Params:
        debug_ = Whether or not to print debug output to the terminal.
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


    // explainRepeat
    /++
        Verbosely explains a repeat, including what
        `kameloso.plugins.common.core.PrivilegeLevel` and
        `dialect.defs.IRCUser.Class` were involved.

        Gated behind version `ExplainRepeat`.
     +/
    version(ExplainRepeat)
    void explainRepeat(const Repeat repeat)
    {
        import kameloso.common : Tint, logger;
        import lu.conv : Enum;

        logger.logf("%s%s%s %s repeating %1$s%5$s%3$s-level event (invoking %1$s%6$s%3$s) " ~
            "based on WHOIS results: user is %1$s%7$s%3$s class",
            Tint.info, context.name, Tint.log, contextName,
            Enum!PrivilegeLevel.toString(repeat.replay.privilegeLevel), repeat.replay.caller,
            Enum!(IRCUser.Class).toString(repeat.replay.event.sender.class_));
    }


    // repeaterDelegate
    /++
        Delegate to call from inside a `kameloso.thread.CarryingFiber`.
     +/
    void repeaterDelegate()
    {
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!Repeat)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != thisFiber.payload.init),
            "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

        Repeat repeat = thisFiber.payload;

        with (PrivilegeLevel)
        final switch (repeat.replay.privilegeLevel)
        {
        case admin:
            if (repeat.replay.event.sender.class_ >= IRCUser.Class.admin)
            {
                goto case ignore;
            }
            break;

        case staff:
            if (repeat.replay.event.sender.class_ >= IRCUser.Class.staff)
            {
                goto case ignore;
            }
            break;

        case operator:
            if (repeat.replay.event.sender.class_ >= IRCUser.Class.operator)
            {
                goto case ignore;
            }
            break;

        case whitelist:
            if (repeat.replay.event.sender.class_ >= IRCUser.Class.whitelist)
            {
                goto case ignore;
            }
            break;

        case registered:
            if (repeat.replay.event.sender.account.length)
            {
                goto case ignore;
            }
            break;

        case anyone:
            if (repeat.replay.event.sender.class_ >= IRCUser.Class.anyone)
            {
                goto case ignore;
            }

            // repeat.replay.event.sender.class_ is Class.blacklist here (or unset)
            // Do nothing an drop down
            break;

        case ignore:
            version(ExplainRepeat) explainRepeat(repeat);
            repeat.replay.trigger();
            break;
        }
    }

    /++
        Queues the delegate `repeaterDelegate` with the passed
        `kameloso.plugins.common.core.Replay` attached to it.
     +/
    void repeat(Replay replay)
    {
        import kameloso.plugins.common.base : repeat;
        context.repeat(&repeaterDelegate, replay);
    }
}

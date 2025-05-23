/++
    Mixins for common functionality, such as the issuing of WHOIS calls.

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common.mixins.awareness]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.mixins;

debug version = Debug;

private:

import dialect.defs;
import std.typecons : Flag, No, Yes;

public:


// WHOISFiberDelegate
/++
    Functionality for catching WHOIS results and calling passed function aliases
    with the resulting account information that was divined from it, in the form
    of the actual [dialect.defs.IRCEvent|IRCEvent], the target
    [dialect.defs.IRCUser|IRCUser] within it, the user's `account` field, or merely
    alone as an arity-0 function.

    The mixed in function to call is named `enqueueAndWHOIS`. It will construct
    the fiber, enqueue it as awaiting the proper IRCEvent types, and issue the
    WHOIS query.

    Example:
    ---
    void onSuccess(const IRCEvent successEvent) { /* ... */ }
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
mixin template WHOISFiberDelegate(
    alias onSuccess,
    alias onFailure = null,
    Flag!"alwaysLookup" alwaysLookup = No.alwaysLookup)
{
    import kameloso.plugins : IRCPlugin;
    import std.traits : ParameterIdentifierTuple, isSomeFunction;

    enum parentFunction = __FUNCTION__;

    static if (!isSomeFunction!onSuccess)
    {
        import std.format : format;

        enum pattern = "First parameter of `%s` is not a success function";
        enum message = pattern.format(parentFunction);
        static assert(0, message);
    }
    else static if (!isSomeFunction!onFailure && !is(typeof(onFailure) == typeof(null)))
    {
        import std.format : format;

        enum pattern = "Second parameter of `%s` is not a failure function";
        enum message = pattern.format(parentFunction);
        static assert(0, message);
    }

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.function_, "WHOISFiberDelegate");
    }

    alias paramNames = ParameterIdentifierTuple!(mixin(parentFunction));

    static if ((paramNames.length == 0) || !is(typeof(mixin(paramNames[0])) : IRCPlugin))
    {
        import std.format : format;

        enum pattern = "`WHOISFiberDelegate` should be mixed into the context of an event handler. " ~
            "(First parameter of `%s` is not an `IRCPlugin` subclass)";
        enum message = pattern.format(parentFunction);
        static assert(0, message);
    }
    else
    {
        alias _context = mixin(paramNames[0]);
    }

    /++
        Constant denoting that [WHOISFiberDelegate] has been mixed in.
     +/
    enum hasWHOISFiber = true;

    static if (!alwaysLookup && !__traits(compiles, { alias _ = .hasUserAwareness; }))
    {
        pragma(msg, "Warning: `" ~ parentFunction ~ "` mixes in `WHOISFiberDelegate` " ~
            "but its parent module does not mix in `UserAwareness`");
    }

    // _carriedNickname
    /++
        Nickname being looked up, stored outside of any separate function to make
        it available to all of them.
     +/
    string _carriedNickname;

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
        import kameloso.plugins.common.scheduling : unawait;
        import kameloso.thread : CarryingFiber;
        import dialect.common : opEqualsCaseInsensitive;
        import dialect.defs : IRCEvent, IRCUser;
        import lu.conv : toString;
        import lu.traits : TakesParams;
        import std.algorithm.searching : canFind;
        import std.traits : arity;
        import core.thread.fiber : Fiber;

        auto thisFiber = cast(CarryingFiber!IRCEvent) Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);

        while (true)
        {
            assert((thisFiber.payload.type != IRCEvent.Type.UNSET),
                "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

            immutable whoisEvent = thisFiber.payload;

            assert(whoisEventTypes[].canFind(whoisEvent.type),
                "WHOIS fiber delegate was invoked with an unexpected event type: " ~
                "`IRCEvent.Type." ~ whoisEvent.type.toString ~'`');

            /++
                Invoke `onSuccess`.
             +/
            void callOnSuccess()
            {
                static if (TakesParams!(onSuccess, IRCEvent))
                {
                    return onSuccess(whoisEvent);
                }
                else static if (TakesParams!(onSuccess, IRCUser))
                {
                    return onSuccess(whoisEvent.target);
                }
                else static if (TakesParams!(onSuccess, string))
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
                    enum message = pattern.format(
                        parentFunction,
                        typeof(onSuccess).stringof,
                        __traits(identifier, onSuccess));
                    static assert(0, message);
                }
            }

            /++
                Invoke `onFailure`, if it's available.
             +/
            void callOnFailure()
            {
                static if (!is(typeof(onFailure) == typeof(null)))
                {
                    static if (TakesParams!(onFailure, IRCEvent))
                    {
                        return onFailure(whoisEvent);
                    }
                    else static if (TakesParams!(onFailure, IRCUser))
                    {
                        return onFailure(whoisEvent.target);
                    }
                    else static if (TakesParams!(onFailure, string))
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
                        enum message = pattern.format(
                            parentFunction,
                            typeof(onFailure).stringof,
                            __traits(identifier, onFailure));
                        static assert(0, message);
                    }
                }
            }

            if (whoisEvent.type == IRCEvent.Type.ERR_UNKNOWNCOMMAND)
            {
                if (!whoisEvent.aux[0].length || (whoisEvent.aux[0] == "WHOIS"))
                {
                    // WHOIS query failed due to unknown command.
                    // Some flavours of ERR_UNKNOWNCOMMAND don't say what the
                    // command was, so we'll have to assume it's the right one.
                    // Return and end fiber.
                    return callOnFailure();
                }
                else
                {
                    // Wrong unknown command; await a new one
                    Fiber.yield();
                    continue;
                }
            }

            immutable m = _context.state.server.caseMapping;

            if (!whoisEvent.target.nickname.opEqualsCaseInsensitive(_carriedNickname, m))
            {
                // Wrong WHOIS; await a new one
                Fiber.yield();
                continue;
            }

            // Clean up awaiting fiber entries on exit, just to be neat.
            scope(exit) unawait(_context, thisFiber, whoisEventTypes[]);

            with (IRCEvent.Type)
            switch (whoisEvent.type)
            {
            case RPL_WHOISACCOUNT:
            case RPL_WHOISREGNICK:
                return callOnSuccess();

            case RPL_WHOISUSER:
                if (_context.state.coreSettings.preferHostmasks)
                {
                    return callOnSuccess();
                }
                else
                {
                    // We're not interested in RPL_WHOISUSER if we're not in hostmasks mode
                    Fiber.yield();
                    continue;
                }

            case RPL_ENDOFWHOIS:
            case ERR_NOSUCHNICK:
            //case ERR_UNKNOWNCOMMAND:  // Already handled above
                return callOnFailure();

            default:
                assert(0, "Unexpected WHOIS event type encountered in `whoisFiberDelegate`");
            }

            // Would end loop here but statement not reachable
            //return;
            assert(0, "Escaped terminal switch in `whoisFiberDelegate`");
        }
    }

    // enqueueAndWHOIS
    /++
        Constructs a [kameloso.thread.CarryingFiber|CarryingFiber] carrying a
        [dialect.defs.IRCEvent|IRCEvent] and enqueues it into the
        [kameloso.plugins.IRCPluginState.awaitingFibers|IRCPluginState.awaitingFibers]
        associative array, then issues a WHOIS query (unless overridden via
        the `issueWhois` parameter).

        Params:
            nickname = Nickname of the user the enqueueing event relates to.
            issueWhois = Whether to actually issue `WHOIS` queries at all or just enqueue.
            background = Whether or not to issue queries as low-priority background messages.

        Throws:
            [object.Exception|Exception] if a success of failure function was to trigger
            in an impossible scenario, such as on WHOIS results on Twitch.
     +/
    void enqueueAndWHOIS(
        const string nickname,
        const bool issueWhois = true,
        const bool background = false)
    {
        import kameloso.plugins.common.scheduling : await;
        import kameloso.constants : BufferSize;
        import kameloso.messaging : whois;
        import kameloso.thread : CarryingFiber;
        import lu.string : advancePast;
        import lu.traits : TakesParams;
        import std.string : indexOf;
        import std.traits : arity;
        import core.thread.fiber : Fiber;

        version(TwitchSupport)
        {
            if (_context.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Define Twitch queries as always succeeding, since WHOIS isn't applicable

                version(Debug)
                {
                    import kameloso.common : logger;

                    // Warn about it though, since it's a programming error
                    enum pattern = "<l>%s</> tried to enqueue and WHOIS <l>%s</> on Twitch";
                    logger.warningf(pattern, parentFunction, nickname);

                    version(PrintStacktraces)
                    {
                        import kameloso.misc: printStacktrace;
                        printStacktrace();
                    }
                }

                static if (__traits(compiles, { alias _ = .hasUserAwareness; }))
                {
                    if (const user = nickname in _context.state.users)
                    {
                        static if (TakesParams!(onSuccess, IRCEvent))
                        {
                            // Can't WHOIS on Twitch
                            enum message = "Tried to enqueue a `" ~
                                typeof(onSuccess).stringof ~ " onSuccess` function " ~
                                "when on Twitch (can't WHOIS)";
                            throw new Exception(message);
                        }
                        else static if (TakesParams!(onSuccess, IRCUser))
                        {
                            return onSuccess(*user);
                        }
                        else static if (TakesParams!(onSuccess, string))
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

                static if (
                    TakesParams!(onSuccess, IRCEvent) ||
                    TakesParams!(onSuccess, IRCUser))
                {
                    // Can't WHOIS on Twitch
                    enum message = "Tried to enqueue a `" ~
                        typeof(onSuccess).stringof ~ " onSuccess` function " ~
                        "when on Twitch without `UserAwareness` (can't WHOIS)";
                    throw new Exception(message);
                }
                else static if (TakesParams!(onSuccess, string))
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

        static if (!alwaysLookup && __traits(compiles, { alias _ = .hasUserAwareness; }))
        {
            if (const user = nickname in _context.state.users)
            {
                if (user.account.length)
                {
                    static if (TakesParams!(onSuccess, IRCEvent))
                    {
                        // No can do, drop down and WHOIS
                    }
                    else static if (TakesParams!(onSuccess, IRCUser))
                    {
                        return onSuccess(*user);
                    }
                    else static if (TakesParams!(onSuccess, string))
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
                else
                {
                    static if (!is(typeof(onFailure) == typeof(null)))
                    {
                        import kameloso.constants : Timeout;
                        import std.datetime.systime : Clock;

                        if ((Clock.currTime.toUnixTime() - user.updated) <=
                            Timeout.Integers.whoisRetrySeconds)
                        {
                            static if (TakesParams!(onFailure, IRCEvent))
                            {
                                // No can do, drop down and WHOIS
                            }
                            else static if (TakesParams!(onFailure, IRCUser))
                            {
                                return onFailure(*user);
                            }
                            else static if (TakesParams!(onFailure, string))
                            {
                                return onFailure(user.account);
                            }
                            else static if (arity!onSuccess == 0)
                            {
                                return onFailure();
                            }
                            else
                            {
                                // Will already have asserted previously?
                            }
                        }
                    }
                }
            }
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&whoisFiberDelegate, BufferSize.fiberStack);
        await(_context, fiber, whoisEventTypes[]);

        string slice = nickname;  // mutable
        immutable nicknamePart = slice.advancePast('!', inherit: true);

        version(WithPrinterPlugin)
        {
            import kameloso.thread : ThreadMessage, boxed;
            plugin.state.messages ~= ThreadMessage.busMessage("printer", boxed("squelch " ~ nicknamePart));
        }

        if (issueWhois)
        {
            import kameloso.messaging : Message;

            if (background)
            {
                // Need Property.forced to not miss events
                enum properties =
                    Message.Property.forced |
                    Message.Property.quiet |
                    Message.Property.background;
                whois(_context.state, nicknamePart, properties);
            }
            else
            {
                // Ditto
                enum properties =
                    Message.Property.forced |
                    Message.Property.quiet |
                    Message.Property.priority;
                whois(_context.state, nicknamePart, properties);
            }
        }

        _carriedNickname = nicknamePart;
    }
}


// MessagingProxy
/++
    Mixin to give shorthands to the functions in [kameloso.messaging], for
    easier use when in a `with (plugin) { /* ... */ }` scope.

    This merely makes it possible to use commands like
    `raw("PING :irc.freenode.net")` without having to import
    [kameloso.messaging] and pass the plugin's
    [kameloso.plugins.IRCPluginState|IRCPluginState] in every
    call of the functions.

    Params:
        debug_ = Whether or not to include debugging output.
 +/
mixin template MessagingProxy(Flag!"debug_" debug_ = No.debug_)
{
private:
    import kameloso.plugins : IRCPlugin;
    import kameloso.messaging : Message;
    import std.meta : AliasSeq;
    static import kameloso.messaging;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.class_, "MessagingProxy");

        static if (!is(typeof(this) : IRCPlugin))
        {
            import std.format : format;

            enum wrongThisPattern = "`%s` mixes in `MessagingProxy` but is " ~
                "itself not an `IRCPlugin` subclass";
            enum wrongThisMessage = wrongThisPattern.format(typeof(this).stringof);
            static assert(0, wrongThisMessage);
        }
    }

    /++
        Constant denoting that [MessagingProxy] has been mixed in.
     +/
    enum hasMessagingProxy = true;

    // chan
    /++
        Sends a channel message.
     +/
    pragma(inline, true)
    void chan(
        const string channelName,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.chan(
            state,
            channelName,
            content,
            properties,
            caller);
    }

    // announce
    /++
        Sends a Twitch announcement.
     +/
    pragma(inline, true)
    void announce(
        const IRCEvent.Channel channel,
        const string content,
        const string colour = "primary",
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.announce(
            state,
            channel,
            content,
            colour,
            properties,
            caller);
    }

    // reply
    /++
        Replies to a channel message.
     +/
    pragma(inline, true)
    void reply(
        const IRCEvent event,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.reply(
            state,
            event,
            content,
            properties,
            caller);
    }

    // query
    /++
        Sends a private query message to a user.
     +/
    pragma(inline, true)
    void query(
        const string nickname,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.query(
            state,
            nickname,
            content,
            properties,
            caller);
    }

    // privmsg
    /++
        Sends either a channel message or a private query message depending on
        the arguments passed to it.

        This reflects how channel messages and private messages are both the
        underlying same type; [dialect.defs.IRCEvent.Type.PRIVMSG].
     +/
    pragma(inline, true)
    void privmsg(
        const string channel,
        const string nickname,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.privmsg(
            state,
            channel,
            nickname,
            content,
            properties,
            caller);
    }

    // emote
    /++
        Sends an `ACTION` "emote" to the supplied target (nickname or channel).
     +/
    pragma(inline, true)
    void emote(
        const string emoteTarget,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.emote(
            state,
            emoteTarget,
            content,
            properties,
            caller);
    }

    // mode
    /++
        Sets a channel mode.

        This includes modes that pertain to a user in the context of a channel, like bans.
     +/
    pragma(inline, true)
    void mode(
        const string channel,
        const const(char)[] modes,
        const string content = string.init,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.mode(
            state,
            channel,
            modes,
            content,
            properties,
            caller);
    }

    // topic
    /++
        Sets the topic of a channel.
     +/
    pragma(inline, true)
    void topic(
        const string channel,
        const string content,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.topic(
            state,
            channel,
            content,
            properties,
            caller);
    }

    // invite
    /++
        Invites a user to a channel.
     +/
    pragma(inline, true)
    void invite(
        const string channel,
        const string nickname,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.invite(
            state,
            channel,
            nickname,
            properties,
            caller);
    }

    // join
    /++
        Joins a channel.
     +/
    pragma(inline, true)
    void join(
        const string channel,
        const string key = string.init,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.join(
            state,
            channel,
            key,
            properties,
            caller);
    }

    // kick
    /++
        Kicks a user from a channel.
     +/
    pragma(inline, true)
    void kick(
        const string channel,
        const string nickname,
        const string reason = string.init,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.kick(
            state,
            channel,
            nickname,
            reason,
            properties,
            caller);
    }

    // part
    /++
        Leaves a channel.
     +/
    pragma(inline, true)
    void part(
        const string channel,
        const string reason = string.init,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.part(
            state,
            channel,
            reason,
            properties,
            caller);
    }

    // quit
    /++
        Disconnects from the server, optionally with a quit reason.
     +/
    pragma(inline, true)
    void quit(
        const string reason = string.init,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.quit(
            state,
            reason,
            properties,
            caller);
    }

    // whois
    /++
        Queries the server for WHOIS information about a user.
     +/
    pragma(inline, true)
    void whois(
        const string nickname,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.whois(
            state,
            nickname,
            properties,
            caller);
    }

    // raw
    /++
        Sends text to the server, verbatim.

        This is used to send messages of types for which there exist no helper
        functions.
     +/
    pragma(inline, true)
    void raw(
        const string line,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.raw(
            state,
            line,
            properties,
            caller);
    }

    // immediate
    /++
        Sends raw text to the server, verbatim, bypassing all queues and
        throttling delays.
     +/
    pragma(inline, true)
    void immediate(
        const string line,
        const Message.Property properties = Message.Property.none,
        const string caller = __FUNCTION__)
    {
        return kameloso.messaging.immediate(
            state,
            line,
            properties,
            caller);
    }

    // immediateline
    /++
        Merely an alias to [immediate], because we use both terms at different places.
     +/
    alias immediateline = immediate;

    /+
        Generates the functions `askToWriteln`, `askToTrace`, `askToLog`,
        `askToInfo`, `askToWarning`, and `askToError`,
     +/
    static foreach (immutable verb; AliasSeq!
        ("Writeln",
        "Trace",
        "Log",
        "Info",
        "Warn",
        "Warning",
        "Error"))
    {
        /++
            Generated `askToVerb` function. Asks the main event loop to output text
            to the local terminal.

            No need for any annotation;
            [kameloso.messaging.askToOutputImpl|askToOutputImpl] is
            `@system` and nothing else.
         +/
        mixin("
pragma(inline, true)
void askTo" ~ verb ~ "(const string line)
{
    return kameloso.messaging.askTo" ~ verb ~ "(state, line);
}");
    }
}

///
unittest
{
    import kameloso.plugins : IRCPlugin, IRCPluginImpl, IRCPluginState;

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

        /*chan(string.init, string.init);
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
        enum whoisProperties = (Message.Property.forced | Message.Property.quiet);
        whois(string.init, whoisProperties);
        raw(string.init);
        immediate(string.init);
        immediateline(string.init);*/
        askToWriteln(string.init);
        askToTrace(string.init);
        askToLog(string.init);
        askToInfo(string.init);
        askToWarn(string.init);
        askToWarning(string.init);
        askToError(string.init);
    }

    class MyPlugin2 : IRCPlugin
    {
        mixin MessagingProxy fromMixin;
        mixin IRCPluginImpl;
    }

    static import kameloso.messaging;

    MyPlugin2 plugin2 = new MyPlugin2(state);

    foreach (immutable funstring; __traits(derivedMembers, kameloso.messaging))
    {
        import std.algorithm.comparison : among;
        import std.algorithm.searching : startsWith;

        static if (funstring.among!
                ("object",
                "dialect",
                "kameloso",
                "Message") ||
            funstring.startsWith("ask"))
        {
            //pragma(msg, "ignoring " ~ funstring);
        }
        else static if (!__traits(compiles, { mixin("alias _ = plugin2.fromMixin." ~ funstring ~ ";"); }))
        {
            import std.format : format;

            enum pattern = "`MessagingProxy` is missing a wrapper for `kameloso.messaging.%s`";
            enum message = pattern.format(funstring);
            static assert(0, message);
        }
    }
}

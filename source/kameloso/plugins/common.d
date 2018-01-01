module kameloso.plugins.common;

import kameloso.ircdefs;

import std.concurrency : Tid, send;
import std.typecons : Flag, No, Yes;


// IRCPlugin
/++
 +  Interface that all `IRCPlugin`s must adhere to.
 +
 +  There will obviously be more functions but only these are absolutely needed.
 +  It is neccessary so that all plugins may be kept in one array, and foreached
 +  through when new events have been generated.
 +
 +  TODO: Revisit this list and remove those that aren't being used.
 +/
interface IRCPlugin
{
    import kameloso.common : Labeled;
    import core.thread : Fiber;
    import std.array : Appender;

    /// Executed to return a reference to the current `IRCBot`
    ref IRCBot bot() @property;

    /// Executed to get a list of nicknames a plugin wants `WHOIS`ed
    ref WHOISRequest[string] yieldWHOISRequests();

    /// Executed to let plugins modify an event mid-parse
    void postprocess(ref IRCEvent);

    /// Executed upon new IRC event parsed from the server
    void onEvent(const IRCEvent);

    /// Executed when the plugin is requested to write its settings to disk
    void writeConfig(const string);

    /// Executed during setup to let plugins read settings from disk
    void loadConfig(const string);

    /// Executed when gathering things to put in the configuration file
    void addToConfig(ref Appender!string);

    /// Executed when connection has been established
    void start();

    /// Executed when we want a plugin to print its settings and such
    void present() const;

    /// Executed when a plugin wants to examine all the other plugins
    void peekPlugins(const IRCPlugin[]);

    /// Executed when we want a plugin to print its Settings struct
    void printSettings() const;

    /// Executed during shutdown or plugin restart
    void teardown();

    /// Returns the name of the plugin, sliced off the module name
    string name() @property const;

    /// Returns an array of the descriptions of the bot commands a plugin offers
    string[string] commands() @property const;

    /// Returns a reference to the current `IRCPluginState`
    ref IRCPluginState state() @property;

    /// Returns a reference to the list of awaiting `Fiber`s, keyed by `Type`
    ref Fiber[][IRCEvent.Type] awaitingFibers() @property;

    /// Returns a reference to the list of timed `Fiber`s, labeled by UNIX time
    ref Labeled!(Fiber, long)[] timedFibers() @property;
}


// WHOISRequest
/++
 +  A queued event to be replayed upon a `WHOIS` request response.
 +
 +  It is abstract; all objects must be of a concrete `WHOISRequestImpl` type.
 +/
abstract class WHOISRequest
{
    /// Stored `IRCEvent` to replay
    IRCEvent event;

    /// When the user this concerns was last `WHOIS`ed
    size_t lastWhois;

    /// Replay the event
    void trigger();
}


/++
 +  Implementation of a queued `WHOIS` request call.
 +
 +  It functions like a Command pattern object in that it stores a payload and
 +  a function pointer, which we queue and do a `WHOIS` call. When the response
 +  returns we trigger the object and the original IRCEvent is replayed.
 +/
final class WHOISRequestImpl(F, Payload = typeof(null)) : WHOISRequest
{
    /// Stored function pointer/delegate
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the `IRCEvent`
        Payload payload;

        this(Payload payload, IRCEvent event, F fn)
        {
            this.payload = payload;
            this.event = event;
            this.fn = fn;
        }
    }
    else
    {
        this(IRCEvent event, F fn)
        {
            this.event = event;
            this.fn = fn;
        }
    }

    /++
     +  Call the passed function/delegate pointer, optionally with the stored
     +  `IRCEvent` and/or `Payload`.
     +/
    override void trigger()
    {
        import std.meta : AliasSeq, staticMap;
        import std.traits : Parameters, Unqual, arity;

        assert((fn !is null), "null fn in WHOISRequestImpl!" ~ F.stringof);

        alias Params = staticMap!(Unqual, Parameters!fn);

        static if (is(Params : AliasSeq!IRCEvent))
        {
            fn(event);
        }
        else static if (is(Params : AliasSeq!(Payload, IRCEvent)))
        {
            fn(payload, event);
        }
        else static if (is(Params : AliasSeq!Payload))
        {
            fn(payload);
        }
        else static if (arity!fn == 0)
        {
            fn();
        }
        else
        {
            static assert(0, "Unknown function signature in WHOISRequestImpl: "~
                typeof(fn).stringof);
        }
    }

    /// Identify the queue entry, in case we ever need that
    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : format;

        sink("[%s] @ %s".format(event.type, event.sender.nickname));
    }
}


unittest
{
    WHOISRequest[] queue;

    IRCEvent event;
    event.target.nickname = "kameloso";
    event.content = "hirrpp";
    event.sender.nickname = "zorael";

    // delegate()

    int i = 5;

    void dg()
    {
        ++i;
    }

    WHOISRequest reqdg = new WHOISRequestImpl!(void delegate())(event, &dg);
    queue ~= reqdg;

    with (reqdg.event)
    {
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "hirrpp"), content);
        assert((sender.nickname == "zorael"), sender.nickname);
    }

    assert(i == 5);
    reqdg.trigger();
    assert(i == 6);

    // function()

    static void fn() { }

    auto reqfn = whoisRequest(event, &fn);
    queue ~= reqfn;

    // delegate(ref IRCEvent)

    void dg2(ref IRCEvent thisEvent)
    {
        thisEvent.content = "blah";
    }

    auto reqdg2 = whoisRequest(event, &dg2);
    queue ~= reqdg2;

    assert((reqdg2.event.content == "hirrpp"), event.content);
    reqdg2.trigger();
    assert((reqdg2.event.content == "blah"), event.content);

    // function(IRCEvent)

    static void fn2(IRCEvent thisEvent) { }

    auto reqfn2 = whoisRequest(event, &fn2);
    queue ~= reqfn2;
}


// whoisRequest
/++
 +  Convenience function that returns a `WHOISRequestImpl` of the right type,
 +  *with* a payload attached.
 +/
WHOISRequest whoisRequest(F, Payload)(Payload payload, IRCEvent event, F fn)
{
    return new WHOISRequestImpl!(F, Payload)(payload, event, fn);
}


// whoisRequest
/++
 +  Convenience function that returns a `WHOISRequestImpl` of the right type,
 +  *without* a payload attached.
 +/
WHOISRequest whoisRequest(F)(IRCEvent event, F fn)
{
    return new WHOISRequestImpl!F(event, fn);
}


// IRCPluginState
/++
 +  An aggregate of all variables that make up the common state of plugins.
 +
 +  This neatly tidies up the amount of top-level variables in each plugin
 +  module. This allows for making more or less all functions top-level
 +  functions, since any state could be passed to it with variables of this
 +  type.
 +
 +  Plugin-specific state will be kept inside the `IRCPlugin` itself.
 +/
struct IRCPluginState
{
    import kameloso.common : CoreSettings;
    import std.concurrency : Tid;

    /++
     +  The current `IRCBot`, containing information pertaining to bot in the
     +  bot in the context of the current (alive) connection.
     +/
    IRCBot bot;

    /// The current settings of the bot, non-specific to any plugins.
    CoreSettings settings;

    /// Thread ID to the main thread
    Tid mainThread;

    /// Hashmap of IRC user details
    IRCUser[string] users;

    /// Hashmap of IRC channels
    IRCChannel[string] channels;

    /// Queued `WHOIS` requests and pertaining `IRCEvents` to replay
    WHOISRequest[string] whoisQueue;
}


/// The results trie from comparing a username with the known list of friends
enum FilterResult { fail, pass, whois }


/++
 +  Whether an annotated event ignores, allows or requires the event to be
 +  prefixed with the bot's nickname.
 +/
enum NickPolicy
{
    ignored,      /// Any prefixes will be ignored.
    direct,       /// Message should begin with `CoreSettings.prefix`.
    optional,     /// Message may begin with bot name, if so will be stripped.
    required,     /// Message must begin with bot name, except in `QUERY` events.
    hardRequired, /// Message must begin with bot name, regardless of type.
}
deprecated alias NickPrefixPolicy = NickPolicy;


/// If an annotated function should work in all channels or just in homes
enum ChannelPolicy
{
    /++
     +  The function will only trigger if the event happened in a home, where
     +  applicable (not all events have channels).
     +/
    homeOnly,

    /// The function will trigger regardless of channel.
    any,
}


/// What level of privilege is needed to trigger an event
enum PrivilegeLevel
{
    anyone, /// Anyone may trigger this event.
    friend, /// Only those in the `friends` array may trigger this event.
    master, /// Only you (the `master`) may trigger this event.
}


// BotCommand
/++
 +  Defines an IRC bot command, for people to trigger with messages.
 +
 +  If no `NickPolicy` is specified then it will default to `NickPolicy.direct`
 +  and look for `CoreSettings.prefix` at the beginning of messages, to prefix
 +  the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotCommand
{
    /// The policy to which extent the command needs the bot's nickname
    NickPolicy policy;

    /// The prefix string, one word with no spaces
    string string_;

    this(const NickPolicy policy, const string string_)
    {
        this.policy = policy;
        this.string_ = string_;
    }

    this(const string string_)
    {
        this.policy = NickPolicy.direct;
        this.string_ = string_;
    }
}

deprecated("Prefix has been replaced with Command. This alias will be removed in time.")
alias Prefix = BotCommand;


// BotRegex
/++
 +  Defines an IRC bot regular expression, for people to trigger with messages.
 +
 +  If no `NickPolicy` is specified then it will default to `NickPolicy.direct`
 +  and look for `CoreSettings.prefix` at the beginning of messages, to prefix
 +  the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotRegex
{
    import std.regex : Regex, StaticRegex, regex;

    /// The policy to which extent the command needs the bot's nickname
    NickPolicy policy;

    /++
     +  Regex engine to match incoming messages with (from compile-time-known
     +  expression)
     +/
    StaticRegex!char ctExpr;

    /++
     +  Regex engine to match incoming messages with (from runtime-known
     +  expression)
     +/
    Regex!char rtExpr;

    this(const NickPolicy policy, StaticRegex!char ctExpr)
    {
        this.policy = policy;
        this.ctExpr = ctExpr;
    }

    this(const NickPolicy policy, Regex!char rtExpr)
    {
        this.policy = policy;
        this.rtExpr = rtExpr;
    }

    this(const NickPolicy policy, const string rtExprString)
    {
        this.policy = policy;
        this.rtExpr = rtExprString.regex;
    }

    this(StaticRegex!char ctExpr)
    {
        this.policy = NickPolicy.direct;
        this.ctExpr = ctExpr;
    }

    this(Regex!char rtExpr)
    {
        this.policy = NickPolicy.direct;
        this.rtExpr = rtExpr;
    }

    this(const string rtExprString)
    {
        this.policy = NickPolicy.direct;
        this.rtExpr = rtExprString.regex;
    }
}

/++
 +  Flag denoting that an event-handling function let other functions in the
 +  same module process after it.
 +/
struct Chainable;

/++
 +  Flag denoting that we want verbose debug output of the plumbing when
 +  handling events, iterating through the module
 +/
struct Verbose;

/++
 +  Flag denoting that a variable is to be considered settings and should be
 +  saved in the configuration file.
 +/
struct Settings;

/// Alias to allow the old annotation to still work
deprecated("Use @Settings instead of @Configurable. " ~
           "This alias will eventually be removed.")
alias Configurable = Settings;

/++
 +  Describes an `IRCEvent`-annotated handler function.
 +
 +  This is used to describe functions triggered by `BotCommands`, in the help
 +  listing routine in `chatbot.d`.
 +/
struct Description
{
    string string_;

    this(const string string_)
    {
        this.string_ = string_;
    }

    this(const string string_, bool b)
    {
        this.string_ = string_;
    }
}


// filterUser
/++
 +  Decides whether a nick is known good, known bad, or needs `WHOIS`.
 +
 +  This is used to tell whether a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return whois.
 +  If the user's NickServ account is in the list of friends (or equals the
 +  bot's master's), return pass. Else, return fail and deny use.
 +/
FilterResult filterUser(const IRCPluginState state, const IRCEvent event)
{
    import kameloso.constants : Timeout;
    import core.time : seconds;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : Clock, SysTime;

    auto user = event.sender.nickname in state.users;

    if (!user || !user.account.length &&
        ((SysTime.fromUnixTime(user.lastWhois) - Clock.currTime)
          < Timeout.whois.seconds))
    {
        return FilterResult.whois;
    }
    else if ((user.account == state.bot.master) ||
        state.bot.friends.canFind(user.account))
    {
        return FilterResult.pass;
    }
    else
    {
        return FilterResult.fail;
    }
}


// IRCPluginImpl
/++
 +  Mixin that fully implements an `IRCPlugin`.
 +
 +  Uses compile-time introspection to call top-level functions to extend
 +  behaviour;
 +      .onEvent            (doesn't proxy anymore)
 +      .bot                (by ref; accessor and mutator)
 +      .postprocess        (proxy for modifications to an event during parsing)
 +      .yieldWHOISRequests (returns queue)
 +      .writeConfig
 +      .loadConfig
 +      .present            (unused, subject for removal)
 +      .peekPlugins        (takes a reference to the main `IRCPlugin[]` array)
 +      .printSettings      (prints settings)
 +      .addToConfig
 +      .start
 +      .teardown
 +      .name               (returns plugin type name)
 +      .state              (returns privateState)
 +      .initialise         (via this())
 +/
mixin template IRCPluginImpl(bool debug_ = false, string module_ = __MODULE__)
{
    import kameloso.common : Labeled;
    import core.thread : Fiber;
    import std.concurrency : Tid;

    IRCPluginState privateState;
    Fiber[][IRCEvent.Type] privateAwaitingFibers;
    Labeled!(Fiber, long)[] privateTimedFibers;

    enum hasIRCPluginImpl = true;

    // onEvent
    /++
     +  Pass on the supplied `IRCEvent` to functions annotated with the right
     +  `IRCEvent.Types`.
     +/
    void onEvent(const IRCEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.string : beginsWith, has, nom, stripPrefix;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, isSomeFunction, getUDAs, hasUDA;
        import std.typecons : No, Yes;

        funloop:
        foreach (fun; Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEvent.Type)))
        {
            enum verbose = hasUDA!(fun, Verbose) || debug_;

            static if (verbose)
            {
                import std.stdio : writeln, writefln;
            }

            foreach (eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
            {
                import std.format : format;

                enum name = "%s : %s (%s)".format(module_,
                    __traits(identifier, fun), eventTypeUDA);

                static if (eventTypeUDA == IRCEvent.Type.ANY)
                {
                    // UDA is `ANY`, let pass
                }
                else
                {
                    if (eventTypeUDA != event.type)
                    {
                        // The current event does not match this function's
                        // particular UDA; continue to the next one
                        continue;  // next Type UDA
                    }
                }

                static if (hasUDA!(fun, ChannelPolicy))
                {
                    enum policy = getUDAs!(fun, ChannelPolicy)[0];
                }
                else
                {
                    // Default policy if none given is `homeOnly`
                    enum policy = ChannelPolicy.homeOnly;
                }

                static if (verbose)
                {
                    writefln("%s.%s: %s", module_,
                        __traits(identifier, fun), policy);
                }

                with (ChannelPolicy)
                final switch (policy)
                {
                case homeOnly:
                    import std.algorithm.searching : canFind;

                    if (!event.channel.length)
                    {
                        // it is a non-channel event, like a `QUERY`
                    }
                    else if (!privateState.bot.homes.canFind(event.channel))
                    {
                        static if (verbose)
                        {
                            writeln(name, " ignore invalid channel ",
                                    event.channel);
                        }

                        // channel policy does not match
                        continue funloop;  // next function
                    }
                    break;

                case any:
                    // drop down, no need to check
                    break;
                }

                IRCEvent mutEvent = event;  // mutable

                // Evaluate each BotCommand UDAs with the current event
                static if (hasUDA!(fun, BotCommand))
                {
                    if (!event.content.length)
                    {
                        // Event has a `BotCommand` set up but
                        // `event.content` is empty; cannot possibly be of
                        // interest.
                        continue funloop;  // next function
                    }

                    foreach (commandUDA; getUDAs!(fun, BotCommand))
                    {
                        static assert(commandUDA.string_.length,
                            name ~ " had an empty BotCommand string");

                        // Reset between iterations
                        mutEvent = event;

                        if (!privateState.nickPolicyMatches(commandUDA.policy,
                            mutEvent))
                        {
                            continue;  // next BotCommand UDA
                        }

                        import std.string : toLower;

                        string thisCommand;

                        if (mutEvent.content.has!(Yes.decode)(' '))
                        {
                            thisCommand = mutEvent.content
                                .nom!(Yes.decode)(' ');
                        }
                        else
                        {
                            // single word, not a prefix
                            thisCommand = mutEvent.content;
                            mutEvent.content = string.init;
                        }

                        // case-sensitive check goes here
                        enum lowercaseUDAString = commandUDA.string_.toLower();

                        if (thisCommand.toLower() == lowercaseUDAString)
                        {
                            mutEvent.aux = thisCommand;
                            break;  // finish this BotCommand
                        }
                    }
                }

                // Iff no match from BotCommands, evaluate BotRegexes
                if (!mutEvent.aux.length)
                {
                    static if (hasUDA!(fun, BotRegex))
                    {
                        if (!event.content.length)
                        {
                            // Event has a `BotRegex` set up but
                            // `event.content` is empty; cannot possibly be
                            // of interest.
                            continue funloop;  // next function
                        }

                        foreach (regexUDA; getUDAs!(fun, BotRegex))
                        {
                            static assert((regexUDA.ctExpr != StaticRegex!char.init) ||
                                (regexUDA.rtExpr != Regex!char.init),
                                name ~ " has uninitialised BotRegex engines");

                            // Reset between iterations
                            mutEvent = event;

                            if (!privateState.nickPolicyMatches(regexUDA.policy,
                                mutEvent))
                            {
                                continue;
                            }

                            string thisCommand;

                            if (mutEvent.content.has!(Yes.decode)(' '))
                            {
                                thisCommand = mutEvent.content
                                    .nom!(Yes.decode)(' ');
                            }
                            else
                            {
                                // single word, not a prefix
                                thisCommand = mutEvent.content;
                                mutEvent.content = string.init;
                            }

                            import std.regex : matchFirst;

                            try
                            {
                                if (regexUDA.ctExpr != StaticRegex!char.init)
                                {
                                    if (!thisCommand.matchFirst(regexUDA.ctExpr).empty)
                                    {
                                        mutEvent.aux = thisCommand;
                                    }
                                }
                                else if (regexUDA.rtExpr != Regex!char.init)
                                {
                                    // Implicit rtExpr non-init
                                    if (!thisCommand.matchFirst(regexUDA.rtExpr).empty)
                                    {
                                        mutEvent.aux = thisCommand;
                                    }
                                }
                                else
                                {
                                    logger.warningf("Uninitialised BotRegex " ~
                                        "(%s)", name);
                                    continue;
                                }
                            }
                            catch (const Exception e)
                            {
                                logger.warning("BotRegex exception: ", e.msg);
                                continue;  // next BotRegex
                            }

                            if (mutEvent.aux.length) break;
                        }
                    }
                }

                static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
                {
                    // Bot{Command,Regex} exists but neither matched; skip
                    if (!mutEvent.aux.length) continue funloop; // next fun
                }

                import std.meta   : AliasSeq, staticMap;
                import std.traits : Parameters, Unqual, arity;

                static if (hasUDA!(fun, PrivilegeLevel))
                {
                    static assert (is(typeof(.hasUserAwareness)),
                        module_ ~ " is missing UserAwareness mixin " ~
                        "(needed for PrivilegeLevel checks).");

                    enum privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];

                    static if (verbose)
                    {
                        writefln("%s.%s", module_, __traits(identifier, fun));
                        writeln("PrivilegeLevel.:", privilegeLevel);
                    }

                    with (PrivilegeLevel)
                    final switch (privilegeLevel)
                    {
                    case friend:
                    case master:
                        immutable result = privateState.filterUser(mutEvent);

                        with (privateState)
                        with (FilterResult)
                        final switch (result)
                        {
                        case pass:
                            if ((privilegeLevel == master) &&
                                (users[mutEvent.sender.nickname].account !=
                                    bot.master))
                            {
                                static if (verbose)
                                {
                                    writefln("%s: %s passed privilege " ~
                                        "check but isn't master; continue",
                                        name, mutEvent.sender.nickname);
                                }
                                continue;
                            }
                            break;

                        case whois:
                            static if (verbose)
                            {
                                writefln("%s:%s (%s)", module_,
                                    __traits(identifier, fun), event.type);
                            }

                            import kameloso.plugins.common : doWhois;

                            alias This = typeof(this);
                            alias Params = staticMap!(Unqual, Parameters!fun);
                            enum isIRCPluginParam(T) = is(T == IRCPlugin);

                            static if (verbose)
                            {
                                writefln("%s.%s WHOIS for %s",
                                    typeof(this).stringof,
                                    __traits(identifier, fun), event.type);
                            }

                            static if (is(Params : AliasSeq!IRCEvent) ||
                                (arity!fun == 0))
                            {
                                return this.doWhois(mutEvent,
                                    mutEvent.sender.nickname, &fun);
                            }
                            else static if (is(Params : AliasSeq!(This, IRCEvent)) ||
                                is(Params : AliasSeq!This))
                            {
                                return this.doWhois(this, mutEvent,
                                    mutEvent.sender.nickname, &fun);
                            }
                            else static if (Filter!(isIRCPluginParam, Params).length)
                            {
                                pragma(msg, module_ ~ "." ~
                                    __traits(identifier, fun));
                                pragma(msg, typeof(fun).stringof);
                                pragma(msg, Params);
                                static assert(0, "Function signature takes " ~
                                    "IRCPlugin instead of subclass plugin.");
                            }
                            else
                            {
                                pragma(msg, module_ ~ "." ~
                                    __traits(identifier, fun));
                                pragma(msg, typeof(fun).stringof);
                                pragma(msg, Params);
                                static assert(0, "Unknown function signature.");
                            }

                        case fail:
                            static if (verbose)
                            {
                                import kameloso.common : logger;
                                logger.warningf("%s: %s failed privilege " ~
                                    "check; continue", name,
                                    mutEvent.sender.nickname);
                            }
                            continue;
                        }
                        break;

                    case anyone:
                        break;
                    }
                }

                alias Params = staticMap!(Unqual, Parameters!fun);

                static if (verbose)
                {
                    writefln("%s.%s on %s", typeof(this).stringof,
                        __traits(identifier, fun), event.type);
                }

                static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                    is(Params : AliasSeq!(IRCPlugin, IRCEvent)))
                {
                    fun(this, mutEvent);
                }
                else static if (is(Params : AliasSeq!(typeof(this))) ||
                    is(Params : AliasSeq!IRCPlugin))
                {
                    fun(this);
                }
                else static if (is(Params : AliasSeq!IRCEvent))
                {
                    fun(mutEvent);
                }
                else static if (arity!fun == 0)
                {
                    fun();
                }
                else
                {
                    pragma(msg, module_ ~ "." ~ __traits(identifier, fun));
                    pragma(msg, typeof(fun).stringof);
                    pragma(msg, Params);
                    static assert(0, "Unknown function signature: " ~
                        typeof(fun).stringof);
                }

                static if (hasUDA!(fun, Chainable))
                {
                    // onEvent found an event and triggered a function, but
                    // it's Chainable and there may be more, so keep looking
                    continue funloop;
                }
                else
                {
                    // The triggered function is not Chainable so return and
                    // let the main loop continue with the next plugin.
                    return;
                }
            }
        }
    }


    // this(IRCPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level `.initialise(IRCPlugin)` if it
     +  exists.
     +
     +  Params:
     +      state = the aggregate of all plugin state variables, making
     +              this the "original state" of the plugin.
     +/
    this(IRCPluginState state)
    {
        this.privateState = state;

        static if (__traits(compiles, .initialise(this)))
        {
            .initialise(this);
        }
    }


    // bot
    /++
     +  Yields a reference of the current `IRCBot` to the caller.
     +
     +  This is used to let the main loop examine and update the otherwise
     +  inaccessible `privateState.bot`.
     +/
    ref IRCBot bot() @property
    {
        return privateState.bot;
    }


    // postprocess
    /++
     +  Lets a plugin modify an `IRCEvent` while it's begin constructed, before
     +  it's finalised and passed on to be handled.
     +
     +  Params:
     +      ref event = an `IRCEvent` undergoing parsing.
     +/
    void postprocess(ref IRCEvent event)
    {
        static if (__traits(compiles, .postprocess(this, event)))
        {
            .postprocess(this, event);
        }
    }


    // yieldWHOISReuests
    /++
     +  Yields a reference to the `WHOIS` request queue.
     +
     +  The main loop does this after processing all on-event functions so as to
     +  know what nicks the plugin wants a` WHOIS` for. After the `WHOIS`
     +  response returns, the event bundled with the `WHOISRequest` will be
     +  replayed.
     +
     +  Returns:
     +      a reference to the local `WHOIS` request queue.
     +/
    ref WHOISRequest[string] yieldWHOISRequests()
    {
        return privateState.whoisQueue;
    }


    // writeConfig
    /++
     +  Writes configuration to disk.
     +
     +  Params:
     +      configFile = the file to write to.
     +/
    void writeConfig(const string configFile)
    {
        static if (__traits(compiles, .writeConfig(this, string.init)))
        {
            .writeConfig(this, configFile);
        }
    }


    // loadConfig
    /++
     +  Loads configuration from disk.
     +
     +  This does not proxy a call but merely loads configuration from disk for
     +  all struct variables annotated `Settings`.
     +/
    void loadConfig(const string configFile)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;

        foreach (ref symbol; Filter!(isStruct, getSymbolsByUDA!(thisModule, Settings)))
        {
            alias T = typeof(symbol);

            if (symbol != T.init)
            {
                // This symbol was already configured earlier;
                // --> this is a reconnect
                continue;
            }

            import kameloso.common : meldInto;
            import kameloso.config : readConfigInto;
            import std.typecons : No, Yes;

            T tempSymbol;
            configFile.readConfigInto(tempSymbol);
            tempSymbol.meldInto!(Yes.overwrite)(symbol);
        }

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                alias T = typeof(symbol);

                if (symbol != T.init)
                {
                    // As above
                    continue;
                }

                import kameloso.common : meldInto;
                import kameloso.config : readConfigInto;
                import std.typecons : No, Yes;

                T tempSymbol;
                configFile.readConfigInto(tempSymbol);
                tempSymbol.meldInto!(Yes.overwrite)(symbol);
            }
        }
    }


    // present
    /++
     +  Print some information to the screen, usually settings.
     +/
    void present() const
    {
        static if (__traits(compiles, .present(this)))
        {
            .present(this);
        }
    }


    // peekPlugins
    /++
     +  Lends a const reference to the `IRCPlugin[]` array to the plugin.
     +/
    void peekPlugins(const IRCPlugin[] plugins)
    {
        static if (__traits(compiles, .peekPlugins(this, plugins)))
        {
            .peekPlugins(this, plugins);
        }
    }


    // printSettings
    /++
     +  Prints the plugin's `Settings`-annotated structs, with a hardcoded width
     +  to suit all the other plugins' settings member name lengths, to date.
     +
     +  It both prints module-level structs as well as structs in the
     +  `IRCPlugin` (subtype) itself.
     +/
    void printSettings() const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.common : printObject;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;

        enum width = 18;

        alias moduleLevelSymbols = getSymbolsByUDA!(thisModule, Settings);

        foreach (symbol; Filter!(isStruct, moduleLevelSymbols))
        {
            // FIXME: Hardcoded value
            printObject!width(symbol);
        }

        foreach (immutable i, symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                // FIXME: Hardcoded value
                printObject!width(symbol);
            }
        }
    }


    // addToConfig
    /++
     +  Gathers the configuration text the plugin wants to contribute to the
     +  configuration file.
     +
     +  Params:
     +      ref sink = `Appender` to fill with plugin-specific settings text.
     +/
    import std.array : Appender;
    void addToConfig(ref Appender!string sink) const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.config : serialise;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;

        alias moduleLevelSymbols = getSymbolsByUDA!(thisModule, Settings);

        foreach (symbol; Filter!(isStruct, moduleLevelSymbols))
        {
            sink.serialise(symbol);
        }

        foreach (immutable i, symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                sink.serialise(symbol);
            }
        }
    }


    // start
    /++
     +  Activates the plugin, run when connection has been established.
     +/
    void start()
    {
        static if (__traits(compiles, .start(this)))
        {
            .start(this);
        }
    }


    // teardown
    /++
     +  Deinitialises the plugin.
     +/
    void teardown()
    {
        static if (__traits(compiles, .teardown(this)))
        {
            .teardown(this);
        }
    }


    // name
    /++
     +  Returns the name of the plugin.
     +
     +  Slices the last field of the module name; ergo, `kameloso.plugins.xxx`
     +  would return the name `xxx`, as would `kameloso.xxx` and `xxx`.
     +/
    string name() @property const
    {
        import kameloso.string : has, nom;

        string moduleName = module_;

        while (moduleName.has('.'))
        {
            moduleName.nom('.');
        }

        return moduleName;
    }


    // commands
    /++
     +  Collects all bot command strings that this plugin offers and returns
     +  them alongside their `Description`s as an associative `string[string]`
     +  array.
     +/
    string[string] commands() @property const
    {
        import std.meta : Filter;
        import std.traits : getUDAs, getSymbolsByUDA, hasUDA, isSomeFunction;

        mixin("static import thisModule = " ~ module_ ~ ";");

        alias symbols = getSymbolsByUDA!(thisModule, BotCommand);
        alias funs = Filter!(isSomeFunction, symbols);

        string[string] descriptions;

        foreach (fun; funs)
        {
            foreach (commandUDA; getUDAs!(fun, BotCommand))
            {
                static if (hasUDA!(fun, Description))
                {
                    enum descriptionUDA = getUDAs!(fun, Description)[0];
                    descriptions[commandUDA.string_] = descriptionUDA.string_;
                }
            }
        }

        return descriptions;
    }


    // state
    /++
     +  Accessor and mutator, returns a reference to the current private
     +  `IRCPluginState`.
     +
     +  This is needed to have `state` be part of the `IRCPlugin` interface, so
     +  `main.d` can access the property, albeit indirectly.
     +/
    pragma(inline)
    ref IRCPluginState state() @property
    {
        return this.privateState;
    }


    // awaitingFibers
    /++
     +  Returns a reference to a plugin's list of `Fiber`s awaiting events.
     +
     +  These are callback `Fiber`s, registered when a plugin wants an action
     +  performed and then to react to the server's response to it.
     +/
    pragma(inline)
    ref Fiber[][IRCEvent.Type] awaitingFibers() @property
    {
        return this.privateAwaitingFibers;
    }


    // timedFibers
    /++
     +  Returns a reference to a plugin's list of `Fiber`s awaiting execution by
     +  time.
     +
     +  Like `awaitingFibers` these are callback `Fiber`s, registered when a
     +  plugin wants an action performed at a certain point in time.
     +/
    pragma(inline)
    ref Labeled!(Fiber, long)[] timedFibers() @property
    {
        return this.privateTimedFibers;
    }


    // delayFiber
    /++
     +  Queues a `Fiber` to be called at a point n seconds later, by appending
     +  it to `timedFibers`.
     +
     +  It only supports a precision of `kameloso.constants.Timeout.receive` + 1
     +  seconds.
     +/
    void delayFiber(Fiber fiber, const long secs)
    {
        import kameloso.common : labeled;
        import std.datetime.systime : Clock;

        immutable time = Clock.currTime.toUnixTime + secs;
        privateTimedFibers ~= labeled(fiber, time);
    }
}

deprecated("Use IRCPluginImpl instead of IRCPluginBasics")
alias IRCPluginBasics = IRCPluginImpl;


// OnEventImpl
/++
 +  Not needed anymore, the functionality was moved into `IRCPlugin`.
 +/
mixin template OnEventImpl(bool debug_ = false, string module_ = __MODULE__)
{
    pragma(msg, "OnEventImpl is deprecated and is no longer needed. " ~
        "The on-event functionality has been moved into class IRCPlugin.");
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
 +/
mixin template MessagingProxy(bool debug_ = false, string module_ = __MODULE__)
{
    static import kameloso.messaging;
    import std.typecons : Flag, No, Yes;

    enum hasMessagingProxy = true;

    // chan
    /++
     +  Sends a channel message.
     +/
    pragma(inline)
    void chan(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string content)
    {
        return kameloso.messaging.chan!quiet(state.mainThread, channel, content);
    }


    // query
    /++
     +  Sends a private query message to a user.
     +/
    pragma(inline)
    void query(Flag!"quiet" quiet = No.quiet)(const string nickname,
        const string content)
    {
        return kameloso.messaging.query!quiet(state.mainThread, nickname, content);
    }


    // privmsg
    /++
     +  Sends either a channel message or a private query message depending on
     +  the arguments passed to it.
     +
     +  This reflects how channel messages and private messages are both the
     +  underlying same type; `PRIVMSG`.
     +/
    pragma(inline)
    void privmsg(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string nickname, const string content)
    {
        return kameloso.messaging.privmsg!quiet(state.mainThread, channel,
            nickname, content);
    }


    // throttleline
    /++
     +  Sends either a channel message or a private query message depending on
     +  the arguments passed to it.
     +
     +  It sends it in a throttled fashion, usable for long output when the bot
     +  may otherwise get kicked for spamming.
     +/
    pragma(inline)
    void throttleline(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string nickname, const string content)
    {
        return kameloso.messaging.throttleline!quiet(state.mainThread, channel,
            nickname, content);
    }


    // emote
    /++
     +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
     +/
    pragma(inline)
    void emote(Flag!"quiet" quiet = No.quiet)(const string emoteTarget,
        const string content)
    {
        return kameloso.messaging.emote!quiet(state.mainThread, emoteTarget,
            content);
    }


    // chanmode
    /++
     +  Sets a channel mode.
     +
     +  This includes modes that pertain to a user in the context of a channel,
     +  like bans.
     +/
    pragma(inline)
    void chanmode(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string modes, const string content = string.init)
    {
        return kameloso.messaging.chanmode!quiet(state.mainThread, channel, modes, content);
    }


    // topic
    /++
     +  Sets the topic of a channel.
     +/
    pragma(inline)
    void topic(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string content)
    {
        return kameloso.messaging.topic!quiet(state.mainThread, channel, content);
    }


    // invite
    /++
     +  Invites a user to a channel.
     +/
    pragma(inline)
    void invite(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string nickname)
    {
        return kameloso.messaging.invite!quiet(state.mainThread, channel, nickname);
    }


    // join
    /++
     +  Joins a channel.
     +/
    pragma(inline)
    void join(Flag!"quiet" quiet = No.quiet)(const string channel)
    {
        return kameloso.messaging.join!quiet(state.mainThread, channel);
    }


    // kick
    /++
     +  Kicks a user from a channel.
     +/
    void kick(Flag!"quiet" quiet = No.quiet)(const string channel,
        const string nickname, const string reason = string.init)
    {
        return kameloso.messaging.kick!quiet(state.mainThread, channel, nickname, reason);
    }


    // part
    /++
     +  Leaves a channel.
     +/
    pragma(inline)
    void part(Flag!"quiet" quiet = No.quiet)(const string channel)
    {
        return kameloso.messaging.part!quiet(state.mainThread, channel);
    }


    // quit
    /++
     +  Disconnects from the server, optionally with a quit reason.
     +/
    pragma(inline)
    void quit(Flag!"quiet" quiet = No.quiet)(const string reason = string.init)
    {
        return kameloso.messaging.quit!quiet(state.mainThread, reason);
    }


    // raw
    /++
     +  Sends text to the server, verbatim.
     +
     +  This is used to send messages of types for which there exist no helper
     +  functions.
     +/
    pragma(inline)
    void raw(Flag!"quiet" quiet = No.quiet)(const string line)
    {
        return kameloso.messaging.raw!quiet(state.mainThread, line);
    }
}


// UserAwareness
/++
 +  Implements user awareness in a plugin module.
 +
 +  Plugins that deal with users in any form will need event handlers to handle
 +  people joining and leaving channels, disconnecting from the server, and
 +  other events related to user details (including services account names).
 +
 +  If more elaborate ones are needed, additional functions can be written and,
 +  where applicable, annotated appropriately.
 +/
mixin template UserAwareness(bool debug_ = false, string module_ = __MODULE__)
{
    enum hasUserAwareness = true;

    // onUserAwarenessQuitMixin
    /++
     +  Removes a user's `IRCUser` entry from a plugin's user list upon them
     +  disconnecting.
     +/
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onUserAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.users.remove(event.sender.nickname);
    }


    // onUserAwarenessNickMixin
    /++
     +  Tracks a nick change, moving any old `IRCUser` entry in `state.users` to
     +  point to the new nickname.
     +/
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onUserAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin.state)
        {
            if (auto oldUser = event.sender.nickname in users)
            {
                // Does this work?
                users[event.target.nickname] = *oldUser;
                users.remove(event.sender.nickname);
            }
            else
            {
                users[event.target.nickname] = event.sender;
            }
        }
    }


    // onUserAwarenessUserInfoMixin
    /++
     +  Catches a user's information and saves it in the plugin's `IRCUser`
     +  array, along with a timestamp of the results of the last `WHOIS` call,
     +  which is this.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISUSER)
    void onUserAwarenessUserInfoMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.datetime.systime : Clock;

        plugin.catchUser(event.target);

        // Record lastWhois here so it happens even if no `RPL_WHOISACCOUNT`
        auto user = event.target.nickname in plugin.state.users;
        if (!user) return;  // probably the bot
        (*user).lastWhois = Clock.currTime.toUnixTime;
    }


    // onUserAwarenessAccountInfoSenderMixin
    /++
     +  Adds a user to the `IRCUser` array, potentially including their services
     +  account name.
     +
     +  Servers with the (enabled) capability `extended-join` will include the
     +  account name of whoever joins in the event string. If it's there, catch
     +  the user into the user array so we won't have to `WHOIS` them later.
     +
     +  `ACCOUNTS` events will only be processed if a user's `IRCUser` entry
     +  already exists, to counter the fact that `ACCOUNT` events don't imply a
     +  specific channel and as such can't honour `ChannelPolicy.homeOnly`.
     +  This way the user will only be updated with its account info if it was
     +  already created elsewhere.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.ACCOUNT)
    void onUserAwarenessAccountInfoSenderMixin(IRCPlugin plugin, const IRCEvent event)
    {
        if ((event.type == IRCEvent.Type.ACCOUNT) &&
            (event.sender.nickname !in plugin.state.users))
        {
            return;
        }

        plugin.catchUser(event.sender);

        if (event.sender.account == "*")
        {
            plugin.state.users[event.sender.nickname].account = string.init;
        }
    }


    // onUserAwarenessAccountInfoTargetMixin
    /++
     +  Records a user's services account by saving it to the user's `IRCBot` in
     +  the `state.users` associative array.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    void onUserAwarenessAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // No point catching the entire user when we only want the account

        if (auto user = event.target.nickname in plugin.state.users)
        {
            (*user).account = event.target.account;
        }
        else
        {
            plugin.state.users[event.target.nickname] = event.target;
        }
    }


    // onUserAwarenessWHOReplyMixin
    /++
     +  Catches a user's information from a `WHO` reply event.
     +
     +  It usually contains everything interesting except services account name.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_WHOREPLY)
    void onUserAwarenessWHOReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.target);
    }


    // onUserAwarenessNamesReplyMixin
    /++
     +  Catch users in a reply for the request for a `NAMES` list of all the
     +  participants in a channel, if they are expressed in the full
     +  `user!ident@address` form.
     +
     +  Freenode only sends a list of the nicknames but SpotChat sends the full
     +  information.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_NAMREPLY)
    void onUserAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.common : meldInto;
        import kameloso.irc : stripModeSign;
        import kameloso.string : has, nom;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : canFind;
        import std.typecons : No, Yes;

        auto names = event.content.splitter(" ");

        if (names.empty || !names.front.has('!') || !names.front.has('@'))
        {
            return;
        }

        with (plugin.state)
        {
            // SpotChat-like, names are in full nick!ident@address form
            foreach (immutable userstring; names)
            {
                string slice = userstring;

                immutable nickname = slice.nom('!').stripModeSign();
                if (nickname == bot.nickname) continue;

                immutable ident = slice.nom('@');
                immutable address = slice;

                const newUser = IRCUser(nickname, ident, address);

                auto user = nickname in users;
                if (!user)
                {
                    users[nickname] = IRCUser.init;
                    user = nickname in users;
                }

                newUser.meldInto!(Yes.overwrite)(*user);
            }
        }
    }


    // onUserAwarenessEndOfWHOIS
    /++
     +  Remove an exhausted `WHOIS` request from the queue upon end of `WHOIS`.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onUserAwarenessEndOfWHOISMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.whoisQueue.remove(event.target.nickname);
    }


    // onUserAwarenessEndOfWhoNames
    /++
     +  Rehashes, or optimises, the `IRCUser` associative array upon the end
     +  of a `WHO` reply.
     +
     +  These replies can list hundreds of users depending on the size of the
     +  channel. Once an associative array has grown sufficiently it becomes
     +  inefficient. Rehashing it makes it take its new size into account and
     +  makes lookup faster.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_ENDOFWHO)
    void onUserAwarenessEndOfWHOMixin(IRCPlugin plugin)
    {
        plugin.state.users.rehash();
    }
}

deprecated("BasicEventHandlers has been replaced by UserAwareness. " ~
    "This alias will eventually be removed.")
alias BasicEventHandlers = UserAwareness;


// ChannelAwareness
/++
 +  Implements channel awareness in a plugin module.
 +
 +  Plugins that need to track channels and the users in them need some event
 +  handlers to handle the bookkeeping. Notably when the bot joins and leaves
 +  channels, when someone else joins, leaves or disconnects, someone changes
 +  their nickname, changes channel modes or topic, as well as some events that
 +  list information about users and what channels they're in.
 +
 +  Channel awareness needs user awareness, or things won't work.
 +/
mixin template ChannelAwareness(bool debug_ = false, string module_ = __MODULE__)
{
    static assert(is(typeof(.hasUserAwareness)), module_ ~
        " is missing UserAwareness mixin (needed for ChannelAwareness).");

    enum hasChannelAwareness = true;


    // onChannelAwarenessSelfjoinMixin
    /++
     +  Create a new `IRCChannel` in the `state.channels` associative array list
     +  when the bot joins a channel.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.SELFJOIN)
    void onChannelAwarenessSelfjoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel] = IRCChannel.init;
    }


    // onChannelAwarenessSelfpartMixin
    /++
     +  Remove an `IRCChannel` from the internal list when the bot leaves it.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.SELFPART)
    void onChannelAwarenessSelfpartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin.state)
        {
            // Decrement user refcounts before destroying channel

            foreach (immutable nickname; channels[event.channel].users)
            {
                // users array may not contain the user
                auto user = nickname in users;
                if (!user)
                {
                    users[nickname] = event.sender;
                    user = nickname in users;
                }

                if (--(*user).refcount == 0)
                {
                    users.remove(nickname);
                }
            }

            channels.remove(event.channel);
        }
    }


    // onChannelAwarenessChannelAwarenessJoinMixin
    /++
     +  Add a user as being part of a channel when they join one.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.JOIN)
    void onChannelAwarenessJoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin.state)
        {
            channels[event.channel].users ~= event.sender.nickname;

            auto user = event.sender.nickname in users;
            if (!user)
            {
                users[event.sender.nickname] = event.sender;
                user = event.sender.nickname in users;
            }

            ++(*user).refcount;
        }
    }


    // onChannelAwarenessPartMixin
    /++
     +  Remove a user from being part of a channel when they leave one.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.PART)
    void onChannelAwarenessPartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        with (plugin.state)
        {
            immutable userIndex = channels[event.channel].users
                .countUntil(event.sender.nickname);

            assert((userIndex != -1), "Tried to part a user that wasn't there: " ~
                event.sender.nickname);

            channels[event.channel].users = channels[event.channel].users
                .remove(userIndex);

            auto user = event.sender.nickname in users;
            if (!user)
            {
                users[event.sender.nickname] = event.sender;
                user = event.sender.nickname in users;
            }

            if (--(*user).refcount == 0)
            {
                users.remove(event.sender.nickname);
            }
        }
    }


    // onChannelAwarenessNickMixin
    /++
     +  Updates and renames a user in the internal list of users in a channel if
     +  they change their nickname.
     +/
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onChannelAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.searching : countUntil;

        // User awareness bits take care of the user AA

        foreach (ref channel; plugin.state.channels)
        {
            immutable userIndex = channel.users.countUntil(event.sender.nickname);
            if (userIndex == -1) continue;
            channel.users[userIndex] = event.target.nickname;
        }
    }


    // onChannelAwarenessQuitMixin
    /++
     +  Removes a user from all tracked channels if they disconnect.
     +
     +  Does not touch the internal list of users; the user awareness bits are
     +  expected to take care of that.
     +/
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onChannelAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        foreach (ref channel; plugin.state.channels)
        {
            immutable userIndex = channel.users.countUntil(event.sender.nickname);
            if (userIndex == -1) continue;
            channel.users = channel.users.remove(userIndex);
        }
    }


    // onChannelAwarenessTopicMixin
    /++
     +  Update the entry for an `IRCChannel` if someone changes the topic of it.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.TOPIC)
    @(IRCEvent.Type.RPL_TOPIC)
    void onChannelAwarenessTopicMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel].topic = event.content;
    }


    // onChannelAwarenessCreationTime
    /++
     +  Stores the timestamp of when a channel was created.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_CREATIONTIME)
    void onChannelAwarenessCreationTime(IRCPlugin plugin, const IRCEvent event)
    {
        import std.conv : to;
        plugin.state.channels[event.channel].created = event.aux.to!long;
    }


    // onChannelAwarenessChanModeMixin
    /++
     +  Sets a mode for a channel.
     +
     +  Most modes replace others of the same type, notable exceptions being
     +  bans and mode exemptions.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.CHANMODE)
    void onChannelAwarenessChanModeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;
        plugin.state.channels[event.channel]
            .setMode(event.aux, event.content, plugin.state.bot.server);
    }


    // onChannelAwarensesWHOReplyMixin
    /++
     +  Add a user as being part of a channel upon receiving the reply from the
     +  request for info on all the participants.
     +
     +  This events includes all normal fields like ident and address, but not
     +  their channel modes (e.g. `@` for operator).
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_WHOREPLY)
    void onChannelAwarenessWHOReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.searching : canFind;

        // User awareness bits add the IRCUser
        with (plugin.state)
        {
            if (event.target.nickname == bot.nickname) return;

            if (channels[event.channel].users.canFind(event.target.nickname))
            {
                return;
            }

            channels[event.channel].users ~= event.target.nickname;

            auto user = event.target.nickname in users;
            if (!user)
            {
                users[event.target.nickname] = event.target;
                user = event.target.nickname in users;
            }

            ++(*user).refcount;
        }
    }


    // onChannelAwarenessNamesReplyMixin
    /++
     +  Add users as being part of a channel upon receiving the reply from the
     +  request for a list of all the participants.
     +
     +  On some servers this does not include information about the users, only
     +  their nickname and their channel mode (e.g. `@` for operator), but other
     +  servers express the users in the full `user!ident@address` form. It's
     +  not the job of `ChannelAwareness` to create `IRCUsers` out of them, but
     +  we need a skeletal `IRCUser.init` at least, to increment the refcount
     +  of.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_NAMREPLY)
    void onChannelAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : stripModeSign;
        import kameloso.string : has, nom;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : canFind;

        auto names = event.content.splitter(" ");
        if (names.empty) return;

        with (plugin.state)
        {
            if (names.front.has('!') && names.front.has('@'))
            {
                // SpotChat-like, names are in full nick!ident@address form
                foreach (immutable userstring; names)
                {
                    string slice = userstring;

                    immutable nickname = slice.nom('!').stripModeSign();
                    if (nickname == bot.nickname) continue;

                    if (channels[event.channel].users.canFind(nickname))
                    {
                        continue;
                    }

                    channels[event.channel].users ~= nickname;

                    auto user = nickname in users;
                    if (!user)
                    {
                        /++
                         +  Creating the IRCUser is not in scope for
                         +  ChannelAwareness, but we need one in place to
                         +  increment the refcount. Add an IRCUser.init and let
                         +  UserAwareness flesh it out.
                         +/
                        users[nickname] = IRCUser.init;
                        user = nickname in users;
                    }

                    ++(*user).refcount;
                }
            }
            else
            {
                // Freenode-like, names are just nicknames
                foreach (immutable signedName; names)
                {
                    immutable nickname = stripModeSign(signedName);
                    if (nickname == bot.nickname) continue;

                    if (channels[event.channel].users.canFind(nickname))
                    {
                        continue;
                    }

                    channels[event.channel].users ~= nickname;

                    auto user = nickname in users;
                    if (!user)
                    {
                        // See above
                        users[nickname] = IRCUser.init;
                        user = nickname in users;
                    }

                    ++(*user).refcount;
                }
            }
        }
    }


    // onChannelAwarenessModeListsMixin
    /++
     +  Adds the list of banned users to a tracked channel's list of modes.
     +
     +  Bans are just normal channel modes that are paired with a user and that
     +  don't overwrite other bans (can be stacked).
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_BANLIST)
    @(IRCEvent.Type.RPL_QUIETLIST)
    @(IRCEvent.Type.RPL_INVITELIST)
    void onChannelAwarenessModeListsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;
        // :kornbluth.freenode.net 367 kameloso #flerrp huerofi!*@* zorael!~NaN@2001:41d0:2:80b4:: 1513899527
        // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
        // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
        // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101

        with (IRCEvent.Type)
        with (plugin.state)
        {
            string mode;

            if (event.type == RPL_BANLIST) mode = "+b";
            else if (event.type == RPL_QUIETLIST) mode = "+q";
            else if (event.type == RPL_INVITELIST) mode = "+I";
            else
            {
                assert(0);
            }

            channels[event.channel]
                .setMode(mode, event.content, plugin.state.bot.server);
        }
    }


    // onChannelAwarenessChannelModeIs
    /++
     +  Adds the modes of a channel to a tracked channel's mode list.
     +/
    @(Chainable)
    @(ChannelPolicy.homeOnly)
    @(IRCEvent.Type.RPL_CHANNELMODEIS)
    void onChannelAwarenessChannelModeIs(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;
        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        plugin.state.channels[event.channel]
            .setMode(event.aux, event.content, plugin.state.bot.server);
    }
}


// nickPolicyMatches
/++
 +  Evaluates whether the message in an event satisfies the `NickPolicy`
 +  specified, as fetched from a `BotCommand` or `BotRegex` UDA.
 +
 +  If it doesn't match, the `onEvent` routine shall consider the UDA as not
 +  matching and continue with the next one.
 +
 +  TODO: Support for verbose.
 +/
bool nickPolicyMatches(const IRCPluginState privateState,
    const NickPolicy policy, ref IRCEvent mutEvent)
{
    import kameloso.string : beginsWith, nom, stripPrefix;
    import std.typecons : Flag, No, Yes;

    with (privateState)
    with (mutEvent)
    with (NickPolicy)
    final switch (policy)
    {
    case ignored:
        break;

    case direct:
        if (settings.prefix.length && content.beginsWith(settings.prefix))
        {
            /*static if (verbose)
            {
                writefln("starts with prefix (%s)",
                    settings.prefix);
            }*/

            content.nom!(Yes.decode)(settings.prefix);
        }
        else
        {
            return false;
        }
        break;

    case optional:
        if (content.beginsWith('@'))
        {
            // Using @name to refer to someone is not
            // uncommon; allow for it and strip it away
            content = content[1..$];
        }

        if (content.beginsWith(bot.nickname))
        {
            content = content.stripPrefix(bot.nickname);
        }
        break;

    case required:
        if (type == IRCEvent.Type.QUERY)
        {
            /*static if (verbose)
            {
                writeln(name, "but it is a query, " ~
                    "consider optional");
            }*/
            goto case optional;
        }
        goto case hardRequired;

    case hardRequired:
        if (content.beginsWith('@'))
        {
            content = content[1..$];
        }

        if (content.beginsWith(bot.nickname) &&
            (content.length > bot.nickname.length))
        {
            /*static if (verbose)
            {
                writefln("%s trailing character '%s'",
                    name, content[bot.nickname.length]);
            }*/

            switch (content[bot.nickname.length])
            {
            case ':':
            case ' ':
            case '!':
            case '?':
                // Content begins with bot nickname,
                // followed by this non-nick character;
                // indicative of a command
                break;

            default:
                // Content begins with bot nickname,
                // followed by something allowed in
                // nicks: [a-z] [A-Z] [0-9] _-\[]{}^`|
                // Hence we can't say it's aimed towards
                // us, may be another nick
                return false;
            }
        }
        else
        {
            // Message started with something unrelated
            // (not bot nickname)
            return false;
        }

        // Event.content *guaranteed* to begin with
        // privateState.bot.nickname here
        content = content.stripPrefix(bot.nickname);
        break;
    }

    return true;
}


// catchUser
/++
 +  Catch an `IRCUser`, saving it to the `state.users` array of an `IRCPlugin`.
 +
 +  If a user already exists, meld the new information into the old one.
 +/
void catchUser(Flag!"overwrite" overwrite = Yes.overwrite)
    (IRCPlugin plugin, const IRCUser newUser)
{
    import kameloso.common : meldInto;

    if (!newUser.nickname.length || (newUser.nickname == plugin.state.bot.nickname))
    {
        return;
    }

    with (plugin)
    {
        auto user = newUser.nickname in state.users;

        if (!user)
        {
            state.users[newUser.nickname] = IRCUser.init;
            user = newUser.nickname in state.users;
        }

        newUser.meldInto!overwrite(*user);
    }
}


// doWhois
/++
 +  Construct and queue a `WHOIS` request in the local request queue.
 +
 +  The main loop will catch up on it and do the neccessary `WHOIS` calls, then
 +  replay the event.
 +
 +  Params:
 +      event = the event to replay once we have `WHOIS` account information.
 +      fp = the function pointer to call when that happens.
 +/
void doWhois(F, Payload)(IRCPlugin plugin, Payload payload,
    const IRCEvent event, const string nickname, F fn)
{
    import kameloso.constants : Timeout;
    import core.time : seconds;
    import std.datetime.systime : Clock, SysTime;

    const user = nickname in plugin.state.users;

    if (user && ((Clock.currTime - SysTime.fromUnixTime(user.lastWhois))
        < Timeout.whois.seconds))
    {
        return;
    }

    with (plugin)
    {
        static if (!is(Payload == typeof(null)))
        {
            state.whoisQueue[nickname] = whoisRequest(payload, event, fn);
        }
        else
        {
            state.whoisQueue[nickname] = whoisRequest(state, event, fn);
        }
    }
}

/// Ditto
void doWhois(F)(IRCPlugin plugin, const IRCEvent event,
    const string nickname, F fn)
{
    return doWhois!(F, typeof(null))(plugin, null, event, nickname, fn);
}


// isStruct
/++
 +  Eponymous template that is true if the passed type is a struct.
 +
 +  Used with `std.meta.Filter`, which cannot take `is()` expressions.
 +/
enum isStruct(T) = is(T == struct);

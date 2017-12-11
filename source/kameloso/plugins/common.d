module kameloso.plugins.common;

import kameloso.common : CoreSettings;
import kameloso.ircdefs;


// IRCPlugin
/++
 +  Interface that all IRCPlugins must adhere to.
 +
 +  There will obviously be more functions but only these are absolutely needed.
 +  It is neccessary so that all plugins may be kept in one array, and foreached
 +  through when new events have been generated.
 +/
interface IRCPlugin
{
    import std.array : Appender;

    /// Executed on update to the internal IRCBot struct
    void newBot(IRCBot);

    /// Executed after a plugin has run its onEvent course to pick up bot changes
    IRCBot yieldBot();

    /// Executed to get a list of nicknames a plugin wants WHOISed
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

    /// Executed when we want a plugin to print its Settings struct
    void printSettings() const;

    /// Executed during shutdown or plugin restart
    void teardown();

    /// Returns the name of the plugin, sliced off the module name
    string name() @property const;

    /// Returns a reference to the current `IRCPluginState`
    ref IRCPluginState state() @property;

    /// Sets a new `IRCPluginState`
    void state(IRCPluginState) @property;
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

    /// Call the passed function/delegate pointer, optionally with the stored
    /// `IRCEvent` and/or `Payload`
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
            static assert(0, "Unknown function signature in WHOISRequestImpl: " ~
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
 +  Convenience function that returns a WHOISRequestImpl of the right type,
 +  with a payload attached.
 +/
WHOISRequest whoisRequest(F, Payload)(Payload payload, IRCEvent event, F fn)
{
    return new WHOISRequestImpl!(F, Payload)(payload, event, fn);
}

// whoisRequest
/++
 +  Convenience function that returns a WHOISRequestImpl of the right type,
 +  without a payload attached.
 +/
WHOISRequest whoisRequest(F)(IRCEvent event, F fn)
{
    return new WHOISRequestImpl!F(event, fn);
}

// IRCPluginState
/++
 +  An aggregate of all variables that make up the state of a given plugin.
 +
 +  This neatly tidies up the amount of top-level variables in each plugin
 +  module. This allows for making more or less all functions top-level
 +  functions, since any state could be passed to it with variables of this type.
 +/
struct IRCPluginState
{
    import std.concurrency : Tid;

    /++
     +  The current `IRCBot`, containing information pertaining to bot in the
     +  bot in the context of the current (alive) connection.
     +/
    IRCBot bot;

    /++
     +  The current core settings of the bot, currently only housing the
     +  filename of the main configuration file as well as a flag monochrome.
     +/
    CoreSettings settings;

    /// Thread ID to the main thread
    Tid mainThread;

    /// Hashmap of IRC user details
    IRCUser[string] users;

    /// Queued WHOIS requests and pertaining IRCEvents to replay
    WHOISRequest[string] whoisQueue;
}


/// The results trie from comparing a username with the known list of friends
enum FilterResult { fail, pass, whois }


/// Whether an annotated event ignores, allows or requires the event to be
/// prefixed with the bot's nickname
enum NickPolicy
{
    ignored,      /// Any prefixes will be ignored.
    direct,       /// Message should begin with `CoreSettings.prefix`.
    optional,     /// Message may begin with bot name, if so will be stripped.
    required,     /// Message must begin with bot name, except in `QUERY` events.
    hardRequired, /// Message must always begin with bot name, regardless of type.
}
deprecated alias NickPrefixPolicy = NickPolicy;


/// If an annotated function should work in all channels or just in homes
enum ChannelPolicy
{
    /// The function will only trigger if the event happened in a home, where
    /// applicable (not all events have channels).
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


// Prefix
/++
 +  Describes how an on-text function is triggered.
 +
 +  The prefix policy decides to what extent the actual prefix string_ is
 +  required. It isn't needed for functions that don't trigger on text messages;
 +  this is merely to gather everything needed to have trigger "verb" commands.
 +
 +  If no `NickPolicy` is specified then it will default to `NickPolicy.direrct`
 +  and look for `CoreSettings.prefix` at the beginning of messages, to prefix
 +  the string. (Usually "!", making it "!command".)
 +/
struct Prefix
{
    /// The policy to which extent the prefix string_ is required
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
        policy = NickPolicy.direct;
        this.string_ = string_;
    }
}


/// Flag denoting that an event-handling function let other functions in the
/// same module process after it.
struct Chainable;

/// Flag denoting that we want verbose debug output of the plumbing when
/// handling events, iterating through the module
struct Verbose;

/// Flag denoting that a variable is to be considered settings and should be
/// saved in the configuration file.
struct Settings;

/// Alias to allow the old annotation to  still work
deprecated("Use @Settings instead of @Configurable. " ~
           "This alias will eventually be removed.")
alias Configurable = Settings;


// filterUser
/++
 +  Decides whether a nick is known good, known bad, or needs WHOIS.
 +
 +  This is used to tell whether a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return whois.
 +  If the user's NickServ login is in the list of friends (or equals the bot's
 +  master's), return pass. Else, return fail and deny use.
 +/
FilterResult filterUser(const IRCPluginState state, const IRCEvent event)
{
    import kameloso.constants : Timeout;
    import std.algorithm.searching : canFind;
    import std.datetime : Clock, SysTime;
    import core.time : seconds;

    auto user = event.sender.nickname in state.users;

    if (!user || !user.login.length &&
        ((SysTime.fromUnixTime(user.lastWhois) - Clock.currTime)
          < Timeout.whois.seconds))
    {
        return FilterResult.whois;
    }
    else if ((user.login == state.bot.master) ||
        state.bot.friends.canFind(user.login))
    {
        return FilterResult.pass;
    }
    else
    {
        return FilterResult.fail;
    }
}


// IRCPluginBasics
/++
 +  Mixin with the basics of any plugin.
 +
 +  Uses compile-time introspection to call top-level functions to extend
 +  behaviour;
 +      .initialise
 +      .start
 +      .present
 +      .writeConfig
 +      .teardown
 +/
mixin template IRCPluginImpl(bool debug_ = false, string module_ = __MODULE__)
{
    IRCPluginState privateState;

    // onEvent
    /++
     +  Pass on the supplied IRCEvent to functions annotated with the right
     +  `IRCEvent.Types`.
     +/
    void onEvent(const IRCEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.traits : getSymbolsByUDA, isSomeFunction, getUDAs, hasUDA;

        funloop:
        foreach (fun; getSymbolsByUDA!(thisModule, IRCEvent.Type))
        {
            static if (isSomeFunction!fun)
            {
                import std.stdio : writeln, writefln;

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
                        // UDA is ANY, let pass
                    }
                    else
                    {
                        if (eventTypeUDA != event.type)
                        {
                            // The current event does not match this function's
                            // particular UDA; continue to the next one
                            continue;
                        }
                    }

                    static if (hasUDA!(fun, ChannelPolicy))
                    {
                        enum policy = getUDAs!(fun, ChannelPolicy)[0];
                    }
                    else
                    {
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
                            // it is a non-channel event, like a QUERY
                        }
                        else if (!privateState.bot.homes.canFind(event.channel))
                        {
                            static if (verbose)
                            {
                                writeln(name, " ignore invalid channel ",
                                        event.channel);
                            }
                            continue funloop;
                        }
                        break;

                    case any:
                        // drop down, no need to check
                        break;
                    }

                    IRCEvent mutEvent = event;  // mutable
                    string contextPrefix;

                    static if (hasUDA!(fun, Prefix))
                    {
                        if (!event.content.length)
                        {
                            // Event has a Prefix set up but event.content is
                            // empty; cannot possibly be of interest
                            return;
                        }

                        bool matches;

                        foreach (prefixUDA; getUDAs!(fun, Prefix))
                        {
                            import kameloso.string : nom, beginsWith,
                                stripPrefix;

                            if (matches)
                            {
                                static if (verbose)
                                {
                                    writeln(name, " MATCH! breaking");
                                }

                                break;
                            }

                            // Reset between iterations
                            mutEvent = event;
                            contextPrefix = string.init;

                            with (privateState)
                            with (event)
                            with (NickPolicy)
                            final switch (prefixUDA.policy)
                            {
                            case ignored:
                                break;

                            case direct:
                                if (settings.prefix.length &&
                                    content.beginsWith(settings.prefix))
                                {
                                    static if (verbose)
                                    {
                                        writefln("starts with prefix (%s)",
                                            settings.prefix);
                                    }

                                    mutEvent.content = content;
                                    mutEvent.content.nom(settings.prefix);
                                }
                                else
                                {
                                    continue;
                                }
                                break;

                            case optional:
                                if (content.beginsWith(bot.nickname))
                                {
                                    mutEvent.content = content
                                        .stripPrefix(bot.nickname);
                                }
                                break;

                            case required:
                                if (type == IRCEvent.Type.QUERY)
                                {
                                    static if (verbose)
                                    {
                                        writeln(name, "but it is a query, " ~
                                            "consider optional");
                                    }
                                    goto case optional;
                                }
                                goto case hardRequired;

                            case hardRequired:
                                if (content.beginsWith(bot.nickname) &&
                                   (content.length > bot.nickname.length))
                                {
                                    static if (verbose)
                                    {
                                        writefln("%s trailing character '%s'",
                                            name, content[bot.nickname.length]);
                                    }

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
                                        continue;
                                    }
                                }
                                else
                                {
                                    // Message started with something unrelated
                                    // (not bot nickname)
                                    continue;
                                }

                                // Event.content *guaranteed* to begin with
                                // privateState.bot.nickname here
                                mutEvent.content = content
                                    .stripPrefix(bot.nickname);
                                break;
                            }

                            static assert(prefixUDA.string_.length,
                                name ~ " had an empty Prefix string");

                            import std.string : indexOf, toLower;

                            if (mutEvent.content.indexOf(' ') == -1)
                            {
                                // single word, not a prefix
                                contextPrefix = mutEvent.content;
                                mutEvent.content = string.init;
                            }
                            else
                            {
                                import std.typecons : Yes;

                                contextPrefix = mutEvent
                                    .content
                                    .nom!(Yes.decode)(' ')
                                    .toLower();
                            }

                            // case-sensitive check goes here
                            enum lowercasePrefix = prefixUDA
                                .string_
                                .toLower();

                            matches = (contextPrefix == lowercasePrefix);
                            continue;
                        }

                        // We can't label the innermost foreach! So we have to
                        // runtime-skip here...
                        if (!matches) continue;
                    }

                    static if (hasUDA!(fun, PrivilegeLevel))
                    {
                        enum privilegeLevel = getUDAs!(fun,
                            PrivilegeLevel)[0];

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

                            with (FilterResult)
                            final switch (result)
                            {
                            case pass:
                                if ((privilegeLevel == master) &&
                                    (privateState.users[mutEvent.sender.nickname].login !=
                                        privateState.bot.master))
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

                                import std.meta   : AliasSeq, Filter, staticMap;
                                import std.traits : Parameters, Unqual, arity;

                                alias Params = staticMap!(Unqual, Parameters!fun);
                                enum isIRCPluginParam(T) = is(T == IRCPlugin);

                                static if (verbose)
                                {
                                    writeln("%s.%s WHOIS for %s",
                                        typeof(this).stringof,
                                        __traits(identifier, fun), event.type);
                                }

                                static if (is(Params : AliasSeq!IRCEvent) ||
                                    (is(Params : AliasSeq!(IRCPluginState, IRCEvent)) ||
                                    is(Params : AliasSeq!IRCPluginState) ||
                                    (arity!fun == 0)))
                                {
                                    return this.doWhois(mutEvent, mutEvent.sender.nickname, &fun);
                                }
                                else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                                    (is(Params : AliasSeq!(typeof(this)))))
                                {
                                    return this.doWhois(this, mutEvent, mutEvent.sender.nickname, &fun);
                                }
                                else static if (Filter!(isIRCPluginParam, Params).length)
                                {
                                    pragma(msg, typeof(fun).stringof);
                                    pragma(msg, __traits(identifier, fun));
                                    pragma(msg, Params);
                                    static assert(0, "Function signature has " ~
                                        "IRCPlugin instead of concrete plugin.");
                                }
                                else
                                {
                                    pragma(msg, typeof(fun).stringof);
                                    pragma(msg, __traits(identifier, fun));
                                    pragma(msg, Params);
                                    static assert(0, "Unknown function signature.");
                                }

                            case fail:
                                static if (verbose)
                                {
                                    import kameloso.common : logger;
                                    logger.warningf("%s: %s failed privilege check; continue",
                                        name, mutEvent.sender.nickname);
                                }
                                continue;
                            }
                            break;

                        case anyone:
                            break;
                        }
                    }

                    import std.meta   : AliasSeq, staticMap;
                    import std.traits : Parameters, Unqual, arity;

                    alias Params = staticMap!(Unqual, Parameters!fun);

                    static if (verbose)
                    {
                        writeln("%s.%s on %s", typeof(this).stringof,
                            __traits(identifier, fun), event.type);
                    }

                    static if (is(Params : AliasSeq!IRCEvent))
                    {
                        fun(mutEvent);
                    }
                    else static if (is(Params : AliasSeq!(IRCPluginState, IRCEvent)))
                    {
                        pragma(msg, __traits(identifier, fun) ~
                            " is using an IRCPluginState parameter, change to plugin");
                        fun(privateState, mutEvent);
                    }
                    else static if (is(Params : AliasSeq!IRCPluginState))
                    {
                        pragma(msg, __traits(identifier, fun) ~
                            " is using an IRCPluginState parameter, change to plugin");
                        fun(privateState);
                    }
                    else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(IRCPlugin, IRCEvent)))
                    {
                        fun(this, mutEvent);
                    }
                    else static if (is(Params : AliasSeq!(typeof(this))) ||
                        is(Params : AliasSeq!IRCPlugin))
                    {
                        fun(this);
                    }
                    else static if (arity!fun == 0)
                    {
                        fun();
                    }
                    else
                    {
                        pragma(mg, typeof(fun).stringof);
                        pragma(msg, __traits(identifier, fun));
                        pragma(msg, Params);
                        static assert(0, "Unknown function signature: " ~
                            typeof(fun).stringof);
                    }

                    static if (hasUDA!(fun, Chainable))
                    {
                        continue funloop;
                    }
                    else
                    {
                        return;
                    }
                }
            }
        }
    }

    // this(IRCPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level .initialise() if it exists.
     +
     +  Params:
     +      origState = the aggregate of all plugin state variables, making
     +                  this the "original state" of the plugin.
     +/
    this(IRCPluginState state)
    {
        // Plugin has a state variable; assign to it
        this.privateState = state;

        static if (__traits(compiles, .initialise(this)))
        {
            .initialise(this);
        }
    }

    // newBot
    /++
     +  Inherits a new IRCBot.
     +
     +  Invoked on all plugins when changes has been made to the bot.
     +
     +  Params:
     +      bot = the new bot to inherit
     +/
    void newBot(IRCBot bot)
    {
        privateState.bot = bot;
    }

    // yieldBot
    /++
     +  Yields a copy of the current IRCot to the caller.
     +
     +  This is used to let the main loop examine it for updates to propagate
     +  to other plugins.
     +
     +  Returns:
     +      a copy of the current IRCBot.
     +/
    IRCBot yieldBot()
    {
        return privateState.bot;
    }

    // postprocess
    /++
     +  FIXME
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
     +  Yields a reference to the WHOIS request queue.
     +
     +  The main loop does this after processing all on-event functions so as to
     +  know what nicks the plugin wants a WHOI for. After the WHOIS response
     +  returns, the event bundled in the WHOISRequest will be replayed.
     +
     +  Returns:
     +      a reference to the local WHOIS request queue.
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
     +  This does not proxy a cal but merely loads configuration from disk for
     +  all variables annotated Settings.
     +/
    void loadConfig(const string configFile)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.traits : getSymbolsByUDA, hasUDA;

        foreach (ref symbol; getSymbolsByUDA!(thisModule, Settings))
        {
            static if (is(typeof(symbol) == struct))
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

    // printSettings
    /++
     +  FIXME
     +/
    void printSettings() const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.common : printObject;
        import std.traits : getSymbolsByUDA, hasUDA;

        alias moduleLevelSymbols = getSymbolsByUDA!(thisModule, Settings);

        foreach (immutable i, symbol; moduleLevelSymbols)
        {
            static if (is(typeof(symbol) == struct))
            {
                import std.format : format;
                import std.traits : Unqual;

                // FIXME: Hardcoded value
                printObject!17(symbol);
            }
        }

        foreach (immutable i, symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                // FIXME: Hardcoded value
                printObject!17(symbol);
            }
        }
    }

    // addToConfig
    /++
     +  Gathers the configuration text the plugin wants to contribute to the
     +  configuration file.
     +
     +  Params:
     +      ref sink = Appender to fill with plugin-specific settings text.
     +/
    import std.array : Appender;
    void addToConfig(ref Appender!string sink) const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.traits : getSymbolsByUDA, isType, isSomeFunction;

        foreach (symbol; getSymbolsByUDA!(thisModule, Settings))
        {
            static if (!isType!symbol && !isSomeFunction!symbol &&
                !__traits(isTemplate, symbol))
            {
                import kameloso.config : serialise;
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
     +  Slices the last field of the module name; ergo, kameloso.plugins.xxx
     +  would return the name xxx, as would kameloso.xxx and xxx.
     +/
    string name() @property const
    {
        import kameloso.string : nom;
        import std.string : indexOf;

        string moduleName = module_;

        while (moduleName.indexOf('.') != -1)
        {
            moduleName.nom('.');
        }

        return moduleName;
    }

    ref IRCPluginState state() @property
    {
        return this.privateState;
    }

    void state(IRCPluginState state) @property
    {
        this.privateState = state;
    }
}

deprecated("Use IRCPluginImpl instead of IRCPluginBasics")
alias IRCPluginBasics = IRCPluginImpl;


// OnEventImpl
/++
 +  Not needed anymore, the functionality was moved into `IRCPlugin`.
 +/
mixin template OnEventImpl(bool debug_ = false, string module_ = __MODULE__) {}


// BasicEventHandlers
/++
 +  Rudimentary IRCEvent handlers.
 +
 +  Almost any plugin will need handlers for RPL_WHOISACCOUNT, RPL_ENDOFWHOIS,
 +  PART, QUIT, and SELFNICK. This mixin provides those. If more elaborate ones
 +  are needed, additional functions can be written and annotated appropriately.
 +/
mixin template BasicEventHandlers(string module_ = __MODULE__)
{
    // onLeaveMixin
    /++
     +  Remove a user from the user array.
     +
     +  This automatically deauthenticates them from the bot's service, as all
     +  track of them will have disappeared. A new WHOIS must be made then.
     +/
    @(Chainable)
    @(IRCEvent.Type.PART)
    @(IRCEvent.Type.QUIT)
    void onLeaveMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.users.remove(event.sender.nickname);
    }


    // onNickMixin
    /++
     +  Tracks a nick change, moving any old IRCUser entry in state.users to
     +  point to the new nickname.
     +/
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin)
        {
            if (auto oldUser = event.sender.nickname in state.users)
            {
                state.users[event.target.nickname] = *oldUser;
                state.users.remove(event.sender.nickname);
            }
            else
            {
                state.users[event.target.nickname] = event.sender;
            }
        }
    }


    // onUserInfoMixin
    /++
     +  Catches a user's information and saves it in the IRCUser array, along
     +  with a timestamp of the last WHOIS call, which is this.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISUSER)
    void onUserInfoMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.datetime : Clock;

        with (plugin)
        {
            plugin.catchUser(event.target);

            // Record lastWhois here so it happens even if no RPL_WHOISACCOUNT event
            auto user = event.target.nickname in state.users;
            if (!user) return;  // probably the bot
            (*user).lastWhois = Clock.currTime.toUnixTime;
        }
    }


    // onJoinMixin
    /++
     +  Adds a user to the user array if the login is known.
     +
     +  Servers with the (enabled) capability `extended-join` will include the
     +  login name of whoever joins in the event string. If it's there, catch
     +  the user into the user array so we won't have to WHOIS them later.
     +/
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.ACCOUNT)
    void onLoginInfoSenderMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin)
        {
            plugin.catchUser(event.sender);

            if (event.sender.login == "*")
            {
                assert(event.sender.nickname in state.users);
                state.users[event.sender.nickname].login = string.init;
            }
        }
    }


    // onLoginInfoTargetMixin
    /++
     +  Records a user's NickServ login by saving it to the user's IRCBot in
     +  the state.users associative array.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    void onLoginInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin)
        {
            // No point catching the entire user
            if (auto user = event.target.nickname in state.users)
            {
                (*user).login = event.target.login;
            }
            else
            {
                state.users[event.target.nickname] = event.target;
            }
        }
    }


    // onWHOReplyMixin
    /++
     +  Catches a user's information from a WHO reply event.
     +
     +  It usually contains everything interesting except login.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOREPLY)
    void onWHOReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.target);
    }


    // onEndOfWHOIS
    /++
     +  Remove an exhausted WHOIS request from the queue upon end of WHOIS.
     +/
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onEndOfWHOISMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.whoisQueue.remove(event.target.nickname);
    }

    // catchUser
    /++
     +  Catch an IRCUser, saving it to the state.users array.
     +
     +  If a user already exists, meld the new information into the old one.
     +/
    import std.typecons : Flag, Yes;
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
     +  Construct and queue a WHOIS request in the local request queue.
     +
     +  The main loop will catch up on it and do the neccessary WHOIS calls,
     +  then replay the event.
     +
     +  Params:
     +      event = the IRCEvent to replay once we have WHOIS login information.
     +      fp = the function pointer to call when that happens.
     +/
    void doWhois(F, Payload)(IRCPlugin plugin, Payload payload,
        const IRCEvent event, const string nickname, F fn)
    {
        import kameloso.constants : Timeout;
        import std.datetime : Clock, SysTime, seconds;

        const user = nickname in plugin.state.users;

        if (user && ((Clock.currTime - SysTime.fromUnixTime(user.lastWhois))
            < Timeout.whois.seconds))
        {
            return;
        }

        static if (!is(Payload == typeof(null)))
        {
            plugin.state.whoisQueue[nickname] = whoisRequest(payload, event, fn);
        }
        else
        {
            plugin.state.whoisQueue[nickname] = whoisRequest(plugin.state, event, fn);
        }
    }

    /// Ditto
    void doWhois(F)(IRCPlugin plugin, const IRCEvent event,
        const string nickname, F fn)
    {
        return doWhois!(F, typeof(null))(plugin, null, event, nickname, fn);
    }
}

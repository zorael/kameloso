/++
 +  The is not a plugin by itself but contains code common to all plugins,
 +  without which they will *not* function.
 +
 +  It is mandatory if you plan to use any form of plugin. Indeed, the very
 +  definition of an `IRCPlugin` is in here.
 +/
module kameloso.plugins.common;

import kameloso.ircdefs;

import core.thread : Fiber;
import std.typecons : Flag, No, Yes;


// 2.079.0 getSymolsByUDA
/++
 +  2.079.0 has a bug that breaks plugin processing completely. It's fixed in
 +  patch .1 (2.079.1), but there's no API for knowing the patch number.
 +
 +  Infer it by testing for the broken behaviour and warn (during compilation).
 +/
static if (__VERSION__ == 2079)
{
    import std.traits : getSymbolsByUDA;

    struct UDA_2079 {}
    struct Foo_2079
    {
        @UDA_2079
        {
            int i;
            void fun() {}
            int n;
        }
    }

    static if (getSymbolsByUDA!(Foo_2079, UDA_2079).length != 3)
    {
        pragma(msg, "WARNING: You are using a 2.079.0 compiler with a broken " ~
            "crucial trait in its standard library. The program will not " ~
            "function normally. Please upgrade to 2.079.1.");
    }
}


// IRCPlugin
/++
 +  Interface that all `IRCPlugin`s must adhere to.
 +
 +  Plugins may implement it manually, or mix in `IRCPluginImpl`.
 +
 +  This is currently shared with all `service`-class "plugins".
 +/
interface IRCPlugin
{
    import std.array : Appender;

    @safe:

    /// Returns a reference to the current `IRCPluginState` of the plugin.
    ref IRCPluginState state() pure nothrow @nogc @property;

    /// Executed to let plugins modify an event mid-parse.
    void postprocess(ref IRCEvent) @system;

    /// Executed upon new IRC event parsed from the server.
    void onEvent(const IRCEvent) @system;

    /// Executed when the plugin is requested to initialise its disk resources.
    void initResources() @system;

    /// Executed during setup to let plugins read settings from disk.
    string[][string] deserialiseConfigFrom(const string);

    /// Executed when gathering things to put in the configuration file.
    void serialiseConfigInto(ref Appender!string) const;

    /// Executed during start if we want to change a setting by its string name.
    void setSettingByName(const string, const string);

    /// Executed when connection has been established.
    void start() @system;

    /// Executed when a plugin wants to examine all the other plugins.
    void peekPlugins(IRCPlugin[], const IRCEvent event) @system;

    /// Executed when we want a plugin to print its Settings struct.
    void printSettings() @system const;

    /// Executed during shutdown or plugin restart.
    void teardown() @system;

    /// Returns the name of the plugin, sliced off the module name.
    string name() @property const;

    /// Returns an array of the descriptions of the commands a plugin offers.
    string[string] commands() pure nothrow @property const;

    /++
     +  Call a plugin to perform its periodic tasks, iff the time is equal to or
     +  exceeding `nextPeriodical`.
     +/
    void periodically(const long) @system;

    /// Reloads the plugin, where such is applicable.
    void reload() @system;
}


// WHOISRequest
/++
 +  A queued event to be replayed upon a `WHOIS` request response.
 +
 +  It is abstract; all objects must be of a concrete `WHOISRequestImpl` type.
 +/
abstract class WHOISRequest
{
    /// Stored `kameloso.ircdefs.IRCEvent` to replay.
    IRCEvent event;

    /// `PrivilegeLevel` of the function to replay.
    PrivilegeLevel privilegeLevel;

    /// When this request was issued.
    long when;

    /// Replay the stored event.
    void trigger();

    /// Creates a new `WHOISRequest` with a timestamp of the current time.
    this() @safe
    {
        import std.datetime.systime : Clock;
        when = Clock.currTime.toUnixTime;
    }
}


// WHOISRequestImpl
/++
 +  Implementation of a queued `WHOIS` request call.
 +
 +  It functions like a Command pattern object in that it stores a payload and
 +  a function pointer, which we queue and do a `WHOIS` call. When the response
 +  returns we trigger the object and the original `kameloso.ircdefs.IRCEvent`
 +  is replayed.
 +/
final class WHOISRequestImpl(F, Payload = typeof(null)) : WHOISRequest
{
    @safe:

    /// Stored function pointer/delegate.
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the `kameloso.ircdefs.IRCEvent`.
        Payload payload;

        /// Create a new `WHOISRequestImpl` with the passed variables.
        this(Payload payload, IRCEvent event, PrivilegeLevel privilegeLevel, F fn)
        {
            super();

            this.payload = payload;
            this.event = event;
            this.privilegeLevel = privilegeLevel;
            this.fn = fn;
        }
    }
    else
    {
        /// Create a new `WHOISRequestImpl` with the passed variables.
        this(IRCEvent event, PrivilegeLevel privilegeLevel, F fn)
        {
            super();

            this.event = event;
            this.privilegeLevel = privilegeLevel;
            this.fn = fn;
        }
    }

    /++
     +  Call the passed function/delegate pointer, optionally with the stored
     +  `kameloso.ircdefs.IRCEvent` and/or `Payload`.
     +/
    override void trigger() @system
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
            static assert(0, "Unknown function signature in WHOISRequestImpl: " ~ typeof(fn).stringof);
        }
    }

    /// Identify the queue entry, in case we ever need that.
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
    PrivilegeLevel pl = PrivilegeLevel.admin;

    // delegate()

    int i = 5;

    void dg()
    {
        ++i;
    }

    WHOISRequest reqdg = new WHOISRequestImpl!(void delegate())(event, pl, &dg);
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

    auto reqfn = whoisRequest(event, pl, &fn);
    queue ~= reqfn;

    // delegate(ref IRCEvent)

    void dg2(ref IRCEvent thisEvent)
    {
        thisEvent.content = "blah";
    }

    auto reqdg2 = whoisRequest(event, pl, &dg2);
    queue ~= reqdg2;

    assert((reqdg2.event.content == "hirrpp"), event.content);
    reqdg2.trigger();
    assert((reqdg2.event.content == "blah"), event.content);

    // function(IRCEvent)

    static void fn2(IRCEvent thisEvent) { }

    auto reqfn2 = whoisRequest(event, pl, &fn2);
    queue ~= reqfn2;
}


// whoisRequest
/++
 +  Convenience function that returns a `WHOISRequestImpl` of the right type,
 +  *with* a payload attached.
 +
 +  Params:
 +      payload = Payload to attach to the `WHOISRequest`.
 +      event = `kameloso.ircdefs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS`
 +          results.
 +      fn = Function/delegate pointer to call upon receiving the results.
 +
 +  Returns:
 +      A `WHOISRequest` with template parameters inferred from the arguments
 +      passed to this function.
 +/
WHOISRequest whoisRequest(F, Payload)(Payload payload, IRCEvent event,
    PrivilegeLevel privilegeLevel, F fn) @safe
{
    return new WHOISRequestImpl!(F, Payload)(payload, event, privilegeLevel, fn);
}


// whoisRequest
/++
 +  Convenience function that returns a `WHOISRequestImpl` of the right type,
 +  *without* a payload attached.
 +
 +  Params:
 +      event = `kameloso.ircdefs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS`
 +          results.
 +      fn = Function/delegate pointer to call upon receiving the results.
 +
 +  Returns:
 +      A `WHOISRequest` with template parameters inferred from the arguments
 +      passed to this function.
 +/
WHOISRequest whoisRequest(F)(IRCEvent event, PrivilegeLevel privilegeLevel, F fn) @safe
{
    return new WHOISRequestImpl!F(event, privilegeLevel, fn);
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
 +  Plugin-specific state should be kept inside the `IRCPlugin` itself.
 +/
struct IRCPluginState
{
    import kameloso.common : CoreSettings, Labeled;
    import core.thread : Fiber;
    import std.concurrency : Tid;

    /++
     +  The current `kameloso.ircdefs.IRCBot`, containing information pertaining
     +  to bot in the bot in the context of the current (alive) connection.
     +/
    IRCBot bot;

    /// The current settings of the bot, non-specific to any plugins.
    CoreSettings settings;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
     +  Queued `WHOIS` requests and pertaining `kameloso.ircdefs.IRCEvent`s to
     +  replay.
     +
     +  The main loop iterates this after processing all on-event functions so
     +  as to know what nicks the plugin wants a `WHOIS` for. After the `WHOIS`
     +  response returns, the event bundled with the `WHOISRequest` will be
     +  replayed.
     +/
    WHOISRequest[string] whoisQueue;

    /++
     +  The list of awaiting `core.thread.Fiber`s, keyed by
     +  `kameloso.ircdefs.IRCEvent.Type`.
     +/
    Fiber[][IRCEvent.Type] awaitingFibers;

    /// The list of timed `core.thread.Fiber`s, labeled by UNIX time.
    Labeled!(Fiber, long)[] timedFibers;

    /// The next (Unix time) timestamp at which to call `periodically`.
    long nextPeriodical;
}


/++
 +  The tristate results from comparing a username with the admin or whitelist
 +  lists.
 +/
enum FilterResult { fail, pass, whois }


/++
 +  To what extent the annotated function demands its triggering
 +  `kameloso.ircdefs.IRCEvent`'s contents be prefixed with the bot's nickname.
 +/
enum NickPolicy
{
    ignored,     /// Any prefixes will be ignored.
    /++
     +  Message should begin with `kameloso.common.CoreSettings.prefix`
     +  (e.g. "`!`")
     +/
    direct,
    optional,    /// Message may begin with bot name, if so it will be stripped.
    required,    /// Message must begin with bot name, except in `QUERY` events.
    hardRequired,/// Message must begin with bot name, regardless of type.
}

/// Whether an annotated function should work in all channels or just in homes.
enum ChannelPolicy
{
    /++
     +  The annotated function will only trigger if the event happened in a
     +  home, where applicable (not all events have channels).
     +/
    home,

    /// The annotated function will trigger regardless of channel.
    any,
}


/// What level of privilege is needed to trigger an event.
enum PrivilegeLevel
{
    anyone, /// Anyone may trigger this event.
    whitelist, /// Only those of the `whitelist` class may trigger this event.
    admin, /// Only the administrators may trigger this event.
    ignore, /// Override privilege checks.
}


// BotCommand
/++
 +  Defines an IRC bot command, for people to trigger with messages.
 +
 +  If no `NickPolicy` is specified then it will default to `NickPolicy.direct`
 +  and look for `kameloso.common.CoreSettings.prefix` at the beginning of
 +  messages, to prefix the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotCommand
{
    /// The policy to which extent the command needs the bot's nickname.
    NickPolicy policy;

    /// The prefix string, one word with no spaces.
    string string_;

    /++
     +  Create a new `BotCommand` with the passed `policy` and trigger
     +  `string_`.
     +/
    this(const NickPolicy policy, const string string_) pure
    {
        this.policy = policy;
        this.string_ = string_;
    }

    /++
     +  Create a new `BotCommand` with a default `direct` policy and the passed
     +  trigger `string_`.
     +/
    this(const string string_) pure
    {
        this.policy = NickPolicy.direct;
        this.string_ = string_;
    }
}


// BotRegex
/++
 +  Defines an IRC bot regular expression, for people to trigger with messages.
 +
 +  If no `NickPolicy` is specified then it will default to `NickPolicy.direct`
 +  and look for `kameloso.common.CoreSettings.prefix` at the beginning of
 +  messages, to prefix the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotRegex
{
    import std.regex : Regex, regex;

    /// The policy to which extent the command needs the bot's nickname.
    NickPolicy policy;

    /++
     +  Regex engine to match incoming messages with.
     +
     +  May be compile-time `ctRegex` or normal `Regex`.
     +/
    Regex!char engine;

    /// Creates a new `BotRegex` with the passed `policy` and regex `engine`.
    this(const NickPolicy policy, Regex!char engine) pure
    {
        this.policy = policy;
        this.engine = engine;
    }

    /++
     +  Creates a new `BotRegex` with the passed `policy` and regex `expression`
     +  string.
     +/
    this(const NickPolicy policy, const string expression)
    {
        this.policy = policy;
        this.engine = expression.regex;
    }

    /// Creates a new `BotRegex` with the passed regex `engine`.
    this(Regex!char engine) pure
    {
        this.policy = NickPolicy.direct;
        this.engine = engine;
    }

    /// Creates a new `BotRegex` with the passed regex `expression` string.
    this(const string expression)
    {
        this.policy = NickPolicy.direct;
        this.engine = expression.regex;
    }
}


/++
 +  Annotation denoting that an event-handling function let other functions in
 +  the same module process after it.
 +/
struct Chainable;


/++
 +  Annotation denoting that an event-handling function is the end of a chain,
 +  letting no other functions in the same module be triggered after it has
 +  been.
 +
 +  This is not strictly neccessary since anything non-`Chainable` is implicitly
 +  `Terminating`, but we add it to silence warnings and in hopes of the code
 +  becoming more self-documenting.
 +/
struct Terminating;


/++
 +  Annotation denoting that we want verbose debug output of the plumbing when
 +  handling events, iterating through the module's event handler functions.
 +/
struct Verbose;


/++
 +  Annotation denoting that a function is part of an awareness mixin that
 +  should be processed *before* normal plugin functions.
 +/
struct AwarenessEarly;


/++
 +  Annotation denoting that a function is part of an awareness mixin that
 +  should be processed *after* normal plugin functions.
 +/
struct AwarenessLate;


/++
 +  Annotation denoting that a variable is to be as considered as settings for a
 +  plugin and thus should be serialised and saved in the configuration file.
 +/
struct Settings;


// Description
/++
 +  Describes an `kameloso.ircdefs.IRCEvent`-annotated handler function.
 +
 +  This is used to describe functions triggered by `BotCommand`s, in the help
 +  listing routine in `kameloso.plugins.chatbot`.
 +/
struct Description
{
    /// Description string.
    string string_;

    /// Creates a new `Description` with the passed `string_` description text.
    this(const string string_)
    {
        this.string_ = string_;
    }
}


// filterUser
/++
 +  Decides whether a nickname is known good (whitelisted/admin), known bad (not
 +  whitelisted/admin), or needs `WHOIS` (to tell if whitelisted/admin).
 +
 +  This is used to tell whether a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return `FilterResult.whois`.
 +  If the user's NickServ account is in the whitelist (or equals one of the
 +  bot's admins'), return `FilterResult.pass`. Else, return `FilterResult.fail`
 +  and deny use.
 +
 +  Params:
 +      state = The current `IRCPluginState` for context (`admins` and
 +          `whitelist` arrays, etc).
 +      event = `kameloso.ircdefs.IRCEvent` to filter.
 +
 +  Returns:
 +      A `FilterResult` saying the event should `pass`, `fail`, or that more
 +      information about the sender is needed via a `WHOIS` call.
 +/
FilterResult filterUser(const IRCPluginState state, const IRCEvent event) @safe
{
    import kameloso.constants : Timeout;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : Clock, SysTime;

    immutable user = event.sender;
    immutable now = Clock.currTime.toUnixTime;

    immutable timediff = (now - user.lastWhois);
    immutable isAdmin = state.bot.admins.canFind(user.account);
    immutable isWhitelisted = (user.class_ == IRCUser.Class.whitelist);
    immutable isBlacklisted = (user.class_ == IRCUser.Class.blacklist);

    if (user.account.length && (isAdmin || isWhitelisted))
    {
        return FilterResult.pass;
    }
    else if (isBlacklisted)
    {
        return FilterResult.fail;
    }
    else if ((!user.account.length && (timediff > Timeout.whois)) ||
        (!isWhitelisted && (timediff > 6 * Timeout.whois)))
    {
        return FilterResult.whois;
    }
    else
    {
        return FilterResult.fail;
    }
}

///
unittest
{
    import std.conv : text;
    import std.datetime.systime : Clock;

    IRCPluginState state;
    IRCEvent event;

    event.type = IRCEvent.Type.CHAN;
    event.sender.nickname = "zorael";

    immutable res1 = state.filterUser(event);
    assert((res1 == FilterResult.whois), res1.text);

    event.sender.account = "zorael";
    state.bot.admins = [ "zorael" ];

    immutable res2 = state.filterUser(event);
    assert((res2 == FilterResult.pass), res2.text);

    state.bot.admins = [ "harbl" ];
    event.sender.class_ = IRCUser.Class.whitelist;

    immutable res3 = state.filterUser(event);
    assert((res3 == FilterResult.pass), res3.text);

    event.sender.class_ = IRCUser.Class.anyone;
    event.sender.lastWhois = Clock.currTime.toUnixTime;

    immutable res4 = state.filterUser(event);
    assert((res4 == FilterResult.fail), res4.text);

    event.sender.class_ = IRCUser.Class.blacklist;
    event.sender.lastWhois = long.init;

    immutable res5 = state.filterUser(event);
    assert((res5 == FilterResult.fail), res5.text);
}


// IRCPluginImpl
/++
 +  Mixin that fully implements an `IRCPlugin`.
 +
 +  Uses compile-time introspection to call top-level functions to extend
 +  behaviour;
 +/
mixin template IRCPluginImpl(bool debug_ = false, string module_ = __MODULE__)
{
    import kameloso.common : Labeled;
    import core.thread : Fiber;
    import std.array : Appender;

    enum hasIRCPluginImpl = true;

    @safe:

    /// This plugin's `IRCPluginState` structure.
    IRCPluginState privateState;

    // onEvent
    /++
     +  Pass on the supplied `kameloso.ircdefs.IRCEvent` to functions annotated
     +  with the right `kameloso.ircdefs.IRCEvent.Type`s.
     +
     +  It also does checks for `ChannelPolicy`, `PrivilegeLevel` and
     +  `NickPolicy` where such is appropriate.
     +
     +  Params:
     +      event = Parsed `kameloso.ircdefs.IRCEvent` to dispatch to event
     +          handlers.
     +/
    void onEvent(const IRCEvent event) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.string : beginsWith, has, nom, stripPrefix, strippedLeft;
        import std.meta : AliasSeq, Filter, templateNot, templateOr;
        import std.traits : getSymbolsByUDA, isSomeFunction, getUDAs, hasUDA;
        import std.typecons : No, Yes;

        alias earlyAwareness(alias T) = hasUDA!(T, AwarenessEarly);
        alias lateAwareness(alias T) = hasUDA!(T, AwarenessLate);
        alias isAwarenessFunction = templateOr!(earlyAwareness, lateAwareness);
        alias isNormalPluginFunction = templateNot!isAwarenessFunction;

        alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEvent.Type));

        enum Next
        {
            continue_,
            repeat,
            return_,
        }

        Next handle(alias fun)(const IRCEvent event)
        {
            enum verbose = hasUDA!(fun, Verbose) || debug_;

            static if (verbose)
            {
                import kameloso.conv : Enum;
                import std.stdio : writeln, writefln;
                version(Cygwin_) import std.stdio : flush;
            }

            udaloop:
            foreach (eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
            {
                enum name = ()
                {
                    import kameloso.conv : Enum;
                    import kameloso.string : nom;
                    import std.format : format;

                    string pluginName = module_;
                    // pop two dots
                    pluginName.nom('.');
                    pluginName.nom('.');

                    return "[%s] %s (%s)".format(pluginName,__traits(identifier, fun),
                        Enum!(IRCEvent.Type).toString(eventTypeUDA));
                }();

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

                static if (verbose)
                {
                    writeln("-- ", name);
                    version(Cygwin_) stdout.flush();
                }

                static if (hasUDA!(fun, ChannelPolicy))
                {
                    enum policy = getUDAs!(fun, ChannelPolicy)[0];
                }
                else
                {
                    // Default policy if none given is `home`
                    enum policy = ChannelPolicy.home;
                }

                static if (verbose)
                {
                    writeln("...ChannelPolicy.", Enum!ChannelPolicy.toString(policy));
                    version(Cygwin_) stdout.flush();
                }

                with (ChannelPolicy)
                final switch (policy)
                {
                case home:
                    import std.algorithm.searching : canFind;

                    if (!event.channel.length)
                    {
                        // it is a non-channel event, like a `QUERY`
                    }
                    else if (!privateState.bot.homes.canFind(event.channel))
                    {
                        static if (verbose)
                        {
                            writeln("...ignore invalid channel ", event.channel);
                            version(Cygwin_) stdout.flush();
                        }

                        // channel policy does not match
                        return Next.continue_;  // next function
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
                        return Next.continue_;  // next function
                    }

                    foreach (commandUDA; getUDAs!(fun, BotCommand))
                    {
                        static assert(commandUDA.string_.length, name ~ " had an empty BotCommand string");

                        static if (verbose)
                        {
                            writefln(`...BotCommand "%s"`, commandUDA.string_);
                            version(Cygwin_) stdout.flush();
                        }

                        // Reset between iterations
                        mutEvent = event;

                        if (!privateState.nickPolicyMatches(commandUDA.policy, mutEvent))
                        {
                            static if (verbose)
                            {
                                writeln("...policy doesn't match; continue next BotCommand");
                                version(Cygwin_) stdout.flush();
                            }

                            continue;  // next BotCommand UDA
                        }

                        import std.string : toLower;

                        string thisCommand;

                        mutEvent.content = mutEvent.content.strippedLeft;

                        if (mutEvent.content.has!(Yes.decode)(' '))
                        {
                            thisCommand = mutEvent.content.nom!(Yes.decode)(' ');
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
                            static if (verbose)
                            {
                                writeln("...command matches!");
                                version(Cygwin_) stdout.flush();
                            }

                            mutEvent.aux = thisCommand;
                            break;  // finish this BotCommand
                        }
                    }
                }

                // Iff no match from BotCommands, evaluate BotRegexes
                static if (hasUDA!(fun, BotRegex))
                {
                    if (!mutEvent.aux.length)
                    {
                        if (!event.content.length)
                        {
                            // Event has a `BotRegex` set up but
                            // `event.content` is empty; cannot possibly be
                            // of interest.
                            return Next.continue_;  // next function
                        }

                        foreach (regexUDA; getUDAs!(fun, BotRegex))
                        {
                            static assert((regexUDA.ending == Regex!char.init),
                                name ~ " has an incomplete BotRegex");

                            if (!privateState.nickPolicyMatches(regexUDA.policy, event))
                            {
                                static if (verbose)
                                {
                                    writeln("...policy doesn't match; continue next BotRegex");
                                    version(Cygwin_) stdout.flush();
                                }

                                continue;  // next BotRegex UDA
                            }

                            // Reset between iterations
                            mutEvent = event;
                            string thisCommand;

                            if (mutEvent.content.has!(Yes.decode)(' '))
                            {
                                thisCommand = mutEvent.content.nom!(Yes.decode)(' ');
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
                                immutable hits = thisCommand.matchFirst(regexUDA.engine);

                                if (!hits.empty)
                                {
                                    mutEvent.aux = hits[0];
                                }
                            }
                            catch (const Exception e)
                            {
                                logger.warning("BotRegex exception: ", e.msg);
                                continue;  // next BotRegex
                            }

                            if (mutEvent.aux.length) continue udaloop;
                        }
                    }
                }

                static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
                {
                    // Bot{Command,Regex} exists but neither matched; skip
                    static if (verbose)
                    {
                        writeln("...neither BotCommand nor BotRegex matched; continue funloop");
                        version(Cygwin_) stdout.flush();
                    }

                    if (!mutEvent.aux.length) return Next.continue_; // next fun
                }
                else static if (!hasUDA!(fun, Chainable) &&
                    !hasUDA!(fun, Terminating) &&
                    ((eventTypeUDA == IRCEvent.Type.CHAN) ||
                    (eventTypeUDA == IRCEvent.Type.QUERY)))
                {
                    import kameloso.conv : Enum;
                    import std.format : format;

                    enum typestring = Enum!(IRCEvent.Type).toString(eventTypeUDA);
                    pragma(msg, "Note: %s is a wildcard %s event but is not Chainable nor Terminating"
                        .format(name, typestring));
                }

                static if (!hasUDA!(fun, PrivilegeLevel) && !isAwarenessFunction!fun)
                {
                    with (IRCEvent.Type)
                    {
                        import kameloso.conv : Enum;

                        alias U = eventTypeUDA;

                        enum message = module_ ~ '.' ~ __traits(identifier, fun) ~
                            " is annotated with user-facing IRCEvent.Type." ~
                            Enum!(IRCEvent.Type).toString(U) ~ " but is missing a PrivilegeLevel.";

                        static assert(!((U == CHAN) ||
                            (U == QUERY) ||
                            (U == EMOTE) ||
                            (U == JOIN) ||
                            (U == PART) ||
                            //(U == QUIT) ||
                            //(U == NICK) ||
                            (U == AWAY)),
                            message);
                    }
                }

                import std.meta   : AliasSeq, staticMap;
                import std.traits : Parameters, Unqual, arity;

                static if (hasUDA!(fun, PrivilegeLevel))
                {
                    enum privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];

                    static if (privilegeLevel != PrivilegeLevel.ignore)
                    {
                        static assert (__traits(compiles, .hasMinimalAuthentication),
                            module_ ~ " is missing MinimalAuthentication mixin " ~
                            "(needed for PrivilegeLevel checks).");
                    }

                    static if (verbose)
                    {
                        writeln("...PrivilegeLevel.", Enum!PrivilegeLevel.toString(privilegeLevel));
                        version(Cygwin_) stdout.flush();
                    }

                    with (PrivilegeLevel)
                    final switch (privilegeLevel)
                    {
                    case whitelist:
                    case admin:
                        immutable result = privateState.filterUser(mutEvent);

                        with (privateState)
                        with (FilterResult)
                        final switch (result)
                        {
                        case pass:
                            import std.algorithm.searching : canFind;

                            if ((privilegeLevel == admin) &&
                                !bot.admins.canFind(mutEvent.sender.account))
                            {
                                static if (verbose)
                                {
                                    writefln("...%s passed privilege check but isn't admin " ~
                                        "when admin is what we want; continue",
                                        mutEvent.sender.nickname);
                                    version(Cygwin_) stdout.flush();
                                }
                                return Next.continue_;
                            }
                            break;

                        case whois:
                            import kameloso.plugins.common : doWhois;

                            alias This = typeof(this);
                            alias Params = staticMap!(Unqual, Parameters!fun);
                            enum isIRCPluginParam(T) = is(T == IRCPlugin);

                            static if (verbose)
                            {
                                writefln("...%s WHOIS", typeof(this).stringof);
                                version(Cygwin_) stdout.flush();
                            }

                            static if (is(Params : AliasSeq!IRCEvent) ||
                                (arity!fun == 0))
                            {
                                this.doWhois(mutEvent, privilegeLevel, &fun);
                                return Next.continue_;
                            }
                            else static if (is(Params : AliasSeq!(This, IRCEvent)) ||
                                is(Params : AliasSeq!This))
                            {
                                this.doWhois(this, mutEvent, privilegeLevel, &fun);
                                return Next.continue_;
                            }
                            else static if (Filter!(isIRCPluginParam, Params).length)
                            {
                                pragma(msg, name);
                                pragma(msg, typeof(fun).stringof);
                                pragma(msg, Params);
                                static assert(0, "Function signature takes IRCPlugin instead of subclass plugin");
                            }
                            else
                            {
                                pragma(msg, name);
                                pragma(msg, typeof(fun).stringof);
                                pragma(msg, Params);
                                static assert(0, "Unknown event handler function signature");
                            }

                        case fail:
                            static if (verbose)
                            {
                                import kameloso.common : logger;
                                logger.warningf("...%s failed privilege check; continue", mutEvent.sender.nickname);
                            }
                            return Next.continue_;
                        }
                        break;

                    case anyone:
                        if (mutEvent.sender.class_ == IRCUser.Class.blacklist)
                        {
                            // Continue with the next function or abort?
                            return Next.continue_;
                        }
                        break;

                    case ignore:
                        break;
                    }
                }

                alias Params = staticMap!(Unqual, Parameters!fun);

                static if (verbose)
                {
                    writeln("...calling!");
                    version(Cygwin_) stdout.flush();
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
                    pragma(msg, name);
                    pragma(msg, typeof(fun).stringof);
                    pragma(msg, Params);
                    static assert(0, "Unknown event handler function signature");
                }

                static if (hasUDA!(fun, Chainable))
                {
                    // onEvent found an event and triggered a function, but
                    // it's Chainable and there may be more, so keep looking
                    break udaloop;  // drop down
                }
                else /*static if (hasUDA!(fun, Terminating))*/
                {
                    // The triggered function is not Chainable so return and
                    // let the main loop continue with the next plugin.
                    return Next.return_;
                }
            }

            return Next.continue_;
        }

        alias earlyFuns = Filter!(earlyAwareness, funs);
        alias lateFuns = Filter!(lateAwareness, funs);
        alias pluginFuns = Filter!(isNormalPluginFunction, funs);

        // Sanitise and try again once on UTF/Unicode exceptions

        void tryCatchHandle(funlist...)(const IRCEvent event)
        {
            import core.exception : UnicodeException;
            import std.utf : UTFException;
            import std.encoding : sanitize;

            foreach (fun; funlist)
            {
                try
                {
                    immutable next = handle!fun(event);

                    with (Next)
                    final switch (next)
                    {
                    case continue_:
                        continue;

                    case repeat:
                        // only repeat once so we don't endlessly loop
                        if (handle!fun(event) == continue_) continue;
                        else
                        {
                            return;
                        }

                    case return_:
                        return;
                    }
                }
                catch (const UTFException e)
                {
                    IRCEvent saneEvent = event;
                    saneEvent.content = sanitize(saneEvent.content);
                    handle!fun(cast(const)saneEvent);
                }
                catch (const UnicodeException e)
                {
                    IRCEvent saneEvent = event;
                    saneEvent.content = sanitize(saneEvent.content);
                    handle!fun(cast(const)saneEvent);
                }
            }
        }

        tryCatchHandle!earlyFuns(event);
        tryCatchHandle!pluginFuns(event);
        tryCatchHandle!lateFuns(event);
    }


    // this(IRCPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level `.initialise(IRCPlugin)` if it
     +  exists.
     +
     +  Params:
     +      state = The aggregate of all plugin state variables, making
     +          this the "original state" of the plugin.
     +/
    this(IRCPluginState state) @system
    {
        this.privateState = state;

        static if (__traits(compiles, .initialise))
        {
            .initialise(this);
        }
    }


    // postprocess
    /++
     +  Lets a plugin modify an `kameloso.ircdefs.IRCEvent` while it's begin
     +  constructed, before it's finalised and passed on to be handled.
     +/
    void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, .postprocess))
        {
            .postprocess(this, event);
        }
    }


    // initResources
    /++
     +  Writes plugin resources to disk, creating them if they don't exist.
     +/
    void initResources() @system
    {
        static if (__traits(compiles, .initResources))
        {
            .initResources(this);
        }
    }


    // deserialiseConfigFrom
    /++
     +  Loads configuration from disk.
     +
     +  This does not proxy a call but merely loads configuration from disk for
     +  all struct variables annotated `Settings`.
     +/
    string[][string] deserialiseConfigFrom(const string configFile)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.config : readConfigInto;
        import kameloso.meld : meldInto;
        import kameloso.traits : isStruct;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;
        import std.typecons : No, Yes;

        alias symbols = Filter!(isStruct, getSymbolsByUDA!(thisModule, Settings));

        string[][string] invalidEntries;

        foreach (ref symbol; symbols)
        {
            alias T = typeof(symbol);

            if (symbol != T.init)
            {
                // This symbol was already configured earlier;
                // --> this is a reconnect
                continue;
            }

            T tempSymbol;
            immutable theseInvalidEntries = configFile.readConfigInto(tempSymbol);

            foreach (immutable section, const sectionEntries; theseInvalidEntries)
            {
                invalidEntries[section] ~= sectionEntries;
            }

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

                T tempSymbol;
                const theseInvalidEntries = configFile.readConfigInto(tempSymbol);

                foreach (immutable section, const sectionEntries; theseInvalidEntries)
                {
                    invalidEntries[section] ~= sectionEntries;
                }

                tempSymbol.meldInto!(Yes.overwrite)(symbol);
            }
        }

        return invalidEntries;
    }


    // setSettingByName
    /++
     +  Change a plugin's `Settings`-annotated settings struct member by their
     +  string name.
     +
     +  This is used to allow for command-line argument to set any plugin's
     +  setting by only knowing its name.
     +
     +  Example:
     +  ---
     +  struct FooSettings
     +  {
     +      int bar;
     +  }
     +
     +  @Settings FooSettings settings;
     +
     +  setSettingByName("bar", 42);
     +  assert(settings.bar == 42);
     +  ---
     +
     +  Params:
     +      setting = String name of the struct member to set.
     +      value = String value to set it to (after converting it to the
     +          correct type).
     +/
    void setSettingByName(const string setting, const string value)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.common : logger;
        import kameloso.objmanip : setMemberByName;
        import kameloso.traits : isStruct;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;

        alias symbols = Filter!(isStruct, getSymbolsByUDA!(thisModule, Settings));
        bool success;

        foreach (ref symbol; symbols)
        {
            success = symbol.setMemberByName(setting, value);
            if (success) break;
        }

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                success = symbol.setMemberByName(setting, value);
                if (success) break;
            }
        }

        if (!success)
        {
            logger.warningf("No such %s plugin setting: %s", name, setting);
        }
    }


    // peekPlugins
    /++
     +  Lends a const reference to the array of `IRCPlugin`s to the plugin.
     +
     +  This is to allow for plugins to inspect eachother, notably for the
     +  `kameloso.plugins.chatbot.Chatbot` plugin to list all plugins'
     +  `BotCommand`s. This is not to be directly used, but rather to be called
     +  by the main loop's message-receiving after having been sent a
     +  `kameloso.common.ThreadMessage.PeekPlugins` thread message.
     +/
    void peekPlugins(IRCPlugin[] plugins, const IRCEvent event) @system
    {
        static if (__traits(compiles, .peekPlugins))
        {
            .peekPlugins(this, plugins, event);
        }
    }


    // printSettings
    /++
     +  Prints the plugin's `Settings`-annotated structs, with a hardcoded width
     +  to suit all the other plugins' settings member name lengths, to date.
     +
     +  It both prints module-level structs as well as structs in the
     +  `kameloso.ircdefs.IRCPlugin` (subtype) itself.
     +/
    void printSettings() const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.common : printObject;
        import kameloso.traits : isStruct;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;
        import std.typecons : Flag, No, Yes;

        alias moduleLevelSymbols = getSymbolsByUDA!(thisModule, Settings);

        foreach (symbol; Filter!(isStruct, moduleLevelSymbols))
        {
            printObject!(No.printAll)(symbol);
        }

        foreach (immutable i, symbol; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) &&
                (is(typeof(this.tupleof[i]) == struct)))
            {
                printObject!(No.printAll)(symbol);
            }
        }
    }


    // serialiseConfigInto
    /++
     +  Gathers the configuration text the plugin wants to contribute to the
     +  configuration file.
     +
     +  Example:
     +  ---
     +  Appender!string sink;
     +  sink.reserve(128);  // LDC fix
     +  serialiseConfigInto(sink);
     +  ---
     +
     +  Params:
     +      sink = Reference `std.array.Appender` to fill with plugin-specific
     +          settings text.
     +/
    void serialiseConfigInto(ref Appender!string sink) const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.config : serialise;
        import kameloso.traits : isStruct;
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
     +  Runs early after-connect routines, immediately after connection has been
     +  established.
     +/
    void start() @system
    {
        import std.meta : AliasSeq, staticMap;
        import std.traits : Parameters, Unqual;

        static if (__traits(compiles, .start))
        {
            import std.datetime.systime : SysTime;

            alias Params = staticMap!(Unqual, Parameters!(.start));

            static if (is(Params : AliasSeq!(typeof(this), SysTime)))
            {
                import std.datetime.systime : Clock;
                .start(this, Clock.currTime);
            }
            else
            {
                .start(this);
            }
        }
    }


    // teardown
    /++
     +  Deinitialises the plugin.
     +/
    void teardown() @system
    {
        static if (__traits(compiles, .teardown))
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
     +  Collects all `BotCommand` strings that this plugin offers and returns
     +  them alongside their `Description`s as an associative `string[string]`
     +  array.
     +
     +  Returns:
     +      Associative array of all `Descriptions`, keyed by
     +      `BotCommand.string_`s.
     +/
    string[string] commands() pure nothrow @property const
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
     +  This is needed to have `state` be part of the `IRCPlugin` *interface*,
     +  so `main.d` can access the property, albeit indirectly.
     +/
    pragma(inline)
    ref IRCPluginState state() pure nothrow @nogc @property
    {
        return this.privateState;
    }


    // periodically
    /++
     +  Calls `.periodically` on a plugin if the internal private timestamp says
     +  the interval since the last call has passed, letting the plugin do
     +  scheduled tasks.
     +/
    void periodically(const long now) @system
    {
        static if (__traits(compiles, .periodically))
        {
            if (now >= state.nextPeriodical)
            {
                .periodically(this);
            }
        }
    }


    // reload
    /++
     +  Reloads the plugin, where such makes sense.
     +/
    void reload() @system
    {
        static if (__traits(compiles, .reload))
        {
            .reload(this);
        }
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
 +/
mixin template MessagingProxy(bool debug_ = false, string module_ = __MODULE__)
{
    static import kameloso.messaging;
    import std.functional : partial;
    import std.typecons : Flag, No, Yes;

    enum hasMessagingProxy = true;

    // chan
    /++
     +  Sends a channel message.
     +/
    pragma(inline)
    alias chan(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.chan!quiet, privateState);

    // query
    /++
     +  Sends a private query message to a user.
     +/
    pragma(inline)
    alias query(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.query!quiet, privateState);

    // privmsg
    /++
     +  Sends either a channel message or a private query message depending on
     +  the arguments passed to it.
     +
     +  This reflects how channel messages and private messages are both the
     +  underlying same type; `PRIVMSG`.
     +
     +  It sends it in a throttled fashion, usable for long output when the bot
     +  may otherwise get kicked for spamming.
     +/
    pragma(inline)
    alias privmsg(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.privmsg!quiet, privateState);

    deprecated("All outgoing messages are now throttled. Use privmsg instead.")
    alias throttleline = privmsg;

    // emote
    /++
     +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
     +/
    pragma(inline)
    alias emote(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.emote!quiet, privateState);

    // mode
    /++
     +  Sets a channel mode.
     +
     +  This includes modes that pertain to a user in the context of a channel,
     +  like bans.
     +/
    pragma(inline)
    alias mode(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.mode!quiet, privateState);

    // topic
    /++
     +  Sets the topic of a channel.
     +/
    pragma(inline)
    alias topic(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.topic!quiet, privateState);

    // invite
    /++
     +  Invites a user to a channel.
     +/
    pragma(inline)
    alias invite(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.invite!quiet, privateState);

    // join
    /++
     +  Joins a channel.
     +/
    pragma(inline)
    alias join(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.join!quiet, privateState);

    // kick
    /++
     +  Kicks a user from a channel.
     +/
    pragma(inline)
    alias kick(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.kick!quiet, privateState);

    // part
    /++
     +  Leaves a channel.
     +
     +  Cannot seemingly be wrapped using `std.functional.partial` due to the
     +  default `= string.init` parameter.
     +/
    pragma(inline)
    void part(Flag!"quiet" quiet = No.quiet)(const string reason = string.init)
    {
        //alias part(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.part!quiet, privateState);
        return kameloso.messaging.quit!quiet(state, reason);
    }

    // quit
    /++
     +  Disconnects from the server, optionally with a quit reason.
     +
     +  Cannot seemingly be wrapped using `std.functional.partial` due to the
     +  default `= string.init` parameter.
     +/
    pragma(inline)
    void quit(Flag!"quiet" quiet = No.quiet)(const string reason = string.init)
    {
        //alias quit(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.quit!quiet, privateState);
        return kameloso.messaging.quit!quiet(state, reason);
    }

    // raw
    /++
     +  Sends text to the server, verbatim.
     +
     +  This is used to send messages of types for which there exist no helper
     +  functions.
     +/
    pragma(inline)
    alias raw(Flag!"quiet" quiet = No.quiet) = partial!(kameloso.messaging.raw!quiet, privateState);
}


// MinimalAuthenticator
/++
 +  Implements triggering of queued events in a plugin module.
 +/
mixin template MinimalAuthentication(bool debug_ = false, string module_ = __MODULE__)
{
    enum hasMinimalAuthentication = true;

    // onMinimalAuthenticationAccountInfoTargetMixin
    /++
     +  Replays any queued requests awaiting the result of a WHOIS.
     +
     +  This function was part of `UserAwareness` but triggering queued requests
     +  is too common to conflate with it.
     +
     +  Most of the time a plugin doesn't require a full `UserAwareness`; only
     +  those that need looking up users outside of the current event do. The
     +  persistency service allows for plugins to just read the information from
     +  the `kameloso.ircdefs.IRCUser` embedded in th event directly, and that's
     +  often enough.
     +
     +  General rule: if a plugin doesn't access `state.users`, it's probably
     +  going to be enough with only `MinimalAuthentication`.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    void onMinimalAuthenticationAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (plugin.state)
        {
            // See if there are any queued WHOIS requests to trigger
            if (auto request = event.target.nickname in whoisQueue)
            {
                import kameloso.constants : Timeout;
                import std.algorithm.searching : canFind;
                import std.datetime.systime : Clock;

                immutable now = Clock.currTime.toUnixTime;
                immutable then = request.when;

                if ((now - then) > Timeout.whois)
                {
                    // Entry is too old, request timed out. Remove it.
                    whoisQueue.remove(event.target.nickname);
                    return;
                }

                with (PrivilegeLevel)
                final switch (request.privilegeLevel)
                {
                case admin:
                    if (bot.admins.canFind(event.target.nickname))
                    {
                        request.trigger();
                        whoisQueue.remove(event.target.nickname);
                    }
                    break;

                case whitelist:
                    if (bot.admins.canFind(event.target.nickname) ||
                        (event.target.class_ == IRCUser.Class.whitelist))
                    {
                        request.trigger();
                        whoisQueue.remove(event.target.nickname);
                    }
                    break;

                case anyone:
                    if (event.target.class_ != IRCUser.Class.blacklist)
                    {
                        request.trigger();
                    }

                    // Always remove queued request even if blacklisted
                    whoisQueue.remove(event.target.nickname);
                    break;

                case ignore:
                    break;
                }
            }
        }
    }


    // onMinimalAuthenticationEndOfWHOISMixin
    /++
     +  Removes an exhausted `WHOIS` request from the queue upon end of `WHOIS`.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onMinimalAuthenticationEndOfWHOISMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.whoisQueue.remove(event.target.nickname);
    }
}


// UserAwareness
/++
 +  Implements *user awareness* in a plugin module.
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

    static if (!__traits(compiles, .hasMinimalAuthentication))
    {
        mixin MinimalAuthentication!(debug_, module_);
    }

    // onUserAwarenessQuitMixin
    /++
     +  Removes a user's `kameloso.ircdefs.IRCUser` entry from a plugin's user
     +  list upon them disconnecting.
     +/
    @(AwarenessLate)
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onUserAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.users.remove(event.sender.nickname);
    }


    // onUserAwarenessNickMixin
    /++
     +  Upon someone changing nickname, update their entry in the `IRCPlugin`'s
     +  `IRCPluginState.users` array to point to the new nickname.
     +
     +  Does *not* add a new entry if one doesn't exits, to counter the fact
     +  that `NICK` events don't belong to a channel, and as such can't be
     +  regulated with `ChannelPolicy` annotations. This way the user will only
     +  be moved if it was already added elsewhere. Else we'll leak users.
     +
     +  Removes the old entry after assigning it to the new key.
     +/
    @(AwarenessEarly)  // late?
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
        }
    }


    // onUserAwarenessCatchSenderMixin
    /++
     +  Catches a user's information and saves it in the plugin's
     +  `IRCPluginState.users` array of `kameloso.ircdefs.IRCUser`s.
     +
     +  `IRCEvent.Type.RPL_WHOISUSER` events carry values in the
     +  `IRCUser.lastWhois` field that we want to store.
     +
     +  `IRCEvent.Type.CHGHOST` occurs when a user changes host on some servers
     +  that allow for custom host addresses.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISUSER)
    @(IRCEvent.Type.CHGHOST)
    void onUserAwarenessCatchSenderMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.target);
    }


    // onUserAwarenessCatchSenderInHomeMixin
    /++
     +  Adds a user to the `IRCPlugin`'s `IRCPluginState.users` array,
     +  potentially including their services account name.
     +
     +  Servers with the (enabled) capability `extended-join` will include the
     +  account name of whoever joins in the event string. If it's there, catch
     +  the user into the user array so we don't have to `WHOIS` them later.
     +
     +  `IRCEvent.Type.RPL_WHOREPLY` is included here to deduplicate
     +  functionality.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.ACCOUNT)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @(ChannelPolicy.home)
    void onUserAwarenessCatchSenderInHomeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.sender);
    }


    // onUserAwarenessAccountInfoTargetMixin
    /++
     +  Records a user's services account by saving it to the user's
     +  `kameloso.ircdefs.IRCBot` in the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    void onUserAwarenessAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.users[event.target.nickname] = event.target;
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
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @(ChannelPolicy.home)
    void onUserAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : stripModesign;
        import kameloso.meld : meldInto;
        import kameloso.string : has, nom;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : canFind;
        import std.typecons : No, Yes;

        auto names = event.content.splitter(" ");

        if (names.empty || !names.front.has('!') || !names.front.has('@'))
        {
            // Empty or Freenode-like, where the list is just of nicknames with
            // possible mode prefix
            return;
        }

        with (plugin.state)
        {
            // SpotChat-like, names are in full nick!ident@address form
            foreach (immutable userstring; names)
            {
                string slice = userstring;
                immutable signed = slice.nom('!');

                // UserAwareness doesn't care about the modes
                immutable nickname = bot.server.stripModesign(signed);

                if (nickname == bot.nickname) continue;

                immutable ident = slice.nom('@');
                immutable address = slice;

                immutable newUser = IRCUser(nickname, ident, address);

                if (auto user = nickname in users)
                {
                    newUser.meldInto!(Yes.overwrite)(*user);
                }
                else
                {
                    users[nickname] = newUser;
                }
            }
        }
    }


    // onUserAwarenessEndOfWhoNames
    /++
     +  Rehashes, or optimises, the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array upon the end of a `WHO` or a `NAMES` reply.
     +
     +  These replies can list hundreds of users depending on the size of the
     +  channel. Once an associative array has grown sufficiently, it becomes
     +  inefficient. Rehashing it makes it take its new size into account and
     +  makes lookup faster.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFNAMES)
    @(IRCEvent.Type.RPL_ENDOFWHO)
    @(ChannelPolicy.home)
    void onUserAwarenessEndOfListMixin(IRCPlugin plugin)
    {
        plugin.state.users.rehash();
    }


    // onUserAwarenessPingMixin
    /++
     +  Rehash the internal `IRCPluginState.users` associative array of
     +  `kameloso.ircdefs.IRCUser`s, once every `hoursBetweenRehashes` hours.
     +
     +  We ride the periodicity of `PING` to get a natural cadence without
     +  having to resort to timed `core.thread.Fiber`s.
     +
     +  The number of hours is so far hardcoded but can be made configurable if
     +  there's a use-case for it.
     +
     +  This reimplements `IRCPlugin.periodically`.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.PING)
    void onUserAwarenessPingMixin(IRCPlugin plugin)
    {
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime.toUnixTime;
        enum hoursBetweenRehashes = 12;

        if (now >= plugin.state.nextPeriodical)
        {
            /// Once every few hours, rehash the `users` array.
            plugin.state.users.rehash();
            plugin.state.nextPeriodical = now + (hoursBetweenRehashes * 3600);
        }
    }
}


// ChannelAwareness
/++
 +  Implements *channel awareness* in a plugin module.
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
    static assert(__traits(compiles, .hasUserAwareness), module_ ~
        " is missing UserAwareness mixin (needed for ChannelAwareness).");

    enum hasChannelAwareness = true;


    // onChannelAwarenessSelfjoinMixin
    /++
     +  Create a new `kameloso.ircdefs.IRCChannel` in the the `IRCPlugin`'s
     +  `IRCPluginState.channels` associative array when the bot joins a
     +  channel.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.SELFJOIN)
    @(ChannelPolicy.home)
    void onChannelAwarenessSelfjoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel] = IRCChannel.init;
    }


    // onChannelAwarenessSelfpartMixin
    /++
     +  Removes an `kameloso.ircdefs.IRCChannel` from the internal list when the
     +  bot leaves it.
     +
     +  Additionally decrements the reference count of all known
     +  `kameloso.ircdefs.IRCUser`s that was in that channel, to keep track of
     +  when a user runs out of scope.
     +/
    @(AwarenessLate)
    @(Chainable)
    @(IRCEvent.Type.SELFPART)
    @(IRCEvent.Type.SELFKICK)
    @(ChannelPolicy.home)
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
     +  Adds a user as being part of a channel when they join one.
     +
     +  Increments the `kameloso.ircdefs.IRCUser`'s reference count, so that we
     +  know the user is in one more channel that we're monitoring.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @(ChannelPolicy.home)
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
     +  Removes a user from being part of a channel when they leave one.
     +
     +  Decrements the user's reference count, so we know that it is in one
     +  channel less now (and should possibly be removed if it is no longer in
     +  any we're tracking).
     +/
    @(AwarenessLate)
    @(Chainable)
    @(IRCEvent.Type.PART)
    @(ChannelPolicy.home)
    void onChannelAwarenessPartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        with (plugin.state)
        {
            immutable userIndex = channels[event.channel].users
                .countUntil(event.sender.nickname);

            assert((userIndex != -1), "Tried to part a user that wasn't there: " ~ event.sender.nickname);

            channels[event.channel].users = channels[event.channel].users.remove(userIndex);

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
     +  Upon someone changing nickname, update their entry in the
     +  `IRCPluginState.users` associative array point to the new nickname.
     +
     +  Removes the old entry.
     +/
    @(AwarenessEarly)
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
    @(AwarenessLate)
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
     +  Update the entry for an `kameloso.ircdefs.IRCChannel` if someone changes
     +  the topic of it.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.TOPIC)
    @(IRCEvent.Type.RPL_TOPIC)
    @(ChannelPolicy.home)
    void onChannelAwarenessTopicMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel].topic = event.content;
    }


    // onChannelAwarenessCreationTime
    /++
     +  Stores the timestamp of when a channel was created.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_CREATIONTIME)
    @(ChannelPolicy.home)
    void onChannelAwarenessCreationTime(IRCPlugin plugin, const IRCEvent event)
    {
        import std.conv : to;
        plugin.state.channels[event.channel].created = event.aux.to!long;
    }


    // onChannelAwarenessModeMixin
    /++
     +  Sets a mode for a channel.
     +
     +  Most modes replace others of the same type, notable exceptions being
     +  bans and mode exemptions. We let `kameloso.irc.setMode` take care of
     +  that.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.MODE)
    @(ChannelPolicy.home)
    void onChannelAwarenessModeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;
        plugin.state.channels[event.channel].setMode(event.aux, event.content, plugin.state.bot.server);
    }


    // onChannelAwarenessWHOReplyMixin
    /++
     +  Adds a user as being part of a channel upon receiving the reply from the
     +  request for info on all the participants.
     +
     +  This events includes all normal fields like ident and address, but not
     +  their channel modes (e.g. `@` for operator).
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @(ChannelPolicy.home)
    void onChannelAwarenessWHOReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.searching : canFind;
        import std.string : representation;

        // User awareness bits add the IRCUser
        with (plugin.state)
        {
            if (event.aux.length)
            {
                // Register operators, half-ops, voiced etc
                // Can be more than one if multi-prefix capability is enabled
                // Server-sent string, can assume ASCII (@,%,+...) and go char
                // by char
                foreach (immutable modesign; event.aux.representation)
                {
                    if (auto modechar = modesign in bot.server.prefixchars)
                    {
                        import kameloso.irc : setMode;
                        channels[event.channel].setMode(*modechar, event.target.nickname, bot.server);
                    }
                    /*else
                    {
                        logger.warningf(`Invalid modesign in RPL_WHOREPLY: "%s" ` ~
                            `The server did not advertise it!`, modesign);
                    }*/
                }
            }

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
     +  Adds users as being part of a channel upon receiving the reply from the
     +  request for a list of all the participants.
     +
     +  On some servers this does not include information about the users, only
     +  their nickname and their channel mode (e.g. `@` for operator), but other
     +  servers express the users in the full `user!ident@address` form. It's
     +  not the job of `ChannelAwareness` to create `kameloso.ircdefs.IRCUser`s
     +  out of them, but we need a skeletal `kameloso.ircdefs.IRCUser` at least,
     +  to increment the refcount of.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @(ChannelPolicy.home)
    void onChannelAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : stripModesign;
        import kameloso.string : has, nom;
        import std.algorithm.iteration : splitter;
        import std.algorithm.searching : canFind;
        import std.string : representation;

        if (!event.content.length) return;

        auto names = event.content.splitter(" ");

        with (plugin.state)
        {
            foreach (immutable userstring; names)
            {
                string slice = userstring;
                string nickname;

                if (names.front.has('!') && names.front.has('@'))
                {
                    // SpotChat-like, names are in full nick!ident@address form
                    nickname = slice.nom('!');
                }
                else
                {
                    // Freenode-like, only a nickname with possible @%+ prefix
                    nickname = userstring;
                }

                string modesigns;
                nickname = bot.server.stripModesign(nickname, modesigns);

                // Register operators, half-ops, voiced etc
                // Can be more than one if multi-prefix capability is enabled
                // Server-sent string, can assume ASCII (@,%,+...) and go char
                // by char
                foreach (immutable modesign; modesigns.representation)
                {
                    if (auto modechar = modesign in bot.server.prefixchars)
                    {
                        import kameloso.irc : setMode;
                        channels[event.channel].setMode(*modechar, nickname, bot.server);
                    }
                    else
                    {
                        logger.warning("Invalid modesign in RPL_NAMREPLY: ", modesign);
                    }
                }

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
                    user.nickname = nickname;
                }

                ++(*user).refcount;
            }
        }
    }


    // onChannelAwarenessModeListsMixin
    /++
     +  Adds the list of banned users to a tracked channel's list of modes.
     +
     +  Bans are just normal A-mode channel modes that are paired with a user
     +  and that don't overwrite other bans (can be stacked).
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_BANLIST)
    @(IRCEvent.Type.RPL_EXCEPTLIST)
    @(IRCEvent.Type.RPL_INVITELIST)
    @(IRCEvent.Type.RPL_REOPLIST)
    @(IRCEvent.Type.RPL_QUIETLIST)
    @(ChannelPolicy.home)
    void onChannelAwarenessModeListsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;
        import std.conv : to;

        // :kornbluth.freenode.net 367 kameloso #flerrp huerofi!*@* zorael!~NaN@2001:41d0:2:80b4:: 1513899527
        // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
        // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
        // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101

        with (IRCEvent.Type)
        with (plugin.state)
        {
            // Map known list types to their modechars
            immutable ubyte[IRCEvent.Type.RPL_QUIETLIST+1] modecharsByType =
            [
                RPL_BANLIST : 'b',
                RPL_EXCEPTLIST : plugin.state.bot.server.exceptsChar,
                RPL_INVITELIST : plugin.state.bot.server.invexChar,
                RPL_REOPLIST : 'R',
                RPL_QUIETLIST : 'q',
            ];

            channels[event.channel].setMode((cast(char)modecharsByType[event.type]).to!string,
                event.content, plugin.state.bot.server);
        }
    }


    // onChannelAwarenessChannelModeIs
    /++
     +  Adds the modes of a channel to a tracked channel's mode list.
     +/
    @(AwarenessEarly)
    @(Chainable)
    @(IRCEvent.Type.RPL_CHANNELMODEIS)
    @(ChannelPolicy.home)
    void onChannelAwarenessChannelModeIs(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc : setMode;

        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        plugin.state.channels[event.channel].setMode(event.aux, event.content, plugin.state.bot.server);
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
 +  Params:
 +      privateState = `IRCPluginState` of the calling `IRCPlugin`.
 +      policy = Policy to apply.
 +      mutEvent = Reference to the mutable `kameloso.ircdefs.IRCEvent` we're
 +          considering.
 +
 +  Returns:
 +      `true` if the message is in a context where the event matches the
 +      `policy`, `false` if not.
 +
 +  TODO:
 +      Support for verbose.
 +/
bool nickPolicyMatches(const IRCPluginState privateState, const NickPolicy policy, ref IRCEvent mutEvent) @safe
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
                writefln("starts with prefix (%s)", settings.prefix);
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
                writeln(name, "but it is a query, consider optional");
                version(Cygwin_) stdout.flush();
            }*/
            goto case optional;
        }
        goto case hardRequired;

    case hardRequired:
        if (content.beginsWith('@'))
        {
            content = content[1..$];
        }

        if (content.beginsWith(bot.nickname) && (content.length > bot.nickname.length))
        {
            /*static if (verbose)
            {
                writefln("%s trailing character '%s'", name, content[bot.nickname.length]);
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
 +  Catch an `kameloso.ircdefs.IRCUser`, saving it to the `IRCPlugin`'s
 +  `IRCPluginState.users` array.
 +
 +  If a user already exists, meld the new information into the old one.
 +
 +  Params:
 +      overwrite = Whether the catch should completely overwrite any old
 +          entries, or if they should be conservatively melded.
 +      plugin = Current `IRCPlugin`.
 +      newUser = The `kameloso.ircdefs.IRCUser` to catch.
 +/
void catchUser(Flag!"overwrite" overwrite = Yes.overwrite)
    (IRCPlugin plugin, IRCUser newUser) pure nothrow @safe
{
    import kameloso.meld : meldInto;

    if (!newUser.nickname.length || (newUser.nickname == plugin.state.bot.nickname))
    {
        return;
    }

    with (plugin)
    {
        // Twitch nicknames are always the same as the user accounts; the
        // displayed name/alias is sent separately as a "display-name" IRCv3 tag
        if (state.bot.server.daemon == IRCServer.Daemon.twitch)
        {
            newUser.account = newUser.nickname;
        }

        if (auto user = newUser.nickname in state.users)
        {
            newUser.meldInto!overwrite(*user);
        }
        else
        {
            state.users[newUser.nickname] = newUser;
        }
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
 +      plugin = Current `IRCPlugin`.
 +      payload = Payload to attach to the `WHOISRequest`, generally an
 +          `kameloso.ircdefs.IRCEvent` to replay once the `WHOIS` result
 +          return.
 +      event = `kameloso.ircdefs.IRCEvent` that instigated this `WHOIS` call.
 +      privilegeLevel = Privilege level to compare the user with.
 +      fn = Function/delegate pointer to call when the results return.
 +/
void doWhois(F, Payload)(IRCPlugin plugin, Payload payload, const IRCEvent event,
    PrivilegeLevel privilegeLevel, F fn)
{
    import kameloso.constants : Timeout;
    import std.datetime.systime : Clock;

    immutable user = event.sender;
    immutable now = Clock.currTime.toUnixTime;

    if ((now - user.lastWhois) < Timeout.whois)
    {
        return;
    }

    with (plugin)
    {
        static if (!is(Payload == typeof(null)))
        {
            state.whoisQueue[user.nickname] = whoisRequest(payload, event, privilegeLevel, fn);
        }
        else
        {
            state.whoisQueue[user.nickname] = whoisRequest(state, event, privilegeLevel, fn);
        }
    }
}

/// Ditto
void doWhois(F)(IRCPlugin plugin, const IRCEvent event, PrivilegeLevel privilegeLevel, F fn)
{
    return doWhois!(F, typeof(null))(plugin, null, event, privilegeLevel, fn);
}


// addChannelUserMode
/++
 +  Adds a channel mode to a channel, to elevate or demote a participating user
 +  to/from a prefixed mode, like operator, halfop and voiced.
 +
 +  This is done by populating the `mods` associative array of
 +  `IRCPluginState.channel[channelName]`, keyed by the *modechar* of the mode
 +  (o for +o and @, v for +v and +, etc) with values of `string[]` arrays of
 +  nicknames with that mode ("prefix").
 +
 +  Params:
 +      plugin = Current `IRCPlugin`.
 +      channel = Reference to the channel to add/remove the mode to/from.
 +      modechar = Mode character, e.g. o for @, v for +.
 +      nickname = Nickname the modechange relates to.
 +/
void addChannelUserMode(IRCPlugin plugin, ref IRCChannel channel,
    const char modechar, const string nickname) pure nothrow @safe
{
    import std.algorithm.searching : canFind;

    with (plugin.state)
    {
        // Create the prefix mod array if it doesn't exist
        auto modslist = modechar in channel.mods;
        if (!modslist)
        {
            channel.mods[modechar] = [ nickname ];
            return;
        }

        if (!(*modslist).canFind(nickname))
        {
            (*modslist) ~= nickname;
        }
    }
}


// applyCustomSettings
/++
 +  Changes a setting of a plugin, given both the names of the plugin and the
 +  setting, in string form.
 +
 +  This merely iterates the passed `plugins` and calls their `setSettingByName`
 +  methods.
 +
 +  Params:
 +      plugins = Array of all `IRCPlugin`s.
 +      customSettings = Array of custom settings to apply to plugins' own
 +          setting, in the string forms of "`plugin.setting=value`".
 +/
void applyCustomSettings(IRCPlugin[] plugins, string[] customSettings) @trusted
{
    import kameloso.common : logger;
    import kameloso.string : has, nom;
    import std.string : toLower;

    top:
    foreach (immutable line; customSettings)
    {
        string slice = line;
        string pluginstring;
        string setting;
        string value;

        if (!slice.has!(Yes.decode)("."))
        {
            logger.warning("Bad plugin.setting=value format");
            continue;
        }

        pluginstring = slice.nom!(Yes.decode)(".").toLower;

        if (slice.has!(Yes.decode)("="))
        {
            setting = slice.nom!(Yes.decode)("=");
            value = slice;
        }
        else
        {
            setting = slice;
            value = "true";
        }

        if (pluginstring == "core")
        {
            import kameloso.common : initLogger, settings;
            import kameloso.objmanip : setMemberByName;

            settings.setMemberByName(setting, value);

            if ((setting == "monochrome") || (setting == "brightTerminal"))
            {
                initLogger(settings.monochrome, settings.brightTerminal);
            }

            // FIXME: Re-evaluate whether plugins should keep a copy of the settings
            foreach (plugin; plugins)
            {
                plugin.state.settings.setMemberByName(setting, value);
            }

            continue top;
        }
        else
        {
            foreach (plugin; plugins)
            {
                if (plugin.name != pluginstring) continue;
                plugin.setSettingByName(setting, value);
                continue top;
            }
        }

        logger.warning("Invalid plugin: ", pluginstring);
    }
}


// delayFiber
/++
    +  Queues a `core.thread.Fiber` to be called at a point n seconds later, by
    +  appending it to `timedFibers`.
    +
    +  It only supports a precision of a *worst* case of
    +  `kameloso.constants.Timeout.receive` * 3 + 1 seconds, but generally less
    +  than that. See the main loop for more information.
    +/
void delayFiber(IRCPlugin plugin, Fiber fiber, const long secs)
{
    import kameloso.common : labeled;
    import std.datetime.systime : Clock;

    immutable time = Clock.currTime.toUnixTime + secs;
    plugin.state.timedFibers ~= labeled(fiber, time);
}

/++
 +  The is not a plugin by itself but contains code common to all plugins,
 +  without which they will *not* function.
 +
 +  It is mandatory if you plan to use any form of plugin. Indeed, the very
 +  definition of an `IRCPlugin` is in here.
 +/
module kameloso.plugins.common;

import kameloso.irc.common : IRCClient;
import kameloso.irc.defs;

import core.thread : Fiber;
import std.typecons : Flag, No, Yes;

//version = TwitchWarnings;


// 2.079.0 getSymolsByUDA
/++
 +  2.079.0 has a bug that breaks plugin processing completely. It's fixed in
 +  patch .1 (2.079.1), but there's no API for knowing the patch number.
 +
 +  Infer it by testing for the broken behaviour and warn (during compilation).
 +/
private
static if (__VERSION__ == 2079L)
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
    @safe:

    /++
     +  Returns a reference to the current `IRCPluginState` of the plugin.
     +
     +  Returns:
     +      Reference to an `IRCPluginState`.
     +/
    ref inout(IRCPluginState) state() inout pure nothrow @nogc @property;

    /// Executed to let plugins modify an event mid-parse.
    void postprocess(ref IRCEvent) @system;

    /// Executed upon new IRC event parsed from the server.
    void onEvent(const IRCEvent) @system;

    /// Executed when the plugin is requested to initialise its disk resources.
    void initResources() @system;

    /// Executed during setup to let plugins read settings from disk.
    string[][string] deserialiseConfigFrom(const string);

    /// Executed when gathering things to put in the configuration file.
    import std.array : Appender;
    void serialiseConfigInto(ref Appender!string) const;

    /++
     +  Executed during start if we want to change a setting by its string name.
     +
     +  Returns:
     +      Boolean of whether the set succeeded or not.
     +/
    bool setSettingByName(const string, const string);

    /// Executed when connection has been established.
    void start() @system;

    /// Executed when we want a plugin to print its Settings struct.
    void printSettings() @system const;

    /// Executed during shutdown or plugin restart.
    void teardown() @system;

    /++
     +  Returns the name of the plugin, sliced off the module name.
     +
     +  Returns:
     +      The string name of the plugin.
     +/
    string name() @property const;

    /++
     +  Returns an array of the descriptions of the commands a plugin offers.
     +
     +  Returns:
     +      An associative `Description[string]` array.
     +/
    Description[string] commands() pure nothrow @property const;

    /++
     +  Call a plugin to perform its periodic tasks, iff the time is equal to or
     +  exceeding `nextPeriodical`.
     +/
    void periodically(const long) @system;

    /// Reloads the plugin, where such is applicable.
    void reload() @system;

    /// Executed when a bus message arrives from another plugin.
    import kameloso.thread : Sendable;
    void onBusMessage(const string, shared Sendable content) @system;
}


// WHOISRequest
/++
 +  A queued event to be replayed upon a `WHOIS` request response.
 +
 +  It is abstract; all objects must be of a concrete `WHOISRequestImpl` type.
 +/
abstract class WHOISRequest
{
    /// Stored `kameloso.irc.defs.IRCEvent` to replay.
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
 +  returns we trigger the object and the original `kameloso.irc.defs.IRCEvent`
 +  is replayed.
 +
 +  Params:
 +      F = Some function type.
 +      Payload = Optional payload type.
 +/
final class WHOISRequestImpl(F, Payload = typeof(null)) : WHOISRequest
{
@safe:
    /// Stored function pointer/delegate.
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the `kameloso.irc.defs.IRCEvent`.
        Payload payload;

        /++
         +  Create a new `WHOISRequestImpl` with the passed variables.
         +
         +  Params:
         +      payload = Payload of templated type `Payload` to attach to this
         +          `WHOISRequestImpl`.
         +      event = `kameloso.irc.defs.IRCEvent` to attach to this
         +          `WHOISRequestImpl`.
         +      privilegeLevel = The privilege level required to trigger the
         +          passed function.
         +      fn = Function pointer to call with the attached payloads when
         +          the request is triggered.
         +/
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
        /++
         +  Create a new `WHOISRequestImpl` with the passed variables.
         +
         +  Params:
         +      payload = Payload of templated type `Payload` to attach to this
         +          `WHOISRequestImpl`.
         +      fn = Function pointer to call with the attached payloads when
         +          the request is triggered.
         +/
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
     +  `kameloso.irc.defs.IRCEvent` and/or `Payload`.
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
 +      event = `kameloso.irc.defs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS` results.
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
 +      event = `kameloso.irc.defs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS` results.
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
 +  functions, since any state could be passed to it with variables of this type.
 +
 +  Plugin-specific state should be kept inside the `IRCPlugin` itself.
 +/
struct IRCPluginState
{
    import kameloso.common : CoreSettings, Labeled;
    import core.thread : Fiber;
    import std.concurrency : Tid;

    /++
     +  The current `kameloso.irc.common.IRCClient`, containing information pertaining
     +  to the bot in the context of the current (alive) connection.
     +/
    IRCClient client;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
     +  Queued `WHOIS` requests and pertaining `kameloso.irc.defs.IRCEvent`s to
     +  replay.
     +
     +  The main loop iterates this after processing all on-event functions so
     +  as to know what nicks the plugin wants a `WHOIS` for. After the `WHOIS`
     +  response returns, the event bundled with the `WHOISRequest` will be replayed.
     +/
    WHOISRequest[][string] whoisQueue;

    /++
     +  The list of awaiting `core.thread.Fiber`s, keyed by
     +  `kameloso.irc.defs.IRCEvent.Type`.
     +/
    Fiber[][IRCEvent.Type] awaitingFibers;

    /// The list of timed `core.thread.Fiber`s, labeled by UNIX time.
    Labeled!(Fiber, long)[] timedFibers;

    /// The next (Unix time) timestamp at which to call `periodically`.
    long nextPeriodical;
}


/++
 +  The tristate results from comparing a username with the admin or whitelist lists.
 +/
enum FilterResult { fail, pass, whois }


/++
 +  To what extent the annotated function demands its triggering
 +  `kameloso.irc.defs.IRCEvent`'s contents be prefixed with the bot's nickname.
 +/
enum PrefixPolicy
{
    direct,   /// Message will be treated as-is without looking for prefixes.
    prefixed, /// Message should begin with `kameloso.common.CoreSettings.prefix` (e.g. "`!`")
    optionalNickname, /// Message may begin with bot name, if so it will be stripped.
    requiredNickname, /// Message must begin with bot name, except in `QUERY` events.
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
    ignore = 0, /// Override privilege checks.
    anyone = 1, /// Anyone may trigger this event.
    whitelist = 2, /// Only those of the `whitelist` class may trigger this event.
    admin = 3, /// Only the administrators may trigger this event.
}


// BotCommand
/++
 +  Defines an IRC bot command, for people to trigger with messages.
 +
 +  If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.prefixed`
 +  and look for `kameloso.common.CoreSettings.prefix` at the beginning of
 +  messages, to prefix the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotCommand
{
    /// The policy to which extent the command needs the bot's nickname.
    PrefixPolicy policy;

    /// The prefix string, one word with no spaces.
    string string_;

    /++
     +  Create a new `BotCommand` with the passed `policy` and trigger `string_`.
     +/
    this(const PrefixPolicy policy, const string string_) pure
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
        this.policy = PrefixPolicy.prefixed;
        this.string_ = string_;
    }
}


// BotRegex
/++
 +  Defines an IRC bot regular expression, for people to trigger with messages.
 +
 +  If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.prefixed`
 +  and look for `kameloso.common.CoreSettings.prefix` at the beginning of
 +  messages, to prefix the `string_`. (Usually "`!`", making it "`!command`".)
 +/
struct BotRegex
{
    import std.regex : Regex, regex;

    /// The policy to which extent the command needs the bot's nickname.
    PrefixPolicy policy;

    /++
     +  Regex engine to match incoming messages with.
     +
     +  May be compile-time `ctRegex` or normal `Regex`.
     +/
    Regex!char engine;

    /// Creates a new `BotRegex` with the passed `policy` and regex `engine`.
    this(const PrefixPolicy policy, Regex!char engine) pure
    {
        this.policy = policy;
        this.engine = engine;
    }

    /++
     +  Creates a new `BotRegex` with the passed `policy` and regex `expression` string.
     +/
    this(const PrefixPolicy policy, const string expression)
    {
        this.policy = policy;
        this.engine = expression.regex;
    }

    /// Creates a new `BotRegex` with the passed regex `engine`.
    this(Regex!char engine) pure
    {
        this.policy = PrefixPolicy.prefixed;
        this.engine = engine;
    }

    /// Creates a new `BotRegex` with the passed regex `expression` string.
    this(const string expression)
    {
        this.policy = PrefixPolicy.prefixed;
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
 +  letting no other functions in the same module be triggered after it has been.
 +
 +  This is not strictly necessary since anything non-`Chainable` is implicitly
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
 +  Annotation denoting that a function is part of an awareness mixin, and at
 +  what point it should be processed.
 +/
enum Awareness
{
    setup,
    early,
    late,
    cleanup,
}


/++
 +  Annotation denoting that a variable is to be as considered as settings for a
 +  plugin and thus should be serialised and saved in the configuration file.
 +/
struct Settings;


// Description
/++
 +  Describes an `kameloso.irc.defs.IRCEvent`-annotated handler function.
 +
 +  This is used to describe functions triggered by `BotCommand`s, in the help
 +  listing routine in `kameloso.plugins.chatbot`.
 +/
struct Description
{
    /// Description string.
    string string_;

    /// Command usage syntax help string.
    string syntax;

    /// Creates a new `Description` with the passed `string_` description text.
    this(const string string_, const string syntax = string.init)
    {
        this.string_ = string_;
        this.syntax = syntax;
    }
}


/++
 +  Annotation denoting that a variable is the basename of a *resource* file or directory.
 +/
struct Resource;


/++
 +  Annotation denoting that a variable is the basename of a *configuration*
 +  file or directory.
 +/
struct Configuration;


/++
 +  Annotation denoting that a variable enables and disables a plugin.
 +/
struct Enabler;


// filterUser
/++
 +  Decides if a nickname is known good (whitelisted/admin), known bad (not
 +  whitelisted/admin), or needs `WHOIS` (to tell if whitelisted/admin).
 +
 +  This is used to tell whether or not a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return `FilterResult.whois`.
 +  If the user's NickServ account is in the whitelist (or equals one of the
 +  bot's admins'), return `FilterResult.pass`. Else, return `FilterResult.fail`
 +  and deny use.
 +
 +  Params:
 +      event = `kameloso.irc.defs.IRCEvent` to filter.
 +      level = The `PrivilegeLevel` context in which this user should be filtered.
 +
 +  Returns:
 +      A `FilterResult` saying the event should `pass`, `fail`, or that more
 +      information about the sender is needed via a `WHOIS` call.
 +/
FilterResult filterUser(const IRCEvent event, const PrivilegeLevel level) @safe
{
    import kameloso.constants : Timeout;
    import std.datetime.systime : Clock, SysTime;

    immutable user = event.sender;
    immutable now = Clock.currTime.toUnixTime;
    immutable timediff = (now - user.lastWhois);

    immutable isBlacklisted = (user.class_ == IRCUser.Class.blacklist);

    if (user.account.length)
    {
        immutable whoisExpired = (timediff > 6 * Timeout.whoisRetry);
        immutable isAdmin = (user.class_ == IRCUser.Class.admin);  // Trust in persistence.d
        immutable isWhitelisted = (user.class_ == IRCUser.Class.whitelist);
        immutable isAnyone = (user.class_ == IRCUser.Class.anyone);
        //immutable isSpecial = (user.class_ == IRCUser.Class.special);

        if (isAdmin && (level <= PrivilegeLevel.admin))
        {
            return FilterResult.pass;
        }
        else if (isWhitelisted && (level <= PrivilegeLevel.whitelist))
        {
            return FilterResult.pass;
        }
        else if (isAnyone && ((level <= PrivilegeLevel.anyone) || whoisExpired))
        {
            return FilterResult.pass;
        }
        else if ((level == PrivilegeLevel.ignore) && !isBlacklisted)
        {
            return FilterResult.pass;
        }
        /*else if (isBlacklisted || isSpecial)
        {
            return FilterResult.fail;
        }*/
    }
    else
    {
        if (isBlacklisted)
        {
            // Should always be ignored
        }
        else if (level == PrivilegeLevel.ignore)
        {
            return FilterResult.pass;
        }
        else if (timediff > Timeout.whoisRetry)
        {
            return FilterResult.whois;
        }
    }

    return FilterResult.fail;
}

///
unittest
{
    import kameloso.conv : Enum;
    import std.datetime.systime : Clock;

    IRCEvent event;
    PrivilegeLevel level = PrivilegeLevel.admin;

    event.type = IRCEvent.Type.CHAN;
    event.sender.nickname = "zorael";

    immutable res1 = filterUser(event, level);
    assert((res1 == FilterResult.whois), Enum!FilterResult.toString(res1));

    event.sender.class_ = IRCUser.Class.admin;
    event.sender.account = "zorael";

    immutable res2 = filterUser(event, level);
    assert((res2 == FilterResult.pass), Enum!FilterResult.toString(res2));

    event.sender.class_ = IRCUser.Class.whitelist;

    immutable res3 = filterUser(event, level);
    assert((res3 == FilterResult.fail), Enum!FilterResult.toString(res3));

    event.sender.class_ = IRCUser.Class.anyone;
    event.sender.lastWhois = Clock.currTime.toUnixTime;

    immutable res4 = filterUser(event, level);
    assert((res4 == FilterResult.fail), Enum!FilterResult.toString(res4));

    event.sender.class_ = IRCUser.Class.blacklist;
    event.sender.lastWhois = long.init;

    immutable res5 = filterUser(event, level);
    assert((res5 == FilterResult.fail), Enum!FilterResult.toString(res5));
}


// IRCPluginImpl
/++
 +  Mixin that fully implements an `IRCPlugin`.
 +
 +  Uses compile-time introspection to call top-level functions to extend behaviour;
 +/
version(WithPlugins)
mixin template IRCPluginImpl(bool debug_ = false, string module_ = __MODULE__)
{
    import core.thread : Fiber;

    enum hasIRCPluginImpl = true;

    @safe:

    /// This plugin's `IRCPluginState` structure.
    IRCPluginState privateState;

    /++
     +  Introspects the current plugin, looking for a `Settings`-annotated struct
     +  member that has a bool annotated with `Enabler`, which denotes it as the
     +  bool that toggles a plugin on and off.
     +
     +  It then returns its value.
     +
     +  Returns:
     +      `true` if the plugin is deemed enabled (or cannot be disabled),
     +      `false` if not.
     +/
    private bool pluginIsEnabled() const @property pure nothrow @nogc
    {
        import std.traits : Unqual, hasUDA;

        bool retval = true;

        top:
        foreach (immutable i, immutable member; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings))
            {
                foreach (immutable n, immutable submember; this.tupleof[i].tupleof)
                {
                    static if (hasUDA!(this.tupleof[i].tupleof[n], Enabler))
                    {
                        static assert(is(typeof(this.tupleof[i].tupleof[n]) : bool),
                            Unqual!(typeof(this)).stringof ~ " has a non-bool Enabler");

                        retval = submember;
                        break top;
                    }
                }
            }
        }

        return retval;
    }


    // allowImpl
    /++
     +  Judges whether an event may be triggered, based on the event itself and
     +  the annotated `PrivilegeLevel` of the handler in question.
     +
     +  Pass the passed arguments to `filterUser`, doing nothing otherwise.
     +
     +  Sadly we can't keep an `allow` around to override since calling it from
     +  inside the same mixin always seems to resolve the original. So instead,
     +  only have `allowImpl` and use introspection to determine whether to call
     +  that or any custom-defined `allow` in `typeof(this)`.
     +
     +  Params:
     +      event = `kameloso.irc.defs.IRCEvent` to allow, or not.
     +      privilegeLevel = `PrivilegeLevel` of the handler in question.
     +
     +  Returns:
     +      `true` if the event should be allowed to trigger, `false` if not.
     +/
    private FilterResult allowImpl(const IRCEvent event, const PrivilegeLevel privilegeLevel)
    {
        return filterUser(event, privilegeLevel);
    }


    // onEvent
    /++
     +  Pass on the supplied `kameloso.irc.defs.IRCEvent` to `onEventImpl`.
     +
     +  This is made a separate function to allow plugins to override it and
     +  insert their own code, while still leveraging `onEventImpl` for the
     +  actual dirty work.
     +
     +  Params:
     +      event = Parse `kameloso.irc.defs.IRCEvent` to pass onto `onEventImpl`.
     +
     +  See_Also:
     +      onEventImpl
     +/
    void onEvent(const IRCEvent event) @system
    {
        return onEventImpl(event);
    }


    // onEventImpl
    /++
     +  Pass on the supplied `kameloso.irc.defs.IRCEvent` to functions annotated
     +  with the right `kameloso.irc.defs.IRCEvent.Type`s.
     +
     +  It also does checks for `ChannelPolicy`, `PrivilegeLevel` and
     +  `PrefixPolicy` where such is appropriate.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to dispatch to event handlers.
     +/
    private void onEventImpl(const IRCEvent event) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.string : contains, nom;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : getSymbolsByUDA, isSomeFunction, getUDAs, hasUDA;

        if (!pluginIsEnabled) return;

        alias setupAwareness(alias T) = hasUDA!(T, Awareness.setup);
        alias earlyAwareness(alias T) = hasUDA!(T, Awareness.early);
        alias lateAwareness(alias T) = hasUDA!(T, Awareness.late);
        alias cleanupAwareness(alias T) = hasUDA!(T, Awareness.cleanup);
        alias isAwarenessFunction = templateOr!(setupAwareness, earlyAwareness,
            lateAwareness, cleanupAwareness);
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
                version(FlushStdout) import std.stdio : flush;
            }

            udaloop:
            foreach (eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
            {
                enum name = ()
                {
                    import kameloso.conv : Enum;
                    import std.format : format;

                    string pluginName = module_;
                    while (pluginName.contains('.'))
                    {
                        pluginName.nom('.');
                    }

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
                    version(FlushStdout) stdout.flush();
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
                    version(FlushStdout) stdout.flush();
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
                    else if (!privateState.client.homes.canFind(event.channel))
                    {
                        static if (verbose)
                        {
                            writeln("...ignore invalid channel ", event.channel);
                            version(FlushStdout) stdout.flush();
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
                            version(FlushStdout) stdout.flush();
                        }

                        // Reset between iterations
                        mutEvent = event;

                        if (!privateState.client.prefixPolicyMatches(commandUDA.policy, mutEvent))
                        {
                            static if (verbose)
                            {
                                writeln("...policy doesn't match; continue next BotCommand");
                                version(FlushStdout) stdout.flush();
                            }

                            continue;  // next BotCommand UDA
                        }

                        import kameloso.string : strippedLeft;
                        import std.typecons : No, Yes;

                        string thisCommand;

                        mutEvent.content = mutEvent.content.strippedLeft;

                        if (mutEvent.content.contains!(Yes.decode)(' '))
                        {
                            thisCommand = mutEvent.content.nom!(Yes.decode)(' ');
                        }
                        else
                        {
                            // single word, not a prefix
                            thisCommand = mutEvent.content;
                            mutEvent.content = string.init;
                        }

                        import std.algorithm.comparison : equal;
                        import std.uni : asLowerCase, toLower;

                        enum lowercaseUDAString = commandUDA.string_.toLower;

                        if ((thisCommand.length == lowercaseUDAString.length) &&
                            thisCommand.asLowerCase.equal(lowercaseUDAString))
                        {
                            static if (verbose)
                            {
                                writeln("...command matches!");
                                version(FlushStdout) stdout.flush();
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

                            if (!privateState.client.prefixPolicyMatches(regexUDA.policy, event))
                            {
                                static if (verbose)
                                {
                                    writeln("...policy doesn't match; continue next BotRegex");
                                    version(FlushStdout) stdout.flush();
                                }

                                continue;  // next BotRegex UDA
                            }

                            // Reset between iterations
                            mutEvent = event;
                            string thisCommand;

                            if (mutEvent.content.contains!(Yes.decode)(' '))
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
                        version(FlushStdout) stdout.flush();
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
                        version(FlushStdout) stdout.flush();
                    }

                    static if (__traits(hasMember, this, "allow") &&
                        isSomeFunction!(__traits(getMember, this, "allow")))
                    {
                        immutable result = allow(mutEvent, privilegeLevel);
                    }
                    else
                    {
                        immutable result = allowImpl(mutEvent, privilegeLevel);
                    }

                    with (FilterResult)
                    final switch (result)
                    {
                    case pass:
                        // Drop down
                        break;

                    case whois:
                        import kameloso.plugins.common : doWhois;

                        alias This = typeof(this);
                        alias Params = staticMap!(Unqual, Parameters!fun);
                        enum isIRCPluginParam(T) = is(T == IRCPlugin);

                        static if (verbose)
                        {
                            writefln("...%s WHOIS", typeof(this).stringof);
                            version(FlushStdout) stdout.flush();
                        }

                        static if (is(Params : AliasSeq!IRCEvent) || (arity!fun == 0))
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
                        return Next.continue_;
                    }
                }

                alias Params = staticMap!(Unqual, Parameters!fun);

                static if (verbose)
                {
                    writeln("...calling!");
                    version(FlushStdout) stdout.flush();
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

        alias setupFuns = Filter!(setupAwareness, funs);
        alias earlyFuns = Filter!(earlyAwareness, funs);
        alias lateFuns = Filter!(lateAwareness, funs);
        alias cleanupFuns = Filter!(cleanupAwareness, funs);
        alias pluginFuns = Filter!(isNormalPluginFunction, funs);

        /// Sanitise and try again once on UTF/Unicode exceptions
        static void sanitizeEvent(ref IRCEvent event)
        {
            import std.encoding : sanitize;

            with (event)
            {
                raw = sanitize(raw);
                channel = sanitize(channel);
                content = sanitize(content);
                aux = sanitize(aux);
                tags = sanitize(tags);
            }
        }

        /// Wrap all the functions in the passed `funlist` in try-catch blocks.
        void tryCatchHandle(funlist...)(const IRCEvent event)
        {
            import core.exception : UnicodeException;
            import std.utf : UTFException;

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
                    /*logger.warningf("tryCatchHandle UTFException on %s: %s",
                        __traits(identifier, fun), e.msg);*/

                    IRCEvent saneEvent = event;
                    sanitizeEvent(saneEvent);
                    handle!fun(cast(const)saneEvent);
                }
                catch (const UnicodeException e)
                {
                    /*logger.warningf("tryCatchHandle UnicodeException on %s: %s",
                        __traits(identifier, fun), e.msg);*/

                    IRCEvent saneEvent = event;
                    sanitizeEvent(saneEvent);
                    handle!fun(cast(const)saneEvent);
                }
            }
        }

        tryCatchHandle!setupFuns(event);
        tryCatchHandle!earlyFuns(event);
        tryCatchHandle!pluginFuns(event);
        tryCatchHandle!lateFuns(event);
        tryCatchHandle!cleanupFuns(event);
    }


    // this(IRCPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level `.initialise(IRCPlugin)` if it exists.
     +
     +  There's no point in checking whether the plugin is enabled or not, as it
     +  will only be possible to change the setting after having created the
     +  plugin (and serialised settings into it).
     +
     +  Params:
     +      state = The aggregate of all plugin state variables, making
     +          this the "original state" of the plugin.
     +/
    this(IRCPluginState state) @system
    {
        import kameloso.common : settings;
        import kameloso.traits : isConfigurableVariable;
        import std.traits : hasUDA;

        this.privateState = state;

        foreach (immutable i, ref member; this.tupleof)
        {
            static if (isConfigurableVariable!member)
            {
                static if (hasUDA!(this.tupleof[i], Resource))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(settings.resourceDirectory, member).expandTilde;
                }
                else static if (hasUDA!(this.tupleof[i], Configuration))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(settings.configDirectory, member).expandTilde;
                }
            }
        }

        static if (__traits(compiles, .initialise))
        {
            .initialise(this);
        }
    }


    // postprocess
    /++
     +  Lets a plugin modify an `kameloso.irc.defs.IRCEvent` while it's begin
     +  constructed, before it's finalised and passed on to be handled.
     +/
    void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, .postprocess))
        {
            if (!pluginIsEnabled) return;
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
            if (!pluginIsEnabled) return;
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
        import kameloso.meld : MeldingStrategy, meldInto;
        import kameloso.traits : isStruct;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;

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

            tempSymbol.meldInto!(MeldingStrategy.aggressive)(symbol);
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

                tempSymbol.meldInto!(MeldingStrategy.aggressive)(symbol);
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
     +
     +  Returns:
     +      `true` if a member was found and set, `false` otherwise.
     +/
    bool setSettingByName(const string setting, const string value)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

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

        return success;
    }


    // printSettings
    /++
     +  Prints the plugin's `Settings`-annotated structs.
     +
     +  It both prints module-level structs as well as structs in the
     +  `kameloso.irc.defs.IRCPlugin` (subtype) itself.
     +/
    void printSettings() const
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.printing : printObject;
        import kameloso.traits : isStruct;
        import std.meta : Filter;
        import std.traits : getSymbolsByUDA, hasUDA;
        import std.typecons : No, Yes;

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
     +  sink.reserve(128);
     +  serialiseConfigInto(sink);
     +  ---
     +
     +  Params:
     +      sink = Reference `std.array.Appender` to fill with plugin-specific
     +          settings text.
     +/
    import std.array : Appender;
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
        static if (__traits(compiles, .start))
        {
            if (!pluginIsEnabled) return;

            import std.datetime.systime : SysTime;
            import std.meta : AliasSeq, staticMap;
            import std.traits : Parameters, Unqual;

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
     +  De-initialises the plugin.
     +/
    void teardown() @system
    {
        static if (__traits(compiles, .teardown))
        {
            if (!pluginIsEnabled) return;
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
    string name() @property const pure
    {
        enum ctName =
        {
            import kameloso.string : contains, nom;

            string moduleName = module_;

            while (moduleName.contains('.'))
            {
                moduleName.nom('.');
            }

            return moduleName;
        }();

        return ctName;
    }


    // commands
    /++
     +  Collects all `BotCommand` strings that this plugin offers at compile
     +  time, then at runtime returns them alongside their `Description`s as an
     +  associative `Description[string]` array.
     +
     +  Returns:
     +      Associative array of all `Descriptions`, keyed by
     +      `BotCommand.string_`s.
     +/
    Description[string] commands() pure nothrow @property const
    {
        enum ctCommands =
        {
            import std.meta : Filter;
            import std.traits : getUDAs, getSymbolsByUDA, hasUDA, isSomeFunction;

            mixin("static import thisModule = " ~ module_ ~ ";");

            alias symbols = getSymbolsByUDA!(thisModule, BotCommand);
            alias funs = Filter!(isSomeFunction, symbols);

            Description[string] descriptions;

            foreach (fun; funs)
            {
                foreach (commandUDA; getUDAs!(fun, BotCommand))
                {
                    static if (hasUDA!(fun, Description))
                    {
                        descriptions[commandUDA.string_] = getUDAs!(fun, Description)[0];
                    }
                }
            }

            return descriptions;
        }();

        return pluginIsEnabled ? ctCommands : (Description[string]).init;
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
    ref inout(IRCPluginState) state() inout pure nothrow @nogc @property
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
            if (!pluginIsEnabled) return;
            .reload(this);
        }
    }


    // onBusMessage
    /++
     +  Proxies a bus message to the plugin, to let it handle it (or not).
     +/
    import kameloso.thread : Sendable;
    void onBusMessage(const string header, shared Sendable content) @system
    {
        static if (__traits(compiles, .onBusMessage))
        {
            import std.meta : AliasSeq;
            import std.traits : Parameters, Unqual, staticMap;

            alias Params = staticMap!(Unqual, Parameters!(.onBusMessage));
            alias This = typeof(this);

            static if (is(Params : AliasSeq!(This, string, Sendable)))
            {
                .onBusMessage(this, header, content);
            }
            else static if (is(Params : AliasSeq!(This, string)))
            {
                .onBusMessage(this, header);
            }
            else
            {
                static assert(0, "Invalid signature on " ~ module_ ~ ".onBusMessage");
            }
        }
    }
}

unittest
{
    IRCPluginState state;

    struct TestSettings
    {
        @Enabler bool enuubled = false;
    }

    final class TestPlugin : IRCPlugin
    {
        @Settings TestSettings testSettings;

        mixin IRCPluginImpl;
    }

    TestPlugin p = new TestPlugin(state);
    assert(!p.pluginIsEnabled);

    p.testSettings.enuubled = true;
    assert(p.pluginIsEnabled);
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
version(WithPlugins)
mixin template MessagingProxy(bool debug_ = false, string module_ = __MODULE__)
{
    static import kameloso.messaging;
    static import kameloso.common;

    import std.functional : partial;
    import std.typecons : Flag, No, Yes;

    enum hasMessagingProxy = true;

    pragma(inline):

    // chan
    /++
     +  Sends a channel message.
     +/
    void chan(Flag!"priority" priority = No.priority)(const string channel,
        const string content, bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.chan!priority(privateState, channel, content, quiet);
    }

    // query
    /++
     +  Sends a private query message to a user.
     +/
    void query(Flag!"priority" priority = No.priority)(const string nickname,
        const string content, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.query!priority(privateState, nickname, content, quiet);
    }

    // privmsg
    /++
     +  Sends either a channel message or a private query message depending on
     +  the arguments passed to it.
     +
     +  This reflects how channel messages and private messages are both the
     +  underlying same type; `PRIVMSG`.
     +/
    void privmsg(Flag!"priority" priority = No.priority)(const string channel,
        const string nickname, const string content, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.privmsg!priority(privateState, channel, nickname, content, quiet);
    }

    // emote
    /++
     +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
     +/
    void emote(Flag!"priority" priority = No.priority)(const string emoteTarget,
        const string content, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.emote!priority(privateState, emoteTarget, content, quiet);
    }

    // mode
    /++
     +  Sets a channel mode.
     +
     +  This includes modes that pertain to a user in the context of a channel, like bans.
     +/
    void mode(Flag!"priority" priority = No.priority)(const string channel,
        const string modes, const string content = string.init,
        const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.mode!priority(privateState, channel, modes, content, quiet);
    }

    // topic
    /++
     +  Sets the topic of a channel.
     +/
    void topic(Flag!"priority" priority = No.priority)(const string channel,
        const string content, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.topic!priority(privateState, channel, content, quiet);
    }

    // invite
    /++
     +  Invites a user to a channel.
     +/
    void invite(Flag!"priority" priority = No.priority)(const string channel,
        const string nickname, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.invite!priority(privateState, channel, nickname, quiet);
    }

    // join
    /++
     +  Joins a channel.
     +/
    void join(Flag!"priority" priority = No.priority)(const string channel,
        const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.join!priority(privateState, channel, quiet);
    }

    // kick
    /++
     +  Kicks a user from a channel.
     +/
    void kick(Flag!"priority" priority = No.priority)(const string channel,
        const string nickname, const string reason = string.init,
        const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.kick!priority(privateState, channel, nickname, reason, quiet);
    }

    // part
    /++
     +  Leaves a channel.
     +/
    void part(Flag!"priority" priority = No.priority)(const string channel,
        const string reason = string.init, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.quit!priority(privateState, channel, reason, quiet);
    }

    // quit
    /++
     +  Disconnects from the server, optionally with a quit reason.
     +/
    void quit(Flag!"priority" priority = No.priority)(const string reason = string.init,
        const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.quit!priority(privateState, reason, quiet);
    }

    // raw
    /++
     +  Sends text to the server, verbatim.
     +
     +  This is used to send messages of types for which there exist no helper
     +  functions.
     +/
    void raw(Flag!"priority" priority = No.priority)(const string line,
        const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.raw!priority(privateState, line, quiet);
    }

    // askToWriteln
    /++
     +  Asks the main thread to print text to the local terminal.
     +/
    alias askToWriteln = partial!(kameloso.messaging.askToWriteln, privateState);

    // askToTrace
    /++
     +  Asks the main thread to `logger.trace` text to the local terminal.
     +/
    alias askToTrace = partial!(kameloso.messaging.askToTrace, privateState);

    // askToLog
    /++
     +  Asks the main thread to `logger.log` text to the local terminal.
     +/
    alias askToLog = partial!(kameloso.messaging.askToLog, privateState);

    // askToInfo
    /++
     +  Asks the main thread to `logger.info` text to the local terminal.
     +/
    alias askToInfo = partial!(kameloso.messaging.askToInfo, privateState);

    // askToWarn
    /++
     +  Asks the main thread to `logger.warning` text to the local terminal.
     +/
    alias askToWarn = partial!(kameloso.messaging.askToWarn, privateState);
    alias askToWarning = askToWarn;

    // askToError
    /++
     +  Asks the main thread to `logger.error` text to the local terminal.
     +/
    alias askToError = partial!(kameloso.messaging.askToError, privateState);
}


// MinimalAuthenticator
/++
 +  Implements triggering of queued events in a plugin module.
 +/
version(WithPlugins)
mixin template MinimalAuthentication(bool debug_ = false, string module_ = __MODULE__)
{
    static if (__traits(compiles, .hasMinimalAuthentication))
    {
        static assert(0, "Double mixin of MinimalAuthentication in module " ~ module_);
    }
    else
    {
        enum hasMinimalAuthentication = true;
    }

    // onMinimalAuthenticationAccountInfoTargetMixin
    /++
     +  Replays any queued requests awaiting the result of a WHOIS. Before that,
     +  records the user's services account by saving it to the user's
     +  `kameloso.irc.common.IRCClient` in the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array.
     +
     +  This function was part of `UserAwareness` but triggering queued requests
     +  is too common to conflate with it.
     +
     +  Most of the time a plugin doesn't require a full `UserAwareness`; only
     +  those that need looking up users outside of the current event do. The
     +  persistency service allows for plugins to just read the information from
     +  the `kameloso.irc.defs.IRCUser` embedded in the event directly, and that's
     +  often enough.
     +
     +  General rule: if a plugin doesn't access `state.users`, it's probably
     +  going to be enough with only `MinimalAuthentication`.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    void onMinimalAuthenticationAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // Catch the user here, before replaying anything.
        // No need to catchUser; just inherit
        plugin.state.users[event.target.nickname] = event.target;

        string[] garbageNicknames;

        // See if there are any queued WHOIS requests to trigger
        if (auto requestsForNickname = event.target.nickname in plugin.state.whoisQueue)
        {
            size_t[] garbageIndexes;

            foreach (immutable i, request; *requestsForNickname)
            {
                import kameloso.constants : Timeout;
                import std.algorithm.searching : canFind;
                import std.datetime.systime : Clock;

                immutable now = Clock.currTime.toUnixTime;
                immutable then = request.when;

                if ((now - then) > Timeout.whoisRetry)
                {
                    // Entry is too old, request timed out. Flag it for removal.
                    garbageIndexes ~= i;
                    continue;
                }

                void explainReplay()
                {
                    import kameloso.common : logger, settings;
                    import kameloso.conv : Enum;

                    string infotint, logtint;

                    version(Colours)
                    {
                        if (!settings.monochrome)
                        {
                            import kameloso.logger : KamelosoLogger;

                            infotint = (cast(KamelosoLogger)logger).infotint;
                            logtint = (cast(KamelosoLogger)logger).logtint;
                        }
                    }

                    logger.logf("%s%s%s plugin replaying %1$s%4$s%3$s-tier event " ~
                        "based on WHOIS results (user is %1$s%5$s%3$s class)",
                        infotint, plugin.name, logtint,
                        Enum!PrivilegeLevel.toString(request.privilegeLevel),
                        Enum!(IRCUser.Class).toString(event.target.class_));
                }

                with (PrivilegeLevel)
                final switch (request.privilegeLevel)
                {
                case admin:
                    if (event.target.class_ == IRCUser.Class.admin)
                    {
                        explainReplay();
                        request.trigger();
                        garbageIndexes ~= i;
                    }
                    break;

                case whitelist:
                    if ((event.target.class_ == IRCUser.Class.admin) ||
                        (event.target.class_ == IRCUser.Class.whitelist))
                    {
                        explainReplay();
                        request.trigger();
                        garbageIndexes ~= i;
                    }
                    break;

                case anyone:
                    if (event.target.class_ != IRCUser.Class.blacklist)
                    {
                        explainReplay();
                        request.trigger();
                    }

                    // Always remove queued request even if blacklisted
                    garbageIndexes ~= i;
                    break;

                case ignore:
                    break;
                }
            }

            foreach_reverse (immutable i; garbageIndexes)
            {
                import std.algorithm.mutation : SwapStrategy, remove;
                plugin.state.whoisQueue[event.target.nickname].remove!(SwapStrategy.unstable)(i);
            }

            if (!plugin.state.whoisQueue[event.target.nickname].length)
            {
                // All requests were processed, flag for removal
                garbageNicknames ~= event.target.nickname;
            }
        }

        foreach (immutable garbageNick; garbageNicknames)
        {
            plugin.state.whoisQueue.remove(garbageNick);
        }
    }


    // onMinimalAuthenticationEndOfWHOISMixin
    /++
     +  Removes an exhausted `WHOIS` request from the queue upon end of `WHOIS`.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onMinimalAuthenticationEndOfWHOISMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.whoisQueue.remove(event.target.nickname);
    }


    // onMinimalAuthenticationUnknownCommandWHOIS
    /++
     +  Clears all queued `WHOIS` requests if the server says it doesn't support
     +  `WHOIS` at all.
     +
     +  This is the case with Twitch servers.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
    void onMinimalAuthenticationUnknownCommandWHOIS(IRCPlugin plugin, const IRCEvent event)
    {
        if (event.aux == "WHOIS")
        {
            // We're on a server that doesn't support WHOIS
            // --> clear WHOIS queue and pretend like nothing happened
            plugin.state.whoisQueue.clear();
        }
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
version(WithPlugins)
mixin template UserAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    static if (__traits(compiles, .hasUserAwareness))
    {
        static assert(0, "Double mixin of UserAwareness in module " ~ module_);
    }
    else
    {
        enum hasUserAwareness = true;
    }

    static if (!__traits(compiles, .hasMinimalAuthentication))
    {
        mixin MinimalAuthentication!(debug_, module_);
    }

    // onUserAwarenessQuitMixin
    /++
     +  Removes a user's `kameloso.irc.defs.IRCUser` entry from a plugin's user
     +  list upon them disconnecting.
     +/
    @(Awareness.cleanup)
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
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onUserAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        if (auto oldUser = event.sender.nickname in plugin.state.users)
        {
            plugin.state.users[event.target.nickname] = *oldUser;
            plugin.state.users.remove(event.sender.nickname);
        }

        foreach (ref channel; plugin.state.channels)
        {
            import std.algorithm.searching : countUntil;

            immutable userIndex = channel.users.countUntil(event.sender.nickname);

            if (userIndex != -1)
            {
                channel.users[userIndex] = event.target.nickname;  // not sender
            }
        }
    }


    // onUserAwarenessCatchTargetMixin
    /++
     +  Catches a user's information and saves it in the plugin's
     +  `IRCPluginState.users` array of `kameloso.irc.defs.IRCUser`s.
     +
     +  `kameloso.irc.defs.IRCEvent.Type.RPL_WHOISUSER` events carry values in
     +  the `kameloso.irc.defs.IRCUser.lastWhois` field that we want to store.
     +
     +  `kameloso.irc.defs.IRCEvent.Type.CHGHOST` occurs when a user changes host
     +  on some servers that allow for custom host addresses.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISUSER)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @(IRCEvent.Type.CHGHOST)
    @channelPolicy
    void onUserAwarenessCatchTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.target);
    }


    // onUserAwarenessCatchSenderMixin
    /++
     +  Adds a user to the `IRCPlugin`'s `IRCPluginState.users` array,
     +  potentially including their services account name.
     +
     +  Servers with the (enabled) capability `extended-join` will include the
     +  account name of whoever joins in the event string. If it's there, catch
     +  the user into the user array so we don't have to `WHOIS` them later.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.ACCOUNT)
    @channelPolicy
    void onUserAwarenessCatchSenderMixin(IRCPlugin plugin, const IRCEvent event)
    {
        if (event.type == IRCEvent.Type.ACCOUNT)
        {
            // ACCOUNT events don't carry a channel, so check our channel user
            // lists to see if we should catch this one or not.

            foreach (const channel; plugin.state.channels)
            {
                import std.algorithm.searching : canFind;

                if (channel.users.canFind(event.sender.nickname))
                {
                    // ACCOUNT of a user that's in a relevant channel
                    return plugin.catchUser(event.sender);
                }
            }
        }
        else
        {
            plugin.catchUser(event.sender);
        }
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
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @channelPolicy
    void onUserAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc.common : IRCControlCharacter, stripModesign;
        import kameloso.irc.colours : stripColours;
        import kameloso.string : contains, nom;
        import std.algorithm.iteration : splitter;

        auto names = event.content.splitter(" ");

        foreach (immutable userstring; names)
        {
            string slice = userstring;
            IRCUser newUser;

            if (!slice.contains('!') || !slice.contains('@'))
            {
                // Freenode-like, only nicknames with possible modesigns
                immutable nickname = plugin.state.client.server.stripModesign(slice);
                if (nickname == plugin.state.client.nickname) continue;
                newUser.nickname = nickname;
            }
            else
            {
                // SpotChat-like, names are in full nick!ident@address form
                immutable signed = slice.nom('!');
                immutable nickname = plugin.state.client.server.stripModesign(signed);
                if (nickname == plugin.state.client.nickname) continue;

                immutable ident = slice.nom('@');

                // Do addresses ever contain bold, italics, underlined?
                immutable address = slice.contains(IRCControlCharacter.colour) ?
                    stripColours(slice) : slice;

                newUser = IRCUser(nickname, ident, address);
            }

            plugin.catchUser(newUser);
        }
    }


    // onUserAwarenessEndOfListMixin
    /++
     +  Rehashes, or optimises, the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array upon the end of a `WHO` or a `NAMES` list.
     +
     +  These replies can list hundreds of users depending on the size of the
     +  channel. Once an associative array has grown sufficiently, it becomes
     +  inefficient. Rehashing it makes it take its new size into account and
     +  makes lookup faster.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFNAMES)
    @(IRCEvent.Type.RPL_ENDOFWHO)
    @channelPolicy
    void onUserAwarenessEndOfListMixin(IRCPlugin plugin)
    {
        plugin.state.users.rehash();
    }


    // onUserAwarenessPingMixin
    /++
     +  Rehash the internal `IRCPluginState.users` associative array of
     +  `kameloso.irc.defs.IRCUser`s, once every `hoursBetweenRehashes` hours.
     +
     +  We ride the periodicity of `PING` to get a natural cadence without
     +  having to resort to timed `core.thread.Fiber`s.
     +
     +  The number of hours is so far hardcoded but can be made configurable if
     +  there's a use-case for it.
     +
     +  This re-implements `IRCPlugin.periodically`.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.PING)
    void onUserAwarenessPingMixin(IRCPlugin plugin)
    {
        import std.datetime.systime : Clock;

        enum hoursBetweenRehashes = 12;

        immutable now = Clock.currTime.toUnixTime;

        if (now >= _nextPingRehashTimestamp)
        {
            // Once every `hoursBetweenRehashes` hours, rehash the `users` array.
            plugin.state.users.rehash();
            _nextPingRehashTimestamp = now + (hoursBetweenRehashes * 3600);
        }
    }

    /++
     +  UNIX timestamp of when the `IRCPluginState.users` array is next to be
     +  rehashed in `onUserAwarenessPingMixin`.
     +/
    long _nextPingRehashTimestamp;
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
version(WithPlugins)
mixin template ChannelAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    static assert(__traits(compiles, .hasUserAwareness), module_ ~
        " is missing UserAwareness mixin (needed for ChannelAwareness).");

    static if (__traits(compiles, .hasChannelAwareness))
    {
        static assert(0, "Double mixin of ChannelAwareness in module " ~ module_);
    }
    else
    {
        enum hasChannelAwareness = true;
    }


    // onChannelAwarenessSelfjoinMixin
    /++
     +  Create a new `kameloso.irc.defs.IRCChannel` in the the `IRCPlugin`'s
     +  `IRCPluginState.channels` associative array when the bot joins a channel.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.SELFJOIN)
    @channelPolicy
    void onChannelAwarenessSelfjoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel] = IRCChannel.init;
        plugin.state.channels[event.channel].name = event.channel;
    }


    // onChannelAwarenessSelfpartMixin
    /++
     +  Removes an `kameloso.irc.defs.IRCChannel` from the internal list when the
     +  bot leaves it.
     +
     +  Remove users from the `plugin.state.users` array if, by leaving, it left
     +  the last channel we can observe it from, so as not to leak users. It can
     +  be argued that this should be part of user awareness, however this would
     +  not be possible if it were not for channel-tracking. As such keep the
     +  behaviour in channel awareness.
     +/
    @(Awareness.cleanup)
    @(Chainable)
    @(IRCEvent.Type.SELFPART)
    @(IRCEvent.Type.SELFKICK)
    @channelPolicy
    void onChannelAwarenessSelfpartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // On Twitch SELFPART may occur on untracked channels
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        nickloop:
        foreach (immutable nickname; channel.users)
        {
            foreach (const channel; plugin.state.channels)
            {
                import std.algorithm.searching : canFind;
                if (channel.users.canFind(nickname)) continue nickloop;
            }

            // nickname is not in any of our other tracked channels; remove
            plugin.state.users.remove(nickname);
        }

        plugin.state.channels.remove(event.channel);
    }


    // onChannelAwarenessJoinMixin
    /++
     +  Adds a user as being part of a channel when they join one.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @channelPolicy
    void onChannelAwarenessJoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel].users ~= event.sender.nickname;
    }


    // onChannelAwarenessPartMixin
    /++
     +  Removes a user from being part of a channel when they leave one.
     +
     +  Remove the user from the `plugin.state.users` array if, by leaving, it
     +  left the last channel we can observe it from, so as not to leak users.
     +  It can be argued that this should be part of user awareness, however
     +  this would not be possible if it were not for channel-tracking. As such
     +  keep the behaviour in channel awareness.
     +/
    @(Awareness.late)
    @(Chainable)
    @(IRCEvent.Type.PART)
    @channelPolicy
    void onChannelAwarenessPartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        immutable userIndex = plugin.state.channels[event.channel].users
            .countUntil(event.sender.nickname);

        if (userIndex == -1)
        {
            // On Twitch servers with no NAMES on joining a channel, users
            // that you haven't seen may leave despite never having been seen
            return;
        }

        plugin.state.channels[event.channel].users = plugin.state.channels[event.channel].users
            .remove!(SwapStrategy.unstable)(userIndex);

        foreach (const channel; plugin.state.channels)
        {
            import std.algorithm.searching : canFind;
            if (channel.users.canFind(event.sender.nickname)) return;
        }

        // event.sender is not in any of our tracked channels; remove
        plugin.state.users.remove(event.sender.nickname);
    }


    // onChannelAwarenessNickMixin
    /++
     +  Upon someone changing nickname, update their entry in the
     +  `IRCPluginState.users` associative array point to the new nickname.
     +
     +  Removes the old entry.
     +/
    @(Awareness.setup)
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
            channel.users[userIndex] = event.target.nickname;  // not sender
        }
    }


    // onChannelAwarenessQuitMixin
    /++
     +  Removes a user from all tracked channels if they disconnect.
     +
     +  Does not touch the internal list of users; the user awareness bits are
     +  expected to take care of that.
     +/
    @(Awareness.late)
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onChannelAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        foreach (ref channel; plugin.state.channels)
        {
            immutable userIndex = channel.users.countUntil(event.sender.nickname);
            if (userIndex == -1) continue;
            channel.users = channel.users.remove!(SwapStrategy.unstable)(userIndex);
        }
    }


    // onChannelAwarenessTopicMixin
    /++
     +  Update the entry for an `kameloso.irc.defs.IRCChannel` if someone changes
     +  the topic of it.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.TOPIC)
    @(IRCEvent.Type.RPL_TOPIC)
    @channelPolicy
    void onChannelAwarenessTopicMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.channels[event.channel].topic = event.content;
    }


    // onChannelAwarenessCreationTimeMixin
    /++
     +  Stores the timestamp of when a channel was created.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_CREATIONTIME)
    @channelPolicy
    void onChannelAwarenessCreationTimeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.conv : to;
        plugin.state.channels[event.channel].created = event.aux.to!long;
    }


    // onChannelAwarenessModeMixin
    /++
     +  Sets a mode for a channel.
     +
     +  Most modes replace others of the same type, notable exceptions being
     +  bans and mode exemptions. We let `kameloso.irc.common.setMode` take care of that.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.MODE)
    @channelPolicy
    void onChannelAwarenessModeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc.common : setMode;
        plugin.state.channels[event.channel].setMode(event.aux, event.content, plugin.state.client.server);
    }


    // onChannelAwarenessWhoReplyMixin
    /++
     +  Adds a user as being part of a channel upon receiving the reply from the
     +  request for info on all the participants.
     +
     +  This events includes all normal fields like ident and address, but not
     +  their channel modes (e.g. `@` for operator).
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @channelPolicy
    void onChannelAwarenessWhoReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.string : representation;

        // User awareness bits add the IRCUser
        if (event.aux.length)
        {
            // Register operators, half-ops, voiced etc
            // Can be more than one if multi-prefix capability is enabled
            // Server-sent string, can assume ASCII (@,%,+...) and go char by char
            foreach (immutable modesign; event.aux.representation)
            {
                if (const modechar = modesign in plugin.state.client.server.prefixchars)
                {
                    import kameloso.irc.common : setMode;
                    import std.conv : to;

                    immutable modestring = (*modechar).to!string;
                    plugin.state.channels[event.channel].setMode(modestring,
                        event.target.nickname, plugin.state.client.server);
                }
                /*else
                {
                    logger.warningf(`Invalid modesign in RPL_WHOREPLY: "%s" ` ~
                        `The server did not advertise it!`, modesign);
                }*/
            }
        }

        if (event.target.nickname == plugin.state.client.nickname) return;

        import std.algorithm.searching : canFind;
        if (plugin.state.channels[event.channel].users.canFind(event.target.nickname))
        {
            // Already registered
            return;
        }

        plugin.state.channels[event.channel].users ~= event.target.nickname;
    }


    // onChannelAwarenessNamesReplyMixin
    /++
     +  Adds users as being part of a channel upon receiving the reply from the
     +  request for a list of all the participants.
     +
     +  On some servers this does not include information about the users, only
     +  their nickname and their channel mode (e.g. `@` for operator), but other
     +  servers express the users in the full `user!ident@address` form.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @channelPolicy
    void onChannelAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.string : contains;
        import std.algorithm.iteration : splitter;

        if (!event.content.length) return;

        auto names = event.content.splitter(" ");

        foreach (immutable userstring; names)
        {
            string slice = userstring;
            string nickname;

            if (userstring.contains('!') && userstring.contains('@'))
            {
                import kameloso.string : nom;
                // SpotChat-like, names are in full nick!ident@address form
                nickname = slice.nom('!');
            }
            else
            {
                // Freenode-like, only a nickname with possible @%+ prefix
                nickname = userstring;
            }

            import kameloso.irc.common : stripModesign;

            string modesigns;
            nickname = plugin.state.client.server.stripModesign(nickname, modesigns);

            // Register operators, half-ops, voiced etc
            // Can be more than one if multi-prefix capability is enabled
            // Server-sent string, can assume ASCII (@,%,+...) and go char by char
            import std.string : representation;
            foreach (immutable modesign; modesigns.representation)
            {
                if (auto modechar = modesign in plugin.state.client.server.prefixchars)
                {
                    import kameloso.irc.common : setMode;
                    import std.conv : to;
                    immutable modestring = (*modechar).to!string;
                    plugin.state.channels[event.channel]
                        .setMode(modestring, nickname, plugin.state.client.server);
                }
                else
                {
                    //logger.warning("Invalid modesign in RPL_NAMREPLY: ", modesign);
                }
            }

            if (nickname == plugin.state.client.nickname) continue;

            import std.algorithm.searching : canFind;
            if (plugin.state.channels[event.channel].users.canFind(nickname))
            {
                // Already registered
                continue;
            }

            plugin.state.channels[event.channel].users ~= nickname;
        }
    }


    // onChannelAwarenessModeListsMixin
    /++
     +  Adds the list of banned users to a tracked channel's list of modes.
     +
     +  Bans are just normal A-mode channel modes that are paired with a user
     +  and that don't overwrite other bans (can be stacked).
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_BANLIST)
    @(IRCEvent.Type.RPL_EXCEPTLIST)
    @(IRCEvent.Type.RPL_INVITELIST)
    @(IRCEvent.Type.RPL_REOPLIST)
    @(IRCEvent.Type.RPL_QUIETLIST)
    @channelPolicy
    void onChannelAwarenessModeListsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc.common : setMode;
        import std.conv : to;

        // :kornbluth.freenode.net 367 kameloso #flerrp huerofi!*@* zorael!~NaN@2001:41d0:2:80b4:: 1513899527
        // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
        // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
        // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101

        with (IRCEvent.Type)
        {
            // Map known list types to their modechars
            immutable ubyte[IRCEvent.Type.RPL_QUIETLIST+1] modecharsByType =
            [
                RPL_BANLIST : 'b',
                RPL_EXCEPTLIST : plugin.state.client.server.exceptsChar,
                RPL_INVITELIST : plugin.state.client.server.invexChar,
                RPL_REOPLIST : 'R',
                RPL_QUIETLIST : 'q',
            ];

            plugin.state.channels[event.channel]
                .setMode((cast(char)modecharsByType[event.type]).to!string,
                event.content, plugin.state.client.server);
        }
    }


    // onChannelAwarenessChannelModeIsMixin
    /++
     +  Adds the modes of a channel to a tracked channel's mode list.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_CHANNELMODEIS)
    @channelPolicy
    void onChannelAwarenessChannelModeIsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irc.common : setMode;

        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        plugin.state.channels[event.channel].setMode(event.aux, event.content, plugin.state.client.server);
    }
}


// TwitchAwareness
/++
 +  Implements scraping of Twitch message events for user details in a module.
 +
 +  Twitch doesn't always enumerate channel participants upon joining a channel.
 +  It seems to mostly be done on larger channels, and only rarely when the
 +  channel is small.
 +
 +  There is a chance of a user leak, if parting users are not broadcast. As
 +  such we mark when the user was last seen in the
 +  `kameloso.irc.defs.IRCUser.lastWhois` member, which opens up the possibility
 +  of pruning the plugin's `IRCPluginState.users` array of old entries.
 +
 +  Twitch awareness needs channel awareness, or it is meaningless.
 +/
version(WithPlugins)
version(TwitchSupport)
mixin template TwitchAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    static assert(__traits(compiles, .hasChannelAwareness), module_ ~
        " is missing ChannelAwareness mixin (needed for TwitchAwareness).");

    static if (__traits(compiles, .hasTwitchAwareness))
    {
        static assert(0, "Double mixin of TwitchAwareness in module " ~ module_);
    }
    else
    {
        enum hasTwitchAwareness = true;
    }


    // onTwitchAwarenessSenderCarryingEvent
    /++
     +  Catch senders from normal Twitch events.
     +
     +  This has to be done on certain Twitch channels whose participants are
     +  not enumerated upon joining it, nor joins or parts announced. By
     +  listening for any message and catching the user that way we ensure we
     +  scrape the channel for everyone that's actively chatting.
     +
     +  The users array will only grow and grow. Special care has to be manually
     +  taken to prune old users, ideally by periodically comparing their
     +  `kameloso.irc.defs.IRCUser.lastWhois` timestamps and removing those that
     +  are too old.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.CHAN)
    @(IRCEvent.Type.EMOTE)
    @(IRCEvent.Type.TWITCH_SUB)
    @(IRCEvent.Type.TWITCH_SUBGIFT)
    @(IRCEvent.Type.TWITCH_REWARDGIFT)
    @(IRCEvent.Type.TWITCH_GIFTUPGRADE)
    @(IRCEvent.Type.TWITCH_CHEER)
    @(IRCEvent.Type.TWITCH_PURCHASE)
    @(IRCEvent.Type.TWITCH_RAID)
    @(IRCEvent.Type.TWITCH_RITUAL)
    @channelPolicy
    void onTwitchAwarenessSenderCarryingEvent(IRCPlugin plugin, const IRCEvent event)
    {
        if (plugin.state.client.server.daemon != IRCServer.Daemon.twitch) return;

        import std.algorithm.searching : canFind;

        auto channel = event.channel in plugin.state.channels;

        if (!channel.users.canFind(event.sender.nickname))
        {
            channel.users ~= event.sender.nickname;
        }

        plugin.catchUser(event.sender);
    }
}


version(TwitchSupport) {}
else
/++
 +  No-op mixin of version !TwitchSupport TwitchAwareness.
 +/
mixin template TwitchAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    static if (__traits(compiles, .hasTwitchAwareness))
    {
        static assert(0, "Double mixin of TwitchAwareness in module " ~ module_);
    }
    else
    {
        enum hasTwitchAwareness = true;
    }
}


// prefixPolicyMatches
/++
 +  Evaluates whether or not the message in an event satisfies the `PrefixPolicy`
 +  specified, as fetched from a `BotCommand` or `BotRegex` UDA.
 +
 +  If it doesn't match, the `onEvent` routine shall consider the UDA as not
 +  matching and continue with the next one.
 +
 +  Params:
 +      client = `kameloso.irc.common.IRCClient` of the calling `IRCPlugin`'s `IRCPluginState`.
 +      policy = Policy to apply.
 +      mutEvent = Reference to the mutable `kameloso.irc.defs.IRCEvent` we're considering.
 +
 +  Returns:
 +      `true` if the message is in a context where the event matches the
 +      `policy`, `false` if not.
 +
 +  TODO:
 +      Support for verbose.
 +/
bool prefixPolicyMatches(const IRCClient client, const PrefixPolicy policy, ref IRCEvent mutEvent)
{
    import kameloso.common : settings;
    import kameloso.string : beginsWith, nom, stripPrefix;
    import std.typecons : No, Yes;

    with (mutEvent)
    with (PrefixPolicy)
    final switch (policy)
    {
    case direct:
        return true;

    case prefixed:
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

    case optionalNickname:
        if (content.beginsWith('@'))
        {
            // Using @name to refer to someone is not
            // uncommon; allow for it and strip it away
            content = content[1..$];
        }

        if (content.beginsWith(client.nickname))
        {
            content = content.stripPrefix(client.nickname);
        }
        break;

    case requiredNickname:
        if (type == IRCEvent.Type.QUERY)
        {
            /*static if (verbose)
            {
                writeln(name, "but it is a query, consider optional");
                version(FlushStdout) stdout.flush();
            }*/
            goto case optionalNickname;
        }

        if (content.beginsWith('@'))
        {
            content = content[1..$];
        }

        if (content.beginsWith(client.nickname) && (content.length > client.nickname.length))
        {
            /*static if (verbose)
            {
                writefln("%s trailing character '%s'", name, content[client.nickname.length]);
            }*/

            switch (content[client.nickname.length])
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
        // client.nickname here
        content = content.stripPrefix(client.nickname);
        break;
    }

    return true;
}


// catchUser
/++
 +  Catch an `kameloso.irc.defs.IRCUser`, saving it to the `IRCPlugin`'s
 +  `IRCPluginState.users` array.
 +
 +  If a user already exists, meld the new information into the old one.
 +
 +  Params:
 +      plugin = Current `IRCPlugin`.
 +      newUser = The `kameloso.irc.defs.IRCUser` to catch.
 +/
void catchUser(IRCPlugin plugin, IRCUser newUser) @safe
{
    if (!newUser.nickname.length || (newUser.nickname == plugin.state.client.nickname))
    {
        return;
    }

    version(TwitchSupport)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            import std.datetime.systime : Clock;

            // There's no need to meld Twitch users, they never change.
            if (auto user = newUser.nickname in plugin.state.users)
            {
                user.lastWhois = Clock.currTime.toUnixTime;
            }
            else
            {
                newUser.lastWhois = Clock.currTime.toUnixTime;
                plugin.state.users[newUser.nickname] = newUser;
            }
            return;
        }
    }

    if (auto user = newUser.nickname in plugin.state.users)
    {
        import kameloso.meld : meldInto;
        newUser.meldInto(*user);
    }
    else
    {
        plugin.state.users[newUser.nickname] = newUser;
    }
}


// doWhois
/++
 +  Construct and queue a `WHOIS` request in the local request queue.
 +
 +  The main loop will catch up on it and do the necessary `WHOIS` calls, then
 +  replay the event.
 +
 +  Params:
 +      plugin = Current `IRCPlugin`.
 +      payload = Payload to attach to the `WHOISRequest`, generally an
 +          `kameloso.irc.defs.IRCEvent` to replay once the `WHOIS` results return.
 +      event = `kameloso.irc.defs.IRCEvent` that instigated this `WHOIS` call.
 +      privilegeLevel = Privilege level to compare the user with.
 +      fn = Function/delegate pointer to call when the results return.
 +/
void doWhois(F, Payload)(IRCPlugin plugin, Payload payload, const IRCEvent event,
    PrivilegeLevel privilegeLevel, F fn)
{
    version(TwitchWarnings)
    {
        if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
        {
            import kameloso.common : logger;
            import kameloso.printing : printObject;

            logger.warning("Tried to WHOIS on Twitch");
            printObject(event);
            return;
        }
    }

    immutable user = event.sender.isServer ? event.target : event.sender;
    assert(user.nickname.length, "Bad user derived in doWhois (no nickname.length)");

    static if (!is(Payload == typeof(null)))
    {
        plugin.state.whoisQueue[user.nickname] ~= whoisRequest(payload, event, privilegeLevel, fn);
    }
    else
    {
        plugin.state.whoisQueue[user.nickname] ~= whoisRequest(event, privilegeLevel, fn);
    }
}

/// Ditto
void doWhois(F)(IRCPlugin plugin, const IRCEvent event, PrivilegeLevel privilegeLevel, F fn)
{
    return doWhois!(F, typeof(null))(plugin, null, event, privilegeLevel, fn);
}


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
 +
 +  Returns:
 +      `true` if no setting name mismatches occured, `false` if it did.
 +/
bool applyCustomSettings(IRCPlugin[] plugins, string[] customSettings) @trusted
{
    import kameloso.common : logger, settings;
    import kameloso.string : contains, nom;

    string logtint, warningtint;

    version(Colours)
    {
        if (!settings.monochrome)
        {
            import kameloso.logger : KamelosoLogger;

            logtint = (cast(KamelosoLogger)logger).logtint;
            warningtint = (cast(KamelosoLogger)logger).warningtint;
        }
    }

    bool noErrors = true;

    top:
    foreach (immutable line; customSettings)
    {
        string slice = line;
        string pluginstring;
        string setting;
        string value;

        if (!slice.contains!(Yes.decode)("."))
        {
            logger.warningf(`Bad %splugin%s.%1$ssetting%2$s=%1$svalue%2$s format. ("%1$s%3$s%2$s")`,
                logtint, warningtint, line);
            continue;
        }

        import std.uni : toLower;
        pluginstring = slice.nom!(Yes.decode)(".").toLower;

        if (slice.contains!(Yes.decode)("="))
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

            foreach (plugin; plugins)
            {
                settings.setMemberByName(setting, value);
            }

            continue top;
        }
        else
        {
            foreach (plugin; plugins)
            {
                if (plugin.name != pluginstring) continue;

                immutable success = plugin.setSettingByName(setting, value);

                if (!success)
                {
                    logger.warningf("No such %s%s%s plugin setting: %1$s%4$s",
                        logtint, plugin.name, warningtint, setting);
                    noErrors = false;
                }

                continue top;
            }
        }

        logger.warning("Invalid plugin: ", logtint, pluginstring);
        noErrors = false;
    }

    return noErrors;
}


// delayFiber
/++
 +  Queues a `core.thread.Fiber` to be called at a point n seconds later, by
 +  appending it to `timedFibers`.
 +
 +  It only supports a precision of a *worst* case of
 +  `kameloso.constants.Timeout.receive` * 3 + 1 seconds, but generally less
 +  than that. See the main loop for more information.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed at a later point in time.
 +      secs = Number of seconds to delay the `fiber`.
 +/
void delayFiber(IRCPlugin plugin, Fiber fiber, const long secs)
{
    import kameloso.common : labeled;
    import std.datetime.systime : Clock;

    immutable time = Clock.currTime.toUnixTime + secs;
    plugin.state.timedFibers ~= labeled(fiber, time);
}


// delayFiber
/++
 +  Queues a `core.thread.Fiber` to be called at a point n seconds later, by
 +  appending it to `timedFibers`.
 +
 +  Overload that implicitly queues `Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      secs = Number of seconds to delay the implicit fiber in the current context.
 +/
void delayFiber(IRCPlugin plugin, const long secs)
{
    return plugin.delayFiber(Fiber.getThis, secs);
}


// awaitEvent
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `kameloso.irc.defs.IRCEvent` matches the passed
 +  `kameloso.irc.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed when the next
 +          `kameloso.irc.defs.IRCEvent` of type `type` comes along.
 +      type = The kind of `kameloso.irc.defs.IRCEvent` that should trigger the
 +          passed awaiting fiber.
 +/
void awaitEvent(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
{
    plugin.state.awaitingFibers[type] ~= fiber;
}


// awaitEvent
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `kameloso.irc.defs.IRCEvent` matches the passed
 +  `kameloso.irc.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      type = The kind of `kameloso.irc.defs.IRCEvent` that should trigger this
 +          implicit awaiting fiber (in the current context).
 +/
void awaitEvent(IRCPlugin plugin, const IRCEvent.Type type)
{
    plugin.state.awaitingFibers[type] ~= Fiber.getThis;
}


// awaitEvents
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `kameloso.irc.defs.IRCEvent` matches all of the passed
 +  `kameloso.irc.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed when the next
 +          `kameloso.irc.defs.IRCEvent` of type `type` comes along.
 +      types = The kinds of `kameloso.irc.defs.IRCEvent` that should trigger
 +          the passed awaiting fiber, in an array with elements of type
 +          `kameloso.irc.defs.IRCEvent.Type`.
 +/
void awaitEvents(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        plugin.state.awaitingFibers[type] ~= fiber;
    }
}


// awaitEvents
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `kameloso.irc.defs.IRCEvent` matches all of the passed
 +  `kameloso.irc.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      types = The kinds of `kameloso.irc.defs.IRCEvent` that should trigger
 +          this implicit awaiting fiber (in the current context), in an array
 +          with elements of type `kameloso.irc.defs.IRCEvent.Type`.
 +/
void awaitEvents(IRCPlugin plugin, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    }
}


// IRCPluginInitialisationException
/++
 +  Exception thrown when an IRC plugin failed to initialise itself or its resources.
 +
 +  A normal `Exception`, which only differs in the sense that we can deduce
 +  what went wrong by its type.
 +/
final class IRCPluginInitialisationException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message, const string file = __FILE__, const int line = __LINE__)
    {
        super(message, file, line);
    }
}


// IRCPluginSettingsException
/++
 +  Exception thrown when an IRC plugin failed to have its settings set.
 +
 +  A normal `Exception`, which only differs in the sense that we can deduce
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


// WHOISFiberDelegate
/++
 +  Functionality for catching WHOIS results and calling passed function aliases
 +  with the resulting account information that was divined from it, in the form
 +  of the actual `kameloso.irc.defs.IRCEvent`, the target
 +  `kameloso.irc.defs.IRCUser` within it, the user's `account` field, or merely
 +  alone as an arity-0 function.
 +
 +  The mixed in function to call is named `enqueueAndWHOIS`. It will construct
 +  the Fiber, enqueue it as awaiting the proper IRCEvent types, and issue the
 +  WHOIS request.
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
 +/
import std.traits : isSomeFunction;
mixin template WHOISFiberDelegate(alias onSuccess, alias onFailure = null)
if (isSomeFunction!onSuccess && (is(typeof(onFailure) == typeof(null)) || isSomeFunction!onFailure))
{
    static assert((__traits(compiles, plugin) || __traits(compiles, service)),
        "WHOISFiberDelegate should be mixed into the context of a plugin. " ~
        "(Could not access neither plugin nor service)");

    import std.conv : text;

    enum carriedVariableName = text("_carriedNickname", hashOf(__FUNCTION__) % 100);
    mixin("string " ~ carriedVariableName ~ ';');

    /// Reusable mixin that catches WHOIS results.
    void whoisFiberDelegate()
    {
        import kameloso.irc.defs : IRCEvent, IRCUser;
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != IRCEvent.init), "Uninitialised payload in carrying fiber");

        const whoisEvent = thisFiber.payload;

        with (IRCEvent.Type)
        with (whoisEvent)
        {
            import kameloso.conv : Enum;
            assert(((type == RPL_WHOISACCOUNT) || (type == RPL_WHOISREGNICK) ||
                (type == RPL_ENDOFWHOIS) || (type == ERR_NOSUCHNICK) || (type == ERR_UNKNOWNCOMMAND)),
                "WHOIS Fiber delegate was invoked with an unexpected event type: " ~
                Enum!(IRCEvent.Type).toString(type));
        }

        if (whoisEvent.type == IRCEvent.Type.ERR_UNKNOWNCOMMAND) return;

        immutable m = plugin.state.client.server.caseMapping;

        if (IRCUser.toLowerCase(mixin(carriedVariableName), m) !=
            IRCUser.toLowerCase(whoisEvent.target.nickname, m))
        {
            // Wrong WHOIS; await a new one
            Fiber.yield();
            return whoisFiberDelegate();  // Recurse
        }

        import std.meta : AliasSeq;
        import std.traits : Parameters, Unqual, arity, staticMap;

        if ((whoisEvent.type == IRCEvent.Type.RPL_WHOISACCOUNT) ||
            (whoisEvent.type == IRCEvent.Type.RPL_WHOISREGNICK))
        {
            alias Params = staticMap!(Unqual, Parameters!onSuccess);

            static if (is(Params : AliasSeq!IRCEvent))
            {
                return onSuccess(whoisEvent);
            }
            else static if (is(Params : AliasSeq!IRCUser))
            {
                return onSuccess(whoisEvent.target);
            }
            else static if (is(Params : AliasSeq!string))
            {
                return onSuccess(whoisEvent.target.account);
            }
            else static if (arity!onSuccess == 0)
            {
                return onSuccess();
            }
            else
            {
                pragma(msg, typeof(onSuccess).stringof ~ "  " ~ __traits(identifier, onSuccess));
                pragma(msg, Params);
                static assert(0, "Unexpected signature of success function " ~
                    "alias passed to mixin WHOISFiberDelegate");
            }
        }
        else /* if ((whoisEvent.type == IRCEvent.Type.RPL_ENDOFWHOIS) ||
            (whoisEvent.type == IRCEvent.Type.ERR_NOSUCHNICK)) */
        {
            static if (!is(typeof(onFailure) == typeof(null)))
            {
                alias Params = staticMap!(Unqual, Parameters!onFailure);

                static if (is(Params : AliasSeq!IRCEvent))
                {
                    return onFailure(whoisEvent);
                }
                else static if (is(Params : AliasSeq!IRCUser))
                {
                    return onFailure(whoisEvent.target);
                }
                else static if (is(Params : AliasSeq!string))
                {
                    return onFailure(whoisEvent.target.account);
                }
                else static if (arity!onFailure == 0)
                {
                    return onFailure();
                }
                else
                {
                    pragma(msg, typeof(onFailure).stringof ~ "  " ~ __traits(identifier, onFailure));
                    pragma(msg, Params);
                    static assert(0, "Unexpected signature of failure function " ~
                        "alias passed to mixin WHOISFiberDelegate");
                }
            }
        }
    }

    /++
     +  Constructs a `CarryingFiber!IRCEvent` and enqueues it into the
     +  `awaitingFibers` associative array, then issues a `WHOIS` call.
     +
     +  Params:
     +      nickname = Nickname to issue a `WHOIS` query for.
     +/
    void enqueueAndWHOIS(const string nickname)
    {
        import kameloso.messaging : raw;
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;
        import std.typecons : No, Yes;

        version(TwitchWarnings)
        {
            if (plugin.state.client.server.daemon == IRCServer.Daemon.twitch)
            {
                import kameloso.common : logger;
                logger.warning("Tried to enqueue and WHOIS on Twitch");
                return;
            }
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&whoisFiberDelegate);

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
            assert(0, "WHOISFiberDelegate mixed in into incorrect context; " ~
                "neither plugin nor service visible");
        }

        with (IRCEvent.Type)
        {
            static immutable types =
            [
                RPL_WHOISACCOUNT,
                RPL_WHOISREGNICK,
                RPL_ENDOFWHOIS,
                ERR_NOSUCHNICK,
                ERR_UNKNOWNCOMMAND,
            ];

            context.awaitEvents(fiber, types);
        }

        context.state.raw!(Yes.priority)("WHOIS " ~ nickname);
        mixin(carriedVariableName) = nickname;
    }
}

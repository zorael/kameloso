/++
 +  The is not a plugin by itself but contains code common to all plugins,
 +  without which they will *not* function.
 +
 +  It is mandatory if you plan to use any form of plugin. Indeed, the very
 +  definition of an `IRCPlugin` is in here.
 +/
module kameloso.plugins.common;

private:

import kameloso.plugins.ircplugin;
import dialect.defs;
import core.thread : Fiber;
import std.typecons : Flag, No, Yes;

//version = TwitchWarnings;
version = PrefixedCommandsFallBackToNickname;
//version = ExplainReplay;


/++
 +  2.079.0 has a bug that breaks plugin processing completely. It's fixed in
 +  patch .1 (2.079.1), but there's no API for knowing the patch number.
 +
 +  Infer it by testing for the broken behaviour and warn (during compilation).
 +/
static if (__VERSION__ == 2079L)
{
    import lu.traits : getSymbolsByUDA;

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
        pragma(msg, "WARNING: You are using a `2.079.0` compiler with a broken " ~
            "crucial trait in its standard library. The program will not " ~
            "function normally. Please upgrade to `2.079.1` or later.");
    }
}


public:


// TriggerRequest
/++
 +  A queued event to be replayed upon a `WHOIS` request response.
 +
 +  It is abstract; all objects must be of a concrete `TriggerRequestImpl` type.
 +/
abstract class TriggerRequest
{
    /// Stored `dialect.defs.IRCEvent` to replay.
    IRCEvent event;

    /// `PrivilegeLevel` of the function to replay.
    PrivilegeLevel privilegeLevel;

    /// When this request was issued.
    long when;

    /// Replay the stored event.
    void trigger();

    /// Creates a new `TriggerRequest` with a timestamp of the current time.
    this() @safe
    {
        import std.datetime.systime : Clock;
        when = Clock.currTime.toUnixTime;
    }
}


// TriggerRequestImpl
/++
 +  Implementation of a queued `WHOIS` request call.
 +
 +  It functions like a Command pattern object in that it stores a payload and
 +  a function pointer, which we queue and do a `WHOIS` call. When the response
 +  returns we trigger the object and the original `dialect.defs.IRCEvent`
 +  is replayed.
 +
 +  Params:
 +      F = Some function type.
 +      Payload = Optional payload type.
 +/
private final class TriggerRequestImpl(F, Payload = typeof(null)) : TriggerRequest
{
@safe:
    /// Stored function pointer/delegate.
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the `dialect.defs.IRCEvent`.
        Payload payload;


        /++
         +  Create a new `TriggerRequestImpl` with the passed variables.
         +
         +  Params:
         +      payload = Payload of templated type `Payload` to attach to this
         +          `TriggerRequestImpl`.
         +      event = `dialect.defs.IRCEvent` to attach to this
         +          `TriggerRequestImpl`.
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
         +  Create a new `TriggerRequestImpl` with the passed variables.
         +
         +  Params:
         +      payload = Payload of templated type `Payload` to attach to this
         +          `TriggerRequestImpl`.
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


    // trigger
    /++
     +  Call the passed function/delegate pointer, optionally with the stored
     +  `dialect.defs.IRCEvent` and/or `Payload`.
     +/
    override void trigger() @system
    {
        import std.meta : AliasSeq, staticMap;
        import std.traits : Parameters, Unqual, arity;

        assert((fn !is null), "null fn in `" ~ typeof(this).stringof ~ '`');

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
            import std.format : format;
            static assert(0, ("`TriggerRequestImpl` instantiated with an invalid " ~
                "trigger function signature: `%s`")
                .format(F.stringof));
        }
    }
}

unittest
{
    TriggerRequest[] queue;

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

    TriggerRequest reqdg = new TriggerRequestImpl!(void delegate())(event, pl, &dg);
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

    auto reqfn = triggerRequest(event, pl, &fn);
    queue ~= reqfn;

    // delegate(ref IRCEvent)

    void dg2(ref IRCEvent thisEvent)
    {
        thisEvent.content = "blah";
    }

    auto reqdg2 = triggerRequest(event, pl, &dg2);
    queue ~= reqdg2;

    assert((reqdg2.event.content == "hirrpp"), event.content);
    reqdg2.trigger();
    assert((reqdg2.event.content == "blah"), event.content);

    // function(IRCEvent)

    static void fn2(IRCEvent thisEvent) { }

    auto reqfn2 = triggerRequest(event, pl, &fn2);
    queue ~= reqfn2;
}


// Replay
/++
 +  An event to be replayed from the context of the main loop, optionally after
 +  having re-postprocessed it.
 +
 +  With this plugins get an ability to postprocess on demand, which is needed
 +  to apply user classes to stored events, such as those saved before issuing
 +  WHOIS queries.
 +/
struct Replay
{
private:
    import kameloso.thread : CarryingFiber;
    import std.traits : Unqual;

    alias This = Unqual!(typeof(this));

public:
    /// `core.thread.Fiber` to call to invoke this replay.
    Fiber fiber;


    // carryingFiber
    /++
     +  Returns `fiber` as a `kameloso.thread.CarryingFiber`, blindly assuming
     +  it can be cast thus.
     +
     +  Returns:
     +      `fiber`, cast as a `kameloso.thread.CarryingFiber`!`Replay`.
     +/
    CarryingFiber!This carryingFiber() pure inout @nogc @property
    {
        auto carrying = cast(CarryingFiber!This)fiber;
        assert(carrying, "Tried to get a `CarryingFiber!Replay` out of a normal Fiber");
        return carrying;
    }


    // isCarrying
    /++
     +  Returns whether or not `fiber` is actually a
     +  `kameloso.thread.CarryingFiber`!`Replay`.
     +
     +  Returns:
     +      `true` if it is of such a subclass, `false` if not.
     +/
    bool isCarrying() const pure @nogc @property
    {
        return cast(CarryingFiber!This)fiber !is null;
    }

    /// The `dialect.defs.IRCEvent` to replay.
    IRCEvent event;

    /// UNIX timestamp of when this replay event was created.
    long created;

    /// Constructor taking a `core.thread.Fiber` and an `dialect.defs.IRCEvent`.
    this(Fiber fiber, const IRCEvent event) @safe
    {
        import std.datetime.systime : Clock;
        created = Clock.currTime.toUnixTime;
        this.fiber = fiber;
        this.event = event;
    }
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
    import kameloso.common : IRCBot;
    import kameloso.thread : ScheduledFiber;
    import std.concurrency : Tid;
    import core.thread : Fiber;

    /++
     +  The current `dialect.defs.IRCClient`, containing information pertaining
     +  to the bot in the context of a client connected to an IRC server.
     +/
    IRCClient client;

    /++
     +  The current `dialect.defs.IRCServer`, containing information pertaining
     +  to the bot in the context of an IRC server.
     +/
    IRCServer server;

    /++
     +  The current `kameloso.common.IRCBot`, containing information pertaining
     +  to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
     +  Queued `WHOIS` requests and pertaining `dialect.defs.IRCEvent`s to
     +  replay.
     +
     +  The main loop iterates this after processing all on-event functions so
     +  as to know what nicks the plugin wants a `WHOIS` for. After the `WHOIS`
     +  response returns, the event bundled with the `TriggerRequest` will be replayed.
     +/
    TriggerRequest[][string] triggerRequestQueue;

    /// This plugin's array of `Replay`s to let the main loop play back.
    Replay[] replays;

    /++
     +  The list of awaiting `core.thread.Fiber`s, keyed by
     +  `dialect.defs.IRCEvent.Type`.
     +/
    Fiber[][] awaitingFibers;

    /// The list of scheduled `core.thread.Fiber`, UNIX time tuples.
    ScheduledFiber[] scheduledFibers;

    /// The next (UNIX time) timestamp at which to call `periodically`.
    long nextPeriodical;

    /++
     +  The UNIX timestamp of when the next queued
     +  `kameloso.common.ScheduledFiber` should be triggered.
     +/
    long nextFiberTimestamp;


    // updateNextFiberTimestamp
    /++
     +  Updates the saved UNIX timestamp of when the next `core.thread.Fiber`
     +  should be triggered.
     +/
    void updateNextFiberTimestamp() pure nothrow @nogc
    {
        // Reset the next timestamp to an invalid value, then update it as we
        // iterate the fibers' labels.

        nextFiberTimestamp = long.max;

        foreach (const scheduledFiber; scheduledFibers)
        {
            if (scheduledFiber.timestamp < nextFiberTimestamp)
            {
                nextFiberTimestamp = scheduledFiber.timestamp;
            }
        }
    }

    /// Whether or not `bot` was altered. Must be reset manually.
    bool botUpdated;

    /// Whether or not `client` was altered. Must be reset manually.
    bool clientUpdated;

    /// Whether or not `server` was altered. Must be reset manually.
    bool serverUpdated;
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
 +      `true` if no setting name mismatches occurred, `false` if it did.
 +/
bool applyCustomSettings(IRCPlugin[] plugins, const string[] customSettings)
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
        immutable value = slice.length ? slice : "true";  // default setting if none given

        if (pluginstring == "core")
        {
            import kameloso.common : initLogger, settings;
            import lu.objmanip : setMemberByName;

            try
            {
                immutable success = settings.setMemberByName(setting, value);

                if (!success)
                {
                    logger.warningf("No such %score%s setting: %1$s%3$s",
                        Tint.log, Tint.warning, setting);
                    noErrors = false;
                }
                else if ((setting == "monochrome") || (setting == "brightTerminal"))
                {
                    initLogger(settings.monochrome, settings.brightTerminal, settings.flush);
                }
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
                    immutable success = plugin.setSettingByName(setting, value);

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

    applyCustomSettings([ plugin ], newSettings);

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

    private struct MyPluginSettings
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
        @Settings MyPluginSettings myPluginSettings;

        string name() @property const
        {
            return "myplugin";
        }

        mixin IRCPluginImpl;
    }
}


// IRCPluginInitialisationException
/++
 +  Exception thrown when an IRC plugin failed to initialise itself or its resources.
 +
 +  A normal `object.Exception`, which only differs in the sense that we can deduce
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


package:


// filterResult
/++
 +  The tristate results from comparing a username with the admin or whitelist lists.
 +/
enum FilterResult
{
    fail,   /// The user is not allowed to trigger this function.
    pass,   /// The user is allowed to trigger this function.

    /++
     +  We don't know enough to say whether the user is allowed to trigger this
     +  function, so do a WHOIS query and act based on the results.
     +/
    whois,
}


// PrefixPolicy
/++
 +  In what way the contents of a `dialect.defs.IRCEvent` should start (be "prefixed")
 +  for an annotated function to be allowed to trigger.
 +/
enum PrefixPolicy
{
    /++
     +  The annotated event handler will not examine the `dialect.defs.IRCEvent.content`
     +  member at all and will always trigger, as long as all other annotations match.
     +/
    direct,

    /++
     +  The annotated event handler will only trigger if the `dialect.defs.IRCEvent.content`
     +  member starts with the `kameloso.common.CoreSettings.prefix` (e.g. "!").
     +  All other annotations must also match.
     +/
    prefixed,

    /++
     +  The annotated event handler will only trigger if the `dialect.defs.IRCEvent.content`
     +  member starts with the bot's name, as if addressed to it.
     +
     +  In `dialect.defs.IRCEvent.Type.QUERY` events this instead behaves as
     +  `PrefixPolicy.direct`.
     +/
    nickname,
}


// ChannelPolicy
/++
 +  Whether an annotated function should be allowed to trigger on events in only
 +  home channels or in guest ones as well.
 +/
enum ChannelPolicy
{
    /++
     +  The annotated function will only be allowed to trigger if the event
     +  happened in a home channel, where applicable. Not all events carry channels.
     +/
    home,

    /++
     +  The annotated function will be allowed to trigger regardless of channel.
     +/
    any,
}


// PrivilegeLevel
/++
 +  What level of privilege is needed to trigger an event handler.
 +
 +  In any event handler context, the triggering user has a *level of privilege*.
 +  This decides whether or not they are allowed to trigger the function.
 +  Put simply this is the "barrier of entry" for event handlers.
 +
 +  Privileges are set on a per-channel basis and are stored in the "users.json"
 +  file in the resource directory.
 +/
enum PrivilegeLevel
{
    /++
     +  Override privilege checks, allowing anyone to trigger the annotated function.
     +/
    ignore = 0,

    /++
     +  Anyone not explicitly blacklisted (with a `dialect.defs.IRCClient.Class.blacklist`
     +  classifier) may trigger the annotated function. As such, to know if they're
     +  blacklisted, unknown users will first be looked up with a WHOIS query
     +  before allowing the function to trigger.
     +/
    anyone = 1,

    /++
     +  Anyone logged onto services may trigger the annotated function.
     +/
    registered = 2,

    /++
     +  Only users with a `dialect.defs.IRCClient.Class.whitelist` classifier
     +  may trigger the annotated function.
     +/
    whitelist = 3,

    /++
     +  Only users with a `dialect.defs.IRCClient.Class.operator` classifier
     +  may trigger the annotated function.
     +
     +  Note: this does not mean IRC "+o" operators.
     +/
    operator = 4,

    /++
     +  Only users defined in the configuration file as an administrator may
     +  trigger the annotated function.
     +/
    admin = 5,
}


// triggerRequest
/++
 +  Convenience function that returns a `TriggerRequestImpl` of the right type,
 +  *with* a subclass plugin reference attached.
 +
 +  Params:
 +      subPlugin = Subclass `IRCPlugin` to call the function pointer `fn` with
 +          as first argument, when the WHOIS results return.
 +      event = `dialect.defs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS` results.
 +      fn = Function/delegate pointer to call upon receiving the results.
 +
 +  Returns:
 +      A `TriggerRequest` with template parameters inferred from the arguments
 +      passed to this function.
 +/
TriggerRequest triggerRequest(Fn, SubPlugin)(SubPlugin subPlugin, const IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn) @safe
{
    return new TriggerRequestImpl!(Fn, SubPlugin)(subPlugin, event, privilegeLevel, fn);
}


// triggerRequest
/++
 +  Convenience function that returns a `TriggerRequestImpl` of the right type,
 +  *without* a subclass plugin reference attached.
 +
 +  Params:
 +      event = `dialect.defs.IRCEvent` that instigated the `WHOIS` lookup.
 +      privilegeLevel = The privilege level policy to apply to the `WHOIS` results.
 +      fn = Function/delegate pointer to call upon receiving the results.
 +
 +  Returns:
 +      A `TriggerRequest` with template parameters inferred from the arguments
 +      passed to this function.
 +/
TriggerRequest triggerRequest(Fn)(const IRCEvent event, const PrivilegeLevel privilegeLevel, Fn fn) @safe
{
    return new TriggerRequestImpl!Fn(event, privilegeLevel, fn);
}


// BotCommand
/++
 +  Defines an IRC bot command, for people to trigger with messages.
 +
 +  If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.prefixed`
 +  and look for `kameloso.common.CoreSettings.prefix` at the beginning of
 +  messages, to prefix the command `word`. (Usually "`!`", making it "`!command`".)
 +
 +  Example:
 +  ---
 +  @(IRCEvent.Type.CHAN)
 +  @(ChannelPolicy.home)
 +  @BotCommand(PrefixPolicy.prefixed, "foo")
 +  @BotCommand(PrefixPolicy.prefixed, "bar")
 +  void onCommandFooOrBar(MyPlugin plugin, const IRCEvent event)
 +  {
 +      // ...
 +  }
 +  ---
 +/
struct BotCommand
{
    /++
     +  In what way the message is required to start for the annotated function to trigger.
     +/
    PrefixPolicy policy = PrefixPolicy.prefixed;

    /++
     +  The command word, without spaces.
     +/
    string word;

    /++
     +  Create a new `BotCommand` with the passed policy and trigger word.
     +/
    this(const PrefixPolicy policy, const string word) pure
    {
        this.policy = policy;
        this.word = word;
    }

    /++
     +  Create a new `BotCommand` with a default `PrefixPolicy.prefixed` policy
     +  and the passed trigger word.
     +/
    this(const string word) pure
    {
        this.word = word;
    }
}


// BotRegex
/++
 +  Defines an IRC bot regular expression, for people to trigger with messages.
 +
 +  If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.direct`
 +  and try to match the regex on all messages, regardless of how they start.
 +
 +  Example:
 +  ---
 +  @(IRCEvent.Type.CHAN)
 +  @(ChannelPolicy.home)
 +  @BotRegex(PrefixPolicy.direct, r"(?:^|\s)MonkaS(?:$|\s)")
 +  void onSawMonkaS(MyPlugin plugin, const IRCEvent event)
 +  {
 +      // ...
 +  }
 +  ---
 +
 +/
struct BotRegex
{
    import std.regex : Regex, regex;

    /++
     +  In what way the message is required to start for the annotated function to trigger.
     +/
    PrefixPolicy policy = PrefixPolicy.direct;

    /++
     +  Regex engine to match incoming messages with.
     +/
    Regex!char engine;

    /++
     +  The regular expression in string form.
     +/
    string expression;

    /++
     +  Creates a new `BotRegex` with the passed policy and regex expression.
     +/
    this(const PrefixPolicy policy, const string expression)
    {
        this.policy = policy;

        if (!expression.length) return;

        this.engine = expression.regex;
        this.expression = expression;
    }

    /++
     +  Creates a new `BotRegex` with the passed regex expression.
     +/
    this(const string expression)
    {
        if (!expression.length) return;

        this.engine = expression.regex;
        this.expression = expression;
    }
}


// Chainable
/++
 +  Annotation denoting that an event-handling function let other functions in
 +  the same module process after it.
 +/
struct Chainable;


// Terminating
/++
 +  Annotation denoting that an event-handling function is the end of a chain,
 +  letting no other functions in the same module be triggered after it has been.
 +
 +  This is not strictly necessary since anything non-`Chainable` is implicitly
 +  `Terminating`, but it's here to silence warnings and in hopes of the code
 +  becoming more self-documenting.
 +/
struct Terminating;


// Verbose
/++
 +  Annotation denoting that we want verbose debug output of the plumbing when
 +  handling events, iterating through the module's event handler functions.
 +/
struct Verbose;


// Settings
/++
 +  Annotation denoting that a struct variable is to be as considered as housing
 +  settings for a plugin and should thus be serialised and saved in the configuration file.
 +/
struct Settings;


// Description
/++
 +  Describes an `dialect.defs.IRCEvent`-annotated handler function.
 +
 +  This is used to describe functions triggered by `BotCommand`s, in the help
 +  listing routine in `kameloso.plugins.chatbot`.
 +/
struct Description
{
    /// Description string.
    string line;

    /// Command usage syntax help string.
    string syntax;

    /// Creates a new `Description` with the passed `line` description text.
    this(const string line, const string syntax = string.init)
    {
        this.line = line;
        this.syntax = syntax;
    }
}


/++
 +  Annotation denoting that a variable is the basename of a resource file or directory.
 +/
struct Resource;


/++
 +  Annotation denoting that a variable is the basename of a configuration
 +  file or directory.
 +/
struct Configuration;


/++
 +  Annotation denoting that a variable enables and disables a plugin.
 +/
struct Enabler;


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
mixin template MessagingProxy(bool debug_ = false, string module_ = __MODULE__)
{
private:
    static import kameloso.messaging;
    static import kameloso.common;
    import std.functional : partial;
    import std.typecons : Flag, No, Yes;

    /// Symbol needed for the mixin constraints to work.
    enum mixinSentinel = true;

    // Use a custom constraint to force the scope to be an IRCPlugin
    static if(!is(__traits(parent, mixinSentinel) : IRCPlugin))
    {
        import lu.traits : CategoryName;
        import std.format : format;

        alias messagingParent = __traits(parent, mixinSentinel);
        alias messagingParentInfo = CategoryName!messagingParent;

        static assert(0, ("%s `%s` mixes in `%s` but it is only supposed to be " ~
            "mixed into an `IRCPlugin` subclass")
            .format(messagingParentInfo.type, messagingParentInfo.fqn, "MessagingProxy"));
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
     +  underlying same type; `dialect.defs.IRCEvent.Type.PRIVMSG`.
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
        const string key = string.init, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.join!priority(privateState, channel, key, quiet);
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
        return kameloso.messaging.part!priority(privateState, channel, reason, quiet);
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


    // whois
    /++
     +  Queries the server for `WHOIS` information about a user.
     +/
    void whois(Flag!"priority" priority = No.priority)(const string nickname,
        const bool force = false, const bool quiet = kameloso.common.settings.hideOutgoing)
    {
        return kameloso.messaging.whois!priority(privateState, nickname, force, quiet);
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


    // immediate
    /++
     +  Sends raw text to the server, verbatim, bypassing all queues and
     +  throttling delays.
     +/
    void immediate(const string line)
    {
        return kameloso.messaging.immediate(privateState, line);
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


// Replayer
/++
 +  Implements queueing of replay events.
 +
 +  This allows us to deal with triggers both in `dialect.defs.IRCEvent.Type.RPL_WHOISACCOUNT`
 +  and `dialect.defs.IRCEvent.Type.ERR_UNKNOWNCOMMAND` while keeping the code
 +  in one place.
 +
 +  Params:
 +      debug_ = Whether or not to print debug output to the terminal.
 +/
version(WithPlugins)
mixin template Replayer(bool debug_ = false, string module_ = __MODULE__)
{
    import lu.traits : MixinConstraints, MixinScope;
    import std.conv : text;
    import std.traits : isSomeFunction;

    mixin MixinConstraints!(MixinScope.function_, "Replayer");

    static if (__traits(compiles, hasReplayer))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("Replayer", __FUNCTION__));
    }
    else
    {
        private enum hasReplayer = true;
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
        import std.format : format;
        static assert(0, ("`Replayer` should be mixed into the context of an event handler. " ~
            "(Could not access variables named neither `plugin` nor `service` " ~
            "from within `%s`)").format(__FUNCTION__));
    }

    private enum requestVariableName = text("_kamelosoRequest", hashOf(__FUNCTION__) % 100);
    mixin("TriggerRequest " ~ requestVariableName ~ ';');

    // explainReplain
    /++
     +  Verbosely explains a replay, including what `PrivilegeLevel` and
     +  `dialect.defs.IRCUser.Class` were involved.
     +
     +  Gated behind version `ExplainReplay`.
     +/
    version(ExplainReplay)
    void explainReplay(const IRCUser user)
    {
        import kameloso.common : Tint, logger;
        import lu.conv : Enum;

        logger.logf("%s%s%s %s replaying %1$s%5$s%3$s-level event " ~
            "based on WHOIS results (user is %1$s%6$s%3$s class)",
            Tint.info, context.name, Tint.log, contextName,
            Enum!PrivilegeLevel.toString(mixin(requestVariableName).privilegeLevel),
            Enum!(IRCUser.Class).toString(user.class_));
    }


    // replayerDelegate
    /++
     +  Delegate to call from inside a `kameloso.thread.CarryingFiber`.
     +/
    void replayerDelegate()
    {
        import kameloso.thread : CarryingFiber;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!Replay)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != thisFiber.payload.init),
            "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

        auto request = mixin(requestVariableName);
        request.event = thisFiber.payload.event;

        with (PrivilegeLevel)
        final switch (request.privilegeLevel)
        {
        case admin:
            if (request.event.sender.class_ >= IRCUser.Class.admin)
            {
                goto case ignore;
            }
            break;

        case operator:
            if (request.event.sender.class_ >= IRCUser.Class.operator)
            {
                goto case ignore;
            }
            break;

        case whitelist:
            if (request.event.sender.class_ >= IRCUser.Class.whitelist)
            {
                goto case ignore;
            }
            break;

        case registered:
            if (request.event.sender.account.length)
            {
                goto case ignore;
            }
            break;

        case anyone:
            if (request.event.sender.class_ >= IRCUser.Class.anyone)
            {
                goto case ignore;
            }

            // request.event.sender.class_ is Class.blacklist here (or unset)
            // Do nothing an drop down
            break;

        case ignore:
            version(ExplainReplay) explainReplay(request.event.sender);
            request.trigger();
            break;
        }
    }

    /++
     +  Queues the delegate `replayerDelegate` with the passed `TriggerRequest`
     +  attached to it.
     +/
    void queueToReplay(TriggerRequest request)
    {
        mixin(requestVariableName) = request;
        context.queueToReplay(&replayerDelegate, request.event);
    }
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


// doWhois
/++
 +  Construct and queue a `WHOIS` request in the local request queue.
 +
 +  The main loop will catch up on it and issue the necessary `WHOIS` queries, then
 +  replay the event.
 +
 +  Params:
 +      plugin = Current `IRCPlugin` as a base class.
 +      subPlugin = Subclass `IRCPlugin` to call the function pointer `fn` with
 +          as first argument, when the WHOIS results return.
 +      event = `dialect.defs.IRCEvent` that instigated this `WHOIS` call.
 +      privilegeLevel = Privilege level to compare the user with.
 +      fn = Function/delegate pointer to call when the results return.
 +/
void doWhois(Fn, SubPlugin)(IRCPlugin plugin, SubPlugin subPlugin, const IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn)
in ((event != IRCEvent.init), "Tried to doWhois with an init IRCEvent")
in ((fn !is null), "Tried to doWhois with a null funtion pointer")
{
    import std.traits : isSomeFunction;

    static assert (isSomeFunction!Fn, "Tried to call `doWhois` with a non-function function");

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            version(TwitchWarnings)
            {
                import kameloso.common : logger, printStacktrace;
                import kameloso.printing : printObject;

                logger.warning(plugin.name, " tried to WHOIS on Twitch");
                printObject(event);
                version(PrintStacktraces) printStacktrace();
            }
            return;
        }
    }

    immutable user = event.sender.isServer ? event.target : event.sender;
    assert(user.nickname.length, "Bad user derived in doWhois (no nickname.length)");

    static if (is(SubPlugin == typeof(null)))
    {
        plugin.state.triggerRequestQueue[user.nickname] ~= triggerRequest(event, privilegeLevel, fn);
    }
    else
    {
        plugin.state.triggerRequestQueue[user.nickname] ~= triggerRequest(subPlugin, event, privilegeLevel, fn);
    }
}


// doWhois
/++
 +  Construct and queue a `WHOIS` request in the local request queue.
 +
 +  The main loop will catch up on it and issue the necessary `WHOIS` queries, then
 +  replay the event.
 +
 +  Overload that does not take an `IRCPlugin` subclass parameter.
 +
 +  Params:
 +      plugin = Current `IRCPlugin` as a base class.
 +      event = `dialect.defs.IRCEvent` that instigated this `WHOIS` call.
 +      privilegeLevel = Privilege level to compare the user with.
 +      fn = Function/delegate pointer to call when the results return.
 +/
void doWhois(Fn)(IRCPlugin plugin, const IRCEvent event, const PrivilegeLevel privilegeLevel, Fn fn)
{
    return doWhois(plugin, null, event, privilegeLevel, fn);
}


// queueToReplay
/++
 +  Queues a `core.thread.Fiber` (actually a `kameloso.thread.CarryingFiber`
 +  with a `Replay` payload) to replay a passed `dialect.defs.IRCEvent` from the
 +  context of the main loop, after postprocessing the event once more.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      dg = Delegate/function pointer to wrap the `core.thread.Fiber` around.
 +      event = The `dialect.defs.IRCEvent` to replay.
 +/
void queueToReplay(Dg)(IRCPlugin plugin, Dg dg, const IRCEvent event)
if (isSomeFunction!Dg)
in ((dg !is null), "Tried to queue a replay with a null delegate pointer")
in ((event != IRCEvent.init), "Tried to queue a replay with an init IRCEvent")
{
    import kameloso.thread : CarryingFiber;
    plugin.state.replays ~= Replay(new CarryingFiber!Replay(dg, 32768), event);
}


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


// delayFiber
/++
 +  Queues a `core.thread.Fiber` to be called at a point `secs` seconds later, by
 +  appending it to the `plugin`'s `IRCPluginState.scheduledFibers`.
 +
 +  Updates the `IRCPluginState.nextFiberTimestamp` UNIX timestamp so that the
 +  main loop knows when to next process the array of `kameloso.thread.ScheduledFiber`s.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed at a later point in time.
 +      secs = Number of seconds to delay the `fiber`.
 +/
void delayFiber(IRCPlugin plugin, Fiber fiber, const long secs)
in ((fiber !is null), "Tried to delay a null Fiber")
{
    import kameloso.thread : ScheduledFiber;
    import std.datetime.systime : Clock;

    immutable time = Clock.currTime.toUnixTime + secs;
    plugin.state.scheduledFibers ~= ScheduledFiber(fiber, time);
    plugin.state.updateNextFiberTimestamp();
}


// delayFiber
/++
 +  Queues a `core.thread.Fiber` to be called at a point n seconds later, by
 +  appending it to the `plugin`'s `IRCPluginState.scheduledFibers`.
 +
 +  Overload that implicitly queues `core.thread.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      secs = Number of seconds to delay the implicit fiber in the current context.
 +/
void delayFiber(IRCPlugin plugin, const long secs)
{
    return plugin.delayFiber(Fiber.getThis, secs);
}


// removeDelayedFiber
/++
 +  Removes a `core.thread.Fiber` from being called at any point later.
 +
 +  Updates the `nextFiberTimestamp` UNIX timestamp so that the main loop knows
 +  when to process the array of `core.thread.Fiber`s.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to dequeue from being executed at a later point in time.
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
 +  Removes a `core.thread.Fiber` from being called at any point later.
 +
 +  Overload that implicitly removes `core.thread.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +/
void removeDelayedFiber(IRCPlugin plugin)
{
    return plugin.removeDelayedFiber(Fiber.getThis);
}


// awaitEvent
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      type = The kind of `dialect.defs.IRCEvent` that should trigger the
 +          passed awaiting fiber.
 +/
void awaitEvent(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= fiber;
}


// awaitEvent
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `core.thread.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      type = The kind of `dialect.defs.IRCEvent` that should trigger this
 +          implicit awaiting fiber (in the current context).
 +/
void awaitEvent(IRCPlugin plugin, const IRCEvent.Type type)
in ((type != IRCEvent.Type.UNSET), "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`")
{
    plugin.state.awaitingFibers[type] ~= Fiber.getThis;
}


// awaitEvents
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to enqueue to be executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          the passed awaiting fiber, in an array with elements of type
 +          `dialect.defs.IRCEvent.Type`.
 +/
void awaitEvents(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
in ((fiber !is null), "Tried to set up a null Fiber to await events")
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= fiber;
    }
}


// awaitEvents
/++
 +  Queues a `core.thread.Fiber` to be called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Overload that implicitly queues `core.thread.Fiber.getThis`.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          this implicit awaiting fiber (in the current context), in an array
 +          with elements of type `dialect.defs.IRCEvent.Type`.
 +/
void awaitEvents(IRCPlugin plugin, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        assert((type != IRCEvent.Type.UNSET),
            "Tried to set up a Fiber to await `IRCEvent.Type.UNSET`");
        plugin.state.awaitingFibers[type] ~= Fiber.getThis;
    }
}


// unlistFiberAwaitingEvent
/++
 +  Dequeues a `core.thread.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to dequeue from being executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      type = The kind of `dialect.defs.IRCEvent` that would trigger the
 +          passed awaiting fiber.
 +/
void unlistFiberAwaitingEvent(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type type)
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


// unlistFiberAwaitingEvent
/++
 +  Dequeues a `core.thread.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches the passed
 +  `dialect.defs.IRCEvent.Type` type. Overload that implicitly dequeues
 +  `core.thread.Fiber.getThis`.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      type = The kind of `dialect.defs.IRCEvent` that would trigger this
 +          implicit awaiting fiber (in the current context).
 +/
void unlistFiberAwaitingEvent(IRCPlugin plugin, const IRCEvent.Type type)
{
    return plugin.unlistFiberAwaitingEvent(Fiber.getThis, type);
}


// unlistFiberAwaitingEvents
/++
 +  Dequeues a `core.thread.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types.
 +
 +  Not necessarily related to the `async/await` pattern in more than by name.
 +  Naming is hard.
 +
 +  Params:
 +      plugin = The current `IRCPlugin`.
 +      fiber = `core.thread.Fiber` to dequeue from being executed when the next
 +          `dialect.defs.IRCEvent` of type `type` comes along.
 +      types = The kinds of `dialect.defs.IRCEvent` that should trigger
 +          the passed awaiting fiber, in an array with elements of type
 +          `dialect.defs.IRCEvent.Type`.
 +/
void unlistFiberAwaitingEvents(IRCPlugin plugin, Fiber fiber, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        plugin.unlistFiberAwaitingEvent(fiber, type);
    }
}


// unlistFiberAwaitingEvents
/++
 +  Dequeues a `core.thread.Fiber` from being called whenever the next parsed and
 +  triggering `dialect.defs.IRCEvent` matches any of the passed
 +  `dialect.defs.IRCEvent.Type` types. Overload that implicitly dequeues
 +  `core.thread.Fiber.getThis`.
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
void unlistFiberAwaitingEvents(IRCPlugin plugin, const IRCEvent.Type[] types)
{
    foreach (immutable type; types)
    {
        plugin.unlistFiberAwaitingEvent(Fiber.getThis, type);
    }
}


import std.traits : isSomeFunction;

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
 +      alwaysLookup = Whether or not to always issue a WHOIS query, even if
 +          the requested user's account is already known.
 +/
mixin template WHOISFiberDelegate(alias onSuccess, alias onFailure = null, bool alwaysLookup = false)
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
    static immutable whoisEventTypes =
    [
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
        import std.algorithm.searching : canFind;
        import std.meta : AliasSeq;
        import std.traits : Parameters, Unqual, arity, staticMap;
        import core.thread : Fiber;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
        assert((thisFiber.payload != IRCEvent.init),
            "Uninitialised `payload` in " ~ typeof(thisFiber).stringof);

        immutable whoisEvent = thisFiber.payload;

        assert(whoisEventTypes.canFind(whoisEvent.type),
            "WHOIS Fiber delegate was invoked with an unexpected event type: " ~
            "`IRCEvent.Type." ~ Enum!(IRCEvent.Type).toString(whoisEvent.type) ~'`');

        /++
         +  Invoke `onSuccess`.
         +/
        void callOnSuccess()
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
                import std.format : format;
                static assert(0, ("Unsupported signature of success function/delegate " ~
                    "alias passed to mixin `WHOISFiberDelegate` in `%s`: `%s %s`")
                    .format(__FUNCTION__, typeof(onSuccess).stringof, __traits(identifier, onSuccess)));
            }
        }

        /++
         +  Invoke `onFailure`, if it's available.
         +/
        void callOnFailure()
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
                    import std.format : format;
                    static assert(0, ("Unsupported signature of failure function/delegate " ~
                        "alias passed to mixin `WHOISFiberDelegate` in `%s`: `%s %s`")
                        .format(__FUNCTION__, typeof(onFailure).stringof, __traits(identifier, onFailure)));
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

        // Clean up awaiting fiber entries on exit, just to be neat.
        scope(exit) context.unlistFiberAwaitingEvents(thisFiber, whoisEventTypes);

        if ((whoisEvent.type == IRCEvent.Type.RPL_WHOISACCOUNT) ||
            (whoisEvent.type == IRCEvent.Type.RPL_WHOISREGNICK))
        {
            callOnSuccess();
        }
        else /* if ((whoisEvent.type == IRCEvent.Type.RPL_ENDOFWHOIS) ||
            (whoisEvent.type == IRCEvent.Type.ERR_NOSUCHNICK)) */
        {
            callOnFailure();
        }
    }


    // enqueueAndWHOIS
    /++
     +  Constructs a `kameloso.thread.CarryingFiber!(dialect.defs.IRCEvent)`
     +  and enqueues it into the `awaitingFibers` associative array, then issues
     +  a `WHOIS` call.
     +
     +  Params:
     +      nickname = Nickname to issue a `WHOIS` query for.
     +/
    void enqueueAndWHOIS(const string nickname)
    {
        import kameloso.messaging : whois;
        import kameloso.thread : CarryingFiber;
        import std.meta : AliasSeq;
        import std.traits : Parameters, Unqual, arity, staticMap;
        import std.typecons : No, Yes;
        import core.thread : Fiber;

        alias Params = staticMap!(Unqual, Parameters!onSuccess);

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
                        static if (is(Params : AliasSeq!IRCEvent))
                        {
                            // No can do
                            return;
                        }
                        else static if (is(Params : AliasSeq!IRCUser))
                        {
                            return onSuccess(*user);
                        }
                        else static if (is(Params : AliasSeq!string))
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

                static if (is(Params : AliasSeq!IRCEvent))
                {
                    // No can do
                    return;
                }
                else static if (is(Params : AliasSeq!IRCUser))
                {
                    // No can do
                    return;
                }
                else static if (is(Params : AliasSeq!string))
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
                    static if (is(Params : AliasSeq!IRCEvent))
                    {
                        // No can do, drop down and WHOIS
                    }
                    else static if (is(Params : AliasSeq!IRCUser))
                    {
                        return onSuccess(*user);
                    }
                    else static if (is(Params : AliasSeq!string))
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

        Fiber fiber = new CarryingFiber!IRCEvent(&whoisFiberDelegate, 32768);

        context.awaitEvents(fiber, whoisEventTypes);
        whois!(Yes.priority)(context.state, nickname, true);  // Need force to not miss events
        mixin(carriedVariableName) = nickname;
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

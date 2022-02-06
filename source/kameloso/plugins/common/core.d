module kameloso.plugins.common.core;

private:

import dialect.defs;
import std.typecons : Flag, No, Yes;

public:

abstract class IRCPlugin
{
@safe:

private:
    import kameloso.thread : Sendable;
    import std.array : Appender;

public:
    static struct CommandMetadata
    {
        string description;
        string syntax;
        bool hidden;
    }

    IRCPluginState state;

    void postprocess(ref IRCEvent event) @system;

    void onEvent(const ref IRCEvent event) @system;

    void initResources() @system;

    void deserialiseConfigFrom(const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries);

    bool serialiseConfigInto(ref Appender!(char[]) sink) const;

    bool setSettingByName(const string setting, const string value);

    void start() @system;

    void printSettings() @system const;

    void teardown() @system;

    string name() @property const pure nothrow @nogc;

    CommandMetadata[string] commands() pure nothrow @property const;

    void reload() @system;

    void onBusMessage(const string header, shared Sendable content) @system;

    bool isEnabled() const @property pure nothrow @nogc;
}

version(WithPlugins)
mixin template IRCPluginImpl(Flag!"debug_" debug_ = No.debug_, string module_ = __MODULE__)
{
    private import kameloso.plugins.common.core : FilterResult, IRCPluginState, Permissions;
    private import dialect.defs : IRCEvent, IRCServer, IRCUser;
    private import core.thread : Fiber;

    alias mixinParent = __traits(parent, {});

    static if (!is(mixinParent : IRCPlugin))
    {
        import lu.traits : CategoryName;
        import std.format : format;

        alias pluginImplParentInfo = CategoryName!mixinParent;

        enum pattern = "%s `%s` mixes in `%s` but it is only supposed to be " ~
            "mixed into an `IRCPlugin` subclass";
        static assert(0, pattern.format(pluginImplParentInfo.type,
            pluginImplParentInfo.fqn, "IRCPluginImpl"));
    }

    @safe:

    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return true;
    }

    pragma(inline, true)
    private FilterResult allow(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        return FilterResult.init;
    }

    private FilterResult allowImpl(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        return FilterResult.init;
    }

    pragma(inline, true)
    override public void onEvent(const ref IRCEvent event) @system {}

    private void onEventImpl( IRCEvent origEvent) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.common.core : IRCEventHandler;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;

        bool udaSanityCheck(alias fun)()
        {
            return true;
        }

        void call(alias fun)(ref IRCEvent event) {}

        enum NextStep
        {
            unset,
            continue_,
            repeat,
            return_,
        }

        NextStep process(alias fun)(ref IRCEvent event)
        {
            import std.algorithm.searching : canFind;

            static immutable uda = getUDAs!(fun, IRCEventHandler)[0];

            enum verbose = (uda.given.verbose || debug_);

            static if (verbose)
            {
                import lu.conv : Enum;
                import std.format : format;
                import std.stdio : writeln, writefln;

                enum funID = "[%s] %s".format(__traits(identifier, thisModule),
                    __traits(identifier, fun));
            }

            static if (!uda.given.acceptedEventTypes.canFind(IRCEvent.Type.ANY))
            {
                if (!uda.given.acceptedEventTypes.canFind(event.type)) return NextStep.continue_;
            }

            static if (verbose)
            {
                writeln("-- ", funID, " @ ", Enum!(IRCEvent.Type).toString(event.type));
                writeln("   ...", Enum!ChannelPolicy.toString(uda.given.channelPolicy));
            }

            if (!event.channel.length) {}
            else
            {
                static if (uda.given.channelPolicy == ChannelPolicy.home)
                {
                    immutable channelMatch = state.bot.homeChannels.canFind(event.channel);
                }
                else static if (uda.given.channelPolicy == ChannelPolicy.guest)
                {
                    immutable channelMatch = !state.bot.homeChannels.canFind(event.channel);
                }
                else
                {
                    enum channelMatch = true;
                }

                if (!channelMatch)
                {
                    static if (verbose)
                    {
                        writeln("   ...ignore non-matching channel ", event.channel);
                    }

                    return NextStep.continue_;
                }
            }

            static if (uda.given.commands.length || uda.given.regexes.length)
            {
                import lu.string : strippedLeft;

                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    return NextStep.continue_;
                }

                immutable origContent = event.content;
                immutable origAux = event.aux;
                bool commandMatch;
            }

            import std.meta : AliasSeq, staticMap;
            import std.traits : Parameters, Unqual, arity;

            static if (uda.given.permissionsRequired != Permissions.ignore)
            {
                static if (!__traits(compiles, .hasMinimalAuthentication))
                {
                    import std.format : format;

                    enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                        "mixin (needed for `Permissions` checks)";
                    static assert(0, pattern.format(module_));
                }

                static if (verbose)
                {
                    writeln("   ...Permissions.",
                        Enum!Permissions.toString(uda.given.permissionsRequired));
                }

                immutable result = this.allow(event, uda.given.permissionsRequired);

                static if (verbose)
                {
                    writeln("   ...allow result is ", Enum!FilterResult.toString(result));
                }

                NextStep rtToReturn;

                if (result == FilterResult.pass) {}
                else if (result == FilterResult.whois)
                {
                    import kameloso.plugins.common.misc : enqueue;
                    import std.traits : fullyQualifiedName;

                    alias Params = staticMap!(Unqual, Parameters!fun);

                    static if (verbose)
                    {
                        writefln("   ...%s WHOIS", typeof(this).stringof);
                    }

                    static if (is(Params : AliasSeq!IRCEvent) || (arity!fun == 0))
                    {
                        this.enqueue(event, uda.given.permissionsRequired, &fun, fullyQualifiedName!fun);

                        static if (uda.given.chainable)
                        {
                            rtToReturn = NextStep.continue_;
                        }
                        else
                        {
                            rtToReturn = NextStep.return_;
                        }
                    }
                    else static if (
                        is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(typeof(this))))
                    {
                        this.enqueue(this, event, uda.given.permissionsRequired, &fun, fullyQualifiedName!fun);

                        static if (uda.given.chainable)
                        {
                            rtToReturn = NextStep.continue_;
                        }
                        else
                        {
                            rtToReturn = NextStep.return_;
                        }
                    }
                    else
                    {
                        import std.format : format;
                        static assert(0, "`%s` has an unsupported function signature: `%s`"
                            .format(fullyQualifiedName!fun, typeof(fun).stringof));
                    }
                }
                else if (result == FilterResult.fail)
                {
                    static if (uda.given.chainable)
                    {
                        rtToReturn = NextStep.continue_;
                    }
                    else
                    {
                        rtToReturn = NextStep.return_;
                    }
                }
                else
                {
                    assert(0);
                }

                if (rtToReturn != NextStep.unset) return rtToReturn;
            }

            static if (verbose)
            {
                writeln("   ...calling!");
            }

            call!fun(event);

            static if (uda.given.chainable)
            {
                return NextStep.continue_;
            }
            else
            {
                return NextStep.return_;
            }
        }

        static void sanitizeEvent(ref IRCEvent event) {}

        void tryProcess(funlist...)(ref IRCEvent event)
        {
            foreach (fun; funlist)
            {
                static assert(udaSanityCheck!fun);

                try
                {
                    immutable next = process!fun(event);

                    if (next == NextStep.continue_)
                    {
                        continue;
                    }
                    else if (next == NextStep.repeat)
                    {
                        if (process!fun(event) == NextStep.continue_)
                        {
                            continue;
                        }
                        else
                        {
                            return;
                        }
                    }
                    else if (next == NextStep.return_)
                    {
                        return;
                    }
                    else
                    {
                        assert(0);
                    }
                }
                catch (Exception e)
                {
                    import std.utf : UTFException;
                    import core.exception : UnicodeException;

                    immutable isRecoverableException =
                        (cast(UnicodeException)e !is null) ||
                        (cast(UTFException)e !is null);

                    if (!isRecoverableException) throw e;

                    sanitizeEvent(event);

                    immutable next = process!fun(event);

                    if (next == NextStep.continue_)
                    {
                        continue;
                    }
                    else if (next == NextStep.repeat)
                    {
                        if (process!fun(event) == NextStep.continue_)
                        {
                            continue;
                        }
                        else
                        {
                            return;
                        }
                    }
                    else if (next == NextStep.return_)
                    {
                        return;
                    }
                    else
                    {
                        assert(0);
                    }
                }
            }
        }

        enum isSetupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0].given.when == Timing.setup);
        enum isEarlyFun(alias T) = (getUDAs!(T, IRCEventHandler)[0].given.when == Timing.early);
        enum isLateFun(alias T) = (getUDAs!(T, IRCEventHandler)[0].given.when == Timing.late);
        enum isCleanupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0].given.when == Timing.cleanup);
        alias hasSpecialTiming = templateOr!(isSetupFun, isEarlyFun,
            isLateFun, isCleanupFun);
        alias isNormalEventHandler = templateNot!hasSpecialTiming;

        alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEventHandler));
        alias setupFuns = Filter!(isSetupFun, funs);
        alias earlyFuns = Filter!(isEarlyFun, funs);
        alias lateFuns = Filter!(isLateFun, funs);
        alias cleanupFuns = Filter!(isCleanupFun, funs);
        alias pluginFuns = Filter!(isNormalEventHandler, funs);

        tryProcess!pluginFuns(origEvent);
    }

    public this(IRCPluginState state) @system {}

    override public void postprocess(ref IRCEvent event) @system {}

    override public void initResources() @system {}

    override public void deserialiseConfigFrom(const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries)
    {}

    override public bool setSettingByName(const string setting, const string value)
    {
        return true;
    }

    override public void printSettings() const
    {
        import kameloso.printing : printObject;
        import std.traits : hasUDA;

        foreach (immutable i, const ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                import std.typecons : No, Yes;
                printObject!(No.all)(symbol);
                break;
            }
        }
    }

    private import std.array : Appender;

    override public bool serialiseConfigInto(ref Appender!(char[]) sink) const
    {
        import std.traits : hasUDA;

        bool didSomething;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                import lu.serialisation : serialise;

                sink.serialise(symbol);
                didSomething = true;
                break;
            }
            else static if (hasUDA!(this.tupleof[i], Settings))
            {
                import std.format : format;
                import std.traits : fullyQualifiedName;

                static assert(0, "`%s` is annotated `@Settings` but is not a `struct`"
                    .format(fullyQualifiedName!(this.tupleof[i])));
            }
        }
        return didSomething;
    }

    override public void start() @system {}

    override public void teardown() @system {}

    pragma(inline, true)
    override public string name() @property const pure nothrow @nogc
    {
        return string.init;
    }

    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        return (IRCPlugin.CommandMetadata[string]).init;
    }

    override public void reload() @system {}

    private import kameloso.thread : Sendable;

    override public void onBusMessage(const string header, shared Sendable content) @system {}
}

bool prefixPolicyMatches(bool verbose = false)
    (ref IRCEvent event,
    const PrefixPolicy policy,
    const IRCClient client,
    const string prefix)
{
    return true;
}

FilterResult filterSender(const ref IRCEvent event,
    const Permissions permissionsRequired,
    const bool preferHostmasks) @safe
{
    return FilterResult.init;
}

struct IRCPluginState
{
private:
    import kameloso.kameloso : ConnectionSettings, CoreSettings, IRCBot;
    import kameloso.thread : ScheduledDelegate, ScheduledFiber;
    import std.concurrency : Tid;
    import core.thread : Fiber;

public:
    IRCClient client;
    IRCServer server;
    IRCBot bot;
    CoreSettings settings;
    ConnectionSettings connSettings;
    Tid mainThread;
    IRCUser[string] users;
    IRCChannel[string] channels;
    Replay[][string] replays;
    bool hasReplays;
    Repeat[] repeats;
    Fiber[][] awaitingFibers;
    void delegate(const IRCEvent)[][] awaitingDelegates;
    ScheduledFiber[] scheduledFibers;
    ScheduledDelegate[] scheduledDelegates;
    long nextScheduledTimestamp;

    void updateSchedule() pure nothrow @nogc {}

    bool botUpdated;
    bool clientUpdated;
    bool serverUpdated;
    bool settingsUpdated;
    bool* abort;
}

abstract class Replay
{
    string caller;
    IRCEvent event;
    Permissions permissionsRequired;
    long when;

    void trigger();

    this() @safe {}
}

private final class ReplayImpl(F, Payload = typeof(null)) : Replay
{
@safe:
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        Payload payload;

        this(Payload payload, IRCEvent event, Permissions permissionsRequired,
            F fn, const string caller)
        {}
    }
    else
    {
        this(IRCEvent event, Permissions permissionsRequired, F fn, const string caller) {}
    }

    override void trigger() @system {}
}

struct Repeat
{
private:
    import kameloso.thread : CarryingFiber;
    import std.traits : Unqual;
    import core.thread : Fiber;

    alias This = Unqual!(typeof(this));

public:
    Fiber fiber;

    CarryingFiber!This carryingFiber() pure inout @nogc @property
    {
        return null;
    }

    bool isCarrying() const pure @nogc @property
    {
        return true;
    }

    Replay replay;
    long created;

    this(Fiber fiber, Replay replay) @safe {}
}

enum FilterResult
{
    fail,
    pass,
    whois,
}

enum PrefixPolicy
{
    direct,
    prefixed,
    nickname,
}

enum ChannelPolicy
{
    home,
    guest,
    any,
}

enum Permissions
{
    ignore = 0,
    anyone = 10,
    registered = 20,
    whitelist = 30,
    operator = 40,
    staff = 50,
    admin = 100,
}

Replay replay(Fn, SubPlugin)
    (SubPlugin subPlugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return null;
}

Replay replay(Fn)
    (const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return null;
}

enum Timing
{
    unset,
    setup,
    early,
    late,
    cleanup,
}

struct IRCEventHandler
{
    static struct GivenValues
    {
        IRCEvent.Type[] acceptedEventTypes;
        Permissions permissionsRequired = Permissions.ignore;
        ChannelPolicy channelPolicy = ChannelPolicy.home;
        Command[] commands;
        Regex[] regexes;
        bool chainable;
        bool verbose;
        Timing when;
    }

    GivenValues given;

    ref auto onEvent(const IRCEvent.Type type)
    {
        this.given.acceptedEventTypes ~= type;
        return this;
    }

    ref auto permissionsRequired(const Permissions permissionsRequired)
    {
        this.given.permissionsRequired = permissionsRequired;
        return this;
    }

    ref auto channelPolicy(const ChannelPolicy channelPolicy)
    {
        this.given.channelPolicy = channelPolicy;
        return this;
    }

    ref auto addCommand(const Command command)
    {
        this.given.commands ~= command;
        return this;
    }

    ref auto addRegex( Regex regex)
    {
        this.given.regexes ~= regex;
        return this;
    }

    ref auto chainable(const bool chainable)
    {
        this.given.chainable = chainable;
        return this;
    }

    ref auto verbose(const bool verbose)
    {
        this.given.verbose = verbose;
        return this;
    }

    ref auto when(const Timing when)
    {
        this.given.when = when;
        return this;
    }

    static struct Command
    {
        static struct GivenValues
        {
            PrefixPolicy policy = PrefixPolicy.prefixed;
            string word;
            string description;
            string syntax;
            bool hidden;
        }

        GivenValues given;

        ref auto policy(const PrefixPolicy policy)
        {
            this.given.policy = policy;
            return this;
        }

        ref auto word(const string word)
        {
            this.given.word = word;
            return this;
        }

        ref auto description(const string description)
        {
            this.given.description = description;
            return this;
        }

        ref auto syntax(const string syntax)
        {
            this.given.syntax = syntax;
            return this;
        }

        ref auto hidden(const bool hidden)
        {
            this.given.hidden = hidden;
            return this;
        }
    }

    static struct Regex
    {
        import std.regex : StdRegex = Regex;

        static struct GivenValues
        {
            PrefixPolicy policy = PrefixPolicy.direct;
            StdRegex!char engine;
            string expression;
            string description;
            bool hidden;
        }

        GivenValues given;

        ref auto policy(const PrefixPolicy policy)
        {
            this.given.policy = policy;
            return this;
        }

        ref auto expression(const string expression)
        {
            import std.regex : regex;

            this.given.expression = expression;
            this.given.engine = expression.regex;
            return this;
        }

        ref auto description(const string description)
        {
            this.given.description = description;
            return this;
        }

        ref auto hidden(const bool hidden)
        {
            this.given.hidden = hidden;
            return this;
        }
    }
}

enum Settings;

enum Resource;

enum Enabler;

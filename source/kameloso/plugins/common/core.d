/++
    Contains the definition of an [IRCPlugin] and its ancilliaries, as well as
    mixins to fully implement it.

    Event handlers can then be module-level functions, annotated with
    [dialect.defs.IRCEvent.Type|IRCEvent.Type]s.

    Example:
    ---
    import kameloso.plugins.common.core;
    import kameloso.plugins.common.awareness;

    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.CHAN)
        .permissionsRequired(Permissions.anyone)
        .channelPolicy(ChannelPolicy.home)
        .addCommand(
            IRCEventHandler.Command()
                .word("foo")
                .policy(PrefixPolicy.prefixed)
        )
    )
    void onFoo(FooPlugin plugin, const ref IRCEvent event)
    {
        // ...
    }

    mixin UserAwareness;
    mixin ChannelAwareness;
    mixin PluginRegistration!FooPlugin;

    final class FooPlugin : IRCPlugin
    {
        // ...

        mixin IRCPluginImpl;
    }
    ---

    See_Also:
        [kameloso.plugins.common.misc],
        [kameloso.plugins.common.awareness],
        [kameloso.plugins.common.delayawait],
        [kameloso.plugins.common.mixins],

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.core;

private:

import kameloso.thread : CarryingFiber;
import dialect.defs;
import std.traits : ParameterStorageClass;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

public:


// IRCPlugin
/++
    Abstract IRC plugin class.

    This is currently shared with all `service`-class "plugins".

    See_Also:
        [IRCPluginImpl]
        [IRCPluginState]
 +/
abstract class IRCPlugin
{
@safe:
private:
    import kameloso.thread : Sendable;
    import std.array : Appender;

public:
    // CommandMetadata
    /++
        Metadata about a [IRCEventHandler.Command]- and/or
        [IRCEventHandler.Regex]-annotated event handler.

        See_Also:
            [IRCPlugin.commands]
     +/
    static struct CommandMetadata
    {
        // policy
        /++
            Prefix policy of this command.
         +/
        PrefixPolicy policy;

        // description
        /++
            Description about what the command does, in natural language.
         +/
        string description;

        // syntaxes
        /++
            Syntaxes on how to use the command.
         +/
        string[] syntaxes;

        // hidden
        /++
            Whether or not the command should be hidden from view (but still
            possible to trigger).
         +/
        bool hidden;

        // isRegex
        /++
            Whether or not the command is based on an `IRCEventHandler.Regex`.
         +/
        bool isRegex;

        // this
        /++
            Constructor taking an [IRCEventHandler.Command].

            Do not touch [syntaxes]; populate them at the call site.
         +/
        this(const IRCEventHandler.Command command) pure @safe nothrow @nogc
        {
            this.policy = command.policy;
            this.description = command.description;
            this.hidden = command.hidden;
            //this.isRegex = false;
        }

        // this
        /++
            Constructor taking an [IRCEventHandler.Regex].

            Do not touch [syntaxes]; populate them at the call site.
         +/
        this(const IRCEventHandler.Regex regex) pure @safe nothrow @nogc
        {
            this.policy = regex.policy;
            this.description = regex.description;
            this.hidden = regex.hidden;
            this.isRegex = true;
        }
    }

    // state
    /++
        An [IRCPluginState] instance containing variables and arrays that represent
        the current state of the plugin. Should generally be passed by reference.
     +/
    IRCPluginState state;

    // postprocess
    /++
        Allows a plugin to modify an event post-parsing.
     +/
    void postprocess(ref IRCEvent event) @system;

    // onEvent
    /++
        Called to let the plugin react to a new event, parsed from the server.
     +/
    void onEvent(const ref IRCEvent event) @system;

    // initResources
    /++
        Called when the plugin is requested to initialise its disk resources.
     +/
    void initResources() @system;

    // deserialiseConfigFrom
    /++
        Reads serialised configuration text into the plugin's settings struct.

        Stores an associative array of `string[]`s of missing entries in its
        first `out string[][string]` parameter, and the invalid encountered
        entries in the second.
     +/
    void deserialiseConfigFrom(
        const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries);

    // serialiseConfigInto
    /++
        Called to let the plugin contribute settings when writing the configuration file.

        Returns:
            Boolean of whether something was added.
     +/
    bool serialiseConfigInto(ref Appender!(char[]) sink) const;

    // setSettingByName
    /++
        Called when we want to change a setting by its string name.

        Returns:
            Boolean of whether the set succeeded or not.
     +/
    bool setSettingByName(const string setting, const string value);

    // setup
    /++
        Called at program start but before connection has been established.
     +/
    void setup() @system;

    // printSettings
    /++
        Called when we want a plugin to print its [Settings]-annotated struct of settings.
     +/
    void printSettings() @system const;

    // teardown
    /++
        Called during shutdown of a connection; a plugin's would-be destructor.
     +/
    void teardown() @system;

    // name
    /++
        Returns the name of the plugin.

        Returns:
            The string name of the plugin.
     +/
    string name() @property const pure nothrow @nogc;

    // commands
    /++
        Returns an array of the descriptions of the commands a plugin offers.

        Returns:
            An associative [IRCPlugin.CommandMetadata] array keyed by string.
     +/
    CommandMetadata[string] commands() pure nothrow @property const;

    // channelSpecificCommands
    /++
        Returns an array of the descriptions of the channel-specific commands a
        plugin offers.

        Returns:
            An associative [IRCPlugin.CommandMetadata] array keyed by string.
     +/
    CommandMetadata[string] channelSpecificCommands(const string) @system;

    // reload
    /++
        Reloads the plugin, where such is applicable.

        Whatever this does is implementation-defined.
     +/
    void reload() @system;

    // onBusMessage
    /++
        Called when a bus message arrives from another plugin.

        It is passed to all plugins and it is up to the receiving plugin to
        discard those not meant for it by examining the value of the `header` argument.
     +/
    void onBusMessage(const string header, shared Sendable content) @system;

    // isEnabled
    /++
        Returns whether or not the plugin is enabled in its settings.

        Returns:
            `true` if the plugin should listen to events, `false` if not.
     +/
    bool isEnabled() const @property pure nothrow @nogc;

    // tick
    /++
        Called on each iteration of the main loop.

        Returns:
            `true` if the plugin did something that warrants checking concurrency
            messages; `false` if not.
     +/
    bool tick() @system;
}


// IRCPluginImpl
/++
    Mixin that fully implements an [kameloso.plugins.common.core.IRCPlugin|IRCPlugin].

    Uses compile-time introspection to call module-level functions to extend behaviour.

    With UFCS, transparently emulates all such as being member methods of the
    mixing-in class.

    Example:
    ---
    final class MyPlugin : IRCPlugin
    {
        MyPluginSettings myPluginSettings;  // type should be annotated @Settings at declaration

        // ...implementation...

        mixin IRCPluginImpl;
    }
    ---

    Params:
        debug_ = Enables some debug output.
        module_ = Name of the current module. Should never be specified and always
            be left to its `__MODULE__` default value. Here be dragons.

    See_Also:
        [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]
 +/
mixin template IRCPluginImpl(
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins.common.core : FilterResult, IRCEventHandler, IRCPluginState, Permissions;
    private import kameloso.thread : Sendable;
    private import dialect.defs : IRCEvent, IRCServer, IRCUser;
    private import lu.traits : getSymbolsByUDA;
    private import std.array : Appender;
    private import std.meta : AliasSeq;
    private import std.traits : getUDAs;
    private import core.thread : Fiber;

    static if (__traits(compiles, { alias _ = this.hasIRCPluginImpl; }))
    {
        import std.format : format;

        enum pattern = "Double mixin of `%s` in `%s`";
        enum message = pattern.format("IRCPluginImpl", typeof(this).stringof);
        static assert(0, message);
    }
    else
    {
        /++
            Marker declaring that [kameloso.plugins.common.core.IRCPluginImpl|IRCPluginImpl]
            has been mixed in.
         +/
        private enum hasIRCPluginImpl = true;
    }

    mixin("private static import thisModule = ", module_, ";");

    // Introspection
    /++
        Namespace for the alias sequences of all event handler functions in this
        module, as well as the one of all [kameloso.plugins.common.core.IRCEventHandler|IRCEventHandler]
        annotations in the module.
     +/
    static struct Introspection
    {
        /++
            Alias sequence of all top-level symbols annotated with
            [kameloso.plugins.common.core.IRCEventHandler|IRCEventHandler]s
            in this module.
         +/
        alias allEventHandlerFunctionsInModule = getSymbolsByUDA!(thisModule, IRCEventHandler);

        /++
            Alias sequence of all
            [kameloso.plugins.common.core.IRCEventHandler|IRCEventHandler]s
            that are annotations of the symbols in [allEventHandlerFunctionsInModule].
         +/
        static immutable allEventHandlerUDAsInModule = ()
        {
            IRCEventHandler[] udas;
            udas.length = allEventHandlerFunctionsInModule.length;

            foreach (immutable i, fun; allEventHandlerFunctionsInModule)
            {
                enum fqn = module_ ~ '.'  ~ __traits(identifier, allEventHandlerFunctionsInModule[i]);
                udas[i] = getUDAs!(fun, IRCEventHandler)[0];
                udas[i].fqn = fqn;
                version(unittest) udaSanityCheckCTFE(udas[i]);
                udas[i].generateTypemap();
            }

            return udas;
        }();
    }

    @safe:

    // isEnabled
    /++
        Introspects the current plugin, looking for a
        [kameloso.plugins.common.core.Settings|Settings]-annotated struct
        member that has a bool annotated with [kameloso.plugins.common.core.Enabler|Enabler],
        which denotes it as the bool that toggles a plugin on and off.

        It then returns its value.

        Returns:
            `true` if the plugin is deemed enabled (or cannot be disabled),
            `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        import kameloso.traits : udaIndexOf;

        bool retval = true;

        top:
        foreach (immutable i, _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    foreach (immutable n, _2; this.tupleof[i].tupleof)
                    {
                        enum enablerUDAIndex = udaIndexOf!(this.tupleof[i].tupleof[n], Enabler);

                        static if (enablerUDAIndex != -1)
                        {
                            alias ThisEnabler = typeof(this.tupleof[i].tupleof[n]);

                            static if (!is(ThisEnabler : bool))
                            {
                                import std.format : format;
                                import std.traits : Unqual;

                                alias UnqualThis = Unqual!(typeof(this));
                                enum pattern = "`%s` has a non-bool `Enabler`: `%s %s`";
                                enum message = pattern.format(
                                    UnqualThis.stringof,
                                    ThisEnabler.stringof,
                                    __traits(identifier, this.tupleof[i].tupleof[n]));
                                static assert(0, message);
                            }

                            retval = this.tupleof[i].tupleof[n];
                            break top;
                        }
                    }
                }
            }
        }

        return retval;
    }

    // allow
    /++
        Judges whether an event may be triggered, based on the event itself and
        the annotated required [kameloso.plugins.common.core.Permissions|Permissions] of the
        handler in question. Wrapper function that merely calls
        [kameloso.plugins.common.core.allowImpl].
        The point behind it is to make something that can be overridden and still
        allow it to call the original logic (below).

        Params:
            event = [dialect.defs.IRCEvent|IRCEvent] to allow, or not.
            permissionsRequired = Required [kameloso.plugins.common.core.Permissions|Permissions]
                of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.
     +/
    pragma(inline, true)
    private auto allow(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        import kameloso.plugins.common.core : allowImpl;
        return allowImpl(this, event, permissionsRequired);
    }

    // onEvent
    /++
        Forwards the supplied [dialect.defs.IRCEvent|IRCEvent] to
        [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl].

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging
        [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl]
        for the actual dirty work.

        Params:
            event = Parsed [dialect.defs.IRCEvent|IRCEvent] to pass onto
                [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl].

        See_Also:
            [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl]
     +/
    pragma(inline, true)
    override public void onEvent(const ref IRCEvent event) @system
    {
        onEventImpl(event);
    }

    // onEventImpl
    /++
        Pass on the supplied [dialect.defs.IRCEvent|IRCEvent] to module-level functions
        annotated with an [kameloso.plugins.common.core.IRCEventHandler|IRCEventHandler],
        registered with the matching [dialect.defs.IRCEvent.Type|IRCEvent.Type]s.

        It also does checks for
        [kameloso.plugins.common.core.ChannelPolicy|ChannelPolicy],
        [kameloso.plugins.common.core.Permissions|Permissions],
        [kameloso.plugins.common.core.PrefixPolicy|PrefixPolicy],
        [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command],
        [kameloso.plugins.common.core.IRCEventHandler.Regex|IRCEventHandler.Regex],
        `chainable` settings etc; where such is applicable.

        This function is private, but since it's part of a mixin template it will
        be visible at the mixin site. Plugins can as such override
        [kameloso.plugins.common.core.IRCPlugin.onEvent|IRCPlugin.onEvent] with
        their own code and invoke [onEventImpl] as a fallback.

        Params:
            origEvent = Parsed [dialect.defs.IRCEvent|IRCEvent] to dispatch to
                event handlers, taken by value so we have an object we can modify.

        See_Also:
            [kameloso.plugins.common.core.IRCPluginImpl.onEvent|IRCPluginImpl.onEvent]
     +/
    private void onEventImpl(/*const ref*/ IRCEvent origEvent) @system
    {
        import kameloso.plugins.common.core : Timing;

        // udaSanityCheckMinimal
        /++
            Verifies that some annotations are as expected.
            Most of the verification is done in
            [kameloso.plugins.common.core.udaSanityCheckCTFE|udaSanityCheckCTFE].
         +/
        version(unittest)
        static bool udaSanityCheckMinimal(alias fun, IRCEventHandler uda)()
        {
            static if ((uda._permissionsRequired != Permissions.ignore) &&
                !__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
            {
                import std.format : format;

                enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                    "mixin (needed for `Permissions` checks)";
                enum message = pattern.format(module_);
                static assert(0, message);
            }

            return true;
        }

        // call
        /++
            Calls the passed function pointer, appropriately.
         +/
        void call(bool inFiber, Fun)(scope Fun fun, const ref IRCEvent event) scope
        {
            import lu.traits : TakesParams;
            import std.traits : ParameterStorageClass, ParameterStorageClassTuple, Parameters, arity;

            static if (
                TakesParams!(fun, typeof(this), IRCEvent) ||
                TakesParams!(fun, IRCPlugin, IRCEvent))
            {
                version(unittest)
                {
                    static assert(assertSaneStorageClasses(
                        ParameterStorageClassTuple!fun[1],
                        is(Parameters!fun[1] == const),
                        inFiber,
                        module_,
                        Fun.stringof), "0");
                }
                fun(this, event);
            }
            else static if (
                TakesParams!(fun, typeof(this)) ||
                TakesParams!(fun, IRCPlugin))
            {
                fun(this);
            }
            else static if (TakesParams!(fun, IRCEvent))
            {
                version(unittest)
                {
                    static assert(assertSaneStorageClasses(
                        ParameterStorageClassTuple!fun[0],
                        is(Parameters!fun[0] == const),
                        inFiber,
                        module_,
                        Fun.stringof), "0");
                }
                fun(event);
            }
            else static if (arity!fun == 0)
            {
                fun();
            }
            else
            {
                import std.format : format;

                enum pattern = "`%s` has an event handler with an unsupported function signature: `%s`";
                enum message = pattern.format(module_, Fun.stringof);
                static assert(0, message);
            }
        }

        // NextStep
        /++
            Signal up the callstack of what to do next.
         +/
        enum NextStep
        {
            unset,
            continue_,
            repeat,
            return_,
        }

        /++
            Cached value set inside the Command loop.
         +/
        string commandWordInEvent;
        string commandWordInEventLower;  /// ditto
        string contentSansCommandWordInEvent;  /// ditto

        // process
        /++
            Process a function.
         +/
        auto process(bool verbose, bool inFiber, bool hasRegexes, Fun)
            (scope Fun fun,
            const string fqn,
            const IRCEventHandler uda,
            ref IRCEvent event) scope
        {
            static if (verbose)
            {
                import lu.conv : Enum;
                import std.stdio : stdout, writeln, writefln;

                writeln("-- ", fqn, " @ ", Enum!(IRCEvent.Type).toString(event.type));
                writeln("   ...", Enum!ChannelPolicy.toString(uda._channelPolicy));
                if (state.settings.flush) stdout.flush();
            }

            if (event.channel.length)
            {
                import std.algorithm.searching : canFind;

                bool channelMatch;

                if (uda._channelPolicy == ChannelPolicy.home)
                {
                    channelMatch = state.bot.homeChannels.canFind(event.channel);
                }
                else if (uda._channelPolicy == ChannelPolicy.guest)
                {
                    channelMatch = !state.bot.homeChannels.canFind(event.channel);
                }
                else /*if (channelPolicy == ChannelPolicy.any)*/
                {
                    channelMatch = true;
                }

                if (!channelMatch)
                {
                    static if (verbose)
                    {
                        writeln("   ...ignore non-matching channel ", event.channel);
                        if (state.settings.flush) stdout.flush();
                    }

                    // channel policy does not match
                    return NextStep.continue_;  // next fun
                }
            }

            // Ignore all commands when in observer mode
            if ((uda.commands.length || hasRegexes) && !state.settings.observerMode)
            {
                import lu.string : strippedLeft;

                immutable origContent = event.content;
                auto origAux = event.aux;  // copy
                bool auxDirty;

                scope(exit)
                {
                    // Restore aux if it has been altered
                    // Unconditionally restore content
                    event.content = origContent;
                    if (auxDirty) event.aux = origAux;  // copy back
                }

                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    // Event has a Command or a Regex set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }

                /// Whether or not a Command or Regex matched.
                bool commandMatch;

                /+
                    Evaluate each Command UDAs with the current event.

                    This is a little complicated, but cache the command word
                    and its lowercase version, and the content without the
                    command word, so we don't have to do it for each Command
                    UDA. This is more than a little hacky, but it's a hot path.
                 +/
                if (uda.commands.length)
                {
                    immutable preLoopContent = event.content;

                    commandForeach:
                    foreach (const command; uda.commands)
                    {
                        static if (verbose)
                        {
                            enum pattern = `   ...Command "%s"`;
                            writefln(pattern, command._word);
                            if (state.settings.flush) stdout.flush();
                        }

                        // The call to .prefixPolicyMatches modifies event.content
                        if (!event.prefixPolicyMatches!verbose(command._policy, state))
                        {
                            static if (verbose)
                            {
                                writeln("   ...policy doesn't match; continue next Command");
                                if (state.settings.flush) stdout.flush();
                            }

                            // Do nothing, proceed to next command but restore content first
                            event.content = preLoopContent;
                            continue commandForeach;
                        }

                        if (!commandWordInEvent.length)
                        {
                            import lu.string : nom;
                            import std.typecons : No, Yes;
                            import std.uni : toLower;

                            // Cache it
                            commandWordInEvent = event.content.nom!(Yes.inherit, Yes.decode)(' ');
                            commandWordInEventLower = commandWordInEvent.toLower();
                            contentSansCommandWordInEvent = event.content;
                        }

                        if (commandWordInEventLower == command._word/*.toLower()*/)
                        {
                            static if (verbose)
                            {
                                writeln("   ...command word matches!");
                                if (state.settings.flush) stdout.flush();
                            }

                            event.aux[$-1] = commandWordInEvent;
                            auxDirty = true;
                            commandMatch = true;
                            event.content = contentSansCommandWordInEvent;
                            break commandForeach;
                        }
                        else
                        {
                            event.content = preLoopContent;
                        }
                    }
                }

                static if (hasRegexes)
                {
                    // iff no match from Commands, evaluate Regexes
                    if (/*uda.regexes.length &&*/ !commandMatch)
                    {
                        regexForeach:
                        foreach (const regex; uda.regexes)
                        {
                            import std.regex : matchFirst;

                            static if (verbose)
                            {
                                enum pattern = `   ...Regex r"%s"`;
                                writefln(pattern, regex._expression);
                                if (state.settings.flush) stdout.flush();
                            }

                            if (!event.prefixPolicyMatches!verbose(regex._policy, state))
                            {
                                static if (verbose)
                                {
                                    writeln("   ...policy doesn't match; continue next Regex");
                                    if (state.settings.flush) stdout.flush();
                                }

                                // Do nothing, proceed to next regex
                                continue regexForeach;
                            }

                            try
                            {
                                const hits = event.content.matchFirst(regex.engine);

                                if (!hits.empty)
                                {
                                    static if (verbose)
                                    {
                                        writeln("   ...expression matches!");
                                        if (state.settings.flush) stdout.flush();
                                    }

                                    event.aux[$-1] = hits[0];
                                    auxDirty = true;
                                    commandMatch = true;
                                    break regexForeach;
                                }
                                else
                                {
                                    static if (verbose)
                                    {
                                        enum matchPattern = `   ...matching "%s" against expression "%s" failed.`;
                                        writefln(matchPattern, event.content, regex._expression);
                                        if (state.settings.flush) stdout.flush();
                                    }
                                }
                            }
                            catch (Exception e)
                            {
                                static if (verbose)
                                {
                                    writeln("   ...Regex exception: ", e.msg);
                                    version(PrintStacktraces) writeln(e);
                                    if (state.settings.flush) stdout.flush();
                                }
                            }
                        }
                    }
                }

                if (!commandMatch)
                {
                    // {Command,Regex} exist implicitly but neither matched; skip
                    static if (verbose)
                    {
                        writeln("   ...no Command nor Regex match; continue funloop");
                        if (state.settings.flush) stdout.flush();
                    }

                    return NextStep.continue_; // next function
                }
            }

            if (uda._permissionsRequired != Permissions.ignore)
            {
                static if (verbose)
                {
                    writeln("   ...Permissions.",
                        Enum!Permissions.toString(uda._permissionsRequired));
                    if (state.settings.flush) stdout.flush();
                }

                immutable result = this.allow(event, uda._permissionsRequired);

                static if (verbose)
                {
                    writeln("   ...allow result is ", Enum!FilterResult.toString(result));
                    if (state.settings.flush) stdout.flush();
                }

                if (result == FilterResult.pass)
                {
                    // Drop down
                }
                else if (result == FilterResult.whois)
                {
                    import kameloso.plugins.common.misc : enqueue;
                    import lu.traits : TakesParams;
                    import std.traits : arity;

                    static if (verbose)
                    {
                        enum pattern = "   ...%s WHOIS";
                        writefln(pattern, typeof(this).stringof);
                        if (state.settings.flush) stdout.flush();
                    }

                    static if (
                        TakesParams!(fun, typeof(this), IRCEvent) ||
                        TakesParams!(fun, IRCPlugin, IRCEvent) ||
                        TakesParams!(fun, typeof(this)) ||
                        TakesParams!(fun, IRCPlugin) ||
                        TakesParams!(fun, IRCEvent) ||
                        (arity!fun == 0))
                    {
                        // Unsure why we need to specifically specify IRCPlugin
                        // now despite typeof(this) being a subclass...
                        enqueue(this, event, uda._permissionsRequired, uda._fiber, fun, fqn);
                        return uda._chainable ? NextStep.continue_ : NextStep.return_;
                    }
                    else
                    {
                        import std.format : format;

                        enum pattern = "`%s` has an event handler with an unsupported function signature: `%s`";
                        enum message = pattern.format(module_, Fun.stringof);
                        static assert(0, message);
                    }
                }
                else /*if (result == FilterResult.fail)*/
                {
                    return uda._chainable ? NextStep.continue_ : NextStep.return_;
                }
            }

            static if (verbose)
            {
                writeln("   ...calling!");
                if (state.settings.flush) stdout.flush();
            }

            /+
                This casts any @safe event handler functions to @system.
                It should no longer be necessary since we removed the `@safe:`
                from the top of all modules with handler functions (including
                `awareness.d`), but it's free, so keep it here in case we add
                something later and accidentally make it @safe.
             +/
            static if (Fun.stringof[$-5..$] == "@safe")
            {
                enum message = "Warning: `" ~ module_ ~ "` has a `" ~ Fun.stringof[0..$-6] ~
                    "` event handler annotated `@safe`, either directly or via mixins, " ~
                    "which incurs unnecessary template instantiations. " ~
                    "It was cast to `@system`, but consider revising source";
                pragma(msg, message);

                mixin("alias SystemFun = " ~ Fun.stringof[0..$-6] ~ " @system;");
            }
            else
            {
                alias SystemFun = Fun;
            }

            static if (inFiber)
            {
                import kameloso.constants : BufferSize;
                import kameloso.thread : CarryingFiber;
                import core.thread : Fiber;

                auto fiber = new CarryingFiber!IRCEvent(
                    () => call!(inFiber, SystemFun)(fun, event),
                    BufferSize.fiberStack);
                fiber.payload = event;
                fiber.call();

                if (fiber.state == Fiber.State.TERM)
                {
                    // Ended immediately, so just destroy
                    destroy(fiber);
                    fiber = null;
                }
            }
            else
            {
                call!(inFiber, SystemFun)(fun, event);
            }

            if (uda._chainable)
            {
                // onEvent found an event and triggered a function, but
                // it's Chainable and there may be more, so keep looking.
                return NextStep.continue_;
            }
            else
            {
                // The triggered function is not Chainable so return and
                // let the main loop continue with the next plugin.
                return NextStep.return_;
            }
        }

        // tryProcess
        /++
            Try a function.
         +/
        auto tryProcess(size_t i)(ref IRCEvent event)
        {
            immutable uda = this.Introspection.allEventHandlerUDAsInModule[i];
            alias fun = this.Introspection.allEventHandlerFunctionsInModule[i];
            version(unittest) static assert(udaSanityCheckMinimal!(fun, uda), "0");

            enum verbose = (uda._verbose || debug_);
            enum fqn = module_ ~ '.' ~ __traits(identifier, fun);

            /+
                Return if the event handler does not accept this type of event.
             +/
            if ((uda.acceptedEventTypeMap.length >= IRCEvent.Type.ANY) &&
                uda.acceptedEventTypeMap[IRCEvent.Type.ANY])
            {
                // ANY; drop down
            }
            else if (event.type >= uda.acceptedEventTypeMap.length)
            {
                // Out of bounds, cannot possibly be an accepted type
                return NextStep.continue_;
            }
            else if (uda.acceptedEventTypeMap[event.type])
            {
                // Drop down
            }
            else
            {
                // In bounds but not an accepted type
                return NextStep.continue_;
            }

            /++
                Call `process` on the function, and return what it tells us to do next.
             +/
            auto callProcess()
            {
                immutable next = process!
                    (verbose,
                    cast(bool)uda._fiber,
                    cast(bool)uda.regexes.length)
                    (&fun,
                    fqn,
                    uda,
                    event);

                if (next == NextStep.continue_)
                {
                    return NextStep.continue_;
                }
                else if (next == NextStep.repeat)
                {
                    // only repeat once so we don't endlessly loop
                    return process!
                        (verbose,
                        cast(bool)uda._fiber,
                        cast(bool)uda.regexes.length)
                        (&fun,
                        fqn,
                        uda,
                        event);
                }
                else if (next == NextStep.return_)
                {
                    return NextStep.return_;
                }
                else /*if (next == NextStep.unset)*/
                {
                    assert(0, "`IRCPluginImpl.onEventImpl.process` returned `Next.unset`");
                }
            }

            try
            {
                return callProcess();
            }
            catch (Exception e)
            {
                import kameloso.plugins.common.core : sanitiseEvent;
                import std.utf : UTFException;
                import core.exception : UnicodeException;

                /*enum pattern = "tryProcess some exception on <l>%s</>: <l>%s";
                logger.warningf(pattern, fqn, e);*/

                immutable isRecoverableException =
                    (cast(UnicodeException)e !is null) ||
                    (cast(UTFException)e !is null);

                if (!isRecoverableException) throw e;

                sanitiseEvent(event);
                return callProcess();
            }

            assert(0, "Unreachable");
        }

        /+
            Perform some sanity checks to make sure nothing is broken.
         +/
        static if (!this.Introspection.allEventHandlerFunctionsInModule.length)
        {
            version(unittest)
            {
                // Skip event handler checks when unittesting, as it triggers
                // unittests in common/core.d
            }
            else
            {
                import std.algorithm.searching : endsWith;

                static if (module_.endsWith(".stub"))
                {
                    // Defined to be empty
                }
                else
                {
                    enum noEventHandlerMessage = "Warning: Module `" ~ module_ ~
                        "` mixes in `IRCPluginImpl`, but there " ~
                        "seem to be no module-level event handlers. " ~
                        "Verify `IRCEventHandler` annotations";
                    pragma(msg, noEventHandlerMessage);
                }
            }
        }

        // funIndexByTiming
        /++
            Populates an array with indices of functions in `allEventHandlerUDAsInModule`
            that were annotated with an [IRCEventHandler] with a [Timing] matching
            the one supplied.
         +/
        auto funIndexByTiming(const Timing timing) scope
        {
            assert(__ctfe, "funIndexByTiming called outside CTFE");

            size_t[] indexes;
            indexes.length = this.Introspection.allEventHandlerUDAsInModule.length;
            size_t n;

            foreach (immutable i; 0..this.Introspection.allEventHandlerUDAsInModule.length)
            {
                if (this.Introspection.allEventHandlerUDAsInModule[i]._when == timing) indexes[n++] = i;
            }

            return indexes[0..n].idup;
        }

        /+
            Build index arrays, either as enums or static immutables.
         +/
        static immutable setupFunIndexes = funIndexByTiming(Timing.setup);
        static immutable earlyFunIndexes = funIndexByTiming(Timing.early);
        static immutable normalFunIndexes = funIndexByTiming(Timing.untimed);
        static immutable lateFunIndexes = funIndexByTiming(Timing.late);
        static immutable cleanupFunIndexes = funIndexByTiming(Timing.cleanup);

        /+
            It seems we can't trust mixed-in awareness functions to actually get
            detected, depending on how late in the module the site of mixin is.
            So statically assert we found some.
         +/
        static if (__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
        {
            static if (!earlyFunIndexes.length)
            {
                import std.format : format;

                enum pattern = "Module `%s` mixes in `MinimalAuthentication`, " ~
                    "yet no `Timing.early` functions were found during introspection. " ~
                    "Try moving the mixin site to earlier in the module";
                immutable message = pattern.format(module_);
                static assert(0, message);
            }
        }

        static if (__traits(compiles, { alias _ = .hasUserAwareness; }))
        {
            static if (!cleanupFunIndexes.length)
            {
                import std.format : format;

                enum pattern = "Module `%s` mixes in `UserAwareness`, " ~
                    "yet no `Timing.cleanup` functions were found during introspection. " ~
                    "Try moving the mixin site to earlier in the module";
                immutable message = pattern.format(module_);
                static assert(0, message);
            }
        }

        static if (__traits(compiles, { alias _ = .hasChannelAwareness; }))
        {
            static if (!lateFunIndexes.length)
            {
                import std.format : format;

                enum pattern = "Module `%s` mixes in `ChannelAwareness`, " ~
                    "yet no `Timing.late` functions were found during introspection. " ~
                    "Try moving the mixin site to earlier in the module";
                immutable message = pattern.format(module_);
                static assert(0, message);
            }
        }

        alias allFunIndexes = AliasSeq!(
            setupFunIndexes,
            earlyFunIndexes,
            normalFunIndexes,
            lateFunIndexes,
            cleanupFunIndexes,
        );

        /+
            Process all functions.
         +/
        aliasLoop:
        foreach (funIndexes; allFunIndexes)
        {
            static foreach (immutable i; funIndexes)
            {{
                immutable next = tryProcess!i(origEvent);

                if (next == NextStep.return_)
                {
                    // return_; end loop, proceed with next index alias
                    continue aliasLoop;
                }
                /*else if (next == NextStep.continue_)
                {
                    // continue_; iterate to next function within this alias
                }*/
                else if (next == NextStep.repeat)
                {
                    immutable newNext = tryProcess!i(origEvent);

                    // Only repeat once
                    if (newNext == NextStep.return_)
                    {
                        // as above, end index loop
                        continue aliasLoop;
                    }
                }
            }}
        }
    }

    // this(IRCPluginState)
    /++
        Basic constructor for a plugin.

        It passes execution to the module-level `initialise` if it exists.

        There's no point in checking whether the plugin is enabled or not, as it
        will only be possible to change the setting after having created the
        plugin (and serialised settings into it).

        Params:
            state = The aggregate of all plugin state variables, making
                this the "original state" of the plugin.
     +/
    public this(IRCPluginState state) @system
    {
        import lu.traits : isSerialisable;

        enum numEventTypes = __traits(allMembers, IRCEvent.Type).length;

        // Inherit select members of state by zeroing out what we don't want
        this.state = state;
        this.state.awaitingFibers = null;
        this.state.awaitingFibers.length = numEventTypes;
        this.state.awaitingDelegates = null;
        this.state.awaitingDelegates.length = numEventTypes;
        this.state.pendingReplays = null;
        this.state.hasPendingReplays = false;
        this.state.readyReplays = null;
        this.state.scheduledFibers = null;
        this.state.scheduledDelegates = null;
        this.state.nextScheduledTimestamp = long.max;
        //this.state.previousWhoisTimestamps = null;  // keep
        this.state.updates = IRCPluginState.Update.nothing;

        foreach (immutable i, ref member; this.tupleof)
        {
            static if (isSerialisable!member)
            {
                import kameloso.traits : udaIndexOf;

                enum resourceUDAIndex = udaIndexOf!(this.tupleof[i], Resource);
                enum configurationUDAIndex = udaIndexOf!(this.tupleof[i], Configuration);
                alias attrs = __traits(getAttributes, this.tupleof[i]);

                static if (resourceUDAIndex != -1)
                {
                    import std.path : buildNormalizedPath;

                    static if (is(typeof(attrs[resourceUDAIndex])))
                    {
                        member = buildNormalizedPath(
                            state.settings.resourceDirectory,
                            attrs[resourceUDAIndex].subdirectory,
                            member);
                    }
                    else
                    {
                        member = buildNormalizedPath(state.settings.resourceDirectory, member);
                    }
                }
                else static if (configurationUDAIndex != -1)
                {
                    import std.path : buildNormalizedPath;

                    static if (is(typeof(attrs[configurationUDAIndex])))
                    {
                        member = buildNormalizedPath(
                            state.settings.configDirectory,
                            attrs[configurationUDAIndex].subdirectory,
                            member);
                    }
                    else
                    {
                        member = buildNormalizedPath(state.settings.configDirectory, member);
                    }
                }
            }
        }

        static if (__traits(compiles, { alias _ = .initialise; }))
        {
            import lu.traits : TakesParams;

            static if (
                is(typeof(.initialise)) &&
                is(typeof(.initialise) == function) &&
                TakesParams!(.initialise, typeof(this)))
            {
                .initialise(this);
            }
            else
            {
                import kameloso.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.initialise` has an unsupported function signature: `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.initialise));
                static assert(0, message);
            }
        }
    }

    // postprocess
    /++
        Lets a plugin modify an [dialect.defs.IRCEvent|IRCEvent] while it's begin
        constructed, before it's finalised and passed on to be handled.

        Params:
            event = The [dialect.defs.IRCEvent|IRCEvent] in flight.
     +/
    override public void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, { alias _ = .postprocess; }))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (
                is(typeof(.postprocess)) &&
                is(typeof(.postprocess) == function) &&
                TakesParams!(.postprocess, typeof(this), IRCEvent))
            {
                import std.traits : ParameterStorageClass, ParameterStorageClassTuple;

                alias SC = ParameterStorageClass;
                alias paramClasses = ParameterStorageClassTuple!(.postprocess);

                static if (paramClasses[1] & SC.ref_)
                {
                    .postprocess(this, event);
                }
                else
                {
                    import std.format : format;

                    enum pattern = "`%s.postprocess` does not take its " ~
                        "`IRCEvent` parameter by `ref`";
                    enum message = pattern.format(module_);
                    static assert(0, message);
                }
            }
            else
            {
                import kameloso.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.postprocess` has an unsupported function signature: `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.postprocess));
                static assert(0, message);
            }
        }
    }

    // initResources
    /++
        Writes plugin resources to disk, creating them if they don't exist.
     +/
    override public void initResources() @system
    {
        static if (__traits(compiles, { alias _ = .initResources; }))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (
                is(typeof(.initResources)) &&
                is(typeof(.initResources) == function) &&
                TakesParams!(.initResources, typeof(this)))
            {
                .initResources(this);
            }
            else
            {
                import kameloso.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.initResources` has an unsupported function signature: `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.initResources));
                static assert(0, message);
            }
        }
    }

    // deserialiseConfigFrom
    /++
        Loads configuration for this plugin from disk.

        This does not proxy a call but merely loads configuration from disk for
        all struct variables annotated [kameloso.plugins.common.core.Settings|Settings].

        "Returns" two associative arrays for missing entries and invalid
        entries via its two out parameters.

        Params:
            configFile = String of the configuration file to read.
            missingEntries = Out reference of an associative array of string arrays
                of expected configuration entries that were missing.
            invalidEntries = Out reference of an associative array of string arrays
                of unexpected configuration entries that did not belong.
     +/
    override public void deserialiseConfigFrom(
        const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries)
    {
        import kameloso.configreader : readConfigInto;
        import kameloso.traits : udaIndexOf;
        import lu.meld : meldInto;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    if (symbol != typeof(symbol).init)
                    {
                        // This symbol has had configuration applied to it already
                        continue;
                    }

                    string[][string] theseMissingEntries;
                    string[][string] theseInvalidEntries;

                    configFile.readConfigInto(theseMissingEntries, theseInvalidEntries, symbol);

                    theseMissingEntries.meldInto(missingEntries);
                    theseInvalidEntries.meldInto(invalidEntries);
                    break;
                }
            }
        }
    }

    // setSettingByName
    /++
        Change a plugin's [kameloso.plugins.common.core.Settings|Settings]-annotated
        settings struct member by their string name.

        This is used to allow for command-line argument to set any plugin's
        setting by only knowing its name.

        Example:
        ---
        @Settings struct FooSettings
        {
            int bar;
        }

        FooSettings settings;

        setSettingByName("bar", 42);
        assert(settings.bar == 42);
        ---

        Params:
            setting = String name of the struct member to set.
            value = String value to set it to (after converting it to the
                correct type).

        Returns:
            `true` if a member was found and set, `false` otherwise.
     +/
    override public bool setSettingByName(const string setting, const string value)
    {
        import kameloso.traits : udaIndexOf;
        import lu.objmanip : setMemberByName;

        bool success;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    success = symbol.setMemberByName(setting, value);
                    break;
                }
            }
        }

        return success;
    }

    // printSettings
    /++
        Prints the plugin's [kameloso.plugins.common.core.Settings|Settings]-annotated settings struct.
     +/
    override public void printSettings() const
    {
        import kameloso.printing : printObject;
        import kameloso.traits : udaIndexOf;

        foreach (immutable i, const ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    import std.typecons : No, Yes;
                    printObject!(No.all)(symbol);
                    break;
                }
            }
        }
    }

    // serialiseConfigInto
    /++
        Gathers the configuration text the plugin wants to contribute to the
        configuration file.

        Example:
        ---
        Appender!(char[]) sink;
        sink.reserve(128);
        serialiseConfigInto(sink);
        ---

        Params:
            sink = Reference [std.array.Appender|Appender] to fill with plugin-specific
                settings text.

        Returns:
            `true` if something was serialised into the passed sink; `false` if not.
     +/
    override public bool serialiseConfigInto(ref Appender!(char[]) sink) const
    {
        import kameloso.traits : udaIndexOf;

        bool didSomething;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    import lu.serialisation : serialise;

                    sink.serialise(symbol);
                    didSomething = true;
                    break;
                }
            }
        }

        return didSomething;
    }

    // setup, reload, teardown
    /+
        Generates functions `setup`, `reload` and `teardown`. These
        merely pass on calls to module-level `.setup`, `.reload` and
        `.teardown`, where such is available.

        `setup` runs early post-connect routines, immediately after connection
        has been established.

        `reload` Reloads the plugin, where such makes sense. What this means is
        implementation-defined.

        `teardown` de-initialises the plugin.
     +/
    static foreach (immutable funName; AliasSeq!("setup", "reload", "teardown"))
    {
        mixin(`
        /++
            Automatically generated function.
         +/
        override public void ` ~ funName ~ `() @system
        {
            static if (__traits(compiles, { alias _ = .` ~ funName ~ `; }))
            {
                import lu.traits : TakesParams;

                if (!this.isEnabled) return;

                static if (
                    is(typeof(.` ~ funName ~ `)) &&
                    is(typeof(.` ~ funName ~ `) == function) &&
                    TakesParams!(.` ~ funName ~ `, typeof(this)))
                {
                    .` ~ funName ~ `(this);
                }
                else
                {
                    import kameloso.traits : stringOfTypeOf;
                    import std.format : format;

                    ` ~ "enum pattern = \"`%s.%s` has an unsupported function signature: `%s`\";
                    enum message = pattern.format(module_, \"" ~ funName ~ `", stringOfTypeOf!(.` ~ funName ~ `));
                    static assert(0, message);
                }
            }
        }`);
    }

    // tick
    /++
        Tick function. Called once every main loop iteration.
     +/
    override public bool tick() @system
    {
        static if (__traits(compiles, { alias _ = .tick; }))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return false;

            static if (
                is(typeof(.tick)) &&
                is(typeof(.tick) == function) &&
                TakesParams!(.tick, typeof(this)))
            {
                return .tick(this);
            }
            else
            {
                import kameloso.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.tick` has an unsupported function signature: `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.tick));
                static assert(0, message);
            }
        }
        else
        {
            return false;
        }
    }

    // name
    /++
        Returns the name of the plugin. (Technically it's the name of the module.)

        Returns:
            The module name of the mixing-in class.
     +/
    pragma(inline, true)
    override public string name() @property const pure nothrow @nogc
    {
        import lu.string : beginsWith;

        enum modulePrefix = "kameloso.plugins.";

        static if (module_.beginsWith(modulePrefix))
        {
            import std.string : indexOf;

            string slice = module_[modulePrefix.length..$];  // mutable
            immutable dotPos = slice.indexOf('.');
            if (dotPos == -1) return slice;
            return (slice[dotPos+1..$] == "base") ? slice[0..dotPos] : slice[dotPos+1..$];
        }
        else
        {
            import std.format : format;

            enum pattern = "Plugin module `%s` is not under `kameloso.plugins`";
            enum message = pattern.format(module_);
            static assert(0, message);
        }
    }

    // channelSpecificCommands
    /++
        Compile a list of our a plugin's oneliner commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each soft command active in the passed channel.
     +/
    override public IRCPlugin.CommandMetadata[string] channelSpecificCommands(const string channelName) @system
    {
        return null;
    }

    // commands
    /++
        Forwards to [kameloso.plugins.common.core.IRCPluginImpl.commandsImpl|IRCPluginImpl.commandsImpl].

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging
        [kameloso.plugins.common.core.IRCPluginImpl.commandsImpl|IRCPluginImpl.commandsImpl]
        for the actual dirty work.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.common.core.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.common.core.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.
     +/
    pragma(inline, true)
    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        return commandsImpl();
    }

    // commandsImpl
    /++
        Collects all [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command]
        command words and [kameloso.plugins.common.core.IRCEventHandler.Regex|IRCEventHandler.Regex]
        regex expressions that this plugin offers at compile time, then at runtime
        returns them alongside their descriptions and their visibility, as an associative
        array of [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s
        keyed by command name strings.

        This function is private, but since it's part of a mixin template it will
        be visible at the mixin site. Plugins can as such override
        [kameloso.plugins.common.core.IRCPlugin.commands|IRCPlugin.commands] with
        their own code and invoke [commandsImpl] as a fallback.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.common.core.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.common.core.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.
     +/
    private auto commandsImpl() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import kameloso.plugins.common.core : IRCEventHandler;
            import std.traits : getUDAs;

            assert(__ctfe, "ctCommandsEnumLiteral called outside CTFE");

            IRCPlugin.CommandMetadata[string] commandAA;

            foreach (fun; this.Introspection.allEventHandlerFunctionsInModule)
            {
                immutable uda = getUDAs!(fun, IRCEventHandler)[0];

                static foreach (immutable command; uda.commands)
                {{
                    enum key = command._word;
                    commandAA[key] = IRCPlugin.CommandMetadata(command);

                    static if (command._hidden)
                    {
                        // Just ignore
                    }
                    else static if (command._description.length)
                    {
                        static if (command.syntaxes.length)
                        {
                            commandAA[key].syntaxes ~= command.syntaxes.dup;
                        }
                        else
                        {
                            commandAA[key].syntaxes ~= "$command";
                        }
                    }
                    else /*static if (!command._hidden && !command._description.length)*/
                    {
                        import std.format : format;

                        enum fqn = module_ ~ '.' ~ __traits(identifier, fun);
                        enum pattern = "Warning: `%s` non-hidden command word \"%s\" is missing a description";
                        enum message = pattern.format(fqn, command._word);
                        pragma(msg, message);
                    }
                }}

                static foreach (immutable regex; uda.regexes)
                {{
                    enum key = `r"` ~ regex._expression ~ `"`;
                    commandAA[key] = IRCPlugin.CommandMetadata(regex);

                    static if (regex._description.length)
                    {
                        commandAA[key].syntaxes ~= regex._expression;
                    }
                    else static if (!regex._hidden)
                    {
                        import std.format : format;

                        enum fqn = module_ ~ '.' ~ __traits(identifier, fun);
                        enum pattern = "Warning: `%s` non-hidden expression \"%s\" is missing a description";
                        enum message = pattern.format(fqn, regex._expression);
                        pragma(msg, message);
                    }
                }}
            }

            return commandAA;
        }();

        // This is an associative array literal. We can't make it static immutable
        // because of AAs' runtime-ness. We could make it runtime immutable once
        // and then just the address, but this is really not a hotspot.
        // So just let it allocate when it wants.
        return this.isEnabled ? ctCommandsEnumLiteral : null;
    }

    // onBusMessage
    /++
        Proxies a bus message to the plugin, to let it handle it (or not).

        Params:
            header = String header for plugins to examine and decide if the
                message was meant for them.
            content = Wildcard content, to be cast to concrete types if the header matches.
     +/
    override public void onBusMessage(const string header, shared Sendable content) @system
    {
        static if (__traits(compiles, { alias _ = .onBusMessage; }))
        {
            import lu.traits : TakesParams;

            static if (
                is(typeof(.onBusMessage)) &&
                is(typeof(.onBusMessage) == function) &&
                TakesParams!(.onBusMessage, typeof(this), string, Sendable))
            {
                .onBusMessage(this, header, content);
            }
            /*else static if (
                is(typeof(.onBusMessage)) &&
                is(typeof(.onBusMessage) == function) &&
                TakesParams!(.onBusMessage, typeof(this), string))
            {
                .onBusMessage(this, header);
            }*/
            else
            {
                import kameloso.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.onBusMessage` has an unsupported function signature: `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.onBusMessage));
                static assert(0, message);
            }
        }
    }
}


// prefixPolicyMatches
/++
    Evaluates whether or not the message in an event satisfies the [PrefixPolicy]
    specified, as fetched from a [IRCEventHandler.Command] or [IRCEventHandler.Regex] UDA.

    If it doesn't match, the [IRCPluginImpl.onEventImpl] routine shall consider
    the UDA as not matching and continue with the next one.

    Params:
        verbose = Whether or not to output verbose debug information to the local terminal.
        event = Reference to the mutable [dialect.defs.IRCEvent|IRCEvent] we're considering.
        policy = Policy to apply.
        state = The calling [IRCPlugin]'s [IRCPluginState].

    Returns:
        `true` if the message is in a context where the event matches the
        `policy`, `false` if not.
 +/
auto prefixPolicyMatches(bool verbose)
    (ref IRCEvent event,
    const PrefixPolicy policy,
    const IRCPluginState state)
{
    import kameloso.string : stripSeparatedPrefix;
    import lu.string : beginsWith;
    import std.typecons : No, Yes;

    static if (verbose)
    {
        import std.stdio : writefln, writeln;
        writeln("...prefixPolicyMatches! policy:", policy);
    }

    bool strippedDisplayName;

    with (PrefixPolicy)
    final switch (policy)
    {
    case direct:
        static if (verbose)
        {
            writeln("direct, so just passes.");
        }
        return true;

    case prefixed:
        if (!state.settings.prefix.length)
        {
            static if (verbose)
            {
                writeln("no prefix set, so defer to nickname case.");
            }

            goto case nickname;
        }
        else if (event.content.beginsWith(state.settings.prefix))
        {
            static if (verbose)
            {
                enum pattern = "starts with prefix (%s)";
                writefln(pattern, state.settings.prefix);
            }

            event.content = event.content[state.settings.prefix.length..$];
        }
        else
        {
            static if (verbose)
            {
                writeln("did not start with prefix but falling back to nickname check");
            }

            goto case nickname;
        }
        break;

    case nickname:
        if (event.content.beginsWith('@'))
        {
            static if (verbose)
            {
                writeln("stripped away prepended '@'");
            }

            // Using @name to refer to someone is not
            // uncommon; allow for it and strip it away
            event.content = event.content[1..$];
        }

        version(TwitchSupport)
        {
            if ((state.server.daemon == IRCServer.Daemon.twitch) &&
                state.client.displayName.length &&
                event.content.beginsWith(state.client.displayName))
            {
                static if (verbose)
                {
                    writeln("begins with displayName! stripping it");
                }

                event.content = event.content
                    .stripSeparatedPrefix(state.client.displayName, Yes.demandSeparatingChars);

                if (state.settings.prefix.length && event.content.beginsWith(state.settings.prefix))
                {
                    static if (verbose)
                    {
                        enum pattern = "further starts with prefix (%s)";
                        writefln(pattern, state.settings.prefix);
                    }

                    event.content = event.content[state.settings.prefix.length..$];
                }

                strippedDisplayName = true;
                // Drop down
            }
        }

        if (strippedDisplayName)
        {
            // Already did something
        }
        else if (event.content.beginsWith(state.client.nickname))
        {
            static if (verbose)
            {
                writeln("begins with nickname! stripping it");
            }

            event.content = event.content
                .stripSeparatedPrefix(state.client.nickname, Yes.demandSeparatingChars);

            if (state.settings.prefix.length && event.content.beginsWith(state.settings.prefix))
            {
                static if (verbose)
                {
                    enum pattern = "further starts with prefix (%s)";
                    writefln(pattern, state.settings.prefix);
                }

                event.content = event.content[state.settings.prefix.length..$];
            }
            // Drop down
        }
        else if (event.type == IRCEvent.Type.QUERY)
        {
            static if (verbose)
            {
                writeln("doesn't begin with nickname but it's a QUERY");
            }
            // Drop down
        }
        else
        {
            static if (verbose)
            {
                writeln("nickname required but not present... returning false.");
            }
            return false;
        }
        break;
    }

    static if (verbose)
    {
        writeln("policy checks out!");
    }

    return true;
}


// filterSender
/++
    Decides if a sender meets a [Permissions] and is allowed to trigger an event
    handler, or if a WHOIS query is needed to be able to tell.

    This requires the Persistence service to be active to work.

    Params:
        event = [dialect.defs.IRCEvent|IRCEvent] to filter.
        permissionsRequired = The [Permissions] context in which this user should be filtered.
        preferHostmasks = Whether to rely on hostmasks for user identification,
            or to use services account logins, which need to be issued WHOIS
            queries to divine.

    Returns:
        A [FilterResult] saying the event should `pass`, `fail`, or that more
        information about the sender is needed via a WHOIS call.
 +/
auto filterSender(
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    const bool preferHostmasks) @safe
{
    import kameloso.constants : Timeout;

    version(WithPersistenceService) {}
    else
    {
        pragma(msg, "Warning: The Persistence service is not compiled in. " ~
            "Event triggers may or may not work. You get to keep the pieces.");
    }

    immutable class_ = event.sender.class_;

    if (class_ == IRCUser.Class.blacklist) return FilterResult.fail;

    immutable timediff = (event.time - event.sender.updated);

    // In hostmasks mode there's zero point to WHOIS a sender, as the instigating
    // event will have the hostmask embedded in it, always.
    immutable whoisExpired = !preferHostmasks && (timediff > Timeout.whoisRetry);

    if (event.sender.account.length)
    {
        immutable isAdmin = (class_ == IRCUser.Class.admin);  // Trust in Persistence
        immutable isStaff = (class_ == IRCUser.Class.staff);
        immutable isOperator = (class_ == IRCUser.Class.operator);
        immutable isElevated = (class_ == IRCUser.Class.elevated);
        immutable isWhitelisted = (class_ == IRCUser.Class.whitelist);
        immutable isAnyone = (class_ == IRCUser.Class.anyone);

        if (isAdmin)
        {
            return FilterResult.pass;
        }
        else if (isStaff && (permissionsRequired <= Permissions.staff))
        {
            return FilterResult.pass;
        }
        else if (isOperator && (permissionsRequired <= Permissions.operator))
        {
            return FilterResult.pass;
        }
        else if (isElevated && (permissionsRequired <= Permissions.elevated))
        {
            return FilterResult.pass;
        }
        else if (isWhitelisted && (permissionsRequired <= Permissions.whitelist))
        {
            return FilterResult.pass;
        }
        else if (/*event.sender.account.length &&*/ permissionsRequired <= Permissions.registered)
        {
            return FilterResult.pass;
        }
        else if (isAnyone && (permissionsRequired <= Permissions.anyone))
        {
            return whoisExpired ? FilterResult.whois : FilterResult.pass;
        }
        else if (permissionsRequired == Permissions.ignore)
        {
            /*assert(0, "`filterSender` saw a `Permissions.ignore` and the call " ~
                "to it could have been skipped");*/
            return FilterResult.pass;
        }
        else
        {
            return FilterResult.fail;
        }
    }
    else
    {
        immutable isLogoutEvent = (event.type == IRCEvent.Type.ACCOUNT);

        with (Permissions)
        final switch (permissionsRequired)
        {
        case admin:
        case staff:
        case operator:
        case elevated:
        case whitelist:
        case registered:
            // Unknown sender; WHOIS if old result expired, otherwise fail
            return (whoisExpired && !isLogoutEvent) ? FilterResult.whois : FilterResult.fail;

        case anyone:
            // Unknown sender; WHOIS if old result expired in mere curiosity, else just pass
            return (whoisExpired && !isLogoutEvent) ? FilterResult.whois : FilterResult.pass;

        case ignore:
            /*assert(0, "`filterSender` saw a `Permissions.ignore` and the call " ~
                "to it could have been skipped");*/
            return FilterResult.pass;
        }
    }
}


// allowImpl
/++
    Judges whether an event may be triggered, based on the event itself and
    the annotated [kameloso.plugins.common.core.Permissions|Permissions] of the
    handler in question. Implementation function.

    Params:
        plugin = The [IRCPlugin] this relates to.
        event = [dialect.defs.IRCEvent|IRCEvent] to allow, or not.
        permissionsRequired = Required [kameloso.plugins.common.core.Permissions|Permissions]
            of the handler in question.

    Returns:
        [FilterResult.pass] if the event should be allowed to trigger,
        [FilterResult.whois] if not.

    See_Also:
        [filterSender]
 +/
auto allowImpl(
    IRCPlugin plugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired) pure @safe
{
    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            if (((permissionsRequired == Permissions.anyone) ||
                (permissionsRequired == Permissions.registered)) &&
                (event.sender.class_ != IRCUser.Class.blacklist))
            {
                // We can't WHOIS on Twitch, and Permissions.anyone is just
                // Permissions.ignore with an extra WHOIS for good measure.
                // Also everyone is registered on Twitch, by definition.
                return FilterResult.pass;
            }
        }
    }

    // Permissions.ignore always passes, even for Class.blacklist.
    return (permissionsRequired == Permissions.ignore) ?
        FilterResult.pass :
        filterSender(event, permissionsRequired, plugin.state.settings.preferHostmasks);
}


// sanitiseEvent
/++
    Sanitise event, used upon UTF/Unicode exceptions.

    Params:
        event = Reference to the mutable [dialect.defs.IRCEvent|IRCEvent] to sanitise.
 +/
void sanitiseEvent(ref IRCEvent event)
{
    import std.encoding : sanitize;
    import std.range : only;

    event.raw = sanitize(event.raw);
    event.channel = sanitize(event.channel);
    event.content = sanitize(event.content);
    event.tags = sanitize(event.tags);
    event.errors = sanitize(event.errors);
    event.errors ~= event.errors.length ? " | Sanitised" : "Sanitised";

    foreach (ref auxN; event.aux)
    {
        auxN = sanitize(auxN);
    }

    foreach (user; only(&event.sender, &event.target))
    {
        user.nickname = sanitize(user.nickname);
        user.ident = sanitize(user.ident);
        user.address = sanitize(user.address);
        user.account = sanitize(user.account);

        version(TwitchSupport)
        {
            user.displayName = sanitize(user.displayName);
            user.badges = sanitize(user.badges);
            user.colour = sanitize(user.colour);
        }
    }
}


// udaSanityCheckCTFE
/++
    Sanity-checks a plugin's [IRCEventHandler]s at compile time.

    Params:
        uda = The [IRCEventHandler] UDA to check.

    Throws:
        Asserts `0` if the UDA is deemed malformed.
 +/
version(unittest)
void udaSanityCheckCTFE(const IRCEventHandler uda)
{
    import std.format : format;

    assert(__ctfe, "udaSanityCheckCTFE called outside CTFE");

    /++
        There's something wrong with how the assert message is printed from CTFE.
        Work around it somewhat by prepending a backtick.

        https://issues.dlang.org/show_bug.cgi?id=24036

        Add a `static if` on the compiler version when this is fixed.
     +/
    enum fix = "`";

    if (!uda.acceptedEventTypes.length)
    {
        enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
            "but it is not declared to accept any `IRCEvent.Type`s";
        immutable message = pattern.format(uda.fqn).idup;
        assert(0, message);
    }

    foreach (immutable type; uda.acceptedEventTypes)
    {
        if (type == IRCEvent.Type.UNSET)
        {
            enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.UNSET`, which is not a valid event type";
            immutable message = pattern.format(uda.fqn).idup;
            assert(0, message);
        }
        else if (type == IRCEvent.Type.PRIVMSG)
        {
            enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.PRIVMSG`, which is not a valid event type. " ~
                "Use `IRCEvent.Type.CHAN` and/or `IRCEvent.Type.QUERY` instead";
            immutable message = pattern.format(uda.fqn).idup;
            assert(0, message);
        }
        else if (type == IRCEvent.Type.WHISPER)
        {
            enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.WHISPER`, which is not a valid event type. " ~
                "Use `IRCEvent.Type.QUERY` instead";
            immutable message = pattern.format(uda.fqn).idup;
            assert(0, message);
        }
        else if ((type == IRCEvent.Type.ANY) && (uda.channelPolicy != ChannelPolicy.any))
        {
            enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.ANY` and is at the same time not annotated " ~
                "`ChannelPolicy.any`, which is the only accepted combination";
            immutable message = pattern.format(uda.fqn).idup;
            assert(0, message);
        }

        if (uda.commands.length || uda.regexes.length)
        {
            if (
                (type != IRCEvent.Type.CHAN) &&
                (type != IRCEvent.Type.QUERY) &&
                (type != IRCEvent.Type.SELFCHAN) &&
                (type != IRCEvent.Type.SELFQUERY))
            {
                import lu.conv : Enum;

                enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` and/or `Regex`, but is at the " ~
                    "same time accepting non-message `IRCEvent.Type.%s events`";
                immutable message = pattern.format(
                    uda.fqn,
                    Enum!(IRCEvent.Type).toString(type)).idup;
                assert(0, message);
            }
        }
    }

    if (uda.commands.length)
    {
        import lu.string : contains;

        foreach (const command; uda.commands)
        {
            if (!command._word.length)
            {
                enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` with an empty (or unspecified) trigger word";
                immutable message = pattern.format(uda.fqn).idup;
                assert(0, message);
            }
            else if (command._word.contains(' '))
            {
                enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` whose trigger " ~
                    `word "%s" contains a space character`;
                immutable message = pattern.format(uda.fqn, command._word).idup;
                assert(0, message);
            }
        }
    }

    if (uda.regexes.length)
    {
        foreach (const regex; uda.regexes)
        {
            if (!regex._expression.length)
            {
                enum pattern = fix ~ "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Regex` with an empty (or unspecified) expression";
                immutable message = pattern.format(uda.fqn).idup;
                assert(0, message);
            }
        }
    }

    // The below is done inside onEventImpl as it needs template access to the module
    /*if ((uda._permissionsRequired != Permissions.ignore) &&
        !__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
    {
        import std.format : format;

        enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
            "mixin (needed for `Permissions` checks)";
        immutable message = pattern.format(module_);
        assert(0, message);
    }*/
}


// assertSaneStorageClasses
/++
    Asserts that a parameter storage class is not `ref` if `inFiber`, and neither
    `ref` nor `out` if not `inFiber`. To be run during CTFE.

    Take the storage class as a template parameter and statically
    assert inside this function, unlike how `udaSanityCheck` returns
    false on failure, so we can format and print the error message
    once here (instead of at all call sites upon receiving false).

    Params:
        storageClass = The storage class of the parameter.
        paramIsConst = Whether or not the parameter is `const`.
        inFiber = Whether or not the event handler is annotated `.fiber(true)`.
        module_ = The module name of the plugin.
        typestring = The signature string of the function.

    Returns:
        `true` if the storage class is valid; asserts `0` if not.
 +/
version(unittest)
auto assertSaneStorageClasses(
    const ParameterStorageClass storageClass,
    const bool paramIsConst,
    const bool inFiber,
    const string module_,
    const string typestring)
{
    import std.format : format;

    assert(__ctfe, "`assertSaneStorageClasses` called outside CTFE");

    static if (__VERSION__ <= 2104L)
    {
        /++
            There's something wrong with how the assert message is printed from CTFE.
            Work around it somewhat by prepending a backtick.

            https://issues.dlang.org/show_bug.cgi?id=24036
         +/
        enum fix = "`";
    }
    else
    {
        // Hopefully no need past 2.104... Update when 2.105 is out.
        enum fix = string.init;
    }

    if (inFiber)
    {
        if (storageClass & ParameterStorageClass.ref_)
        {
            enum pattern = fix ~ "`%s` has a `%s` event handler annotated `.fiber(true)` " ~
                "that takes an `IRCEvent` by `ref`, which is a combination prone " ~
                "to memory corruption. Pass by value instead";
            immutable message = pattern.format(module_, typestring).idup;
            assert(0, message);
        }
    }
    else if (!paramIsConst)
    {
        if (
            (storageClass & ParameterStorageClass.ref_) ||
            (storageClass & ParameterStorageClass.out_))
        {
            enum pattern = fix ~ "`%s` has a `%s` event handler that takes an " ~
                "`IRCEvent` of an unsupported storage class; " ~
                "may not be mutable `ref` or `out`";
            immutable message = pattern.format(module_, typestring).idup;
            assert(0, message);
        }
    }

    return true;
}


// IRCPluginState
/++
    An aggregate of all variables that make up the common state of plugins.

    This neatly tidies up the amount of top-level variables in each plugin
    module. This allows for making more or less all functions top-level
    functions, since any state could be passed to it with variables of this type.

    Plugin-specific state should be kept inside the [IRCPlugin] subclass itself.

    See_Also:
        [IRCPlugin]
 +/
struct IRCPluginState
{
private:
    import kameloso.pods : ConnectionSettings, CoreSettings, IRCBot;
    import kameloso.thread : ScheduledDelegate, ScheduledFiber;
    import std.concurrency : Tid;
    import core.thread : Fiber;

    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Private value.
     +/
    uint _connectionID;

public:
    // Update
    /++
        Bitfield enum of what member of an instance of `IRCPluginState` was updated (if any).
     +/
    enum Update
    {
        /++
            Nothing marked as updated. Initial value.
         +/
        nothing  = 0,

        /++
            [IRCPluginState.bot] was marked as updated.
         +/
        bot      = 1 << 0,

        /++
            [IRCPluginState.client] was marked as updated.
         +/
        client   = 1 << 1,

        /++
            [IRCPluginState.server] was marked as updated.
         +/
        server   = 1 << 2,

        /++
            [IRCPluginState.settings] was marked as updated.
         +/
        settings = 1 << 3,
    }

    // client
    /++
        The current [dialect.defs.IRCClient|IRCClient], containing information
        pertaining to the bot in the context of a client connected to an IRC server.
     +/
    IRCClient client;

    // server
    /++
        The current [dialect.defs.IRCServer|IRCServer], containing information
        pertaining to the bot in the context of an IRC server.
     +/
    IRCServer server;

    // bot
    /++
        The current [kameloso.pods.IRCBot|IRCBot], containing information
        pertaining to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    // settings
    /++
        The current program-wide [kameloso.pods.CoreSettings|CoreSettings].
     +/
    CoreSettings settings;

    // connSettings
    /++
        The current program-wide [kameloso.pods.ConnectionSettings|ConnectionSettings].
     +/
    ConnectionSettings connSettings;

    // mainThread
    /++
        Thread ID to the main thread.
     +/
    Tid mainThread;

    // users
    /++
        Hashmap of IRC user details.
     +/
    IRCUser[string] users;

    // channels
    /++
        Hashmap of IRC channels.
     +/
    IRCChannel[string] channels;

    // pendingReplays
    /++
        Queued [dialect.defs.IRCEvent|IRCEvent]s to replay.

        The main loop iterates this after processing all on-event functions so
        as to know what nicks the plugin wants a WHOIS for. After the WHOIS
        response returns, the event bundled with the [Replay] will be replayed.
     +/
    Replay[][string] pendingReplays;

    // hasReplays
    /++
        Whether or not [pendingReplays] has elements (i.e. is not empty).
     +/
    bool hasPendingReplays;

    // readyReplays
    /++
        [Replay]s primed and ready to be replayed.
     +/
    Replay[] readyReplays;

    // awaitingFibers
    /++
        The list of awaiting [core.thread.fiber.Fiber|Fiber]s, keyed by
        [dialect.defs.IRCEvent.Type|IRCEvent.Type].
     +/
    Fiber[][] awaitingFibers;

    // awaitingDelegates
    /++
        The list of awaiting `void delegate(IRCEvent)` delegates, keyed by
        [dialect.defs.IRCEvent.Type|IRCEvent.Type].
     +/
    void delegate(IRCEvent)[][] awaitingDelegates;

    // scheduledFibers
    /++
        The list of scheduled [core.thread.fiber.Fiber|Fiber], UNIX time tuples.
     +/
    ScheduledFiber[] scheduledFibers;

    // scheduledDelegates
    /++
        The list of scheduled delegate, UNIX time tuples.
     +/
    ScheduledDelegate[] scheduledDelegates;

    // nextScheduledTimestamp
    /++
        The UNIX timestamp of when the next scheduled
        [kameloso.thread.ScheduledFiber|ScheduledFiber] or delegate should be triggered.
     +/
    long nextScheduledTimestamp = long.max;

    // updateSchedule
    /++
        Updates the saved UNIX timestamp of when the next scheduled
        [core.thread.fiber.Fiber|Fiber] or delegate should be triggered.
     +/
    void updateSchedule() pure nothrow @nogc
    {
        // Reset the next timestamp to an invalid value, then update it as we
        // iterate the fibers' and delegates' labels.

        nextScheduledTimestamp = long.max;

        foreach (const scheduledFiber; scheduledFibers)
        {
            if (scheduledFiber.timestamp < nextScheduledTimestamp)
            {
                nextScheduledTimestamp = scheduledFiber.timestamp;
            }
        }

        foreach (const scheduledDg; scheduledDelegates)
        {
            if (scheduledDg.timestamp < nextScheduledTimestamp)
            {
                nextScheduledTimestamp = scheduledDg.timestamp;
            }
        }
    }

    // previousWhoisTimestamps
    /++
        A copy of the main thread's `previousWhoisTimestamps` associative arrays
        of UNIX timestamps of when someone had a WHOIS query aimed at them, keyed
        by nickname.
     +/
    long[string] previousWhoisTimestamps;

    // updates
    /++
        Bitfield of in what way the plugin state was altered during postprocessing
        or event handler execution.

        Example:
        ---
        if (state.updates & IRCPluginState.Update.bot)
        {
            // state.bot was marked as updated
            state.updates |= IRCPluginState.Update.server;
            // state.server now marked as updated
        }
        ---
     +/
    Update updates;

    // abort
    /++
        Pointer to the global abort flag.
     +/
    bool* abort;

    // connectionID
    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Accessor.

        Returns:
            The numeric ID of the current connection.
     +/
    pragma(inline, true)
    auto connectionID() const
    {
        return _connectionID;
    }

    // this
    /++
        Constructor taking a connection ID `uint`.
     +/
    this(const uint connectionID)
    {
        this._connectionID = connectionID;
    }

    // specialRequests
    /++
        This plugin's array of [SpecialRequest]s.
     +/
    SpecialRequest[] specialRequests;
}


// Replay
/++
    Embodies the notion of an event to be replayed, once we know more about a user
    (meaning after a WHOIS query response).
 +/
struct Replay
{
    // caller
    /++
        Name of the caller function or similar context.
     +/
    string caller;

    // event
    /++
        Stored [dialect.defs.IRCEvent|IRCEvent] to replay.
     +/
    IRCEvent event;

    // permissionsRequired
    /++
        [Permissions] required by the function to replay.
     +/
    Permissions permissionsRequired;

    // dg
    /++
        Delegate, whose context includes the plugin to whom this [Replay] relates.
     +/
    void delegate(Replay) dg;

    // timestamp
    /++
        When this request was issued.
     +/
    long timestamp;

    /++
        Creates a new [Replay] with a timestamp of the current time.
     +/
    this(
        void delegate(Replay) dg,
        const ref IRCEvent event,
        const Permissions permissionsRequired,
        const string caller)
    {
        this.timestamp = event.time;
        this.dg = dg;
        this.event = event;
        this.permissionsRequired = permissionsRequired;
        this.caller = caller;
    }
}


// filterResult
/++
    The tristate results from comparing a username with the admin or
    whitelist/elevated/operator/staff lists.
 +/
enum FilterResult
{
    /++
        The user is not allowed to trigger this function.
     +/
    fail,

    /++
        The user is allowed to trigger this function.
     +/
    pass,

    /++
        We don't know enough to say whether the user is allowed to trigger this
        function, so do a WHOIS query and act based on the results.
     +/
    whois,
}


// PrefixPolicy
/++
    In what way the contents of a [dialect.defs.IRCEvent|IRCEvent] must start
    (be "prefixed") for an annotated function to be allowed to trigger.
 +/
enum PrefixPolicy
{
    /++
        The annotated event handler will not examine the [dialect.defs.IRCEvent.content|IRCEvent.content]
        member at all and will always trigger, as long as all other annotations match.
     +/
    direct,

    /++
        The annotated event handler will only trigger if the
        [dialect.defs.IRCEvent.content|IRCEvent.content] member starts with the
        [kameloso.pods.CoreSettings.prefix|CoreSettings.prefix] (e.g. "!").
        All other annotations must also match.
     +/
    prefixed,

    /++
        The annotated event handler will only trigger if the
        [dialect.defs.IRCEvent.content|IRCEvent.content] member starts with the
        bot's name, as if addressed to it.

        In [dialect.defs.IRCEvent.Type.QUERY|QUERY] events this instead behaves as
        [PrefixPolicy.direct].
     +/
    nickname,
}


// ChannelPolicy
/++
    Whether an annotated function should be allowed to trigger on events in only
    home channels or in guest ones as well.
 +/
enum ChannelPolicy
{
    /++
        The annotated function will only be allowed to trigger if the event
        happened in a home channel, where applicable. Not all events carry channels.
     +/
    home,

    /++
        The annotated function will only be allowed to trigger if the event
        happened in a guest channel, where applicable. Not all events carry channels.
     +/
    guest,

    /++
        The annotated function will be allowed to trigger regardless of channel.
     +/
    any,
}


// Permissions
/++
    What level of permissions is needed to trigger an event handler.

    In any event handler context, the triggering user has a *level of privilege*.
    This decides whether or not they are allowed to trigger the function.
    Put simply this is the "barrier of entry" for event handlers.

    Permissions are set on a per-channel basis and are stored in the "users.json"
    file in the resource directory.
 +/
enum Permissions
{
    /++
        Override privilege checks, allowing anyone to trigger the annotated function.
     +/
    ignore = 0,

    /++
        Anyone not explicitly blacklisted (with a
        [dialect.defs.IRCUser.Class.blacklist|IRCUser.Class.blacklist]
        classifier) may trigger the annotated function. As such, to know if they're
        blacklisted, unknown users will first be looked up with a WHOIS query
        before allowing the function to trigger.
     +/
    anyone = 10,

    /++
        Anyone logged onto services may trigger the annotated function.
     +/
    registered = 20,

    /++
        Only users with a [dialect.defs.IRCUser.Class.whitelist|IRCUser.Class.whitelist]
        classifier (or higher) may trigger the annotated function.
     +/
    whitelist = 30,

    /++
        Only users with a [dialect.defs.IRCUser.Class.elevated|IRCUser.Class.elevated]
        classifier (or higher) may trigger the annotated function.
     +/
    elevated = 40,

    /++
        Only users with a [dialect.defs.IRCUser.Class.operator|IRCUser.Class.operator]
        classifier (or higiher) may trigger the annotated function.

        Note: this does not mean IRC "+o" operators.
     +/
    operator = 50,

    /++
        Only users with a [dialect.defs.IRCUser.Class.staff|IRCUser.Class.staff]
        classifier (or higher) may trigger the annotated function.

        These are channel owners.
     +/
    staff = 60,

    /++
        Only users defined in the configuration file as an administrator may
        trigger the annotated function.
     +/
    admin = 100,
}


// Timing
/++
    Declaration of what order event handler function should be given with respects
    to other functions in the same plugin module.
 +/
enum Timing
{
    /++
        No timing.
     +/
    untimed,

    /++
        To be executed during setup; the first thing to happen.
     +/
    setup,

    /++
        To be executed after setup but before normal event handlers.
     +/
    early,

    /++
        To be executed after normal event handlers.
     +/
    late,

    /++
        To be executed last before execution moves on to the next plugin.
     +/
    cleanup,
}


// IRCEventHandler
/++
    Aggregate to annotate event handler functions with, to control what they do
    and how they work.
 +/
struct IRCEventHandler
{
private:
    import kameloso.typecons : UnderscoreOpDispatcher;

public:
    // acceptedEventTypes
    /++
        Array of types of [dialect.defs.IRCEvent] that the annotated event
        handler function should accept.
     +/
    IRCEvent.Type[] acceptedEventTypes;

    // _onEvent
    /++
        Alias to make [kameloso.typecons.UnderscoreOpDispatcher] redirect calls to
        [acceptedEventTypes] but by the name `onEvent`.
     +/
    alias _onEvent = acceptedEventTypes;

    // _permissionsRequired
    /++
        Permissions required of instigating user, below which the annotated
        event handler function should not be triggered.
     +/
    Permissions _permissionsRequired = Permissions.ignore;

    // _channelPolicy
    /++
        What kind of channel the annotated event handler function may be
        triggered in; homes or mere guest channels.
     +/
    ChannelPolicy _channelPolicy = ChannelPolicy.home;

    // commands
    /++
        Array of [IRCEventHandler.Command]s the bot should pick up and listen for.
     +/
    Command[] commands;

    // _addCommand
    /++
        Alias to make [kameloso.typecons.UnderscoreOpDispatcher] redirect calls to
        [commands] but by the name `addCommand`.
     +/
    alias _addCommand = commands;

    // regexes
    /++
        Array of [IRCEventHandler.Regex]es the bot should pick up and listen for.
     +/
    Regex[] regexes;

    // _addRegex
    /++
        Alias to make [kameloso.typecons.UnderscoreOpDispatcher] redirect calls to
        [regexes] but by the name `addRegex`.
     +/
    alias _addRegex = regexes;

    // _chainable
    /++
        Whether or not the annotated event handler function should allow other
        functions to fire after it. If not set (default false), it will
        terminate and move on to the next plugin after the function returns.
     +/
    bool _chainable;

    // _verbose
    /++
        Whether or not additional information should be output to the local
        terminal as the function is (or is not) triggered.
     +/
    bool _verbose;

    // _when
    /++
        Special instruction related to the order of which event handler functions
        within a plugin module are triggered.
     +/
    Timing _when;

    // _fiber
    /++
        Whether or not the annotated event handler should be run from within a
        [core.thread.fiber.Fiber|Fiber].
     +/
    bool _fiber;

    // acceptedEventTypeMap
    /++
        Array of accepted [dialect.defs.IRCEvent.Type|IRCEvent.Type]s.
     +/
    bool[] acceptedEventTypeMap;

    // generateTypemap
    /++
        Generates [acceptedEventTypeMap] from [acceptedEventTypes].
     +/
    void generateTypemap() pure @safe nothrow
    {
        assert(__ctfe, "generateTypemap called outside CTFE");

        foreach (immutable type; acceptedEventTypes)
        {
            if (type >= acceptedEventTypeMap.length) acceptedEventTypeMap.length = type+1;
            acceptedEventTypeMap[type] = true;
        }
    }

    mixin UnderscoreOpDispatcher;

    // fqn
    /++
        Fully qualified name of the function the annotated [IRCEventHandler] is attached to.
     +/
    string fqn;

    // Command
    /++
        Embodies the notion of a chat command, e.g. `!hello`.
     +/
    static struct Command
    {
        // _policy
        /++
            In what way the message is required to start for the annotated function to trigger.
         +/
        PrefixPolicy _policy = PrefixPolicy.prefixed;

        // _word
        /++
            The command word, without spaces.
         +/
        string _word;

        // word
        /++
            The command word, without spaces. Mutator.

            Upon setting this the word is also converted to lowercase.
            Because we define this explicit function we need not rely on
            [kameloso.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher].

            Params:
                word = New command word.

            Returns:
                A `this` reference to the current struct instance.
         +/
        ref auto word(const string word)
        {
            import std.uni : toLower;
            this._word = word.toLower;
            return this;
        }

        // _description
        /++
            Describes the functionality of the event handler function the parent
            [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Command].

            Specifically this is used to describe functions triggered by
            [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
         +/
        string _description;

        // _hidden
        /++
            Whether this is a hidden command or if it should show up in help listings.
         +/
        bool _hidden;

        // syntaxes
        /++
            Command usage syntax help strings.
         +/
        string[] syntaxes;

        // _addSyntax
        /++
            Alias to make [kameloso.typecons.UnderscoreOpDispatcher] redirect calls to
            [syntaxes] but by the name `addSyntax`.
         +/
        alias _addSyntax = syntaxes;

        mixin UnderscoreOpDispatcher;
    }

    // Regex
    /++
        Embodies the notion of a chat command regular expression, e.g. `![Hh]ello+`.
     +/
    static struct Regex
    {
    private:
        import std.regex : StdRegex = Regex;

    public:
        // _policy
        /++
            In what way the message is required to start for the annotated function to trigger.
         +/
        PrefixPolicy _policy = PrefixPolicy.direct;

        // engine
        /++
            Regex engine to match incoming messages with.
         +/
        StdRegex!char engine;

        // _expression
        /++
            The regular expression in string form.
         +/
        string _expression;

        // _description
        /++
            Describes the functionality of the event handler function the parent
            [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Regex].

            Specifically this is used to describe functions triggered by
            [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
         +/
        string _description;

        // _hidden
        /++
            Whether this is a hidden command or if it should show up in help listings.
         +/
        bool _hidden;

        // _expression
        /++
            The regular expression this [IRCEventHandler.Regex] embodies, in string form.

            Upon setting this a regex engine is also created. Because of this extra step we
            cannot rely on [kameloso.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
            to redirect calls.

            Example:
            ---
            Regex()
                .expression(r"(?:^|\s)MonkaS(?:$|\s)")
                .description("Detects MonkaS.")
            ---

            Params:
                expression = New regular expression string.

            Returns:
                A `this` reference to the current struct instance.
         +/
        ref auto expression()(const string expression)
        {
            import std.regex : regex;

            this._expression = expression;
            this.engine = expression.regex;
            return this;
        }

        mixin UnderscoreOpDispatcher;
    }
}


// SpecialRequest
/++
    Embodies the notion of a special request a plugin issues to the main thread.
 +/
interface SpecialRequest
{
private:
    import core.thread : Fiber;

public:
    // context
    /++
        String context of the request.
     +/
    string context();

    // fiber
    /++
        Fiber embedded into the request.
     +/
    Fiber fiber();
}


// SpecialRequestImpl
/++
    Concrete implementation of a [SpecialRequest].

    The template parameter `T` defines that kind of
    [kameloso.thread.CarryingFiber|CarryingFiber] is embedded into it.

    Params:
        T = Type to instantiate the [kameloso.thread.CarryingFiber|CarryingFiber] with.
 +/
final class SpecialRequestImpl(T) : SpecialRequest
{
private:
    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;

    /++
        Private context string.
     +/
    string _context;

    /++
        Private [kameloso.thread.CarryingFiber|CarryingFiber].
     +/
    CarryingFiber!T _fiber;

public:
    // this
    /++
        Constructor.

        Params:
            context = String context of the request.
            fiber = [kameloso.thread.CarryingFiber|CarryingFiber] to embed into the request.
     +/
    this(string context, CarryingFiber!T fiber)
    {
        this._context = context;
        this._fiber = fiber;
    }

    // this
    /++
        Constructor.

        Params:
            context = String context of the request.
            dg = Delegate to create a [kameloso.thread.CarryingFiber|CarryingFiber] from.
     +/
    this(string context, void delegate() dg)
    {
        import kameloso.constants : BufferSize;

        this._context = context;
        this._fiber = new CarryingFiber!T(dg, BufferSize.fiberStack);
    }

    // context
    /++
        String context of the request. May be anything; highly request-specific.

        Returns:
            A string.
     +/
    string context()
    {
        return _context;
    }

    // fiber
    /++
        [kameloso.thread.CarryingFiber|CarryingFiber] embedded into the request.

        Returns:
            A [kameloso.thread.CarryingFiber|CarryingFiber] in the guise of a
            [core.thread.Fiber|Fiber].
     +/
    Fiber fiber()
    {
        return _fiber;
    }
}


// specialRequest
/++
    Instantiates a [SpecialRequestImpl] in the guise of a [SpecialRequest]
    with the implicit type `T` as payload.

    Params:
        T = Type to instantiate [SpecialRequestImpl] with.
        context = String context of the request.
        fiber = [kameloso.thread.CarryingFiber|CarryingFiber] to embed into the request.

    Returns:
        A new [SpecialRequest] that is in actually a [SpecialRequestImpl].
 +/
SpecialRequest specialRequest(T)(const string context, CarryingFiber!T fiber)
{
    return new SpecialRequestImpl!T(context, fiber);
}


// specialRequest
/++
    Instantiates a [SpecialRequestImpl] in the guise of a [SpecialRequest]
    with the explicit type `T` as payload.

    Params:
        T = Type to instantiate [SpecialRequestImpl] with.
        context = String context of the request.
        dg = Delegate to create a [kameloso.thread.CarryingFiber|CarryingFiber] from.

    Returns:
        A new [SpecialRequest] that is in actually a [SpecialRequestImpl].
 +/
SpecialRequest specialRequest(T)(const string context, void delegate() dg)
{
    return new SpecialRequestImpl!T(context, dg);
}


// Settings
/++
    Annotation denoting that a struct variable or struct type is to be considered
    as housing settings for a plugin, and should thus be serialised and saved in
    the configuration file.
 +/
enum Settings;


// Resource
/++
    Annotation denoting that a variable is the basename of a resource file or directory.
 +/
struct Resource
{
    /++
        Subdirectory in which to put the annotated filename.
     +/
    string subdirectory;
}


// Configuration
/++
    Annotation denoting that a variable is the basename of a configuration
    file or directory.
 +/
struct Configuration
{
    /++
        Subdirectory in which to put the annotated filename.
     +/
    string subdirectory;
}


// Enabler
/++
    Annotation denoting that a variable enables and disables a plugin.
 +/
enum Enabler;

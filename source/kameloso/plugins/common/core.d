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

    final class FooPlugin : IRCPlugin
    {
        // ...

        mixin IRCPluginImpl;
    }
    ---

    See_Also:
        [kameloso.plugins.common.misc|plugins.common.misc]

        [kameloso.plugins.common.mixins|plugins.common.mixins]

        [kameloso.plugins.common.delayawait|plugins.common.delayawait]
 +/
module kameloso.plugins.common.core;

private:

import dialect.defs;
import std.typecons : Flag, No, Yes;

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
        Metadata about a [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command]- and/or
        [kameloso.plugins.common.core.IRCEventHandler.Regex|IRCEventHandler.Regex]-annotated event handler.

        See_Also:
            [commands]
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

        /// Constructor. Don't take a `syntax` here, populate it manually.
        this(
            const PrefixPolicy policy,
            const string description,
            const bool hidden) pure @safe nothrow @nogc
        {
            this.policy = policy;
            this.description = description;
            this.hidden = hidden;
        }
    }

    // state
    /++
        An [kameloso.plugins.common.core.IRCPluginState|IRCPluginState] instance containing
        variables and arrays that represent the current state of the plugin.
        Should generally be passed by reference.
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

    // start
    /++
        Called when connection has been established.
     +/
    void start() @system;

    // printSettings
    /++
        Called when we want a plugin to print its
        [kameloso.plugins.common.core.Settings|Settings]-annotated struct of settings.
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
            An associative [CommandMetadata] array keyed by string.
     +/
    CommandMetadata[string] commands() pure nothrow @property const;

    // channelSpecificCommands
    /++
        Returns an array of the descriptions of the channel-specific commands a
        plugin offers.

        Returns:
            An associative [CommandMetadata] array keyed by string.
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
        @Settings MyPluginSettings myPluginSettings;

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
    private import kameloso.plugins.common.core : FilterResult, IRCPluginState, Permissions;
    private import dialect.defs : IRCEvent, IRCServer, IRCUser;
    private import core.thread : Fiber;

    /// Symbol needed for the mixin constraints to work.
    // https://forum.dlang.org/post/sk4hqm$12cf$1@digitalmars.com
    alias mixinParent = __traits(parent, {});

    // Use a custom constraint to force the scope to be an IRCPlugin
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

    static if (__traits(compiles, { alias _ = this.hasIRCPluginImpl; }))
    {
        import std.format : format;
        enum pattern = "Double mixin of `%s` in `%s`";
        static assert(0, pattern.format("IRCPluginImpl", typeof(this).stringof));
    }
    else
    {
        private enum hasIRCPluginImpl = true;
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
        bool retval = true;

        top:
        foreach (immutable i, _; this.tupleof)
        {
            import std.traits : hasUDA;

            static if (
                is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                    hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                foreach (immutable n, _2; this.tupleof[i].tupleof)
                {
                    static if (hasUDA!(this.tupleof[i].tupleof[n], Enabler))
                    {
                        alias ThisEnabler = typeof(this.tupleof[i].tupleof[n]);

                        static if (!is(ThisEnabler : bool))
                        {
                            import std.format : format;
                            import std.traits : Unqual;

                            alias UnqualThis = Unqual!(typeof(this));
                            enum pattern = "`%s` has a non-bool `Enabler`: `%s %s`";

                            static assert(0, pattern.format(UnqualThis.stringof,
                                ThisEnabler.stringof,
                                __traits(identifier, this.tupleof[i].tupleof[n])));
                        }

                        retval = this.tupleof[i].tupleof[n];
                        break top;
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
        [kameloso.plugins.common.core.IRCPluginImpl.allowImpl|IRCPluginImpl.allowImpl].
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
    private FilterResult allow(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        return allowImpl(event, permissionsRequired);
    }

    // allowImpl
    /++
        Judges whether an event may be triggered, based on the event itself and
        the annotated [kameloso.plugins.common.core.Permissions|Permissions] of the
        handler in question. Implementation function.

        Params:
            event = [dialect.defs.IRCEvent|IRCEvent] to allow, or not.
            permissionsRequired = Required [kameloso.plugins.common.core.Permissions|Permissions]
                of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.

        See_Also:
            [kameloso.plugins.common.core.filterSender|filterSender]
     +/
    private FilterResult allowImpl(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        import kameloso.plugins.common.core : filterSender;

        version(TwitchSupport)
        {
            if (state.server.daemon == IRCServer.Daemon.twitch)
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
        return (permissionsRequired == Permissions.ignore) ? FilterResult.pass :
            filterSender(event, permissionsRequired, state.settings.preferHostmasks);
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
        mixin("static import thisModule = ", module_, ";");

        // udaSanityCheck
        /++
            Verifies that annotations are as expected.
         +/
        static bool udaSanityCheck(alias fun)()
        {
            import kameloso.plugins.common.core : IRCEventHandler;
            import std.traits : fullyQualifiedName, getUDAs;

            alias handlerAnnotations = getUDAs!(fun, IRCEventHandler);

            static if (handlerAnnotations.length > 1)
            {
                import std.format : format;
                enum pattern = "`%s` is annotated with more than one `IRCEventHandler`";
                static assert(0, pattern.format(fullyQualifiedName!fun));
            }

            static immutable uda = handlerAnnotations[0];

            static foreach (immutable type; uda._acceptedEventTypes)
            {{
                static if (type == IRCEvent.Type.UNSET)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                        "`@(IRCEvent.Type.UNSET)`, which is not a valid event type.";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }
                else static if (type == IRCEvent.Type.PRIVMSG)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                        "`@(IRCEvent.Type.PRIVMSG)`, which is not a valid event type. " ~
                        "Use `IRCEvent.Type.CHAN` and/or `IRCEvent.Type.QUERY` instead";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }
                else static if (type == IRCEvent.Type.WHISPER)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                        "`@(IRCEvent.Type.WHISPER)`, which is not a valid event type. " ~
                        "Use `IRCEvent.Type.QUERY` instead";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }

                static if (uda._commands.length || uda._regexes.length)
                {
                    static if (
                        (type != IRCEvent.Type.CHAN) &&
                        (type != IRCEvent.Type.QUERY) &&
                        (type != IRCEvent.Type.SELFCHAN) &&
                        (type != IRCEvent.Type.SELFQUERY))
                    {
                        import lu.conv : Enum;
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Command` and/or `Regex`, but is at the " ~
                            "same time accepting non-message `IRCEvent.Type.%s events`";
                        static assert(0, pattern.format(fullyQualifiedName!fun,
                            Enum!(IRCEvent.Type).toString(type)));
                    }
                }
            }}

            static if (uda._commands.length)
            {
                import lu.string : contains;

                static foreach (immutable command; uda._commands)
                {
                    static if (!command._word.length)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Command` with an empty trigger word";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (command._word.contains(' '))
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Command` whose trigger " ~
                            `word "%s" contains a space character`;
                        static assert(0, pattern.format(fullyQualifiedName!fun, command._word));
                    }
                }
            }

            static if (uda._regexes.length)
            {
                static foreach (immutable regex; uda._regexes)
                {
                    import lu.string : contains;

                    static if (!regex._expression.length)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Regex` with an empty expression";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (
                        (regex._policy != PrefixPolicy.direct) &&
                        regex._expression.contains(' '))
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a non-`PrefixPolicy.direct`-annotated " ~
                            "`Regex` with an expression containing spaces";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                }
            }

            static if ((uda._permissionsRequired != Permissions.ignore) &&
                !__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
            {
                import std.format : format;

                enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                    "mixin (needed for `Permissions` checks)";
                static assert(0, pattern.format(module_));
            }

            return true;
        }

        // call
        /++
            Calls the passed function pointer, appropriately.
         +/
        void call(bool inFiber, Fun)(scope Fun fun, ref IRCEvent event) scope
        {
            import lu.traits : TakesParams;
            import std.traits : ParameterStorageClass, Parameters, arity;

            static if (inFiber)
            {
                /++
                    Statically asserts that a parameter storage class is not `ref`.

                    Take the storage class as a template parameter and statically
                    assert inside this function, unlike how `udaSanityCheck` returns
                    false on failure, so we can format and print the error message
                    once here (instead of at all call sites upon receiving false).
                 +/
                static void assertNotRef(ParameterStorageClass storageClass)()
                {
                    static if (storageClass & ParameterStorageClass.ref_)
                    {
                        import std.format : format;

                        enum pattern = "`%s` has a `%s` event handler annotated `.fiber(true)` " ~
                            "that takes an `IRCEvent` by `ref`, which is prone to memory corruption";
                        static assert(0, pattern.format(module_, Fun.stringof));
                    }
                }
            }

            static if (!inFiber)
            {
                /++
                    Statically asserts that a parameter storage class is neither `out` nor `ref`.

                    See `assertNotRef` above.
                 +/
                static void assertNotRefNorOut(ParameterStorageClass storageClass)()
                {
                    static if (
                        (storageClass & ParameterStorageClass.ref_) ||
                        (storageClass & ParameterStorageClass.out_))
                    {
                        import std.format : format;

                        enum pattern = "`%s` has a `%s` event handler that takes an " ~
                            "`IRCEvent` of an unsupported storage class; " ~
                            "may not be mutable `ref` or `out`";
                        static assert(0, pattern.format(module_, Fun.stringof));
                    }
                }
            }

            static if (
                TakesParams!(fun, typeof(this), IRCEvent) ||
                TakesParams!(fun, IRCPlugin, IRCEvent))
            {
                static if (inFiber)
                {
                    import std.traits : ParameterStorageClassTuple;
                    assertNotRef!(ParameterStorageClassTuple!fun[1]);
                }
                else
                {
                    static if (!is(Parameters!fun[1] == const))
                    {
                        import std.traits : ParameterStorageClassTuple;
                        assertNotRefNorOut!(ParameterStorageClassTuple!fun[1]);
                    }
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
                static if (inFiber)
                {
                    import std.traits : ParameterStorageClassTuple;
                    assertNotRef!(ParameterStorageClassTuple!fun[0]);
                }
                else
                {
                    static if (!is(Parameters!fun[0] == const))
                    {
                        import std.traits : ParameterStorageClassTuple;
                        assertNotRefNorOut!(ParameterStorageClassTuple!fun[0]);
                    }
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
                static assert(0, pattern.format(module_, Fun.stringof));
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

        // process
        /++
            Process a function.
         +/
        NextStep process(bool verbose, bool inFiber, Fun)
            (scope Fun fun,
            const string funName,
            const IRCEventHandler uda,
            ref IRCEvent event,
            const bool acceptsAnyType) scope
        {
            import std.algorithm.searching : canFind;

            static if (verbose)
            {
                import lu.conv : Enum;
                import std.stdio : stdout, writeln, writefln;
            }

            if (!acceptsAnyType)
            {
                if (!uda._acceptedEventTypes.canFind(event.type)) return NextStep.continue_;
            }

            static if (verbose)
            {
                writeln("-- ", funName, " @ ", Enum!(IRCEvent.Type).toString(event.type));
                writeln("   ...", Enum!ChannelPolicy.toString(uda._channelPolicy));
                if (state.settings.flush) stdout.flush();
            }

            if (event.channel.length)
            {
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

            // Snapshot content and aux for later restoration
            immutable origContent = event.content;
            immutable origAux = event.aux;

            scope(exit)
            {
                // Restore content and aux as they may have been altered
                event.content = origContent;
                event.aux = origAux;
            }

            if (uda._commands.length || uda._regexes.length)
            {
                import lu.string : strippedLeft;

                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    // Event has a Command or a Regex set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }
            }

            /// Whether or not a Command or Regex matched.
            bool commandMatch;

            // Evaluate each Command UDAs with the current event
            if (uda._commands.length)
            {
                commandForeach:
                foreach (const command; uda._commands)
                {
                    static if (verbose)
                    {
                        writefln(`   ...Command "%s"`, command._word);
                        if (state.settings.flush) stdout.flush();
                    }

                    if (!event.prefixPolicyMatches!verbose
                        (command._policy, state.client, state.settings.prefix))
                    {
                        static if (verbose)
                        {
                            writeln("   ...policy doesn't match; continue next Command");
                            if (state.settings.flush) stdout.flush();
                        }

                        // Do nothing, proceed to next command
                        continue commandForeach;
                    }
                    else
                    {
                        import lu.string : nom;
                        import std.typecons : No, Yes;
                        import std.uni : toLower;

                        immutable thisCommand = event.content
                            .nom!(Yes.inherit, Yes.decode)(' ');

                        if (thisCommand.toLower == command._word.toLower)
                        {
                            static if (verbose)
                            {
                                writeln("   ...command matches!");
                                if (state.settings.flush) stdout.flush();
                            }

                            event.aux = thisCommand;
                            commandMatch = true;
                            break commandForeach;
                        }
                        else
                        {
                            // Restore content to pre-nom state
                            event.content = origContent;
                        }
                    }
                }
            }

            // Iff no match from Commands, evaluate Regexes
            if (uda._regexes.length && !commandMatch)
            {
                regexForeach:
                foreach (const regex; uda._regexes)
                {
                    static if (verbose)
                    {
                        writeln("   ...Regex: `", regex._expression, "`");
                        if (state.settings.flush) stdout.flush();
                    }

                    if (!event.prefixPolicyMatches!verbose
                        (regex._policy, state.client, state.settings.prefix))
                    {
                        static if (verbose)
                        {
                            writeln("   ...policy doesn't match; continue next Regex");
                            if (state.settings.flush) stdout.flush();
                        }

                        // Do nothing, proceed to next regex
                        continue regexForeach;
                    }
                    else
                    {
                        try
                        {
                            import std.regex : matchFirst;

                            const hits = event.content.matchFirst(regex._engine);

                            if (!hits.empty)
                            {
                                static if (verbose)
                                {
                                    writeln("   ...expression matches!");
                                    if (state.settings.flush) stdout.flush();
                                }

                                event.aux = hits[0];
                                commandMatch = true;
                                break regexForeach;
                            }
                            else
                            {
                                static if (verbose)
                                {
                                    writefln(`   ...matching "%s" against expression "%s" failed.`,
                                        event.content, regex._expression);
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

            if (uda._commands.length || uda._regexes.length)
            {
                if (!commandMatch)
                {
                    // {Command,Regex} exist but neither matched; skip
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
                        writefln("   ...%s WHOIS", typeof(this).stringof);
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
                        enqueue(this, event, uda._permissionsRequired, uda._fiber, fun, funName);
                        return uda._chainable ? NextStep.continue_ : NextStep.return_;
                    }
                    else
                    {
                        import std.format : format;
                        enum pattern = "`%s` has an event handler with an unsupported function signature: `%s`";
                        static assert(0, pattern.format(module_, Fun.stringof));
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

        // sanitiseEvent
        /++
            Sanitise event, used upon UTF/Unicode exceptions.
         +/
        static void sanitiseEvent(ref IRCEvent event)
        {
            import std.encoding : sanitize;
            import std.range : only;

            event.raw = sanitize(event.raw);
            event.channel = sanitize(event.channel);
            event.content = sanitize(event.content);
            event.aux = sanitize(event.aux);
            event.tags = sanitize(event.tags);
            event.errors = sanitize(event.errors);
            event.errors ~= event.errors.length ? " | Sanitised" : "Sanitised";

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

        // tryProcess
        /++
            Wrap all the functions in the passed `funlist` in try-catch blocks.
         +/
        void tryProcess(funlist...)(ref IRCEvent event)
        {
            static if (__VERSION__ < 2096L)
            {
                /+
                    Pre-2.096 needs an ugly workaround so as to not allocate an
                    array literal every `tryProcess`. 2.096 and onward can make the
                    UDA a static immutable, but this throws an error on the older
                    compilers; "Declaration uda is already defined in another scope".
                    Making them enums means we get enums of dynamic arrays, and
                    the array literal allocations that entails. We really need
                    them to be static immutable at some level.

                    So compose an array of all UDAs in this funlist, as static
                    immutables, at compile-time. It seems to work.
                 +/
                static immutable ctUDAArray = ()
                {
                    IRCEventHandler[] udas;
                    udas.length = funlist.length;

                    foreach (immutable i, fun; funlist)
                    {
                        udas[i] = getUDAs!(fun, IRCEventHandler)[0];
                    }

                    return udas;
                }();
            }

            foreach (immutable i, fun; funlist)
            {
                import std.algorithm.searching : canFind;
                import std.traits : getUDAs;

                static assert(udaSanityCheck!fun,
                    __traits(identifier, fun) ~ " UDA sanity check failed.");

                static if (__VERSION__ >= 2096L)
                {
                    static immutable uda = getUDAs!(fun, IRCEventHandler)[0];
                }
                else
                {
                    // Can't use static immutables before 2.096
                    // "Declaration uda is already defined in another scope"
                    // See `ctUDAArray` above.
                    immutable uda = ctUDAArray[i];
                }

                enum verbose = (uda._verbose || debug_);
                enum funName = module_ ~ '.' ~ __traits(identifier, fun);

                // Make a special check for IRCEvent.Type.ANY at compile-time,
                // so the processing function won't have to walk the array twice
                enum acceptsAnyType = uda._acceptedEventTypes.canFind(IRCEvent.Type.ANY);

                try
                {
                    immutable next = process!(verbose, cast(bool)uda._fiber)
                        (&fun, funName, uda, event, acceptsAnyType);

                    if (next == NextStep.continue_)
                    {
                        continue;
                    }
                    else if (next == NextStep.repeat)
                    {
                        // only repeat once so we don't endlessly loop
                        if (process!(verbose, cast(bool)uda._fiber)
                            (&fun, funName, uda, event, acceptsAnyType) == NextStep.continue_)
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
                }
                catch (Exception e)
                {
                    /*enum pattern = "tryProcess some exception on <l>%s</>: <l>%s";
                    logger.warningf(pattern, funName, e);*/

                    import std.utf : UTFException;
                    import core.exception : UnicodeException;

                    immutable isRecoverableException =
                        (cast(UnicodeException)e !is null) ||
                        (cast(UTFException)e !is null);

                    if (!isRecoverableException) throw e;

                    sanitiseEvent(event);

                    // Copy-paste, not much we can do otherwise
                    immutable next = process!(verbose, cast(bool)uda._fiber)
                        (&fun, funName, uda, event, acceptsAnyType);

                    if (next == NextStep.continue_)
                    {
                        continue;
                    }
                    else if (next == NextStep.repeat)
                    {
                        // only repeat once so we don't endlessly loop
                        if (process!(verbose, cast(bool)uda._fiber)
                            (&fun, funName, uda, event, acceptsAnyType) == NextStep.continue_)
                        {
                            continue;
                        }
                        else
                        {
                            return;
                        }
                    }
                    else /*if (next == NextStep.return_)*/
                    {
                        return;
                    }
                }
            }
        }

        import kameloso.plugins.common.core : IRCEventHandler;
        import lu.traits : getSymbolsByUDA;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : getUDAs, isSomeFunction;

        enum isSetupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.setup);
        enum isEarlyFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.early);
        enum isLateFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.late);
        enum isCleanupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.cleanup);

        alias hasSpecialTiming = templateOr!(isSetupFun, isEarlyFun,
            isLateFun, isCleanupFun);
        alias isNormalEventHandler = templateNot!hasSpecialTiming;

        alias allFuns = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEventHandler));

        static if (!allFuns.length)
        {
            version(unittest)
            {
                // Skip event handler checks when unittesting, as it triggers
                // unittests in common/core.d
            }
            else
            {
                import std.algorithm.comparison : among;
                import std.meta : AliasSeq;

                // Also skip event handler checks for these specific whitelisted modules
                alias emptyModuleWhitelist = AliasSeq!(
                    "kameloso.plugins.twitch.stub",
                );

                static if (module_.among!emptyModuleWhitelist)
                {
                    // Known to be empty
                }
                else
                {
                    import kameloso.plugins.common.core : PluginModuleInfo;

                    alias PluginModule = PluginModuleInfo!module_;

                    static if (PluginModule.hasPluginClass)
                    {
                        enum message = "Warning: `IRCPlugin` subclass `" ~ PluginModule.className ~
                            "` in module `" ~ module_ ~ "` mixes in `IRCPluginImpl`, but there " ~
                            "seem to be no module-level event handlers. " ~
                            "Verify `IRCEventHandler` annotations";
                        pragma(msg, message);
                    }
                }
            }
        }

        alias setupFuns = Filter!(isSetupFun, allFuns);
        alias earlyFuns = Filter!(isEarlyFun, allFuns);
        alias lateFuns = Filter!(isLateFun, allFuns);
        alias cleanupFuns = Filter!(isCleanupFun, allFuns);
        alias pluginFuns = Filter!(isNormalEventHandler, allFuns);

        tryProcess!setupFuns(origEvent);
        tryProcess!earlyFuns(origEvent);
        tryProcess!pluginFuns(origEvent);
        tryProcess!lateFuns(origEvent);
        tryProcess!cleanupFuns(origEvent);
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
        import std.traits : hasUDA;

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
                import std.path : buildNormalizedPath;

                static if (hasUDA!(this.tupleof[i], Resource))
                {
                    member = buildNormalizedPath(state.settings.resourceDirectory, member);
                }
                else static if (hasUDA!(this.tupleof[i], Configuration))
                {
                    member = buildNormalizedPath(state.settings.configDirectory, member);
                }
            }
        }

        static if (__traits(compiles, { alias _ = .initialise; }))
        {
            import lu.traits : TakesParams;

            static if (TakesParams!(.initialise, typeof(this)))
            {
                .initialise(this);
            }
            else
            {
                import std.format : format;
                enum pattern = "`%s.initialise` has an unsupported function signature: `%s`";
                static assert(0, pattern.format(module_, typeof(.initialise).stringof));
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

            static if (TakesParams!(.postprocess, typeof(this), IRCEvent))
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
                    static assert(0, pattern.format(module_,));
                }
            }
            else
            {
                import std.format : format;
                enum pattern = "`%s.postprocess` has an unsupported function signature: `%s`";
                static assert(0, pattern.format(module_, typeof(.postprocess).stringof));
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

            static if (TakesParams!(.initResources, typeof(this)))
            {
                .initResources(this);
            }
            else
            {
                import std.format : format;
                enum pattern = "`%s.initResources` has an unsupported function signature: `%s`";
                static assert(0, pattern.format(module_, typeof(.initResources).stringof));
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
        import kameloso.config : readConfigInto;
        import lu.meld : meldInto;
        import std.traits : hasUDA;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (
                is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                    hasUDA!(typeof(this.tupleof[i]), Settings)))
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
        import lu.objmanip : setMemberByName;
        import std.traits : hasUDA;

        bool success;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (
                is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                    hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                success = symbol.setMemberByName(setting, value);
                break;
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
        import std.traits : hasUDA;

        foreach (immutable i, const ref symbol; this.tupleof)
        {
            static if (
                is(typeof(this.tupleof[i]) == struct) &&
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
        import std.traits : hasUDA;

        bool didSomething;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (
                is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                    hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                import lu.serialisation : serialise;

                sink.serialise(symbol);
                didSomething = true;
                break;
            }
        }

        return didSomething;
    }

    private import std.meta : AliasSeq;

    // setup, start, teardown, reload
    /+
        Generates functions `setup`, `start`, `reload` and `teardown`. These
        merely pass on calls to module-level `.setup`, `.start`, `.reload` and
        `.teardown`, where such is available.

        `setup` runs early pre-connect routines.

        `start` runs early post-connect routines, immediately after connection
        has been established.

        `reload` Reloads the plugin, where such makes sense. What this means is
        implementation-defined.

        `teardown` de-initialises the plugin.
     +/
    static foreach (immutable funName; AliasSeq!("setup", "start", "reload", "teardown"))
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

                static if (TakesParams!(.` ~ funName ~ `, typeof(this)))
                {
                    .` ~ funName ~ `(this);
                }
                else
                {
                    import std.format : format;
                    ` ~ "enum pattern = \"`%s.%s` has an unsupported function signature: `%s`\";
                    " ~ `static assert(0, pattern.format(module_, "` ~ funName ~ `", typeof(.` ~ funName ~ `).stringof));
                }
            }
        }`);
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

        static if (module_.beginsWith("kameloso.plugins."))
        {
            import std.string : indexOf;

            string slice = module_[17..$];  // mutable
            immutable dotPos = slice.indexOf('.');
            if (dotPos == -1) return slice;
            return (slice[dotPos+1..$] == "base") ? slice[0..dotPos] : slice[dotPos+1..$];
        }
        else
        {
            import std.format : format;

            enum pattern = "Plugin module `%s` is not under `kameloso.plugins`";
            static assert(0, pattern.format(module_));
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
        Collects all [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command]
        command words and [kameloso.plugins.common.core.IRCEventHandler.Regex|IRCEventHandler.Regex]
        regex expressions that this plugin offers at compile time, then at runtime
        returns them alongside their descriptions and their visibility, as an associative
        array of [kameloso.plugins.common.core.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s
        keyed by command name strings.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.common.core.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.common.core.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.
     +/
    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import kameloso.plugins.common.core : IRCEventHandler;
            import lu.traits : getSymbolsByUDA;
            import std.meta : Filter;
            import std.traits : getUDAs, isSomeFunction;

            mixin("static import thisModule = ", module_, ";");

            alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEventHandler));

            IRCPlugin.CommandMetadata[string] commandAA;

            foreach (fun; funs)
            {
                immutable uda = getUDAs!(fun, IRCEventHandler)[0];

                static foreach (immutable command; uda._commands)
                {{
                    enum key = command._word;
                    commandAA[key] = IRCPlugin.CommandMetadata
                        (command._policy, command._description, command._hidden);

                    static if (command._hidden)
                    {
                        // Just ignore
                    }
                    else static if (command._description.length)
                    {
                        static if (command._policy == PrefixPolicy.nickname)
                        {
                            static if (command._syntaxes.length)
                            {
                                // Prefix the command with the bot's nickname,
                                // as that's how it's actually used.
                                foreach (immutable syntax; command._syntaxes)
                                {
                                    commandAA[key].syntaxes ~= "$bot: " ~ syntax;
                                }
                            }
                            else
                            {
                                // Define an empty nickname: command syntax
                                // to give hint about the nickname prefix
                                commandAA[key].syntaxes ~= "$bot: $command";
                            }
                        }
                        else
                        {
                            static if (command._syntaxes.length)
                            {
                                commandAA[key].syntaxes ~= command._syntaxes.dup;
                            }
                            else
                            {
                                commandAA[key].syntaxes ~= "$command";
                            }
                        }
                    }
                    else /*static if (!command._hidden && !command._description.length)*/
                    {
                        import std.format : format;
                        import std.traits : fullyQualifiedName;
                        enum pattern = "Warning: `%s` non-hidden command word \"%s\" is missing a description";
                        pragma(msg, pattern.format(fullyQualifiedName!fun, command._word));
                    }
                }}

                static foreach (immutable regex; uda._regexes)
                {{
                    enum key = `r"` ~ regex._expression ~ `"`;
                        commandAA[key] = IRCPlugin.CommandMetadata
                            (regex._policy, regex._description, regex._hidden);

                    static if (regex._description.length)
                    {
                        static if (regex._policy == PrefixPolicy.direct)
                        {
                            commandAA[key].syntaxes ~= regex._expression;
                        }
                        else static if (regex._policy == PrefixPolicy.prefixed)
                        {
                            commandAA[key].syntaxes ~= "$prefix" ~ regex._expression;
                        }
                        else static if (regex._policy == PrefixPolicy.nickname)
                        {
                            commandAA[key].syntaxes ~= "$nickname: " ~ regex._expression;
                        }
                    }
                    else static if (!regex._hidden)
                    {
                        import std.format : format;
                        import std.traits : fullyQualifiedName;

                        enum pattern = "Warning: `%s` non-hidden expression \"%s\" is missing a description";
                        pragma(msg, pattern.format(fullyQualifiedName!fun, regex._expression));
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

    private import kameloso.thread : Sendable;

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

            static if (TakesParams!(.onBusMessage, typeof(this), string, Sendable))
            {
                .onBusMessage(this, header, content);
            }
            else static if (TakesParams!(.onBusMessage, typeof(this), string))
            {
                .onBusMessage(this, header);
            }
            else
            {
                import std.format : format;
                enum pattern = "`%s.onBusMessage` has an unsupported function signature: `%s`";
                static assert(0, pattern.format(module_, typeof(.onBusMessage).stringof));
            }
        }
    }
}

@system
unittest
{
    @Settings static struct TestSettings
    {
        @Enabler bool enuubled = false;
    }

    static final class TestPlugin : IRCPlugin
    {
        TestSettings testSettings;

        mixin IRCPluginImpl;
    }

    IRCPluginState state;

    TestPlugin p = new TestPlugin(state);
    assert(!p.isEnabled);

    p.testSettings.enuubled = true;
    assert(p.isEnabled);
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
        client = [dialect.defs.IRCClient|IRCClient] of the calling [IRCPlugin]'s [IRCPluginState].
        prefix = The prefix as set in the program-wide settings.

    Returns:
        `true` if the message is in a context where the event matches the
        `policy`, `false` if not.
 +/
auto prefixPolicyMatches(bool verbose = false)
    (ref IRCEvent event,
    const PrefixPolicy policy,
    const IRCClient client,
    const string prefix)
{
    import kameloso.string : stripSeparatedPrefix;
    import lu.string : beginsWith;
    import std.typecons : No, Yes;

    static if (verbose)
    {
        import std.stdio : writefln, writeln;

        writeln("...prefixPolicyMatches! policy:", policy);
    }

    with (PrefixPolicy)
    final switch (policy)
    {
    case direct:
        static if (verbose)
        {
            writefln("direct, so just passes.");
        }
        return true;

    case prefixed:
        if (prefix.length && event.content.beginsWith(prefix))
        {
            static if (verbose)
            {
                writefln("starts with prefix (%s)", prefix);
            }

            event.content = event.content[prefix.length..$];
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

        if (event.content.beginsWith(client.nickname))
        {
            static if (verbose)
            {
                writeln("begins with nickname! stripping it");
            }

            event.content = event.content
                .stripSeparatedPrefix(client.nickname, Yes.demandSeparatingChars);

            if (prefix.length && event.content.beginsWith(prefix))
            {
                static if (verbose)
                {
                    writefln("starts with prefix (%s)", prefix);
                }

                event.content = event.content[prefix.length..$];
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
    import std.algorithm.searching : canFind;

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
    import kameloso.kameloso : ConnectionSettings, CoreSettings, IRCBot;
    import kameloso.thread : ScheduledDelegate, ScheduledFiber;
    import std.concurrency : Tid;
    import core.thread : Fiber;

    /++
        Numeric ID of the current connection, to disambiguate between multiple
        connections in one program run. Private value.
     +/
    uint privateConnectionID;

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
            `IRCPluginState.bot` was marked as updated.
         +/
        bot      = 1 << 0,

        /++
            `IRCPluginState.client` was marked as updated.
         +/
        client   = 1 << 1,

        /++
            `IRCPluginState.server` was marked as updated.
         +/
        server   = 1 << 2,

        /++
            `IRCPluginState.settings` was marked as updated.
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
        The current [kameloso.kameloso.IRCBot|IRCBot], containing information
        pertaining to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    // settings
    /++
        The current program-wide [kameloso.kameloso.CoreSettings|CoreSettings].
     +/
    CoreSettings settings;

    // connSettings
    /++
        The current program-wide [kameloso.kameloso.ConnectionSettings|ConnectionSettings].
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
    auto connectionID()
    {
        return privateConnectionID;
    }

    // this
    /++
        Constructor taking a connection ID `uint`.
     +/
    this(const uint connectionID)
    {
        this.privateConnectionID = connectionID;
    }
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
    this(void delegate(Replay) dg, const ref IRCEvent event,
        const Permissions permissionsRequired, const string caller)
    {
        import std.datetime.systime : Clock;

        timestamp = Clock.currTime.toUnixTime;
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
        [kameloso.kameloso.CoreSettings.prefix|CoreSettings.prefix] (e.g. "!").
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
        [dialect.defs.IRCClient.Class.blacklist|IRCClient.Class.blacklist]
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
        Only users with a [dialect.defs.IRCClient.Class.whitelist|IRCClient.Class.whitelist]
        classifier (or higher) may trigger the annotated function.
     +/
    whitelist = 30,

    /++
        Only users with a [dialect.defs.IRCClient.Class.elevated|IRCClient.Class.elevated]
        classifier (or higher) may trigger the annotated function.
     +/
    elevated = 40,

    /++
        Only users with a [dialect.defs.IRCClient.Class.operator|IRCClient.Class.operator]
        classifier (or higiher) may trigger the annotated function.

        Note: this does not mean IRC "+o" operators.
     +/
    operator = 50,

    /++
        Only users with a [dialect.defs.IRCClient.Class.staff|IRCClient.Class.staff]
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
        Unset.
     +/
    unset,

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
    private import kameloso.traits : UnderscoreOpDispatcher;

    // acceptedEventTypes
    /++
        Array of types of [dialect.defs.IRCEvent] that the annotated event
        handler function should accept.
     +/
    IRCEvent.Type[] _acceptedEventTypes;

    // _onEvent
    /++
        Alias to make [kameloso.traits.UnderscoreOpDispatcher] redirect calls to
        [_acceptedEventTypes] but by the name `onEvent`.
     +/
    alias _onEvent = _acceptedEventTypes;

    // permissionsRequired
    /++
        Permissions required of instigating user, below which the annotated
        event handler function should not be triggered.
     +/
    Permissions _permissionsRequired = Permissions.ignore;

    // channelPolicy
    /++
        What kind of channel the annotated event handler function may be
        triggered in; homes or mere guest channels.
     +/
    ChannelPolicy _channelPolicy = ChannelPolicy.home;

    // commands
    /++
        Array of [IRCEventHandler.Command]s the bot should pick up and listen for.
     +/
    Command[] _commands;

    // _addCommand
    /++
        Alias to make [kameloso.traits.UnderscoreOpDispatcher] redirect calls to
        [_commands] but by the name `addCommand`.
     +/
    alias _addCommand = _commands;

    // regexes
    /++
        Array of [IRCEventHandler.Regex]es the bot should pick up and listen for.
     +/
    Regex[] _regexes;

    // _addRegex
    /++
        Alias to make [kameloso.traits.UnderscoreOpDispatcher] redirect calls to
        [_regexes] but by the name `addRegex`.
     +/
    alias _addRegex = _regexes;

    // chainable
    /++
        Whether or not the annotated event handler function should allow other
        functions to fire after it. If not set (default false), it will
        terminate and move on to the next plugin after the function returns.
     +/
    bool _chainable;

    // verbose
    /++
        Whether or not additional information should be output to the local
        terminal as the function is (or is not) triggered.
     +/
    bool _verbose;

    // when
    /++
        Special instruction related to the order of which event handler functions
        within a plugin module are triggered.
     +/
    Timing _when;

    // fiber
    /++
        Whether or not the annotated event handler should be run from within a
        [core.thread.fiber.Fiber|Fiber].
     +/
    bool _fiber;

    mixin UnderscoreOpDispatcher;

    // Command
    /++
        Embodies the notion of a chat command, e.g. `!hello`.
     +/
    static struct Command
    {
        // policy
        /++
            In what way the message is required to start for the annotated function to trigger.
         +/
        PrefixPolicy _policy = PrefixPolicy.prefixed;

        // word
        /++
            The command word, without spaces.
         +/
        string _word;

        // description
        /++
            Describes the functionality of the event handler function the parent
            [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Command].

            Specifically this is used to describe functions triggered by
            [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
         +/
        string _description;

        // hidden
        /++
            Whether this is a hidden command or if it should show up in help listings.
         +/
        bool _hidden;

        // syntax
        /++
            Command usage syntax help strings.
         +/
        string[] _syntaxes;

        // _addSyntax
        /++
            Alias to make [kameloso.traits.UnderscoreOpDispatcher] redirect calls to
            [_syntaxes] but by the name `addSyntax`.
         +/
        alias _addSyntax = _syntaxes;

        mixin UnderscoreOpDispatcher;
    }

    // Regex
    /++
        Embodies the notion of a chat command regular expression, e.g. `![Hh]ello+`.
     +/
    static struct Regex
    {
        import std.regex : StdRegex = Regex;

        // policy
        /++
            In what way the message is required to start for the annotated function to trigger.
         +/
        PrefixPolicy _policy = PrefixPolicy.direct;

        // engine
        /++
            Regex engine to match incoming messages with.
         +/
        StdRegex!char _engine;

        // expression
        /++
            The regular expression in string form.
         +/
        string _expression;

        // description
        /++
            Describes the functionality of the event handler function the parent
            [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Regex].

            Specifically this is used to describe functions triggered by
            [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
         +/
        string _description;

        // hidden
        /++
            Whether this is a hidden command or if it should show up in help listings.
         +/
        bool _hidden;

        // expression
        /++
            The regular expression this [IRCEventHandler.Regex] embodies, in string form.

            Upon setting this a regex engine is also created. Because of this extra step we
            cannot rely on [kameloso.traits.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
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
        ref auto expression(const string expression)
        {
            import std.regex : regex;

            this._expression = expression;
            this._engine = expression.regex;
            return this;
        }

        mixin UnderscoreOpDispatcher;
    }
}


// PluginModuleInfo
/++
    Introspects a module given a string of its fully qualified name and divines
    the [kameloso.plugins.common.core.IRCPlugin|IRCPlugin] subclass within.

    `.hasPluginClass` will be set to false if there were no plugins in the module,
    and true if there was. In that case, `.Class` will alias to said plugin class,
    and `.className` will become the string of its name.

    Params:
        module_ = String name of a module.
 +/
template PluginModuleInfo(string module_)
{
    static if (__traits(compiles, { mixin("alias thisModule = " ~ module_ ~ ";"); }))
    {
        private:

        import std.meta : ApplyLeft, Filter, NoDuplicates, staticMap;

        mixin("static import thisModule = " ~ module_ ~ ";");

        enum isPlugin(alias T) = is(T : IRCPlugin);
        alias getMember(alias parent, string memberstring) = __traits(getMember, parent, memberstring);
        alias allMembers = staticMap!(ApplyLeft!(getMember, thisModule), __traits(allMembers, thisModule));
        alias allUniqueMembers = NoDuplicates!allMembers;
        alias Plugins = Filter!(isPlugin, allUniqueMembers);

        /+
            Perform some sanity checks.
         +/
        static if (!Plugins.length)
        {
            // It's likely a package or helper module; do nothing but mark as empty
            public enum hasPluginClass = false;
        }
        else static if (Plugins.length > 1)
        {
            import std.format : format;

            enum pattern = "Plugin module `%s` is has more than one `IRCPlugin` subclass: `%s`";
            immutable message = pattern.format(module_, Plugins.stringof);
            static assert(0, message);
        }
        else static if (is(Plugins[0] : IRCPlugin))
        {
            // Benign case, should always be true.
            public alias Class = Plugins[0];
            public enum className = __traits(identifier, Class);
            public enum hasPluginClass = true;
        }
        else
        {
            import std.format : format;

            // Unsure if this ever happens anymore, but may as well keep the error.
            enum pattern = "Unspecific error encountered when performing sanity " ~
                "checks on introspected `IRCPlugin` subclasses in module `%s`";
            immutable message = pattern.format(module_);
            static assert(0, message);
        }
    }
    else
    {
        import std.format : format;

        enum pattern = "Tried to divine the `IRCPlugin` subclass of non-existent module `%s`";
        static assert(0, pattern.format(module_));
    }
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
enum Resource;


// Configuration
/++
    Annotation denoting that a variable is the basename of a configuration
    file or directory.
 +/
enum Configuration;


// Enabler
/++
    Annotation denoting that a variable enables and disables a plugin.
 +/
enum Enabler;

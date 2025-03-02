/++
    Contains the definition of an [IRCPlugin] and its ancillaries, as well as
    mixins to fully implement it.

    Event handlers can then be module-level functions, annotated with
    [dialect.defs.IRCEvent.Type|IRCEvent.Type]s.

    Example:
    ---
    import kameloso.plugins;
    import kameloso.plugins.common.mixins.awareness;

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
    void onFoo(FooPlugin plugin, const IRCEvent event)
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
        [kameloso.plugins.common],
        [kameloso.plugins.common.scheduling],
        [kameloso.plugins.common.mixins],
        [kameloso.plugins.common.mixins.awareness]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins;

debug version = Debug;

private:

import kameloso.pods : CoreSettings;
import kameloso.thread : CarryingFiber;
import dialect.defs;
import std.traits : ParameterStorageClass;
import std.typecons : Flag, No, Yes;
import core.thread.fiber : Fiber;

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
private:
    import kameloso.net : Querier;
    import kameloso.thread : Sendable;
    import std.array : Appender;
    import core.time : Duration;

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

        Params:
            event = The [dialect.defs.IRCEvent|IRCEvent] in flight.

        Returns:
            Boolean of whether messages should be checked.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.postprocess]
     +/
    bool postprocess(ref IRCEvent event) @system;

    // onEvent
    /++
        Called to let the plugin react to a new event, parsed from the server.

        Params:
            event = Parsed [dialect.defs.IRCEvent|IRCEvent] to dispatch to event handlers.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.onEvent]
     +/
    void onEvent(const IRCEvent event) @system;

    // initResources
    /++
        Called when the plugin is requested to initialise its disk resources.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.initResources]
     +/
    void initResources() @system;

    // deserialiseConfigFrom
    /++
        Reads serialised configuration text into the plugin's settings struct.

        Stores an associative array of `string[]`s of missing entries in its
        first `out string[][string]` parameter, and the invalid encountered
        entries in the second.

        Params:
            configFile = String of the configuration file to read.
            missingEntries = Out reference of an associative array of string arrays
                of expected configuration entries that were missing.
            invalidEntries = Out reference of an associative array of string arrays
                of unexpected configuration entries that did not belong.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.deserialiseConfigFrom]
     +/
    void deserialiseConfigFrom(
        const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries) @safe;

    // serialiseConfigInto
    /++
        Called to let the plugin contribute settings when writing the configuration file.

        Params:
            sink = Reference [std.array.Appender|Appender] to fill with plugin-specific settings text.

        Returns:
            Boolean of whether something was added.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.serialiseConfigInto]
     +/
    bool serialiseConfigInto(ref Appender!(char[]) sink) const @safe;

    // setSettingByName
    /++
        Called when we want to change a setting by its string name.

        Params:
            setting = String name of the struct member to set.
            value = String value to set it to (after converting it to the
                correct type).

        Returns:
            `true` if something was serialised into the passed sink; `false` if not.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.setSettingByName]
     +/
    bool setSettingByName(const string setting, const string value) @safe;

    // setup
    /++
        Called at program start but before connection has been established.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.setup]
     +/
    void setup() @system;

    // printSettings
    /++
        Called when we want a plugin to print its [Settings]-annotated struct of settings.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.printSettings]
     +/
    void printSettings() @system const;

    // teardown
    /++
        Called during shutdown of a connection; a plugin's would-be destructor.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.teardown]
     +/
    void teardown() @system;

    // name
    /++
        Returns the name of the plugin.

        Params:
            lowercase = Whether or not to return the name in lowercase.
            fullName = Whether to return the full name, including "Plugin" or "Service".

        Returns:
            The string name of the plugin.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.name]
     +/
    string name(
        const bool lowercase = true,
        const bool fullName = false) const pure @safe nothrow @nogc;

    // commands
    /++
        Returns an array of the descriptions of the commands a plugin offers.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.commands]
     +/
    CommandMetadata[string] commands() const pure @safe nothrow;

    // channelSpecificCommands
    /++
        Returns an array of the descriptions of the channel-specific commands a
        plugin offers.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each soft command active in the passed channel.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.channelSpecificCommands]
     +/
    CommandMetadata[string] channelSpecificCommands(const string channelName) @system;

    // reload
    /++
        Reloads the plugin, where such is applicable.

        Whatever this does is implementation-defined.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.reload]
     +/
    void reload() @system;

    // onBusMessage
    /++
        Called when a bus message arrives from another plugin.

        It is passed to all plugins and it is up to the receiving plugin to
        discard those not meant for it by examining the value of the `header` argument.

        Params:
            header = String header for plugins to examine and decide if the
                message was meant for them.
            content = Wildcard content, to be cast to concrete types if the header matches.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.onBusMessage]
     +/
    void onBusMessage(const string header, /*shared*/ Sendable content) @system;

    // isEnabled
    /++
        Returns whether or not the plugin is enabled in its settings.

        Returns:
            `true` if the plugin is deemed enabled (or cannot be disabled), `false` if not.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.isEnabled]
     +/
    bool isEnabled() const pure @safe nothrow @nogc;

    // tick
    /++
        Called on each iteration of the main loop.

        Params:
            elapsed = Time since last tick.

        Returns:
            `true` to signal the main loop to check for messages; `false` if not.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.tick]
     +/
    bool tick(const Duration elapsed) @system;

    // initialise
    /++
        Called when the plugin is first loaded.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.initialise]
     +/
    void initialise() @system;

    // putUser
    /++
        Inherits a user into the plugin's state.

        Params:
            user = [dialect.defs.IRCUser|IRCUser] to inherit.
            channel = The channel context of the user.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.putUser]
     +/
    void putUser(const IRCUser user, const string channel) @system;

    version(Selftests)
    {
        private import std.typecons : Ternary;

        // selftest
        /++
            Performs self-tests against another bot.

            See_Also:
                [kameloso.plugins.Selftester]
         +/
        Ternary selftest(Selftester) @system;
    }
}


// IRCPluginImpl
/++
    Mixin that fully implements an [kameloso.plugins.IRCPlugin|IRCPlugin].

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
        [kameloso.plugins.IRCPlugin|IRCPlugin]
 +/
mixin template IRCPluginImpl(
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins :
        FilterResult,
        IRCEventHandler,
        IRCPluginState,
        Permissions;
    private import kameloso.thread : Sendable;
    private import dialect.defs : IRCEvent, IRCServer, IRCUser;
    private import std.array : Appender;
    private import std.meta : AliasSeq;
    private import std.traits : getSymbolsByUDA, getUDAs;
    private import core.thread.fiber : Fiber;
    private import core.time : Duration;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.class_, "IRCPluginImpl");

        static if (!is(typeof(this) : IRCPlugin))
        {
            import std.format : format;

            enum wrongThisPattern = "`%s` mixes in `IRCPluginImpl` but is " ~
                "itself not an `IRCPlugin` subclass";
            enum wrongThisMessage = wrongThisPattern.format(typeof(this).stringof);
            static assert(0, wrongThisMessage);
        }
    }

    /++
        Constant denoting that [kameloso.plugins.IRCPluginImpl|IRCPluginImpl]
        has been mixed in.
     +/
    private enum hasIRCPluginImpl = true;

    mixin("private static import thisModule = ", module_, ";");

    // Introspection
    /++
        Namespace for the alias sequences of all event handler functions in this
        module, as well as the one of all [kameloso.plugins.IRCEventHandler|IRCEventHandler]
        annotations in the module.
     +/
    static struct Introspection
    {
        /++
            Alias sequence of all top-level symbols annotated with
            [kameloso.plugins.IRCEventHandler|IRCEventHandler]s
            in this module.
         +/
        alias allEventHandlerFunctionsInModule = getSymbolsByUDA!(thisModule, IRCEventHandler);

        /++
            Alias sequence of all
            [kameloso.plugins.IRCEventHandler|IRCEventHandler]s
            that are annotations of the symbols in [allEventHandlerFunctionsInModule].
         +/
        static immutable allEventHandlerUDAsInModule = ()
        {
            IRCEventHandler[] udas;
            udas.length = allEventHandlerFunctionsInModule.length;

            foreach (immutable i, fun; allEventHandlerFunctionsInModule)
            {
                udas[i] = getUDAs!(fun, IRCEventHandler)[0];
                udas[i].fqn = module_ ~ '.' ~ __traits(identifier, allEventHandlerFunctionsInModule[i]);
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
        [kameloso.plugins.Settings|Settings]-annotated struct
        member that has a bool annotated with [kameloso.plugins.Enabler|Enabler],
        which denotes it as the bool that toggles a plugin on and off.

        It then returns its value.

        Returns:
            `true` if the plugin is deemed enabled (or cannot be disabled),
            `false` if not.
     +/
    override public bool isEnabled() const pure nothrow @nogc
    {
        import lu.traits : udaIndexOf;

        bool retval = true;

        top:
        foreach (immutable i, ref _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                enum typeUDAIndex = udaIndexOf!(typeof(this.tupleof[i]), Settings);
                enum valueUDAIndex = udaIndexOf!(this.tupleof[i], Settings);

                static if ((typeUDAIndex != -1) || (valueUDAIndex != -1))
                {
                    foreach (immutable n, __; this.tupleof[i].tupleof)
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
        the annotated required [kameloso.plugins.Permissions|Permissions] of the
        handler in question. Wrapper function that merely calls
        [kameloso.plugins.allowImpl].
        The point behind it is to make something that can be overridden and still
        allow it to call the original logic (below).

        Params:
            event = [dialect.defs.IRCEvent|IRCEvent] to allow, or not.
            permissionsRequired = Required [kameloso.plugins.Permissions|Permissions]
                of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.
     +/
    pragma(inline, true)
    private FilterResult allow(const IRCEvent event, const Permissions permissionsRequired) @system
    {
        import kameloso.plugins : allowImpl;
        return allowImpl!(cast(bool)debug_)(this, event, permissionsRequired);
    }

    // onEvent
    /++
        Forwards the supplied [dialect.defs.IRCEvent|IRCEvent] to
        [kameloso.plugins.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl].

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging
        [kameloso.plugins.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl]
        for the actual dirty work.

        Params:
            event = Parsed [dialect.defs.IRCEvent|IRCEvent] to pass onto
                [kameloso.plugins.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl].

        See_Also:
            [kameloso.plugins.IRCPluginImpl.onEventImpl|IRCPluginImpl.onEventImpl]
     +/
    pragma(inline, true)
    override public void onEvent(const IRCEvent event) @system
    {
        onEventImpl(event);
    }

    // onEventImpl
    /++
        Pass on the supplied [dialect.defs.IRCEvent|IRCEvent] to module-level functions
        annotated with an [kameloso.plugins.IRCEventHandler|IRCEventHandler],
        registered with the matching [dialect.defs.IRCEvent.Type|IRCEvent.Type]s.

        It also does checks for
        [kameloso.plugins.ChannelPolicy|ChannelPolicy],
        [kameloso.plugins.Permissions|Permissions],
        [kameloso.plugins.PrefixPolicy|PrefixPolicy],
        [kameloso.plugins.IRCEventHandler.Command|IRCEventHandler.Command],
        [kameloso.plugins.IRCEventHandler.Regex|IRCEventHandler.Regex],
        `chainable` settings etc; where such is applicable.

        This function is private, but since it's part of a mixin template it will
        be visible at the mixin site. Plugins can as such override
        [kameloso.plugins.IRCPlugin.onEvent|IRCPlugin.onEvent] with
        their own code and invoke [onEventImpl] as a fallback.

        Params:
            origEvent = Parsed [dialect.defs.IRCEvent|IRCEvent] to dispatch to
                event handlers, taken by value so we have an object we can modify.

        See_Also:
            [kameloso.plugins.IRCPluginImpl.onEvent|IRCPluginImpl.onEvent]
     +/
    private void onEventImpl(/*const*/ IRCEvent origEvent) @system
    {
        import kameloso.plugins : Timing;
        import std.algorithm.searching : canFind;

        // call
        /++
            Calls the passed function pointer, appropriately.
         +/
        void call(bool inFiber, Fun)(scope Fun fun, const IRCEvent event) scope
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

        /+
            Cached values for use in the `process` function.
         +/
        string commandWordInEvent;
        string commandWordInEventLower;
        string contentSansCommandWordInEvent;

        immutable channelIsAHomeChannel = state.bot.homeChannels.canFind(origEvent.channel.name);
        immutable channelIsAGuestChannel = !channelIsAHomeChannel ?
            state.bot.guestChannels.canFind(origEvent.channel.name) :
            false;

        version(TwitchSupport)
        {
            immutable eventHasDistinctSubchannel =
                (origEvent.channel.id && origEvent.subchannel.id &&
                (origEvent.channel.id != origEvent.subchannel.id)) ||
                (origEvent.channel.name.length && origEvent.subchannel.name.length &&
                (origEvent.channel.name != origEvent.subchannel.name));
        }
        else
        {
            immutable eventHasDistinctSubchannel =
                (origEvent.channel.name.length && origEvent.subchannel.name.length &&
                (origEvent.channel.name != origEvent.subchannel.name));
        }

        // process
        /++
            Process a function.
         +/
        auto process(bool verbose, bool inFiber, bool hasRegexes, Fun)
            (scope Fun fun,
            const IRCEventHandler uda,
            ref IRCEvent event) scope
        {
            static if (verbose)
            {
                import lu.conv : toString;
                import std.stdio : stdout, writeln, writefln;

                writeln("-- ", uda.fqn, " @ ", event.type.toString);
                writeln("    ...channelPolicy (", cast(uint)uda._channelPolicy, ')',
                    " home:",  cast(bool)(uda._channelPolicy & ChannelPolicy.home),
                    " guest:", cast(bool)(uda._channelPolicy & ChannelPolicy.guest),
                    " any:",   cast(bool)(uda._channelPolicy & ChannelPolicy.any));
                if (state.coreSettings.flush) stdout.flush();
            }

            if (event.channel.name.length)
            {
                immutable channelMatch =
                    (uda._channelPolicy & ChannelPolicy.home)  ? channelIsAHomeChannel :
                    (uda._channelPolicy & ChannelPolicy.guest) ? channelIsAGuestChannel :
                    (uda._channelPolicy & ChannelPolicy.any)   ? true :
                    false;  // invalid values

                if (!channelMatch)
                {
                    static if (verbose)
                    {
                        writeln("    ...ignore non-matching channel ", event.channel.name);
                        if (state.coreSettings.flush) stdout.flush();
                    }

                    // channel policy does not match
                    return NextStep.continue_;  // next fun
                }
            }

            if (!eventHasDistinctSubchannel)
            {
                // Ok
            }
            else if (uda._acceptExternal)
            {
                // Also ok
            }
            else if ((uda.commands.length || hasRegexes) &&
                this.state.coreSettings.acceptCommandsFromSubchannels)
            {
                // Also ok
            }
            else
            {
                // By process of elimination; not ok
                static if (verbose)
                {
                    writeln("    ...ignore event originating from subchannel ",
                        event.subchannel.name, ':', event.subchannel.id);
                    if (state.coreSettings.flush) stdout.flush();
                }

                return NextStep.continue_;  // next fun
            }

            immutable origContent = event.content;
            const origAux = event.aux;  // copy
            bool auxDirty;

            scope(exit)
            {
                // Restore aux if it has been altered
                // Unconditionally restore content
                event.content = origContent;
                if (auxDirty) event.aux = origAux;  // copy back
            }

            if (uda.commands.length || hasRegexes)
            {
                import lu.string : strippedLeft;

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
                            enum pattern = `    ...Command "%s"`;
                            writefln(pattern, command._word);
                            if (state.coreSettings.flush) stdout.flush();
                        }

                        // The call to .prefixPolicyMatches modifies event.content
                        if (!event.prefixPolicyMatches!verbose(command._policy, state))
                        {
                            static if (verbose)
                            {
                                writeln("    ...policy doesn't match; continue next Command");
                                if (state.coreSettings.flush) stdout.flush();
                            }

                            // Do nothing, proceed to next command but restore content first
                            event.content = preLoopContent;
                            continue commandForeach;
                        }

                        if (!commandWordInEvent.length)
                        {
                            import lu.string : advancePast;
                            import std.typecons : No, Yes;
                            import std.uni : toLower;

                            // Cache it
                            commandWordInEvent = event.content.advancePast(' ', inherit: true);
                            commandWordInEventLower = commandWordInEvent.toLower();
                            contentSansCommandWordInEvent = event.content;
                        }

                        if (commandWordInEventLower == command._word/*.toLower()*/)
                        {
                            static if (verbose)
                            {
                                writeln("    ...command word matches!");
                                if (state.coreSettings.flush) stdout.flush();
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
                                enum pattern = `    ...Regex r"%s"`;
                                writefln(pattern, regex._expression);
                                if (state.coreSettings.flush) stdout.flush();
                            }

                            if (!event.prefixPolicyMatches!verbose(regex._policy, state))
                            {
                                static if (verbose)
                                {
                                    writeln("    ...policy doesn't match; continue next Regex");
                                    if (state.coreSettings.flush) stdout.flush();
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
                                        writeln("    ...expression matches!");
                                        if (state.coreSettings.flush) stdout.flush();
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
                                        enum matchPattern = `    ...matching "%s" against expression "%s" failed.`;
                                        writefln(matchPattern, event.content, regex._expression);
                                        if (state.coreSettings.flush) stdout.flush();
                                    }
                                }
                            }
                            catch (Exception e)
                            {
                                static if (verbose)
                                {
                                    writeln("    ...Regex exception: ", e.msg);
                                    version(PrintStacktraces) writeln(e);
                                    if (state.coreSettings.flush) stdout.flush();
                                }
                            }
                        }
                    }
                }

                if (commandMatch)
                {
                    if (state.coreSettings.observerMode)
                    {
                        static if (verbose)
                        {
                            writeln("    ...observer mode; skip");
                            if (state.coreSettings.flush) stdout.flush();
                        }

                        return NextStep.continue_;  // next function
                    }

                    // Drop down and continue
                }
                else /*if (!commandMatch)*/
                {
                    // {Command,Regex} exist implicitly but neither matched; skip
                    static if (verbose)
                    {
                        writeln("    ...no Command nor Regex match; continue funloop");
                        if (state.coreSettings.flush) stdout.flush();
                    }

                    return NextStep.continue_; // next function
                }
            }

            if (uda._permissionsRequired != Permissions.ignore)
            {
                static if (verbose)
                {
                    writeln("    ...requires Permissions.",
                        uda._permissionsRequired.toString);
                    if (state.coreSettings.flush) stdout.flush();
                }

                immutable result = this.allow(event, uda._permissionsRequired);

                static if (verbose)
                {
                    writeln("    ...allow result is ", result.toString);
                    if (state.coreSettings.flush) stdout.flush();
                }

                if (result == FilterResult.pass)
                {
                    // Drop down
                }
                else if (result == FilterResult.whois)
                {
                    import kameloso.plugins : enqueue;
                    import lu.traits : TakesParams;
                    import std.traits : arity;

                    static if (verbose)
                    {
                        enum pattern = "    ...%s WHOIS";
                        writefln(pattern, typeof(this).stringof);
                        if (state.coreSettings.flush) stdout.flush();
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
                        enqueue(this, event, uda._permissionsRequired, uda._fiber, fun, uda.fqn);
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
                writeln("    ...calling!");
                if (state.coreSettings.flush) stdout.flush();
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
                import kameloso.thread : carryingFiber;
                import core.thread.fiber : Fiber;

                void fiberDg()
                {
                    call!(inFiber, SystemFun)(fun, event);
                }

                scope scopeFiberDg = &fiberDg;

                auto fiber = carryingFiber(
                    scopeFiberDg,
                    event,
                    BufferSize.fiberStack);
                fiber.creator = uda.fqn;
                fiber.call(uda.fqn);

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
            enum verbose = (uda._verbose || debug_);

            version(unittest)
            {
                /++
                    Verify that MinimalAuthentication is mixed in if it needs to be.
                    Most of other verification is done in udaSanityCheckCTFE, invoked elsewhere.
                 +/
                static if (
                    (uda._permissionsRequired != Permissions.ignore) &&
                    !__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
                {
                    import std.format : format;

                    enum pattern = "`%s` is missing a module-level `MinimalAuthentication` " ~
                        "mixin, needed for `Permissions` checks on behalf of `.%s`";
                    enum message = pattern.format(module_, __traits(identifier, fun));
                    static assert(0, message);
                }
            }

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
                import kameloso.plugins : sanitiseEvent;
                import std.utf : UTFException;
                import core.exception : UnicodeException;

                /*enum pattern = "tryProcess some exception on <l>%s</>: <l>%s";
                logger.warningf(pattern, uda.fqn, e);*/

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
                // Skip event handler checks when unit-testing, as it triggers
                // unit tests in common/core.d
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
            import std.exception : assumeUnique;

            assert(__ctfe, "funIndexByTiming called outside CTFE");

            size_t[] indexes;
            indexes.length = this.Introspection.allEventHandlerUDAsInModule.length;
            size_t n;

            foreach (immutable i; 0..this.Introspection.allEventHandlerUDAsInModule.length)
            {
                if (this.Introspection.allEventHandlerUDAsInModule[i]._when == timing) indexes[n++] = i;
            }

            return indexes[0..n].assumeUnique();
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
                enum message = pattern.format(module_);
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
                enum message = pattern.format(module_);
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
                enum message = pattern.format(module_);
                static assert(0, message);
            }
        }

        alias allFunIndexes = AliasSeq!
            (setupFunIndexes,
            earlyFunIndexes,
            normalFunIndexes,
            lateFunIndexes,
            cleanupFunIndexes);

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
        this.state.deferredActions = typeof(state.deferredActions).init;
        this.state.messages = typeof(state.messages).init;
        this.state.priorityMessages = typeof(state.priorityMessages).init;
        this.state.outgoingMessages = typeof(state.outgoingMessages).init;
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
        this.state.updates = IRCPluginState.Update.nothing;

        /+
            Guesstimates. There will never be many deferred actions, but on
            Twitch there will be a *lot* of putUser messages. Outgoing and
            priority are harder to predict, but 16 "should be enough for everyone".
         +/
        this.state.deferredActions.reserve(2);
        this.state.messages.reserve(32);
        this.state.priorityMessages.reserve(16);
        this.state.outgoingMessages.reserve(16);

        foreach (immutable i, ref _; this.tupleof)
        {
            static if (isSerialisable!(this.tupleof[i]))
            {
                import lu.traits : udaIndexOf;

                enum resourceUDAIndex = udaIndexOf!(this.tupleof[i], Resource);
                static if (resourceUDAIndex != -1)
                {
                    import std.path : buildNormalizedPath;

                    alias attrs = __traits(getAttributes, this.tupleof[i]);
                    static if (is(typeof(attrs[resourceUDAIndex])))
                    {
                        // Instance of Resource, e.g. @Resource("subdir") annotation
                        this.tupleof[i] = buildNormalizedPath(
                            state.coreSettings.resourceDirectory,
                            attrs[resourceUDAIndex].subdirectory,
                            this.tupleof[i]);
                    }
                    else
                    {
                        // Resource as a type, e.g. @Resource annotation
                        this.tupleof[i] = buildNormalizedPath(
                            state.coreSettings.resourceDirectory,
                            this.tupleof[i]);
                    }
                }
                else
                {
                    enum configurationUDAIndex = udaIndexOf!(this.tupleof[i], Configuration);
                    static if (configurationUDAIndex != -1)
                    {
                        import std.path : buildNormalizedPath;

                        alias attrs = __traits(getAttributes, this.tupleof[i]);
                        static if (is(typeof(attrs[configurationUDAIndex])))
                        {
                            // Instance of Configuration, e.g. @Configuration("subdir") annotation
                            this.tupleof[i] = buildNormalizedPath(
                                state.coreSettings.configDirectory,
                                attrs[configurationUDAIndex].subdirectory,
                                this.tupleof[i]);
                        }
                        else
                        {
                            // Configuration as a type, e.g. @Configuration annotation
                            this.tupleof[i] = buildNormalizedPath(
                                state.coreSettings.configDirectory,
                                this.tupleof[i]);
                        }
                    }
                }
            }
        }
    }

    // postprocess
    /++
        Lets a plugin modify an [dialect.defs.IRCEvent|IRCEvent] while it's begin
        constructed, before it's finalised and passed on to be handled.

        Params:
            event = The [dialect.defs.IRCEvent|IRCEvent] in flight.

        Returns:
            Boolean of whether messages should be checked.
     +/
    override public bool postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, { alias _ = .postprocess; }))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return true;

            static if (
                is(typeof(.postprocess)) &&
                is(typeof(.postprocess) == function) &&
                TakesParams!(.postprocess, typeof(this), IRCEvent))
            {
                import std.traits : ParameterStorageClass, ParameterStorageClassTuple, ReturnType;

                alias SC = ParameterStorageClass;
                alias paramClasses = ParameterStorageClassTuple!(.postprocess);

                static if (!is(ReturnType!(.postprocess) == bool))
                {
                    import std.format : format;

                    enum pattern = "`%s.postprocess` returns `%s` and not `bool`";
                    enum message = pattern.format(module_, ReturnType!(.postprocess).stringof);
                    static assert(0, message);
                }

                static if (paramClasses[1] & SC.ref_)
                {
                    return .postprocess(this, event);
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
                import lu.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.postprocess` was unexpectedly a `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.postprocess));
                static assert(0, message);
            }
        }
        else
        {
            return false;
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
            import core.memory : GC;

            if (!this.isEnabled) return;

            GC.disable();
            scope(exit) GC.enable();

            static if (
                is(typeof(.initResources)) &&
                is(typeof(.initResources) == function) &&
                TakesParams!(.initResources, typeof(this)))
            {
                .initResources(this);
            }
            else
            {
                import lu.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.initResources` was unexpectedly a `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.initResources));
                static assert(0, message);
            }
        }
    }

    // deserialiseConfigFrom
    /++
        Loads configuration for this plugin from disk.

        This does not proxy a call but merely loads configuration from disk for
        all struct variables annotated [kameloso.plugins.Settings|Settings].

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
        foreach (immutable i, ref _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                import lu.traits : udaIndexOf;

                enum hasSettingsUDA =
                    (udaIndexOf!(typeof(this.tupleof[i]), Settings) != -1) ||
                    (udaIndexOf!(this.tupleof[i], Settings) != -1);

                static if (hasSettingsUDA)
                {
                    import kameloso.configreader : readConfigInto;
                    import lu.meld : meldInto;

                    if (this.tupleof[i] != typeof(this.tupleof[i]).init)
                    {
                        // Symbol found but it has had configuration applied to it already
                        break;
                    }

                    string[][string] theseMissingEntries;
                    string[][string] theseInvalidEntries;

                    configFile.readConfigInto(
                        theseMissingEntries,
                        theseInvalidEntries,
                        this.tupleof[i]);
                    theseMissingEntries.meldInto(missingEntries);
                    theseInvalidEntries.meldInto(invalidEntries);
                    break;
                }
            }
        }
    }

    // setSettingByName
    /++
        Change a plugin's [kameloso.plugins.Settings|Settings]-annotated
        settings struct member by their string name.

        This is used to allow for command-line argument to set any plugin's
        setting by only knowing its name.

        Example:
        ---
        @Settings struct FooSettings
        {
            int bar;
        }

        class FooPlugin : IRCPlugin
        {
            FooSettings settings;
        }

        IRCPluginState state;
        IRCPlugin plugin = new IRCPlugin(state);

        pluign.setSettingByName("bar", 42);
        assert(plugin.settings.bar == 42);
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
        bool success;

        foreach (immutable i, ref _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                import lu.traits : udaIndexOf;

                enum hasSettingsUDA =
                    (udaIndexOf!(typeof(this.tupleof[i]), Settings) != -1) ||
                    (udaIndexOf!(this.tupleof[i], Settings) != -1);

                static if (hasSettingsUDA)
                {
                    import lu.objmanip : setMemberByName;
                    success = this.tupleof[i].setMemberByName(setting, value);
                    break;
                }
            }
        }

        return success;
    }

    // printSettings
    /++
        Prints the plugin's [kameloso.plugins.Settings|Settings]-annotated settings struct.
     +/
    override public void printSettings() const
    {
        foreach (immutable i, ref _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                import lu.traits : udaIndexOf;

                enum hasSettingsUDA =
                    (udaIndexOf!(typeof(this.tupleof[i]), Settings) != -1) ||
                    (udaIndexOf!(this.tupleof[i], Settings) != -1);

                static if (hasSettingsUDA)
                {
                    import kameloso.prettyprint : prettyprint;
                    import std.typecons : No, Yes;

                    prettyprint!(No.all)(this.tupleof[i]);
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
        bool didSomething;

        foreach (immutable i, ref _; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct))
            {
                import lu.traits : udaIndexOf;

                enum hasSettingsUDA =
                    (udaIndexOf!(typeof(this.tupleof[i]), Settings) != -1) ||
                    (udaIndexOf!(this.tupleof[i], Settings) != -1);

                static if (hasSettingsUDA)
                {
                    import lu.serialisation : serialise;

                    sink.serialise(this.tupleof[i]);
                    didSomething = true;
                    break;
                }
            }
        }

        return didSomething;
    }

    // initialise, setup, reload, teardown
    /+
        Generates some functions that merely pass on calls to module-level
        functions, where such is available. If they aren't, this is a no-op.

        * `initialise` runs early pre-connect routines, before connection has been
          established.
        * `setup` runs post-connect routines.
        * `reload` reloads the plugin, where such makes sense. What this means is
          implementation-defined.
        * `teardown` de-initialises the plugin.
     +/
    static foreach (immutable funName; AliasSeq!("initialise", "setup", "reload", "teardown"))
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
                    import kameloso.constants : BufferSize;
                    import core.thread.fiber : Fiber;

                    void ` ~ funName ~ `Dg()
                    {
                        .` ~ funName ~ `(this);
                    }

                    auto ` ~ funName ~ `Fiber = new Fiber(&` ~ funName ~ `Dg, BufferSize.fiberStack);
                    ` ~ funName ~ `Fiber.call();
                }
                else
                {
                    import lu.traits : stringOfTypeOf;
                    import std.format : format;

                    ` ~ "enum pattern = \"`%s.%s` was unexpectedly a `%s`\";
                    enum message = pattern.format(module_, \"" ~ funName ~ `", stringOfTypeOf!(.` ~ funName ~ `));
                    static assert(0, message);
                }
            }
        }`);
    }

    // tick
    /++
        Tick function. Called once every main loop iteration.

        Params:
            elapsed = Time since last tick.

        Returns:
            `true` to signal the main loop to check for messages; `false` if not.
     +/
    override public bool tick(const Duration elapsed) @system
    {
        static if (__traits(compiles, { alias _ = .tick; }))
        {
            import lu.traits : TakesParams;
            import std.traits : ReturnType;

            static if (!is(ReturnType!(.tick) == bool))
            {
                import std.format : format;

                enum pattern = "`%s.tick` returns `%s` and not `bool`";
                enum message = pattern.format(module_, ReturnType!(.tick).stringof);
                static assert(0, message);
            }

            if (!this.isEnabled) return false;

            static if (
                is(typeof(.tick)) &&
                is(typeof(.tick) == function) &&
                TakesParams!(.tick, typeof(this), Duration))
            {
                return .tick(this, elapsed);
            }
            else
            {
                import lu.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.tick` was unexpectedly a `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.tick));
                static assert(0, message);
            }
        }
        else
        {
            return false;
        }
    }

    version(Selftests)
    {
        private import kameloso.plugins : Selftester;
        private import std.typecons : Ternary;

        // selftest
        /++
            Self-test function.

            Params:
                tester = The [kameloso.plugins.Selftester|Selftester] to use
                    for testing.

            Returns:
                [std.typecons.Ternary.yes|Ternary.yes] if the self-test succeeded,
                [std.typecons.Ternary.no|Ternary.no] if it failed, and
                [std.typecons.Ternary.unknown|Ternary.unknown] if the plugin is
                disabled or doesn't have a `.selftest` function.
         +/
        override public Ternary selftest(Selftester tester) @system
        {
            static if (__traits(compiles, { alias _ = .selftest; }))
            {
                import kameloso.plugins : Selftester;
                import lu.traits : TakesParams;

                if (!this.isEnabled) return Ternary.unknown;

                static if (
                    is(typeof(.selftest)) &&
                    is(typeof(.selftest) == function) &&
                    TakesParams!(.selftest, typeof(this), Selftester))
                {
                    tester.plugin = this;
                    tester.sync();

                    try
                    {
                        immutable success = .selftest(this, tester);
                        return success ? Ternary.yes : Ternary.no;
                    }
                    catch (Exception e)
                    {
                        version(PrintStacktraces)
                        {
                            import std.stdio : writeln;
                            writeln(e);
                        }

                        return Ternary.no;
                    }
                }
                else
                {
                    import lu.traits : stringOfTypeOf;
                    import std.format : format;

                    enum pattern = "`%s.selftest` was unexpectedly a `%s`";
                    enum message = pattern.format(module_, stringOfTypeOf!(.selftest));
                    static assert(0, message);
                }
            }
            else
            {
                return Ternary.unknown;
            }
        }
    }

    // name
    /++
        Returns the name of the plugin.

        If `fullName` is `true`, the full name is returned, including "Plugin" or "Service".
        If it is false, these are sliced off the end of the string.

        If `lowercase` is `true`, the name as selected by the above is returned
        in lowercase.

        All cases are evaluated at compile-time for performance.

        Params:
            lowercase = Whether to return the name in lowercase.
            fullName = Whether to return the full name, including "Plugin" or "Service".

        Returns:
            The name of the mixing-in class, in the requested form.
     +/
    override public string name(
        const bool lowercase = true,
        const bool fullName = false) const pure nothrow @nogc
    {
        import std.traits : Unqual;
        import std.uni : toLower;

        enum pluginName = Unqual!(typeof(this)).stringof;

        static immutable ctfeName = ()
        {
            import std.algorithm.searching : countUntil;

            immutable nameEndPos = pluginName.countUntil("Plugin", "Service");

            return (nameEndPos != -1) ?
                pluginName[0..nameEndPos] :
                pluginName;
        }();

        if (fullName)
        {
            static immutable ctfeFullLower = pluginName.toLower();
            return lowercase ? ctfeFullLower : pluginName;
        }
        else
        {
            static immutable ctfeNameLower = ctfeName.toLower();
            return lowercase ? ctfeNameLower : ctfeName;
        }
    }

    // channelSpecificCommands
    /++
        Compile a list of our a plugin's oneliner commands.

        Params:
            channelName = Name of channel whose commands we want to summarise.

        Returns:
            An associative array of
            [kameloso.plugins.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s,
            one for each soft command active in the passed channel.
     +/
    override public IRCPlugin.CommandMetadata[string] channelSpecificCommands(const string channelName) @system
    {
        return null;
    }

    // commands
    /++
        Forwards to [kameloso.plugins.IRCPluginImpl.commandsImpl|IRCPluginImpl.commandsImpl].

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging
        [kameloso.plugins.IRCPluginImpl.commandsImpl|IRCPluginImpl.commandsImpl]
        for the actual dirty work.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.
     +/
    pragma(inline, true)
    override public IRCPlugin.CommandMetadata[string] commands() const pure nothrow
    {
        return commandsImpl();
    }

    // commandsImpl
    /++
        Collects all [kameloso.plugins.IRCEventHandler.Command|IRCEventHandler.Command]
        command words and [kameloso.plugins.IRCEventHandler.Regex|IRCEventHandler.Regex]
        regex expressions that this plugin offers at compile time, then at runtime
        returns them alongside their descriptions and their visibility, as an associative
        array of [kameloso.plugins.IRCPlugin.CommandMetadata|IRCPlugin.CommandMetadata]s
        keyed by command name strings.

        This function is private, but since it's part of a mixin template it will
        be visible at the mixin site. Plugins can as such override
        [kameloso.plugins.IRCPlugin.commands|IRCPlugin.commands] with
        their own code and invoke [commandsImpl] as a fallback.

        Returns:
            Associative array of tuples of all command metadata (descriptions,
            syntaxes, and whether they are hidden), keyed by
            [kameloso.plugins.IRCEventHandler.Command.word|IRCEventHandler.Command.word]s
            and [kameloso.plugins.IRCEventHandler.Regex.expression|IRCEventHandler.Regex.expression]s.
     +/
    private auto commandsImpl() const pure nothrow
    {
        enum ctCommandsEnumLiteral =
        {
            import kameloso.plugins : IRCEventHandler;
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

                        // Cannot use uda.fqn, it has not been given a value at this point
                        enum fqn = module_ ~ '.' ~ __traits(identifier, fun);
                        enum pattern = "Warning: `%s` non-hidden command word " ~
                            `"%s" is missing a description`;
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

                        // As above
                        enum fqn = module_ ~ '.' ~ __traits(identifier, fun);
                        enum pattern = "Warning: `%s` non-hidden regex expression " ~
                            `"%s" is missing a description`;
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
    override public void onBusMessage(const string header, /*shared*/ Sendable content) @system
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
            else
            {
                import lu.traits : stringOfTypeOf;
                import std.format : format;

                enum pattern = "`%s.onBusMessage` was unexpectedly a `%s`";
                enum message = pattern.format(module_, stringOfTypeOf!(.onBusMessage));
                static assert(0, message);
            }
        }
    }

    // putUser
    /++
        Inherits a user, by default into a plugin's state.

        Params:
            user = The user to inherit.
            channel = The channel context of the user.
     +/
    pragma(inline, true)
    override public void putUser(const IRCUser user, const string channel) @system
    {
        putUserImpl(user);
    }

    // putUserImpl
    /++
        Puts a user into the plugin's state.

        Params:
            user = The user to inherit.
     +/
    private void putUserImpl(const IRCUser user) @system
    {
        state.users[user.nickname] = user;
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
    import std.algorithm.searching : startsWith;
    import std.typecons : No, Yes;

    static if (verbose)
    {
        import lu.conv : toString;
        import std.stdio : writefln, writeln;
        writeln("    ...prefixPolicyMatches invoked! policy:", policy.toString);
    }

    bool strippedDisplayName;

    with (PrefixPolicy)
    final switch (policy)
    {
    case direct:
        static if (verbose)
        {
            writeln("        ...as such, just passes.");
        }
        return true;

    case prefixed:
        if (!state.coreSettings.prefix.length)
        {
            static if (verbose)
            {
                writeln("        ...but no prefix defined; defer to nickname case.");
            }
            goto case nickname;
        }
        else if (event.content.startsWith(state.coreSettings.prefix))
        {
            static if (verbose)
            {
                enum pattern = "        ...does start with prefix (%s)";
                writefln(pattern, state.coreSettings.prefix);
            }
            event.content = event.content[state.coreSettings.prefix.length..$];
        }
        else
        {
            static if (verbose)
            {
                writeln("        ...did not start with prefix but falling back to nickname check");
            }
            goto case nickname;
        }
        break;

    case nickname:
        if (event.content.startsWith('@'))
        {
            static if (verbose)
            {
                writeln("        ...stripped away prepended '@'");
            }

            // Using @name to refer to someone is not
            // uncommon; allow for it and strip it away
            event.content = event.content[1..$];
        }

        version(TwitchSupport)
        {
            if ((state.server.daemon == IRCServer.Daemon.twitch) &&
                state.client.displayName.length &&
                event.content.startsWith(state.client.displayName))
            {
                static if (verbose)
                {
                    writeln("        ...begins with displayName! stripping it");
                }

                event.content = event.content
                    .stripSeparatedPrefix(state.client.displayName, demandSeparatingChars: true);

                if (state.coreSettings.prefix.length && event.content.startsWith(state.coreSettings.prefix))
                {
                    static if (verbose)
                    {
                        enum pattern = "            ...further starts with prefix (%s)";
                        writefln(pattern, state.coreSettings.prefix);
                    }
                    event.content = event.content[state.coreSettings.prefix.length..$];
                }

                strippedDisplayName = true;
                // Drop down
            }
        }

        if (strippedDisplayName)
        {
            // Already did something
        }
        else if (event.content.startsWith(state.client.nickname))
        {
            static if (verbose)
            {
                writeln("        ...content begins with nickname! stripping it");
            }

            event.content = event.content
                .stripSeparatedPrefix(state.client.nickname, demandSeparatingChars: true);

            if (state.coreSettings.prefix.length && event.content.startsWith(state.coreSettings.prefix))
            {
                static if (verbose)
                {
                    enum pattern = "            ...further starts with prefix (%s)";
                    writefln(pattern, state.coreSettings.prefix);
                }

                event.content = event.content[state.coreSettings.prefix.length..$];
            }
            // Drop down
        }
        else if (event.type == IRCEvent.Type.QUERY)
        {
            static if (verbose)
            {
                writeln("    ...doesn't begin with nickname but it's a QUERY");
            }
            // Drop down
        }
        else
        {
            static if (verbose)
            {
                writeln("    ..nickname required but not present; returning false.");
            }
            return false;
        }
        break;
    }

    static if (verbose)
    {
        writeln("    ...policy checks out! (dropped down to return true)");
    }

    return true;
}


// filterSender
/++
    Decides if a sender meets a [Permissions] and is allowed to trigger an event
    handler, or if a WHOIS query is needed to be able to tell.

    This requires the Persistence service to be active to work.

    Params:
        verbose = Whether or not to output verbose debug information to the local terminal.
        event = [dialect.defs.IRCEvent|IRCEvent] to filter.
        permissionsRequired = The [Permissions] context in which this user should be filtered.
        preferHostmasks = Whether to rely on hostmasks for user identification,
            or to use services account logins, which need to be issued WHOIS
            queries to divine.

    Returns:
        A [FilterResult] saying the event should `pass`, `fail`, or that more
        information about the sender is needed via a WHOIS call.

    Also_See:
        [filterSenderImpl]
 +/
auto filterSender(bool verbose = false)
    (const IRCEvent event,
    const Permissions permissionsRequired,
    const bool preferHostmasks) @safe
{
    import kameloso.constants : Timeout;

    static if (verbose)
    {
        import lu.conv : toString;
        import std.stdio : writeln;

        writeln("...filterSender of ", event.sender.nickname);
        writeln("    ...permissions:", permissionsRequired.toString);
        writeln("    ...account:", event.sender.account);
        writeln("    ...class:", event.sender.class_.toString);
    }

    if (permissionsRequired == Permissions.ignore)
    {
        static if (verbose)
        {
            writeln("...immediate pass (the call to filterSender could have been skipped)");
        }
        return FilterResult.pass;
    }

    if (event.sender.class_ == IRCUser.Class.blacklist)
    {
        static if (verbose)
        {
            writeln("...immediate fail (blacklist)");
        }
        return FilterResult.fail;
    }

    immutable timediff = (event.time - event.sender.updated);

    // In hostmasks mode there's zero point to WHOIS a sender, as the instigating
    // event will have the hostmask embedded in it, always.
    immutable whoisExpired = !preferHostmasks && (timediff > Timeout.Integers.whoisRetrySeconds);

    static if (verbose)
    {
        writeln("    ...timediff:", timediff);
        writeln("    ...whoisExpired:", whoisExpired);
    }

    if (event.sender.account.length)
    {
        immutable verdict = filterSenderImpl(
            permissionsRequired,
            event.sender.class_,
            whoisExpired);

        static if (verbose)
        {
            writeln("...filterSenderImpl verdict:", verdict.toString);
        }

        return verdict;
    }
    else
    {
        immutable isLogoutEvent = (event.type == IRCEvent.Type.ACCOUNT);

        static if (verbose) writeln("    ...isLogoutEvent:", isLogoutEvent);

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
            immutable verdict = (whoisExpired && !isLogoutEvent) ?
                FilterResult.whois :
                FilterResult.fail;
            static if (verbose) writeln("...filterSenderImpl verdict:", verdict.toString);
            return verdict;

        case anyone:
            // Unknown sender; WHOIS if old result expired in mere curiosity, else just pass
            immutable verdict = (whoisExpired && !isLogoutEvent) ?
                FilterResult.whois :
                FilterResult.pass;
            static if (verbose) writeln("...filterSenderImpl verdict:", verdict.toString);
            return verdict;

        case ignore:
            // Will have already returned earlier
            assert(0, "Unreachable");
        }
    }
}


// filterSenderImpl
/++
    Judges whether an event may be triggered, based on the event itself and
    the annotated [kameloso.plugins.Permissions|Permissions] of the
    handler in question. Implementation function.

    Params:
        permissionsRequired = The [Permissions] context in which this user should be filtered.
        class_ = [dialect.defs.IRCUser.Class|IRCUser.Class] of the sender to filter.
        whoisExpired = Whether or not the sender's WHOIS result has expired
            (and thus may be reissued).

    Returns:
        [FilterResult.pass] if the event should be allowed to trigger,
        [FilterResult.whois] if a WHOIS is required to tell and [FilterResult.fail]
        if the trigger should be denied.

    See_Also:
        [filterSender]
 +/
auto filterSenderImpl(
    const Permissions permissionsRequired,
    const IRCUser.Class class_,
    const bool whoisExpired)
{
    version(WithPersistenceService) {}
    else
    {
        pragma(msg, "Warning: The Persistence service is not compiled in. " ~
            "Event triggers may or may not work. You get to keep the pieces.");
    }

    // Trust in Persistence to have divined the sender's class
    immutable isAdmin = (class_ == IRCUser.Class.admin);
    immutable isStaff = (class_ == IRCUser.Class.staff);
    immutable isOperator = (class_ == IRCUser.Class.operator);
    immutable isElevated = (class_ == IRCUser.Class.elevated);
    immutable isWhitelisted = (class_ == IRCUser.Class.whitelist);
    immutable isRegistered = (class_ == IRCUser.Class.registered);
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
    else if (isRegistered && (permissionsRequired <= Permissions.registered))
    {
        return FilterResult.pass;
    }
    else if (isAnyone && (permissionsRequired <= Permissions.anyone))
    {
        return whoisExpired ? FilterResult.whois : FilterResult.pass;
    }
    else if (permissionsRequired == Permissions.ignore)
    {
        // Ideally this function should not be called if we know it's Permissions.ignore
        return FilterResult.pass;
    }
    else
    {
        return FilterResult.fail;
    }
}


// allowImpl
/++
    Judges whether an event may be triggered, based on the event itself and
    the annotated [kameloso.plugins.Permissions|Permissions] of the
    handler in question. Implementation function.

    Params:
        plugin = The [IRCPlugin] this relates to.
        event = [dialect.defs.IRCEvent|IRCEvent] to allow, or not.
        permissionsRequired = Required [kameloso.plugins.Permissions|Permissions]
            of the handler in question.

    Returns:
        [FilterResult.pass] if the event should be allowed to trigger,
        [FilterResult.whois] if not.

    See_Also:
        [filterSender]
        [filterSenderImpl]
 +/
auto allowImpl(bool verbose = false)
    (IRCPlugin plugin,
    const IRCEvent event,
    const Permissions permissionsRequired) @safe
{
    if (permissionsRequired == Permissions.ignore) return FilterResult.pass;

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Watered-down version of filterSender, since we don't need
            // (and can't rely on) WHOIS

            if (event.sender.class_ == IRCUser.Class.blacklist) return FilterResult.fail;

            return filterSenderImpl(
                permissionsRequired,
                event.sender.class_,
                false);  // whoisExpired
        }
    }

    // Permissions.ignore always passes, even for Class.blacklist.
    return filterSender!verbose
        (event,
        permissionsRequired,
        plugin.state.coreSettings.preferHostmasks);
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

    event.raw = sanitize(event.raw);
    event.channel.name = sanitize(event.channel.name);
    event.content = sanitize(event.content);
    event.tags = sanitize(event.tags);
    event.errors = sanitize(event.errors);
    if (event.errors.length) event.errors ~= " | ";
    event.errors ~= "Sanitised";

    foreach (ref auxN; event.aux)
    {
        auxN = sanitize(auxN);
    }

    IRCUser*[2] bothUsers =
    [
        &event.sender,
        &event.target,
    ];

    foreach (user; bothUsers[])
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

    if (!uda.acceptedEventTypes.length)
    {
        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
            "but it is not declared to accept any `IRCEvent.Type`s";
        immutable message = pattern.format(uda.fqn);
        assert(0, message);
    }

    foreach (immutable type; uda.acceptedEventTypes)
    {
        if (type == IRCEvent.Type.UNSET)
        {
            enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.UNSET`, which is not a valid event type";
            immutable message = pattern.format(uda.fqn);
            assert(0, message);
        }
        else if (type == IRCEvent.Type.PRIVMSG)
        {
            enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.PRIVMSG`, which is not a valid event type. " ~
                "Use `IRCEvent.Type.CHAN` and/or `IRCEvent.Type.QUERY` instead";
            immutable message = pattern.format(uda.fqn);
            assert(0, message);
        }
        else if (type == IRCEvent.Type.WHISPER)
        {
            enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.WHISPER`, which is not a valid event type. " ~
                "Use `IRCEvent.Type.QUERY` instead";
            immutable message = pattern.format(uda.fqn);
            assert(0, message);
        }
        /*else if ((type == IRCEvent.Type.ANY) && !(uda.channelPolicy & ChannelPolicy.any))
        {
            enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                "accepting `IRCEvent.Type.ANY` and is at the same time not annotated " ~
                "`ChannelPolicy.any`, which is the only accepted combination";
            immutable message = pattern.format(uda.fqn);
            assert(0, message);
        }*/

        if (uda.commands.length || uda.regexes.length)
        {
            if ((type != IRCEvent.Type.CHAN) &&
                (type != IRCEvent.Type.QUERY) &&
                (type != IRCEvent.Type.SELFCHAN) &&
                (type != IRCEvent.Type.SELFQUERY))
            {
                import lu.conv : toString;

                enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` and/or `Regex`, but is at the " ~
                    "same time accepting non-message `IRCEvent.Type.%s events`";
                immutable message = pattern.format(
                    uda.fqn,
                    type.toString);
                assert(0, message);
            }
        }
    }

    if (uda.commands.length)
    {
        foreach (const command; uda.commands)
        {
            import std.algorithm.searching : canFind;

            if (!command._word.length)
            {
                enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` with an empty (or unspecified) trigger word";
                immutable message = pattern.format(uda.fqn);
                assert(0, message);
            }
            else if (command._word.canFind(' '))
            {
                enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Command` whose trigger " ~
                    `word "%s" contains a space character`;
                immutable message = pattern.format(uda.fqn, command._word);
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
                enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                    "listening for a `Regex` with an empty (or unspecified) expression";
                immutable message = pattern.format(uda.fqn);
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

    if (inFiber)
    {
        if (storageClass & ParameterStorageClass.ref_)
        {
            enum pattern = "`%s` has a `%s` event handler annotated `.fiber(true)` " ~
                "that takes an `IRCEvent` by `ref`, which is a combination prone " ~
                "to memory corruption. Pass by value instead";
            immutable message = pattern.format(module_, typestring).idup;
            assert(0, message);
        }
    }
    else if (!paramIsConst)
    {
        if ((storageClass & ParameterStorageClass.ref_) ||
            (storageClass & ParameterStorageClass.out_))
        {
            enum pattern = "`%s` has a `%s` event handler that takes an " ~
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
    import kameloso.messaging : Message;
    import kameloso.thread : ScheduledDelegate, ScheduledFiber, ThreadMessage;
    import lu.container : RehashingAA;
    import std.array : Appender;
    import core.thread.fiber : Fiber;

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
        nothing = 0,

        /++
            [IRCPluginState.bot] was marked as updated.
         +/
        bot     = 1 << 0,

        /++
            [IRCPluginState.client] was marked as updated.
         +/
        client  = 1 << 1,

        /++
            [IRCPluginState.server] was marked as updated.
         +/
        server  = 1 << 2,

        /++
            [IRCPluginState.coreSettings] was marked as updated.
         +/
        coreSettings = 1 << 3,
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
    CoreSettings coreSettings;

    // connSettings
    /++
        The current program-wide [kameloso.pods.ConnectionSettings|ConnectionSettings].
     +/
    ConnectionSettings connSettings;

    // users
    /++
        Hashmap of IRC user details.
     +/
    RehashingAA!(IRCUser[string]) users;

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
            if (!scheduledFiber.fiber) continue;  // undelayed

            if (scheduledFiber.timestamp < nextScheduledTimestamp)
            {
                nextScheduledTimestamp = scheduledFiber.timestamp;
            }
        }

        foreach (const scheduledDg; scheduledDelegates)
        {
            if (!scheduledDg.dg) continue;  // ditto

            if (scheduledDg.timestamp < nextScheduledTimestamp)
            {
                nextScheduledTimestamp = scheduledDg.timestamp;
            }
        }
    }

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
        Pointer to the global abort bool.
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
    this(const uint connectionID) pure @safe nothrow @nogc
    {
        this._connectionID = connectionID;
    }

    // deferredActions
    /++
        This plugin's array of [DeferredAction]s.
     +/
    Appender!(DeferredAction[]) deferredActions;

    // messages
    /++
        Messages for the main event loop to take action on.
     +/
    Appender!(ThreadMessage[]) messages;

    // priorityMessages
    /++
        Messages for the main event loop to take action on with a higher priority.
     +/
    Appender!(ThreadMessage[]) priorityMessages;

    // outgoingMessages
    /++
        Events to send to the IRC server.
     +/
    Appender!(Message[]) outgoingMessages;

    // querier
    /++
        FIXME
     +/
    Querier querier;
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

    // acted
    /++
        A WHOIS query was issued for this event.
     +/
    bool acted;

    /++
        Creates a new [Replay] with a timestamp of the current time.

        Params:
            dg = Delegate to call with a prepared [Replay] as argument.
            event = [dialect.defs.IRCEvent|IRCEvent] to stored for later replay.
            permissionsRequired = [Permissions] required by the function to replay.
            caller = Name of the caller function or similar context.
     +/
    this(
        void delegate(Replay) dg,
        const IRCEvent event,
        const Permissions permissionsRequired,
        const string caller) pure @safe nothrow @nogc
    {
        this.timestamp = event.time;
        this.dg = dg;
        this.event = event;
        this.permissionsRequired = permissionsRequired;
        this.caller = caller;
    }
}


// enqueue
/++
    Construct and enqueue a function replay in the plugin's queue of such.

    The main loop will catch up on it and issue WHOIS queries as necessary, then
    replay the event upon receiving the results.

    Params:
        plugin = Subclass [kameloso.plugins.IRCPlugin|IRCPlugin] to
            replay the function pointer `fun` with as first argument.
        event = [dialect.defs.IRCEvent|IRCEvent] to queue up to replay.
        permissionsRequired = Permissions level to match the results from the WHOIS query with.
        inFiber = Whether or not the function should be called from within a Fiber.
        fun = Function/delegate pointer to call when the results return.
        caller = String name of the calling function, or something else that gives context.
 +/
void enqueue(Plugin, Fun)
    (Plugin plugin,
    const IRCEvent event,
    const Permissions permissionsRequired,
    const bool inFiber,
    Fun fun,
    const string caller = __FUNCTION__)
in ((event.type != IRCEvent.Type.UNSET), "Tried to `enqueue` with an unset IRCEvent")
in ((fun !is null), "Tried to `enqueue` with a null function pointer")
{
    import kameloso.constants : Timeout;
    import std.traits : isSomeFunction;

    static if (!is(Plugin : IRCPlugin))
    {
        enum message = "A non-`IRCPlugin`-subclass plugin was passed to `enqueue`";
        static assert(0, message);
    }

    static if (!isSomeFunction!Fun)
    {
        enum message = "A non-function type was passed to `enqueue`";
        static assert(0, message);
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            version(Debug)
            {
                import kameloso.common : logger;

                enum pattern = "<l>%s</> tried to WHOIS on Twitch";
                logger.warningf(pattern, caller);

                version(IncludeHeavyStuff)
                {
                    import kameloso.prettyprint : prettyprint;
                    prettyprint(event);
                }

                version(PrintStacktraces)
                {
                    import kameloso.misc: printStacktrace;
                    printStacktrace();
                }
            }
            return;
        }
    }

    immutable user = event.sender.isServer ? event.target : event.sender;
    assert(user.nickname.length, "Bad user derived in `enqueue` (no nickname)");

    version(ExplainReplay)
    {
        import std.algorithm.searching : startsWith;
        immutable callerSlice = caller.startsWith("kameloso.plugins.") ?
            caller[17..$] :
            caller;
    }

    immutable timeSinceUpdate = (event.time - user.updated);

    if ((timeSinceUpdate < Timeout.Integers.whoisRetrySeconds) &&
        (timeSinceUpdate > Timeout.Integers.whoisGracePeriodSeconds))
    {
        version(ExplainReplay)
        {
            import kameloso.common : logger;
            enum pattern = "<i>%s</> plugin <w>NOT</> queueing an event to be replayed " ~
                "on behalf of <i>%s</>; delta time <i>%d</> is too small";
            logger.logf(pattern, plugin.name, callerSlice, timeSinceUpdate);
        }
        return;
    }

    version(ExplainReplay)
    {
        import kameloso.common : logger;
        enum pattern = "<i>%s</> plugin queueing an event to be replayed on behalf of <i>%s";
        logger.logf(pattern, plugin.name, callerSlice);
    }

    plugin.state.pendingReplays[user.nickname] ~=
        replay(
            plugin,
            event,
            fun,
            permissionsRequired,
            inFiber,
            caller);
    plugin.state.hasPendingReplays = true;
}


// replay
/++
    Convenience function that returns a [kameloso.plugins.Replay] of
    the right type, *with* a subclass plugin reference attached.

    Params:
        plugin = Subclass [kameloso.plugins.IRCPlugin|IRCPlugin] to
            call the function pointer `fun` with as first argument, when the
            WHOIS results return.
        event = [dialect.defs.IRCEvent|IRCEvent] that instigated the WHOIS lookup.
        fun = Function/delegate pointer to call upon receiving the results.
        permissionsRequired = The permissions level policy to apply to the WHOIS results.
        inFiber = Whether or not the function should be called from within a Fiber.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A [kameloso.plugins.Replay|Replay] with template parameters
        inferred from the arguments passed to this function.

    See_Also:
        [kameloso.plugins.Replay|Replay]
 +/
private auto replay(Plugin, Fun)
    (Plugin plugin,
    const IRCEvent event,
    Fun fun,
    const Permissions permissionsRequired,
    const bool inFiber,
    const string caller)
{
    void replayDg(Replay replay)
    {
        import lu.conv : toString;
        import std.algorithm.searching : startsWith;

        version(ExplainReplay)
        void explainReplay()
        {
            import kameloso.common : logger;

            immutable caller = replay.caller.startsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s</> replaying <i>%s</>-level event (invoking <i>%s</>) " ~
                "based on WHOIS results; user <i>%s</> is <i>%s</> class";
            logger.logf(
                pattern,
                plugin.name,
                replay.permissionsRequired.toString,
                caller,
                replay.event.sender.nickname,
                replay.event.sender.class_.toString);
        }

        version(ExplainReplay)
        void explainRefuse()
        {
            import kameloso.common : logger;

            immutable caller = replay.caller.startsWith("kameloso.plugins.") ?
                replay.caller[17..$] :
                replay.caller;

            enum pattern = "<i>%s</> plugin <w>NOT</> replaying <i>%s</>-level event " ~
                "(which would have invoked <i>%s</>) " ~
                "based on WHOIS results: user <i>%s</> is <i>%s</> class";
            logger.logf(
                pattern,
                plugin.name,
                replay.permissionsRequired.toString,
                caller,
                replay.event.sender.nickname,
                replay.event.sender.class_.toString);
        }

        with (Permissions)
        final switch (permissionsRequired)
        {
        case admin:
            if (replay.event.sender.class_ >= IRCUser.Class.admin)
            {
                goto case ignore;
            }
            break;

        case staff:
            if (replay.event.sender.class_ >= IRCUser.Class.staff)
            {
                goto case ignore;
            }
            break;

        case operator:
            if (replay.event.sender.class_ >= IRCUser.Class.operator)
            {
                goto case ignore;
            }
            break;

        case elevated:
            if (replay.event.sender.class_ >= IRCUser.Class.elevated)
            {
                goto case ignore;
            }
            break;

        case whitelist:
            if (replay.event.sender.class_ >= IRCUser.Class.whitelist)
            {
                goto case ignore;
            }
            break;

        case registered:
            if (replay.event.sender.account.length)
            {
                goto case ignore;
            }
            break;

        case anyone:
            if (replay.event.sender.class_ >= IRCUser.Class.anyone)
            {
                goto case ignore;
            }

            // event.sender.class_ is Class.blacklist here (or unset)
            // Do nothing and drop down
            break;

        case ignore:
            version(ExplainReplay) explainReplay();

            void call()
            {
                import lu.traits : TakesParams;
                import std.traits : arity;

                static if (
                    TakesParams!(fun, Plugin, IRCEvent) ||
                    TakesParams!(fun, IRCPlugin, IRCEvent))
                {
                    fun(plugin, replay.event);
                }
                else static if (
                    TakesParams!(fun, Plugin) ||
                    TakesParams!(fun, IRCPlugin))
                {
                    fun(plugin);
                }
                else static if (
                    TakesParams!(fun, IRCEvent))
                {
                    fun(replay.event);
                }
                else static if (arity!fun == 0)
                {
                    fun();
                }
                else
                {
                    // onEventImpl.call should already have statically asserted all
                    // event handlers are of the types above
                    static assert(0, "Unreachable");
                }
            }

            if (inFiber)
            {
                import kameloso.constants : BufferSize;
                import kameloso.thread : carryingFiber;
                import core.thread.fiber : Fiber;

                auto fiber = carryingFiber(
                    &call,
                    replay.event,
                    BufferSize.fiberStack);
                fiber.creator = caller;
                fiber.call(caller);

                if (fiber.state == Fiber.State.TERM)
                {
                    // Ended immediately, so just destroy
                    destroy(fiber);
                    fiber = null;
                }
            }
            else
            {
                call();
            }

            return;
        }

        version(ExplainReplay) explainRefuse();
    }

    return Replay(&replayDg, event, permissionsRequired, caller);
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
    home = 1 << 0,

    /++
        The annotated function will only be allowed to trigger if the event
        happened in a guest channel, where applicable. Not all events carry channels.
     +/
    guest = 1 << 1,

    /++
        The annotated function will be allowed to trigger regardless of channel.
     +/
    any = 1 << 2,
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
        classifier (or higher) may trigger the annotated function.

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
    import lu.typecons : UnderscoreOpDispatcher;

public:
    // acceptedEventTypes
    /++
        Array of types of [dialect.defs.IRCEvent] that the annotated event
        handler function should accept.
     +/
    IRCEvent.Type[] acceptedEventTypes;

    // _onEvent
    /++
        Alias to make the [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
        redirect calls to [acceptedEventTypes] but by the name `onEvent`.
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
        Alias to make the [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
        redirect calls to [commands] but by the name `addCommand`.
     +/
    alias _addCommand = commands;

    // regexes
    /++
        Array of [IRCEventHandler.Regex]es the bot should pick up and listen for.
     +/
    Regex[] regexes;

    // _addRegex
    /++
        Alias to make the [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
        redirect calls to [regexes] but by the name `addRegex`.
     +/
    alias _addRegex = regexes;

    // _chainable
    /++
        Whether or not the annotated event handler function should allow other
        functions to fire after it. If not set (default false), it will
        terminate and move on to the next plugin after the function returns.
     +/
    bool _chainable = false;

    // _verbose
    /++
        Whether or not additional information should be output to the local
        terminal as the function is (or is not) triggered.
     +/
    bool _verbose = false;

    // _when
    /++
        Special instruction related to the order of which event handler functions
        within a plugin module are triggered.
     +/
    Timing _when; //= Timing.untimed;

    // _fiber
    /++
        Whether or not the annotated event handler should be run from within a
        [core.thread.fiber.Fiber|Fiber].
     +/
    bool _fiber = false;

    // _acceptExternal
    /++
        Whether or not the annotated event handler should react to events in a
        channel that actually originate from a distinct subchannel.
     +/
    bool _acceptExternal = false;

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
            the [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher].

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
            Alias to make the [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
            redirect calls to [syntaxes] but by the name `addSyntax`.
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
            cannot rely on [lu.typecons.UnderscoreOpDispatcher|UnderscoreOpDispatcher]
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


// DeferredAction
/++
    Embodies the notion of an action a plugin defers to the main event loop for later execution.
 +/
interface DeferredAction
{
private:
    import core.thread.fiber : Fiber;

public:
    // context
    /++
        String context of the action.
     +/
    string context() const pure @safe nothrow @nogc;

    // subcontext
    /++
        String secondary context of the action.
     +/
    string subcontext() const pure @safe nothrow @nogc;

    // creator
    /++
        Name of the function that created this action.
     +/
    string creator() const pure @safe nothrow @nogc;

    // fiber
    /++
        Fiber embedded into the action.
     +/
    Fiber fiber() @system;
}


// DeferredActionImpl
/++
    Concrete implementation of a [DeferredAction].

    The template parameter `T` defines that kind of
    [kameloso.thread.CarryingFiber|CarryingFiber] is embedded into it.

    Params:
        T = Type to instantiate the [kameloso.thread.CarryingFiber|CarryingFiber] with.
 +/
private final class DeferredActionImpl(T) : DeferredAction
{
private:
    import kameloso.thread : CarryingFiber;
    import core.thread.fiber : Fiber;

    /++
        Private context string.
     +/
    string _context;

    /++
        Private secondary context string.
     +/
    string _subcontext;

    /++
        Private creator string.
     +/
    string _creator;

    /++
        Private [kameloso.thread.CarryingFiber|CarryingFiber].
     +/
    CarryingFiber!T _fiber;

public:
    // this
    /++
        Constructor.

        Params:
            fiber = [kameloso.thread.CarryingFiber|CarryingFiber] to embed into the action.
            context = String context of the action.
            creator = Name of the function that created this action.
     +/
    this(
        CarryingFiber!T fiber,
        string context,
        string subcontext,
        const string creator) pure @safe nothrow @nogc
    {
        this._context = context;
        this._subcontext = subcontext;
        this._fiber = fiber;
        this._creator = creator;
    }

    // this
    /++
        Constructor.

        Params:
            dg = Delegate to create a [kameloso.thread.CarryingFiber|CarryingFiber] from.
            context = String context of the action.
            creator = Name of the function that created this action.
     +/
    this(
        void delegate() dg,
        string context,
        string subcontext,
        const string creator) /*pure @safe @nogc*/ nothrow
    {
        import kameloso.constants : BufferSize;

        this._context = context;
        this._subcontext = subcontext;
        this._fiber = new CarryingFiber!T(dg, BufferSize.fiberStack);
        this._fiber.creator = creator;
        this._creator = creator;
    }

    // context
    /++
        String context of the action. May be anything; highly action-specific.

        Returns:
            A string.
     +/
    string context() const pure @safe nothrow @nogc
    {
        return _context;
    }

    // subcontext
    /++
        String secondary context of the action. May be anything; highly action-specific.

        Returns:
            A string.
     +/
    string subcontext() const pure @safe nothrow @nogc
    {
        return _subcontext;
    }

    // creator
    /++
        Name of the function that created this action.

        Returns:
            A string.
     +/
    string creator() const pure @safe nothrow @nogc
    {
        return _creator;
    }

    // fiber
    /++
        [kameloso.thread.CarryingFiber|CarryingFiber] embedded into the action.

        Returns:
            A [kameloso.thread.CarryingFiber|CarryingFiber] in the guise of a
            [core.thread.fiber.Fiber|Fiber].
     +/
    Fiber fiber()
    {
        return _fiber;
    }
}


// defer
/++
    Instantiates a [DeferredActionImpl] in the guise of a [DeferredAction]
    with the implicit type `T` as payload and appends it to the passed [IRCPlugin]'s
    [IRCPluginState.deferredActions|deferredActions] array.

    Overload that takes a [kameloso.thread.CarryingFiber|CarryingFiber].

    Params:
        T = Type to instantiate [DeferredActionImpl] with.
        plugin = [IRCPlugin] whose [IRCPluginState.deferredActions|deferredActions]
            array the action will be appended to.
        fiber = [kameloso.thread.CarryingFiber|CarryingFiber] to embed into the action.
        context = String context of the action.
        subcontext = String secondary context of the action.
        creator = Name of the function that created this action.
 +/
void defer(T)
    (IRCPlugin plugin,
    CarryingFiber!T fiber,
    const string context = string.init,
    const string subcontext = string.init,
    const string creator = __FUNCTION__) pure @safe nothrow
{
    auto action = new DeferredActionImpl!T(fiber, context, subcontext, creator);
    plugin.state.deferredActions.put(action);
}


// defer
/++
    Instantiates a [DeferredActionImpl] in the guise of a [DeferredAction]
    with the implicit type `T` as payload and appends it to the passed [IRCPlugin]'s
    [IRCPluginState.deferredActions|deferredActions] array.

    Overload that takes a `void delegate()` delegate, which [DeferredActionImpl]'s
    constructor will create a [kameloso.thread.CarryingFiber|CarryingFiber] from.

    Params:
        T = Type to instantiate [DeferredActionImpl] with.
        plugin = [IRCPlugin] whose [IRCPluginState.deferredActions|deferredActions]
            array the action will be appended to.
        dg = Delegate to create a [kameloso.thread.CarryingFiber|CarryingFiber] from.
        context = String context of the action.
        subcontext = String secondary context of the action.
        creator = Name of the function that created this action.
 +/
void defer(T)
    (IRCPlugin plugin,
    void delegate() dg,
    const string context = string.init,
    const string subcontext = string.init,
    const string creator = __FUNCTION__) /*pure @safe*/ nothrow
{
    auto action = new DeferredActionImpl!T(dg, context, subcontext, creator);
    plugin.state.deferredActions.put(action);
}


// applyCustomSettings
/++
    Changes a setting of a plugin, given both the names of the plugin and the
    setting, in string form.

    This merely iterates the passed `plugins` and calls their
    [kameloso.plugins.IRCPlugin.setMemberByName|IRCPlugin.setMemberByName]
    methods.

    Params:
        plugins = Array of all [kameloso.plugins.IRCPlugin|IRCPlugin]s.
        coreSettings = Pointer to a [kameloso.pods.CoreSettings|CoreSettings] struct.
        customSettings = Array of custom settings to apply to plugins' own
            setting, in the string forms of "`plugin.setting=value`".
        toPluginsOnly = Whether to apply settings to the core settings struct
            as well, or only to the plugins.

    Returns:
        `true` if no setting name mismatches occurred, `false` if it did.

    See_Also:
        [lu.objmanip.setSettingByName]
 +/
auto applyCustomSettings(
    IRCPlugin[] plugins,
    ref CoreSettings coreSettings,
    const string[] customSettings,
    const bool toPluginsOnly)
{
    import kameloso.common : logger;
    import lu.objmanip : SetMemberException;
    import lu.string : advancePast;
    import std.algorithm.searching : canFind;
    import std.conv : ConvException;

    bool allSuccess = true;

    top:
    foreach (immutable line; customSettings)
    {
        if (!line.canFind('.'))
        {
            enum pattern = `Bad <l>plugin</>.<l>setting</>=<l>value</> format. (<l>%s</>)`;
            logger.warningf(pattern, line);
            allSuccess = false;
            continue;
        }

        string slice = line;  // mutable
        immutable pluginstring = slice.advancePast(".");
        immutable setting = slice.advancePast('=', inherit: true);
        alias value = slice;

        try
        {
            if (pluginstring == "core")
            {
                import kameloso.common : logger;
                import kameloso.logger : KamelosoLogger;
                import lu.objmanip : setMemberByName;
                import std.algorithm.comparison : among;

                if (toPluginsOnly) continue top;

                immutable success = value.length ?
                    coreSettings.setMemberByName(setting, value) :
                    coreSettings.setMemberByName(setting, true);

                if (!success)
                {
                    enum pattern = `No such <l>core</> setting: "<l>%s</>"`;
                    logger.warningf(pattern, setting);
                    allSuccess = false;
                }
                else
                {
                    if (setting.among!
                        ("colour",
                        "color",
                        "brightTerminal",
                        "headless",
                        "flush"))
                    {
                        logger = new KamelosoLogger(coreSettings);
                    }

                    foreach (plugin; plugins)
                    {
                        plugin.state.coreSettings = coreSettings;

                        // No need to flag as updated when we update here manually
                        //plugin.state.updates |= typeof(plugin.state.updates).coreSettings;
                    }
                }
                continue top;
            }
            else if (!plugins.length)
            {
                continue top;
            }
            else
            {
                foreach (plugin; plugins)
                {
                    if (plugin.name != pluginstring) continue;

                    immutable success = plugin.setSettingByName(
                        setting,
                        value.length ? value : "true");

                    if (!success)
                    {
                        enum pattern = `No such <l>%s</> plugin setting: "<l>%s</>"`;
                        logger.warningf(pattern, pluginstring, setting);
                        allSuccess = false;
                    }
                    continue top;
                }
            }

            // If we're here, the loop was never continued --> unknown plugin
            enum pattern = `Invalid plugin: "<l>%s</>"`;
            logger.warningf(pattern, pluginstring);
            allSuccess = false;
            // Drop down, try next
        }
        catch (SetMemberException e)
        {
            enum pattern = "Failed to set <l>%s</>.<l>%s</>: " ~
                "it requires a value and none was supplied.";
            logger.warningf(pattern, pluginstring, setting);
            version(PrintStacktraces) logger.trace(e.info);
            allSuccess = false;
            // Drop down, try next
        }
        catch (ConvException e)
        {
            enum pattern = `Invalid value for <l>%s</>.<l>%s</>: "<l>%s</>" <t>(%s)`;
            logger.warningf(pattern, pluginstring, setting, value, e.msg);
            allSuccess = false;
            // Drop down, try next
        }
        continue top;
    }

    return allSuccess;
}


// memoryCorruptionCheck
/++
    Mixin that adds a check to ensure that the event type of the event being
    handled is one of the expected types for the function it is mixed into.

    Assumes that it is mixed into a function. (This cannot be statically checked
    and will return in a compile-time error if false.)

    If version `MemoryCorruptionChecks` is not declared it is a no-op and returns
    an empty string.

    Params:
        assertOnError = Whether to `assert(0)` if an error is detected.
            Passed on to the implementation function.

    Returns:
        A string that can be mixed into a function to add the check.

    See_Also:
        [memoryCorruptionCheckImpl]
 +/
auto memoryCorruptionCheck(Flag!"assertOnError" assertOnError = Yes.assertOnError)()
{
    version(MemoryCorruptionChecks)
    {
        assert(__ctfe, "`memoryCorruptionCheck` should only be used as a compile-time string mixin.");

        /+
        // Alternative approach
        import kameloso.string : countUntilLastOccurrenceOf;

        enum _lastDotPos = __FUNCTION__.countUntilLastOccurrenceOf('.');

        static if ((_lastDotPos != -1) &&
            isSomeFunction!(mixin(__FUNCTION__[0.._lastDotPos])))
        {
            static immutable _funName = __FUNCTION__[0.._lastDotPos];
        }
        else
        {
            enum _funName = __FUNCTION__;
        }

        alias _fun = mixin(_funName);
         +/

        enum mixinBody =
    "{
    import lu.traits : udaIndexOf;
    import std.traits : ParameterIdentifierTuple, Parameters, isSomeFunction;
    static import kameloso.plugins;

    enum _sentinelGrandchild = 0;

    static if (isSomeFunction!(__traits(parent, __traits(parent, _sentinelGrandchild))))
    {
        alias _fun = __traits(parent, __traits(parent, _sentinelGrandchild));
        enum _funName = __MODULE__ ~ '.' ~ __traits(identifier, _fun);
    }
    else
    {
        enum _funName = __FUNCTION__;
        alias _fun = mixin(_funName);
    }

    alias _funParams = Parameters!_fun;
    alias _paramNames = ParameterIdentifierTuple!_fun;

    static if ((_funParams.length == 1) && is(_funParams[0] : kameloso.plugins.IRCEvent))
    {
        enum _pluginParamName = \"null\";
        enum _eventParamName = _paramNames[0];
    }
    else static if ((_funParams.length == 2) && is(_funParams[1] : kameloso.plugins.IRCEvent))
    {
        static if (is(_funParams[0] : IRCPlugin))
        {
            enum _pluginParamName = _paramNames[0];
            enum _eventParamName = _paramNames[1];
        }
        else
        {
            enum _message = \"`\" ~ _funName ~ \"` mixes in `memoryCorruptionCheck` \" ~
                \"but does itself not have an `IRCPlugin` parameter.\";
            static assert(0, _message);
        }
    }
    else
    {
        enum _message = \"`\" ~ _funName ~ \"` mixes in `memoryCorruptionCheck` \" ~
            \"but does itself not have an `IRCEvent` parameter.\";
        static assert(0, _message);
    }

    static immutable _udaIndex = udaIndexOf!(_fun, kameloso.plugins.IRCEventHandler);

    static if (_udaIndex == -1)
    {
        enum _message = \"`\" ~ _funName ~ \"` mixes in `memoryCorruptionCheck` \" ~
            \"but is not annotated with an `IRCEventHandler`.\";
        static assert(0, _message);
    }

    static immutable _uda = __traits(getAttributes, _fun)[_udaIndex];

    kameloso.plugins.memoryCorruptionCheckImpl(
        mixin(_pluginParamName),
        mixin(_eventParamName),
        _uda,
        _funName,
        assertOnError: " ~ (assertOnError ? "true" : "false") ~ ");
    }";

        return mixinBody;
    }
    else
    {
        return string.init;
    }
}


// memoryCorruptionCheckImpl
/++
    Implementation of the memory corruption check.

    This part can safely be a function instead of a mixin string to share code.

    Params:
        plugin = The plugin or service the event handler function takes as
            parameter, or `null` if it doesn't take one.
        event = The event to check.
        uda = The [IRCEventHandler] UDA to check against.
        functionName = The name of the function being checked.
        assertOnError = Whether to `assert(0)` if an error is detected. If false,
            the function will output any errors to the terminal and then do nothing.

    See_Also:
        [memoryCorruptionCheck]
 +/
version(MemoryCorruptionChecks)
void memoryCorruptionCheckImpl(
    const IRCPlugin plugin,
    const IRCEvent event,
    const IRCEventHandler uda,
    const string functionName,
    const bool assertOnError) /*pure*/ @safe
{
    import std.algorithm.searching : canFind;
    import std.stdio : writefln;

    bool assertionFailed;

    if (!uda.acceptedEventTypes.canFind(event.type, IRCEvent.Type.ANY))
    {
        import lu.conv : toString;
        enum pattern = "[memoryCorruptionCheck] Event handler `%s` was called " ~
            "with an unexpected event type: `%s`";
        writefln(pattern, functionName, event.type.toString);
        assertionFailed = true;
    }

    if (uda.commands.length)
    {
        import std.uni : toLower;

        if (!event.aux[$-1].length)
        {
            enum pattern = "[memoryCorruptionCheck] Event handler `%s` was called " ~
                "but no command word was found in the event's `aux[$-1]`";
            writefln(pattern, functionName);
            assertionFailed = true;
        }

        // Scan the commands array for the command word
        immutable wordLower = event.aux[$-1].toLower();
        bool hit;

        foreach (const command; uda.commands)
        {
            if (command._word == wordLower)
            {
                hit = true;
                break;
            }
        }

        if (!hit)
        {
            enum pattern = "[memoryCorruptionCheck] Event handler `%s` was invoked " ~
                `with a command word "%s" not found in the UDA annotation of it`;
            writefln(pattern, functionName, event.aux[$-1]);
            assertionFailed = true;
        }
    }

    /+
        If there is a channel and we were passed a plugin, check the channel to
        see if it satisfies the UDA's channel policy.

        If plugin is null then we can't check whether or not the channel is in
        the list of home or guest channels.
     +/
    if (event.channel.name.length && (plugin !is null))
    {
        import std.algorithm.searching : canFind;
        import std.typecons : Ternary;

        static auto getTernaryStateString(const Ternary ternary)
        {
            return
                (ternary == Ternary.yes) ? "yes" :
                (ternary == Ternary.no) ? "no" :
                "unknown";
        }

        Ternary isHomeChannel;
        Ternary isGuestChannel;
        bool satisfied;

        if (uda.channelPolicy & ChannelPolicy.home)
        {
            isHomeChannel = plugin.state.bot.homeChannels.canFind(event.channel.name);
            if (isHomeChannel == Ternary.yes) satisfied = true;
        }

        if (!satisfied && (uda.channelPolicy & ChannelPolicy.guest))
        {
            isGuestChannel = plugin.state.bot.guestChannels.canFind(event.channel.name);
            if (isGuestChannel == Ternary.yes) satisfied = true;
        }

        if (!satisfied && (uda.channelPolicy & ChannelPolicy.any))
        {
            satisfied = true;
        }

        if (!satisfied)
        {
            enum pattern = "[memoryCorruptionCheck] Event handler `%s` was called " ~
                "with an event in channel %s that does not satisfy the channel " ~
                "policy of the function; " ~
                "state is isHomeChannel:%s isGuestChannel:%s, " ~
                "policy is home:%s guest:%s any:%s (value:%d)";

            writefln(pattern,
                functionName,
                event.channel.name,
                getTernaryStateString(isHomeChannel),
                getTernaryStateString(isGuestChannel),
                cast(bool)(uda.channelPolicy & ChannelPolicy.home),
                cast(bool)(uda.channelPolicy & ChannelPolicy.guest),
                cast(bool)(uda.channelPolicy & ChannelPolicy.any),
                cast(uint)(uda.channelPolicy));
            assertionFailed = true;
        }
    }

    version(TwitchSupport)
    {
        immutable channelID = event.channel.id;
        immutable subchannelID = event.subchannel.id;
    }
    else
    {
        enum channelID = 0;
        enum subchannelID = 0;
    }

    /+
        Check whether the event carries a subchannel when the function is not
        annotated to accept such.
     +/
    if (!uda._acceptExternal &&
        (event.subchannel.name.length || subchannelID))
    {
        enum pattern = "[memoryCorruptionCheck] Event handler `%s` was called " ~
            "with an event in channel %s:%d subchannel %s:%d, and the function " ~
            "was not annotated to accept events from external channels";

        writefln(pattern,
            functionName,
            event.channel.name,
            channelID,
            event.subchannel.name,
            subchannelID);
        assertionFailed = true;
    }

    if (assertionFailed)
    {
        /+
            Something went wrong and the error was already output to the terminal.
            Flush stdout just in case, then assert if we were asked to.
         +/
        () @trusted  // writeln trusts stdout.flush, so we will too
        {
            import std.stdio : stdout;
            stdout.flush();
        }();

        if (assertOnError)
        {
            enum message = "Memory corruption check detected an inconsistency; " ~
                "see above for details.";
            assert(0, message);
        }
    }
}

///
version(unittest)
{
    // memoryCorruptionCheckTestCustomIndexUDAIndex
    /++
        Test function for [memoryCorruptionCheck] with a custom UDA index.
     +/
    @123
    @456
    @789
    @(IRCEventHandler())
    @123
    private void memoryCorruptionCheckTestCustomIndexUDAIndex(IRCEvent _)
    {
        mixin(memoryCorruptionCheck);
    }

    // memoryCorruptionCheckTestNestedFunction
    /++
        Test function for [memoryCorruptionCheck] with a nested function.
     +/
    @(IRCEventHandler())
    private void memoryCorruptionCheckTestNestedFunction(IRCEvent _)
    {
        void dg()
        {
            mixin(memoryCorruptionCheck);
        }
    }

    // memoryCorruptionCheckTestNoUDA
    /++
        Test function for [memoryCorruptionCheck] with no UDA.
     +/
    version(none)
    private void memoryCorruptionCheckTestNoUDA(IRCEvent _)
    {
        mixin(memoryCorruptionCheck);
    }

    // memoryCorruptionCheckTestNoEventParameter
    /++
        Test function for [memoryCorruptionCheck] with no event parameter.
     +/
    version(none)
    @(IRCEventHandler())
    private void memoryCorruptionCheckTestNoEventParameter()
    {
        mixin(memoryCorruptionCheck);
    }
}


// Selftester
/++
    Helper struct to aid in testing plugins.
 +/
struct Selftester
{
private:
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.messaging : chan;
    import kameloso.thread : CarryingFiber;
    import core.time : seconds;

    /++
        Replaces some tokens in a string with values from the test context.

        Params:
            line = The string to replace tokens in.

        Returns:
            A string with the tokens replaced.
     +/
    auto replaceTokens(const string line)
    {
        import std.array : replace;

        return line
            .replace("${prefix}", plugin.state.coreSettings.prefix)
            .replace("${channel}", this.channelName)
            .replace("${target}", this.targetNickname)
            .replace("${bot}", plugin.state.client.nickname);
    }

public:
    /++
        The plugin to test.
     +/
    IRCPlugin plugin;

    /++
        The name of the channel to test in.
     +/
    string channelName;

    /++
        The nickname of the other bot to test against.
     +/
    string targetNickname;

    /++
        The [kameloso.thread.CarryingFiber|CarryingFiber] to run the test in.
     +/
    CarryingFiber!IRCEvent fiber;

    /++
        The delay between sending messages.
     +/
    static immutable delayBetween = 3.seconds;

    /++
        Sends a message to the other test bot, prepending it with its nickname.

        Params:
            tokenedLine = The message to send.
     +/
    void send(const string tokenedLine)
    in (fiber, "Tried to send a test message with no fiber attached")
    {
        immutable line = replaceTokens(tokenedLine);
        delay(plugin, delayBetween, yield: true);
        chan(plugin.state, channelName, targetNickname ~ ": " ~ line);
    }

    /++
        Sends a message to the other test bot, prepending it with the
        [kameloso.pods.CoreSettings.prefix|command prefix].

        Params:
            tokenedLine = The message to send.
     +/
    void sendPrefixed(const string tokenedLine)
    in (fiber, "Tried to send a prefixed test message with no fiber attached")
    {
        immutable line = replaceTokens(tokenedLine);
        delay(plugin, delayBetween, yield: true);
        chan(plugin.state, channelName, plugin.state.coreSettings.prefix ~ line);
    }

    /++
        Sends a message to the other test bot as-is, without any prefixing.

        Params:
            tokenedLine = The message to send.
     +/
    void sendPlain(const string tokenedLine)
    in (fiber, "Tried to send a plain test message with no fiber attached")
    {
        immutable line = replaceTokens(tokenedLine);
        delay(plugin, delayBetween, yield: true);
        chan(plugin.state, channelName, line);
    }

    /++
        Yields and waits for a response from the other bot.

        If an event is received that is not in the correct channel, and/or does
        not originate from the correct nickname, it is ignored and the fiber
        is yielded again.

     +/
    void awaitReply()
    in (fiber, "Tried to await a test reply with no fiber attached")
    {
        import core.thread.fiber : Fiber;

        do Fiber.yield();
        while (
            (fiber.payload.channel.name != channelName) ||
            (fiber.payload.sender.nickname != targetNickname));
    }

    /++
        Yields and waits for a response from the other bot, then throws if the
        message doesn't match the passed string.

        Params:
            tokenedExpected = The expected string, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.
     +/
    void expect(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    in (fiber, "Tried to await a specific test reply with no fiber attached")
    {
        awaitReply();
        require(tokenedExpected, file, line);
    }

    /++
        Checks that the last message received matches the passed string, and
        throws if it does not.

        Params:
            tokenedExpected = The expected string, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.

        Throws:
            [object.Exception|Exception] if the last message received does not match
            the expected string.
     +/
    void require(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        immutable actual = this.lastMessage(strip: true);
        immutable expected = replaceTokens(tokenedExpected);

        if (actual != expected)
        {
            import std.format : format;
            enum pattern = `Received "%s" does not match expected "%s" (%s:%d)`;
            immutable message = pattern.format(actual, expected, file, line);
            throw new Exception(message);
        }
    }

    /++
        Yields and waits for a response from the other bot, then throws if the
        message head does not match that of the passed string.

        Params:
            tokenedExpected = The expected head, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.
     +/
    void expectHead(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    in (fiber, "Tried to await a specific test head with no fiber attached")
    {
        awaitReply();
        requireHead(tokenedExpected, file, line);
    }

    /++
        Checks that the head of the last message received matches that of the
        passed string, and throws if it does not.

        Params:
            tokenedExpected = The expected head, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.

        Throws:
            [object.Exception|Exception] if the head of the last message received
            does not match the expected string.
     +/
    void requireHead(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        import std.algorithm.searching : startsWith;

        immutable actual = this.lastMessage(strip: true);
        immutable expectedHead = replaceTokens(tokenedExpected);

        if (!actual.startsWith(expectedHead))
        {
            import std.format : format;
            enum pattern = `Received "%s" does not have the expected head "%s" (%s:%d)`;
            immutable message = pattern.format(actual, expectedHead, file, line);
            throw new Exception(message);
        }
    }

    /++
        Yields and waits for a response from the other bot, then throws if the
        message tail does not match that of the passed string.

        Params:
            tokenedExpected = The expected tail, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.
     +/
    void expectTail(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        awaitReply();
        requireTail(tokenedExpected, file, line);
    }

    /++
        Checks that the tail of the last message received contains the passed
        string, and throws if it does not.

        Params:
            tokenedExpected = The expected tail, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.

        Throws:
            [object.Exception|Exception] if the tail of the last message received
            does not match the expected string.
     +/
    void requireTail(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        import std.algorithm.searching : endsWith;

        immutable actual = this.lastMessage(strip: true);
        immutable expectedTail = replaceTokens(tokenedExpected);

        if (!actual.endsWith(expectedTail))
        {
            import std.format : format;
            enum pattern = `Received "%s" does not have the expected tail "%s" (%s:%d)`;
            immutable message = pattern.format(actual, expectedTail, file, line);
            throw new Exception(message);
        }
    }

    /++
        Yields and waits for a response from the other bot, then throws if the
        message body does not contain the passed string.

        Params:
            tokenedExpected = The expected string, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.
     +/
    void expectInBody(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        awaitReply();
        requireInBody(tokenedExpected, file, line);
    }

    /++
        Checks that the body of the last message received contains the passed
        string, and throws if it does not.

        Params:
            tokenedExpected = The expected string, which may include some replace-tokens.
            file = The file the test is in.
            line = The line the test is on.

        Throws:
            [object.Exception|Exception] if the last message received does not
            contain the expected string.
     +/
    void requireInBody(
        const string tokenedExpected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        import std.algorithm.searching : canFind;

        immutable actual = this.lastMessage(strip: true);
        immutable expected = replaceTokens(tokenedExpected);

        if (!actual.canFind(expected))
        {
            import std.format : format;
            enum pattern = `Received "%s" does not contain the expected "%s" (%s:%d)`;
            immutable message = pattern.format(actual, expected, file, line);
            throw new Exception(message);
        }
    }

    /++
        The last message received from the other bot, stripped of effects.
     +/
    auto lastMessage(const bool strip = true)
    {
        if (strip)
        {
            import kameloso.irccolours : stripEffects;
            return fiber.payload.content.stripEffects();
        }
        else
        {
            return fiber.payload.content;
        }
    }

    // triggeredByTimer
    /++
        Whether or not the last fiber invocation was triggered by a timer.
     +/
    auto triggeredByTimer()
    {
        return (fiber.payload == IRCEvent.init);
    }

    // requireTriggeredByTimer
    /++
        Checks that the last fiber invocation was triggered by a timer.

        Params:
            file = The file the test is in.
            line = The line the test is on.

        Throws:
            [object.Exception|Exception] if the fiber was last called due to a
            scheduled timer firing.
     +/
    void requireTriggeredByTimer(
        const string file = __FILE__,
        const size_t line = __LINE__)
    {
        if (!this.triggeredByTimer)
        {
            import kameloso.prettyprint;
            import std.format : format;

            prettyprint(fiber.payload);

            enum pattern = `Last fiber invocation was triggered not by a timer (%s:%d)`;
            immutable message = pattern.format(file, line);
            throw new Exception(message);
        }
    }

    /++
        Synchronises with the target bot by sending a random number and waiting
        for it to be echoed back.
     +/
    void sync()
    in (fiber, "Tried to synchronise with a target bot with no fiber attached")
    {
        import std.conv : text;
        import std.random : uniform;

        immutable id = uniform(0, 1000);
        this.send(text("say ", id));

        do this.awaitReply();
        while (fiber.payload.content != id.text);
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


// PluginRegistrationEntry
/++
    An entry in [registeredPlugins] corresponding to a plugin registered to be
    instantiated on program startup/connect.
 +/
private struct PluginRegistrationEntry
{
    // priority
    /++
        Priority at which to instantiate the plugin. A lower priority makes it
        get instantiated before other plugins.
     +/
    Priority priority;

    // ctor
    /++
        Function pointer to a "constructor"/builder that instantiates the relevant plugin.
     +/
    IRCPlugin function(IRCPluginState) ctor;

    // this
    /++
        Constructor.

        Params:
            priority = [kameloso.plugins.Priority|Priority] at which
                to instantiate the plugin. A lower priority value makes it get
                instantiated before other plugins.
            ctor = Function pointer to a "constructor"/builder that instantiates
                the relevant plugin.
     +/
    this(
        const Priority priority,
        typeof(this.ctor) ctor) pure @safe nothrow @nogc
    {
        this.priority = priority;
        this.ctor = ctor;
    }
}


// registeredPlugins
/++
    Array of registered plugins, represented by [PluginRegistrationEntry]/-ies,
    to be instantiated on program startup/connect.
 +/
private shared PluginRegistrationEntry[] registeredPlugins;


// module constructor
/++
    Module constructor that merely reserves space for [registeredPlugins] to grow into.
 +/
shared static this()
{
    enum initialSize = 64;
    (cast()registeredPlugins).reserve(initialSize);
}


// registerPlugin
/++
    Registers a plugin to be instantiated on program startup/connect by creating
    a [PluginRegistrationEntry] and appending it to [registeredPlugins].

    Params:
        priority = Priority at which to instantiate the plugin. A lower priority
            makes it get instantiated before other plugins.
        ctor = Function pointer to a "constructor"/builder that instantiates
            the relevant plugin.
 +/
void registerPlugin(
    const Priority priority,
    IRCPlugin function(IRCPluginState) ctor)
{
    registeredPlugins ~= PluginRegistrationEntry(
        priority,
        ctor);
}


// instantiatePlugins
/++
    Instantiates all plugins represented by a [PluginRegistrationEntry] in
    [registeredPlugins].

    Plugin modules may register their plugin classes by mixing in [PluginRegistration].

    Params:
        state = The current plugin state on which to base new plugin instances.

    Returns:
        An array of instantiated [kameloso.plugins.IRCPlugin|IRCPlugin]s.
 +/
auto instantiatePlugins(/*const*/ IRCPluginState state)
{
    import std.algorithm.sorting : sort;

    IRCPlugin[] plugins;
    plugins.length = registeredPlugins.length;
    uint i;

    auto sortedPluginRegistrations = registeredPlugins
        .sort!((a,b) => a.priority.value < b.priority.value);

    foreach (registration; sortedPluginRegistrations)
    {
        plugins[i++] = registration.ctor(state);
    }

    return plugins;
}


// PluginRegistration
/++
    Mixes in a module constructor that registers the supplied [IRCPlugin] subclass
    to be instantiated on program startup/connect.

    Params:
        Plugin = Plugin class of module.
        priority = Priority at which to instantiate the plugin. A lower priority
            makes it get instantiated before other plugins. Defaults to `0.priority`.
        module_ = String name of the module. Only used in case an error message is needed.
 +/
mixin template PluginRegistration(
    Plugin,
    Priority priority = 0.priority,
    string module_ = __MODULE__)
{
    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "PluginRegistration");
    }

    // module constructor
    /++
        Mixed-in module constructor that registers the passed [Plugin] class
        to be instantiated on program startup.
     +/
    shared static this()
    {
        import kameloso.plugins : IRCPluginState;

        static if (__traits(compiles, new Plugin(IRCPluginState.init)))
        {
            import kameloso.plugins : registerPlugin;

            static auto ctor(IRCPluginState state)
            {
                return new Plugin(state);
            }

            registerPlugin(priority, &ctor);
        }
        else
        {
            import std.format : format;

            enum pattern = "`%s.%s` constructor does not compile";
            enum message = pattern.format(module_, Plugin.stringof);
            static assert(0, message);
        }
    }
}


// Priority
/++
    Embodies the notion of a priority at which a plugin should be instantiated,
    and as such, the order in which they will be called to handle events.

    This also affects in what order they appear in the configuration file.
 +/
struct Priority
{
    /++
        Numerical priority value. Lower is higher.
     +/
    int value;

    /++
        Helper `opUnary` to allow for `-10.priority`, instead of having to do the
        (more correct) `(-10).priority`.

        Example:
        ---
        mixin PluginRegistration!(MyPlugin, -10.priority);
        ---

        Params:
            op = Operator.

        Returns:
            A new [Priority] with a [Priority.value|value] equal to the negative of this one's.
     +/
    auto opUnary(string op: "-")() const
    {
        return Priority(-value);
    }
}


// priority
/++
    Helper alias to use the proper style guide and still be able to instantiate
    [Priority] instances with UFCS.

    Example:
    ---
    mixin PluginRegistration!(MyPlugin, 50.priority);
    ---
 +/
alias priority = Priority;


import lu.container : MutexedAA;
import kameloso.net : QueryResponse2;
import kameloso.tables : HTTPVerb;
import std.typecons : Flag, No, Yes;

QueryResponse2 sendHTTPRequest(
    IRCPlugin plugin,
    const string url,
    const string caller = __FUNCTION__,
    const string authorisationHeader = string.init,
    const string clientID = string.init,
    const bool verifyPeer = true,
    shared string[string] customHeaders = null,
    /*const*/ HTTPVerb verb = HTTPVerb.get,
    /*const*/ ubyte[] body = null,
    const string contentType = string.init,
    int id = 0,
    const bool recursing = false)
in (Fiber.getThis(), "Tried to call `sendHTTPRequest` from outside a fiber")
in (url.length, "Tried to send an HTTP request without a URL")
{
    import kameloso.net : HTTPQueryException, EmptyResponseException, ErrorJSONException;
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.thread : ThreadMessage;
    import std.algorithm.searching : endsWith;
    import std.concurrency : send;
    import core.time : MonoTime, msecs;

    version(TraceHTTPRequests)
    {
        import kameloso.common : logger;
        import lu.conv : toString;

        enum tracePattern = "%s: <i>%s<t> (%s)";
        logger.tracef(
            tracePattern,
            verb.toString,
            url,
            caller);
    }

    plugin.state.priorityMessages ~= ThreadMessage.shortenReceiveTimeout;

    immutable pre = MonoTime.currTime;
    if (!id) id = plugin.state.querier.responseBucket.uniqueKey;

    plugin.state.querier.nextWorker.send(
        id,
        url,
        authorisationHeader,
        clientID,
        verifyPeer,
        plugin.state.connSettings.caBundleFile,
        customHeaders,
        verb,
        body.idup,
        contentType);

    //delay(plugin, plugin.transient.approximateQueryTime.msecs, yield: true);
    delay(plugin, 200.msecs, yield: true);
    immutable response = plugin.state.querier.awaitResponse(plugin, id);

    if (response.exceptionText.length)
    {
        throw new HTTPQueryException(
            response.exceptionText,
            response.body,
            response.error,
            response.code);
    }

    /*if (response.host.endsWith(".twitch.tv"))
    {
        // Only update approximate query time for Twitch queries (skip those of custom emotes)
        immutable post = MonoTime.currTime;
        immutable diff = (post - pre);
        immutable msecs_ = diff.total!"msecs";
        averageApproximateQueryTime(plugin, msecs_);
    }*/

    if (response == QueryResponse2.init)
    {
        throw new EmptyResponseException("No response");
    }
    else if (response.code < 200)
    {
        throw new HTTPQueryException(
            response.error,
            response.body,
            response.error,
            response.code);
    }
    else if ((response.code >= 500) && !recursing)
    {
        return sendHTTPRequest(
            plugin: plugin,
            url: url,
            caller: caller,
            authorisationHeader: authorisationHeader,
            clientID: clientID,
            verifyPeer: verifyPeer,
            customHeaders: customHeaders,
            verb: verb,
            body: body,
            contentType: contentType,
            id: id,
            recursing: true);
    }
    else if (response.code >= 400)
    {
        import std.format : format;
        import std.json : JSONException;

        try
        {
            import lu.json : getOrFallback;
            import lu.string : unquoted;
            import std.json : JSONValue, parseJSON;
            import std.string : chomp;

            // {"error":"Unauthorized","status":401,"message":"Must provide a valid Client-ID or OAuth token"}
            /+
            {
                "error": "Unauthorized",
                "message": "Client ID and OAuth token do not match",
                "status": 401
            }
            {
                "error": "Unknown Emote Set",
                "error_code": 70441,
                "status": "Not Found",
                "status_code": 404
            }
            {
                "message": "user not found"
            }
            {
                "error": "Unauthorized",
                "message": "Invalid OAuth token",
                "status": 401
            }
            {
                "error": "Unauthorized",
                "message": "Missing scope: moderator:manage:chat_messages",
                "status": 401
            }
             +/

            enum genericErrorString = "Error";
            enum genericErrorMessageString = "An unspecified error occurred";

            immutable json = parseJSON(response.body);
            uint code = response.code;
            string status;
            string message;

            if (immutable statusCodeJSON = "status_code" in json)
            {
                code = cast(uint)(*statusCodeJSON).integer;
                status = json.getOrFallback("status", genericErrorString);
                message = json.getOrFallback("error", genericErrorMessageString);
            }
            else if (immutable errorJSON = "error" in json)
            {
                status = genericErrorString;
                message = (*errorJSON).str;
            }
            else if (immutable statusJSON = "status" in json)
            {
                import std.json : JSONException;

                code = cast(uint)(*statusJSON).integer;
                status = json.getOrFallback("status", genericErrorString);
                message = json.getOrFallback("error", genericErrorMessageString);
            }
            else if (immutable messageJSON = "message" in json)
            {
                status = genericErrorString;
                message = (*messageJSON).str;
            }
            else
            {
                version(PrintStacktraces)
                {
                    if (!plugin.state.coreSettings.headless)
                    {
                        import std.stdio : stdout, writeln;
                        writeln(json.toPrettyString);
                        stdout.flush();
                    }
                }

                status = genericErrorString;
                message = genericErrorMessageString;
            }

            enum pattern = "%3d %s: %s";
            immutable exceptionMessage = pattern.format(
                code,
                status.chomp.unquoted,
                message.chomp.unquoted);

            throw new ErrorJSONException(exceptionMessage, json);
        }
        catch (JSONException e)
        {
            import kameloso.string : doublyBackslashed;

            version(PrintStacktraces)
            {
                if (!plugin.state.coreSettings.headless)
                {
                    import std.stdio : stdout, writeln;
                    writeln(response.body);
                    stdout.flush();
                }
            }

            throw new HTTPQueryException(
                e.msg,
                response.body,
                response.error,
                response.code,
                e.file.doublyBackslashed,
                e.line);
        }
    }

    return response;
}

private import kameloso.net : Querier;

auto awaitResponse(Querier querier, IRCPlugin plugin, const int id)
in (Fiber.getThis(), "Tried to call `awaitResponse` from outside a fiber")
{
    //import std.datetime.systime : Clock;
    import core.time : MonoTime, seconds;

    /*version(BenchmarkHTTPRequests)
    {
        import std.stdio : writefln;
        uint misses;
    }*/

    //immutable startTimeInUnix = Clock.currTime.toUnixTime();
    //double accumulatingTime = plugin.transient.approximateQueryTime;
    immutable start = MonoTime.currTime;

    while (true)
    {
        immutable hasResponse = querier.responseBucket.has(id);

        if (!hasResponse)
        {
            // Querier errored or otherwise gave up
            // No need to remove the id, it's not there
            return QueryResponse2.init;
        }

        //auto response = plugin.responseBucket[id];  // potential range error due to TOCTTOU
        immutable response = querier.responseBucket.get(id, QueryResponse2.init);

        if (response == QueryResponse2.init)
        {
            import kameloso.plugins.common.scheduling : delay;
            import kameloso.constants : Timeout;
            import core.time : msecs;

            /*immutable nowInUnix = Clock.currTime.toUnixTime();

            if ((nowInUnix - startTimeInUnix) >= Timeout.Integers.httpGETSeconds)
            {
                querier.responseBucket.remove(id);
                return QueryResponse2.init;
            }*/

            immutable now = MonoTime.currTime;

            if ((now - start) >= Timeout.httpGET)
            {
                querier.responseBucket.remove(id);
                return QueryResponse2.init;
            }

            /*version(BenchmarkHTTPRequests)
            {
                ++misses;
                immutable oldAccumulatingTime = accumulatingTime;
            }*/

            // Miss; fired too early, there is no response available yet
            /*alias QC = TwitchPlugin.QueryConstants;
            accumulatingTime *= QC.growthMultiplier;
            immutable briefWait = cast(long)(accumulatingTime / QC.retryTimeDivisor);

            version(BenchmarkHTTPRequests)
            {
                enum pattern = "MISS %d! elapsed: %s | old: %d --> new: %d | wait: %d";
                immutable delta = (nowInUnix - startTimeInUnix);
                writefln(
                    pattern,
                    misses,
                    delta,
                    cast(long)oldAccumulatingTime,
                    cast(long)accumulatingTime,
                    cast(long)briefWait);
            }*/

            static immutable briefWait = 200.msecs;
            delay(plugin, briefWait, yield: true);
            continue;
        }
        else
        {
            /*version(BenchmarkHTTPRequests)
            {
                enum pattern = "HIT! elapsed: %s | response: %s | misses: %d";
                immutable now = MonoTime.currTime;
                immutable delta = (now - start);
                writefln(pattern, delta, response.msecs, misses);
            }*/

            querier.responseBucket.remove(id);
            return response;
        }
    }
}

/++
    Contains the definition of an [IRCPlugin] and its ancilliaries, as well as
    mixins to fully implement it.

    Event handlers can then be module-level functions, annotated with
    [dialect.defs.IRCEvent.Type]s.

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
        Metadata about a [kameloso.plugins.common.core.IRCEventHandler.Command]- and/or
        [kameloso.plugins.common.core.IRCEventHandler.Regex]-annotated event handler.

        See_Also:
            [commands]
     +/
    static struct CommandMetadata
    {
        // description
        /++
            Description about what the command does, in natural language.
         +/
        string description;

        // syntax
        /++
            Syntax on how to use the command.
         +/
        string syntax;

        // hidden
        /++
            Whether or not the command should be hidden from view (but still
            possible to trigger).
         +/
        bool hidden;
    }

    // state
    /++
        An [kameloso.plugins.common.core.IRCPluginState] instance containing
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
    void deserialiseConfigFrom(const string configFile,
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

    // start
    /++
        Called when connection has been established, to start the plugin;
        its would-be constructor.
     +/
    void start() @system;

    // printSettings
    /++
        Called when we want a plugin to print its
        [kameloso.plugins.common.core.Settings]-annotated struct of settings.
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
    Mixin that fully implements an [kameloso.plugins.common.core.IRCPlugin].

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

    See_Also:
        [kameloso.plugins.common.core.IRCPlugin]
 +/
version(WithPlugins)
mixin template IRCPluginImpl(Flag!"debug_" debug_ = No.debug_, string module_ = __MODULE__)
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

    static if (__traits(compiles, this.hasIRCPluginImpl))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("IRCPluginImpl", typeof(this).stringof));
    }
    else
    {
        private enum hasIRCPluginImpl = true;
    }

    @safe:

    // isEnabled
    /++
        Introspects the current plugin, looking for a
        [kameloso.plugins.common.core.Settings]-annotated struct
        member that has a bool annotated with [kameloso.plugins.common.core.Enabler],
        which denotes it as the bool that toggles a plugin on and off.

        It then returns its value.

        Returns:
            `true` if the plugin is deemed enabled (or cannot be disabled),
            `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        import lu.traits : getSymbolsByUDA;
        import std.traits : hasUDA;

        bool retval = true;

        top:
        foreach (immutable i, const ref member; this.tupleof)
        {
            static if (hasUDA!(this.tupleof[i], Settings) ||
                (is(typeof(this.tupleof[i]) == struct) &&
                hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                static if (getSymbolsByUDA!(typeof(this.tupleof[i]), Enabler).length)
                {
                    foreach (immutable n, const submember; this.tupleof[i].tupleof)
                    {
                        static if (hasUDA!(this.tupleof[i].tupleof[n], Enabler))
                        {
                            import std.traits : Unqual;
                            alias ThisEnabler = Unqual!(typeof(this.tupleof[i].tupleof[n]));

                            static if (!is(ThisEnabler == bool))
                            {
                                import std.format : format;

                                alias UnqualThis = Unqual!(typeof(this));
                                enum pattern = "`%s` has a non-bool `Enabler`: `%s %s`";

                                static assert(0, pattern.format(UnqualThis.stringof,
                                    ThisEnabler.stringof,
                                    __traits(identifier, this.tupleof[i].tupleof[n])));
                            }

                            retval = submember;
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
        the annotated required [kameloso.plugins.common.core.Permissions] of the
        handler in question. Wrapper function that merely calls
        [kameloso.plugins.common.core.IRCPluginImpl.allowImpl]. The point behind it is to make something
        that can be overridden and still allow it to call the original logic (below).

        Params:
            event = [dialect.defs.IRCEvent] to allow, or not.
            permissionsRequired = Required [kameloso.plugins.common.core.Permissions]
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
        the annotated [kameloso.plugins.common.core.Permissions] of the
        handler in question. Implementation function.

        Params:
            event = [dialect.defs.IRCEvent] to allow, or not.
            permissionsRequired = Required [kameloso.plugins.common.core.Permissions]
                of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.

        See_Also:
            [kameloso.plugins.common.core.filterSender]
     +/
    private FilterResult allowImpl(const ref IRCEvent event, const Permissions permissionsRequired)
    {
        import kameloso.plugins.common.core : filterSender;
        import std.typecons : Flag, No, Yes;

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
        Pass on the supplied [dialect.defs.IRCEvent] to
        [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl].

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging [onEventImpl] for the
        actual dirty work.

        Params:
            event = Parsed [dialect.defs.IRCEvent] to pass onto
                [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl].

        See_Also:
            [kameloso.plugins.common.core.IRCPluginImpl.onEventImpl]
     +/
    pragma(inline, true)
    override public void onEvent(const ref IRCEvent event) @system
    {
        onEventImpl(event);
    }

    // onEventImpl
    /++
        Pass on the supplied [dialect.defs.IRCEvent] to module-level functions
        annotated with the matching [dialect.defs.IRCEvent.Type]s.

        It also does checks for [kameloso.plugins.common.core.ChannelPolicy],
        [kameloso.plugins.common.core.Permissions], [kameloso.plugins.common.core.PrefixPolicy],
        [kameloso.plugins.common.core.IRCEventHandler.Command], [kameloso.plugins.common.core.IRCEventHandler.Regex]
        etc; where such is applicable.

        Params:
            origEvent = Parsed [dialect.defs.IRCEvent] to dispatch to event handlers.
     +/
    private void onEventImpl(/*const*/ IRCEvent origEvent) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.common.core : IRCEventHandler;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;

        bool udaSanityCheck(alias fun)()
        {
            alias handlerAnnotations = getUDAs!(fun, IRCEventHandler);

            static if (handlerAnnotations.length > 1)
            {
                import std.format;

                enum pattern = "`%s` is annotated with more than one `IRCEventHandler`";
                static assert(0, pattern.format(fullyQualifiedName!fun));
            }

            static immutable uda = handlerAnnotations[0];

            static foreach (immutable type; uda.given.acceptedEventTypes)
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

                static if (uda.given.commands.length || uda.given.regexes.length)
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

            static if (uda.given.commands.length)
            {
                import lu.string : contains;

                static foreach (immutable command; uda.given.commands)
                {
                    static if (!command.given.word.length)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Command` with an empty trigger word";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (command.given.word.contains(' '))
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Command` whose trigger " ~
                            `word "%s" contains a space character`;
                        static assert(0, pattern.format(fullyQualifiedName!fun, command.given.word));
                    }
                }
            }

            static if (uda.given.regexes.length)
            {
                static foreach (immutable regex; uda.given.regexes)
                {
                    static if (!regex.given.expression.length)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                            "listening for a `Regex` with an empty expression";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                }
            }

            return true;
        }

        void call(alias fun)(ref IRCEvent event)
        {
            import std.meta : AliasSeq, staticMap;
            import std.traits : Parameters, Unqual, arity;

            alias Params = staticMap!(Unqual, Parameters!fun);

            static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                is(Params : AliasSeq!(IRCPlugin, IRCEvent)))
            {
                static if (!is(Parameters!fun[1] == const))
                {
                    import std.traits : ParameterStorageClass, ParameterStorageClassTuple;

                    alias SC = ParameterStorageClass;
                    alias paramClasses = ParameterStorageClassTuple!fun;

                    static if ((paramClasses[1] & SC.ref_) ||
                        (paramClasses[1] & SC.out_))
                    {
                        import std.format : format;

                        enum pattern = "`%s` takes an `IRCEvent` of an unsupported storage class; " ~
                            "may not be mutable `ref` or `out`";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                }

                fun(this, event);
            }
            else static if (is(Params : AliasSeq!(typeof(this))) ||
                is(Params : AliasSeq!IRCPlugin))
            {
                fun(this);
            }
            else static if (is(Params : AliasSeq!IRCEvent))
            {
                static if (!is(Parameters!fun[0] == const))
                {
                    import std.traits : ParameterStorageClass, ParameterStorageClassTuple;

                    alias SC = ParameterStorageClass;
                    alias paramClasses = ParameterStorageClassTuple!fun;

                    static if ((paramClasses[0] & SC.ref_) ||
                        (paramClasses[0] & SC.out_))
                    {
                        import std.format : format;

                        enum pattern = "`%s` takes an `IRCEvent` of an unsupported storage class; " ~
                            "may not be mutable `ref` or `out`";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
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
                static assert(0, "`%s` has an unsupported function signature: `%s`"
                    .format(fullyQualifiedName!fun, typeof(fun).stringof));
            }
        }

        enum NextStep
        {
            unset,
            continue_,
            repeat,
            return_,
        }

        /++
            Process a function.
         +/
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

            if (!event.channel.length)
            {
                // it is a non-channel event, like an IRCEvent.Type.QUERY
            }
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
                else /*if (channelPolicy == ChannelPolicy.any)*/
                {
                    enum channelMatch = true;
                }

                if (!channelMatch)
                {
                    static if (verbose)
                    {
                        writeln("   ...ignore non-matching channel ", event.channel);
                    }

                    // channel policy does not match
                    return NextStep.continue_;  // next fun
                }
            }

            static if (uda.given.commands.length || uda.given.regexes.length)
            {
                import lu.string : strippedLeft;

                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    // Event has a Command or a Regex set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }

                // Snapshot content and aux for later restoration
                immutable origContent = event.content;
                immutable origAux = event.aux;

                /// Whether or not a Command or Regex matched.
                bool commandMatch;
            }

            // Evaluate each Command UDAs with the current event
            static if (uda.given.commands.length)
            {
                static foreach (immutable command; uda.given.commands)
                {{
                    if (!commandMatch)
                    {
                        static if (verbose)
                        {
                            writefln(`   ...Command "%s"`, command.given.word);
                        }

                        bool policyMismatch;

                        if (!event.prefixPolicyMatches!verbose
                            (command.given.policy, state.client, state.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("   ...policy doesn't match; continue next Command");
                            }

                            policyMismatch = true;
                        }

                        if (policyMismatch)
                        {
                            // Do nothing, proceed to next command
                        }
                        else
                        {
                            import lu.string : strippedLeft;
                            import std.algorithm.comparison : equal;
                            import std.typecons : No, Yes;
                            import std.uni : asLowerCase, toLower;

                            // If we don't strip left as a separate step, nom won't alter
                            // event.content by ref (as it will be an rvalue).
                            event.content = event.content.strippedLeft;

                            immutable thisCommand = event.content
                                .nom!(Yes.inherit, Yes.decode)(' ');
                            enum lowerWord = command.given.word.toLower;

                            if (thisCommand.asLowerCase.equal(lowerWord))
                            {
                                static if (verbose)
                                {
                                    writeln("   ...command matches!");
                                }

                                event.aux = thisCommand;
                                commandMatch = true;  // breaks the foreach
                            }
                            else
                            {
                                // Restore content to pre-nom state
                                event.content = origContent;
                            }
                        }
                    }
                }}
            }

            // Iff no match from Commands, evaluate Regexes
            static if (uda.given.regexes.length)
            {
                static foreach (immutable regex; uda.given.regexes)
                {{
                    // This reuses previous commandMatch, so a matched Command
                    // will prevent Regex lookups.

                    if (!commandMatch)
                    {
                        static if (verbose)
                        {
                            writeln("   ...Regex: `", regex.given.expression, "`");
                        }

                        bool policyMismatch;

                        if (!event.prefixPolicyMatches!verbose
                            (regex.given.policy, state.client, state.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("   ...policy doesn't match; continue next Regex");
                            }

                            policyMismatch = true;
                        }

                        if (policyMismatch)
                        {
                            // Do nothing, proceed to next regex
                        }
                        else
                        {
                            try
                            {
                                import std.regex : matchFirst;

                                const hits = event.content.matchFirst(regex.given.engine);

                                if (!hits.empty)
                                {
                                    static if (verbose)
                                    {
                                        writeln("   ...expression matches!");
                                    }

                                    event.aux = hits[0];
                                    commandMatch = true;  // breaks the foreach
                                }
                                else
                                {
                                    static if (verbose)
                                    {
                                        writefln(`   ...matching "%s" against expression "%s" failed.`,
                                            event.content, regex.given.expression);
                                    }
                                }
                            }
                            catch (Exception e)
                            {
                                static if (verbose)
                                {
                                    writeln("   ...Regex exception: ", e.msg);
                                    version(PrintStacktraces) writeln(e);
                                }
                            }
                        }
                    }
                }}
            }

            static if (uda.given.commands.length || uda.given.regexes.length)
            {
                if (!commandMatch)
                {
                    // {Command,Regex} exist but neither matched; skip
                    static if (verbose)
                    {
                        writeln("   ...no Command nor Regex match; continue funloop");
                    }

                    return NextStep.continue_; // next function
                }

                scope(exit)
                {
                    if (commandMatch)
                    {
                        // Restore content and aux as they were definitely altered
                        event.content = origContent;
                        event.aux = origAux;
                    }
                }
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

                /*if (result == FilterResult.pass)
                {
                    // Drop down
                }
                else*/ if (result == FilterResult.whois)
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

                // Make a runtime decision on whether to return or not
                if (rtToReturn != NextStep.unset) return rtToReturn;
            }

            static if (verbose)
            {
                writeln("   ...calling!");
            }

            call!fun(event);

            static if (uda.given.chainable)
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

        /// Sanitise and try again once on UTF/Unicode exceptions
        static void sanitizeEvent(ref IRCEvent event)
        {
            import std.encoding : sanitize;
            import std.range : only;

            event.raw = sanitize(event.raw);
            event.channel = sanitize(event.channel);
            event.content = sanitize(event.content);
            event.aux = sanitize(event.aux);
            event.tags = sanitize(event.tags);
            event.errors ~= event.errors.length ? ". Sanitized" : "Sanitized";

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

        /// Wrap all the functions in the passed `funlist` in try-catch blocks.
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
                        // only repeat once so we don't endlessly loop
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
                    /*logger.warningf("tryProcess some exception on %s: %s",
                        __traits(identifier, fun), e.msg);*/

                    import std.utf : UTFException;
                    import core.exception : UnicodeException;

                    immutable isRecoverableException =
                        (cast(UnicodeException)e !is null) ||
                        (cast(UTFException)e !is null);

                    if (!isRecoverableException) throw e;

                    sanitizeEvent(event);

                    // Copy-paste, not much we can do otherwise
                    immutable next = process!fun(event);

                    if (next == NextStep.continue_)
                    {
                        continue;
                    }
                    else if (next == NextStep.repeat)
                    {
                        // only repeat once so we don't endlessly loop
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
        import std.traits : EnumMembers, hasUDA;

        this.state = state;
        this.state.awaitingFibers = state.awaitingFibers.dup;
        this.state.awaitingFibers.length = EnumMembers!(IRCEvent.Type).length;
        this.state.awaitingDelegates = state.awaitingDelegates.dup;
        this.state.awaitingDelegates.length = EnumMembers!(IRCEvent.Type).length;
        this.state.replays = state.replays.dup;
        this.state.hasReplays = state.hasReplays;
        this.state.repeats = state.repeats.dup;
        this.state.scheduledFibers = state.scheduledFibers.dup;
        this.state.scheduledDelegates = state.scheduledDelegates.dup;

        foreach (immutable i, ref member; this.tupleof)
        {
            static if (isSerialisable!member)
            {
                static if (hasUDA!(this.tupleof[i], Resource))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(state.settings.resourceDirectory, member)
                        .expandTilde;
                }
                else static if (hasUDA!(this.tupleof[i], Configuration))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(state.settings.configDirectory, member)
                        .expandTilde;
                }
            }
        }

        static if (__traits(compiles, .initialise))
        {
            import lu.traits : TakesParams;

            static if (TakesParams!(.initialise, typeof(this)))
            {
                .initialise(this);
            }
            else
            {
                import std.format : format;
                static assert(0, "`%s.initialise` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.initialise).stringof));
            }
        }
    }

    // postprocess
    /++
        Lets a plugin modify an [dialect.defs.IRCEvent] while it's begin
        constructed, before it's finalised and passed on to be handled.

        Params:
            event = The [dialect.defs.IRCEvent] in flight.
     +/
    override public void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, .postprocess))
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
                    static assert(0, ("`%s.postprocess` does not take its " ~
                        "`IRCEvent` parameter by `ref`")
                            .format(module_,));
                }
            }
            else
            {
                import std.format : format;
                static assert(0, "`%s.postprocess` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.postprocess).stringof));
            }
        }
    }

    // initResources
    /++
        Writes plugin resources to disk, creating them if they don't exist.
     +/
    override public void initResources() @system
    {
        static if (__traits(compiles, .initResources))
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
                static assert(0, "`%s.initResources` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.initResources).stringof));
            }
        }
    }

    // deserialiseConfigFrom
    /++
        Loads configuration for this plugin from disk.

        This does not proxy a call but merely loads configuration from disk for
        all struct variables annotated [kameloso.plugins.common.core.Settings].

        "Returns" two associative arrays for missing entries and invalid
        entries via its two out parameters.

        Params:
            configFile = String of the configuration file to read.
            missingEntries = Out reference of an associative array of string arrays
                of expected configuration entries that were missing.
            invalidEntries = Out reference of an associative array of string arrays
                of unexpected configuration entries that did not belong.
     +/
    override public void deserialiseConfigFrom(const string configFile,
        out string[][string] missingEntries,
        out string[][string] invalidEntries)
    {
        import kameloso.config : readConfigInto;
        import lu.meld : MeldingStrategy, meldInto;
        import std.traits : hasUDA;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
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
        Change a plugin's [kameloso.plugins.common.core.Settings]-annotated
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
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (hasUDA!(this.tupleof[i], Settings) ||
                hasUDA!(typeof(this.tupleof[i]), Settings)))
            {
                success = symbol.setMemberByName(setting, value);
                if (success) break;
            }
        }

        return success;
    }

    // printSettings
    /++
        Prints the plugin's [kameloso.plugins.common.core.Settings]-annotated settings struct.
     +/
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
            sink = Reference [std.array.Appender] to fill with plugin-specific
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

                // Warn here but nowhere else about this.
                static assert(0, "`%s` is annotated `@Settings` but is not a `struct`"
                    .format(fullyQualifiedName!(this.tupleof[i])));
            }
        }

        return didSomething;
    }

    // start
    /++
        Runs early after-connect routines, immediately after connection has been
        established.
     +/
    override public void start() @system
    {
        static if (__traits(compiles, .start))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (TakesParams!(.start, typeof(this)))
            {
                .start(this);
            }
            else
            {
                import std.format : format;
                static assert(0, "`%s.start` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.start).stringof));
            }
        }
    }

    // teardown
    /++
        De-initialises the plugin.
     +/
    override public void teardown() @system
    {
        static if (__traits(compiles, .teardown))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (TakesParams!(.teardown, typeof(this)))
            {
                .teardown(this);
            }
            else
            {
                import std.format : format;
                static assert(0, "`%s.teardown` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.teardown).stringof));
            }
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
        import std.traits : packageName;

        mixin("static import thisModule = " ~ module_ ~ ";");

        enum moduleNameString = __traits(identifier, thisModule);

        enum cutoutModuleName = ()
        {
            static if (moduleNameString == "base")
            {
                import std.string : indexOf;

                // Assumes a fqn of "kameloso.plugins.*.base"

                string slice = module_;
                immutable firstDot = slice.indexOf('.');
                if (firstDot == -1) return slice;

                slice = slice[firstDot+1..$];
                immutable secondDot = slice.indexOf('.');
                if (secondDot == -1) return slice;

                slice = slice[secondDot+1..$];
                immutable thirdDot = slice.indexOf('.');
                if (thirdDot == -1) return slice;

                return slice[0..thirdDot];
            }
            else
            {
                return moduleNameString;
            }
        }().idup;

        return cutoutModuleName;
    }

    // commands
    /++
        Collects all [kameloso.plugins.common.core.IRCEventHandler.Command] command words and
        [kameloso.plugins.common.core.IRCEventHandler.Regex] regex expressions
        that this plugin offers at compile time, then at runtime returns them
        alongside their [Description]s and their visibility, as an associative
        array of [kameloso.plugins.common.core.IRCPlugin.CommandMetadata]s
        keyed by command name strings.

        Returns:
            Associative array of tuples of all [kameloso.plugins.common.core.Descriptions]
            and whether they are hidden, keyed by [kameloso.plugins.common.core.IRCEventHandler.Command.word]s
            and [kameloso.plugins.common.core.IRCEventHandler.Regex.expression]s.
     +/
    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import kameloso.plugins.common.core : IRCEventHandler;
            import lu.traits : getSymbolsByUDA;
            import std.meta : AliasSeq, Filter;
            import std.traits : getUDAs, hasUDA, isSomeFunction;

            mixin("static import thisModule = " ~ module_ ~ ";");

            alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEventHandler));

            IRCPlugin.CommandMetadata[string] commandAA;

            foreach (fun; funs)
            {
                static immutable uda = getUDAs!(fun, IRCEventHandler)[0];

                static foreach (immutable command; uda.given.commands)
                {{
                    static if (command.given.description.length)
                    {
                        enum key = command.given.word;
                        commandAA[key] = IRCPlugin.CommandMetadata
                            (command.given.description, command.given.syntax, command.given.hidden);

                        static if (command.given.policy == PrefixPolicy.nickname)
                        {
                            static if (command.given.syntax.length)
                            {
                                // Prefix the command with the bot's nickname,
                                // as that's how it's actually used.
                                commandAA[key].syntax = "$nickname: " ~ command.given.syntax;
                            }
                            else
                            {
                                // Define an empty nickname: command syntax
                                // to give hint about the nickname prefix
                                commandAA[key].syntax = "$nickname: $command";
                            }
                        }
                    }
                    else static if (!command.given.hidden)
                    {
                        import std.format : format;
                        import std.traits : fullyQualifiedName;
                        pragma(msg, "Warning: `%s` non-hidden command word \"%s\" is missing a description"
                            .format(fullyQualifiedName!fun, command.given.word));
                    }
                }}

                static foreach (immutable regex; uda.given.regexes)
                {{
                    static if (regex.description.length)
                    {
                        enum key = `r"` ~ regex.expression ~ `"`;
                        commandAA[key] = IRCPlugin.CommandMetadata(regex.description, regex.hidden);

                        static if (regex.given.policy == PrefixPolicy.direct)
                        {
                            commandAA[key].syntax = regex.given.expression;
                        }
                        else static if (regex.given.policy == PrefixPolicy.prefix)
                        {
                            commandAA[key].syntax = "$prefix" ~ regex.given.expression;
                        }
                        else static if (regex.given.policy == PrefixPolicy.nickname)
                        {
                            commandAA[key].syntax = "$nickname: " ~ regex.given.expression;
                        }
                    }
                    else static if (!regex.given.hidden)
                    {
                        import std.format : format;
                        import std.traits : fullyQualifiedName;
                        pragma(msg, "Warning: `%s` non-hidden expression \"%s\" is missing a description"
                            .format(fullyQualifiedName!fun, regex.given.expression));
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

    // reload
    /++
        Reloads the plugin, where such makes sense.

        What this means is implementation-defined.
     +/
    override public void reload() @system
    {
        static if (__traits(compiles, .reload))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (TakesParams!(.reload, typeof(this)))
            {
                .reload(this);
            }
            else
            {
                import std.format : format;
                static assert(0, "`%s.reload` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.reload).stringof));
            }
        }
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
        static if (__traits(compiles, .onBusMessage))
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
                static assert(0, "`%s.onBusMessage` has an unsupported function signature: `%s`"
                    .format(module_, typeof(.onBusMessage).stringof));
            }
        }
    }
}

@system
version(WithPlugins)
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

    If it doesn't match, the [onEvent] routine shall consider the UDA as not
    matching and continue with the next one.

    Params:
        verbose = Whether or not to output verbose debug information to the local terminal.
        event = Reference to the mutable [dialect.defs.IRCEvent] we're considering.
        policy = Policy to apply.
        client = [dialect.defs.IRCClient] of the calling [IRCPlugin]'s [IRCPluginState].
        prefix = The prefix as set in the program-wide settings.

    Returns:
        `true` if the message is in a context where the event matches the
        `policy`, `false` if not.
 +/
bool prefixPolicyMatches(bool verbose = false)
    (ref IRCEvent event,
    const PrefixPolicy policy,
    const IRCClient client,
    const string prefix)
{
    import kameloso.common : stripSeparatedPrefix;
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
        event = [dialect.defs.IRCEvent] to filter.
        permissionsRequired = The [Permissions] context in which this user should be filtered.
        preferHostmasks = Whether to rely on hostmasks for user identification,
            or to use services account logins, which need to be issued WHOIS
            queries to divine.

    Returns:
        A [FilterResult] saying the event should `pass`, `fail`, or that more
        information about the sender is needed via a WHOIS call.
 +/
FilterResult filterSender(const ref IRCEvent event,
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

public:
    // client
    /++
        The current [dialect.defs.IRCClient], containing information pertaining
        to the bot in the context of a client connected to an IRC server.
     +/
    IRCClient client;

    // server
    /++
        The current [dialect.defs.IRCServer], containing information pertaining
        to the bot in the context of an IRC server.
     +/
    IRCServer server;

    // bot
    /++
        The current [kameloso.kameloso.IRCBot], containing information pertaining
        to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    // settings
    /++
        The current program-wide [kameloso.kameloso.CoreSettings].
     +/
    CoreSettings settings;

    // connSettings
    /++
        The current program-wide [kameloso.kameloso.ConnectionSettings].
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

    // replays
    /++
        Queued [dialect.defs.IRCEvent]s to replay.

        The main loop iterates this after processing all on-event functions so
        as to know what nicks the plugin wants a WHOIS for. After the WHOIS
        response returns, the event bundled with the [Replay] will be replayed.
     +/
    Replay[][string] replays;

    // hasReplays
    /++
        Whether or not [replays] has elements (i.e. is not empty).
     +/
    bool hasReplays;

    // repeats
    /++
        This plugin's array of [Repeat]s to let the main loop play back.
     +/
    Repeat[] repeats;

    // awaitingFibers
    /++
        The list of awaiting [core.thread.fiber.Fiber]s, keyed by
        [dialect.defs.IRCEvent.Type].
     +/
    Fiber[][] awaitingFibers;

    // awaitingDelegates
    /++
        The list of awaiting `void delegate(const IRCEvent)` delegates, keyed by
        [dialect.defs.IRCEvent.Type].
     +/
    void delegate(const IRCEvent)[][] awaitingDelegates;

    // scheduledFibers
    /++
        The list of scheduled [core.thread.fiber.Fiber], UNIX time tuples.
     +/
    ScheduledFiber[] scheduledFibers;

    // scheduledDelegates
    /++
        The list of scheduled delegate, UNIX time tuples.
     +/
    ScheduledDelegate[] scheduledDelegates;

    // nextScheduledTimetamp
    /++
        The UNIX timestamp of when the next scheduled
        [kameloso.thread.ScheduledFiber] or delegate should be triggered.
     +/
    long nextScheduledTimestamp;

    // updateSchedule
    /++
        Updates the saved UNIX timestamp of when the next scheduled
        [core.thread.fiber.Fiber] or delegate should be triggered.
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

    // botUpdated
    /++
        Whether or not [bot] was altered. Must be reset manually.
    +/
    bool botUpdated;

    // clientUpdated
    /++
        Whether or not [client] was altered. Must be reset manually.
     +/
    bool clientUpdated;

    // serverUpdated
    /++
        Whether or not [server] was altered. Must be reset manually.
     +/
    bool serverUpdated;

    // settingsUpdated
    /++
        Whether or not [settings] was altered. Must be reset manually.
     +/
    bool settingsUpdated;

    // abort
    /++
        Pointer to the global abort flag.
     +/
    bool* abort;
}


// Replay
/++
    A queued event to be replayed upon a WHOIS query response.

    It is abstract; all objects must be of a concrete [ReplayImpl] type.

    See_Also:
        [ReplayImpl]
 +/
abstract class Replay
{
    // caller
    /++
        Name of the caller function or similar context.
     +/
    string caller;

    // event
    /++
        Stored [dialect.defs.IRCEvent] to replay.
     +/
    IRCEvent event;

    // permissionsRequired
    /++
        [Permissions] required by the function to replay.
     +/
    Permissions permissionsRequired;

    // when
    /++
        When this request was issued.
     +/
    long when;

    // trigger
    /++
        Replay the stored event.
     +/
    void trigger();

    /++
        Creates a new [Replay] with a timestamp of the current time.
     +/
    this() @safe
    {
        import std.datetime.systime : Clock;
        when = Clock.currTime.toUnixTime;
    }
}


// ReplayImpl
/++
    Implementation of the notion of a function call with a bundled payload
    [dialect.defs.IRCEvent], used to replay a previous event.

    It functions like a Command pattern object in that it stores a payload and
    a function pointer, which we queue and issue a WHOIS query. When the response
    returns we trigger the object and the original [dialect.defs.IRCEvent]
    is replayed.

    Params:
        F = Some function type.
        Payload = Optional payload type.

    See_Also:
        [Replay]
        [replay]
 +/
private final class ReplayImpl(F, Payload = typeof(null)) : Replay
{
@safe:
    // fn
    /++
        Stored function pointer/delegate.
     +/
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        // payload
        /++
            Command payload aside from the [dialect.defs.IRCEvent].
         +/
        Payload payload;

        /++
            Create a new [ReplayImpl] with the passed variables.

            Params:
                payload = Payload of templated type `Payload` to attach to this [ReplayImpl].
                event = [dialect.defs.IRCEvent] to attach to this [ReplayImpl].
                permissionsRequired = The permissions level required to replay the
                    passed function.
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
                caller = String of calling function.
         +/
        this(Payload payload, IRCEvent event, Permissions permissionsRequired,
            F fn, const string caller)
        {
            super();

            this.payload = payload;
            this.event = event;
            this.permissionsRequired = permissionsRequired;
            this.fn = fn;
            this.caller = caller;
        }
    }
    else
    {
        /++
            Create a new [ReplayImpl] with the passed variables.

            Params:
                event = [dialect.defs.IRCEvent] to attach to this [ReplayImpl].
                permissionsRequired = The permissions level required to replay the
                    passed function.
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
                caller = String of calling function.
         +/
        this(IRCEvent event, Permissions permissionsRequired, F fn, const string caller)
        {
            super();

            this.event = event;
            this.permissionsRequired = permissionsRequired;
            this.fn = fn;
            this.caller = caller;
        }
    }

    // trigger
    /++
        Call the passed function/delegate pointer, optionally with the stored
        [dialect.defs.IRCEvent] and/or `Payload`.
     +/
    override void trigger() @system
    {
        import lu.traits : TakesParams;
        import std.meta : AliasSeq;
        import std.traits : arity;

        assert((fn !is null), "null fn in `" ~ typeof(this).stringof ~ '`');

        static if (TakesParams!(fn, AliasSeq!(Payload, IRCEvent)))
        {
            fn(payload, event);
        }
        else static if (TakesParams!(fn, AliasSeq!Payload))
        {
            fn(payload);
        }
        else static if (TakesParams!(fn, AliasSeq!IRCEvent))
        {
            fn(event);
        }
        else static if (arity!fn == 0)
        {
            fn();
        }
        else
        {
            import std.format : format;

            enum pattern = "`ReplayImpl` instantiated with an invalid " ~
                "replay function signature: `%s`";
            static assert(0, pattern.format(F.stringof));
        }
    }
}

unittest
{
    Replay[] queue;

    IRCEvent event;
    event.target.nickname = "kameloso";
    event.content = "hirrpp";
    event.sender.nickname = "zorael";
    Permissions pl = Permissions.admin;

    // delegate()

    int i = 5;

    void dg()
    {
        ++i;
    }

    Replay reqdg = new ReplayImpl!(void delegate())(event, pl, &dg, "test");
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

    auto reqfn = replay(event, pl, &fn);
    queue ~= reqfn;

    // delegate(ref IRCEvent)

    void dg2(ref IRCEvent thisEvent)
    {
        thisEvent.content = "blah";
    }

    auto reqdg2 = replay(event, pl, &dg2);
    queue ~= reqdg2;

    assert((reqdg2.event.content == "hirrpp"), event.content);
    reqdg2.trigger();
    assert((reqdg2.event.content == "blah"), event.content);

    // function(IRCEvent)

    static void fn2(IRCEvent _) { }

    auto reqfn2 = replay(event, pl, &fn2);
    queue ~= reqfn2;
}


// Repeat
/++
    An event to be repeated from the context of the main loop after having
    re-postprocessed it.

    With this plugins get an ability to postprocess on demand, which is needed
    to apply user classes to stored events, such as those saved before issuing
    WHOIS queries.
 +/
struct Repeat
{
private:
    import kameloso.thread : CarryingFiber;
    import std.traits : Unqual;
    import core.thread : Fiber;

    alias This = Unqual!(typeof(this));

public:
    // fiber
    /++
        [core.thread.fiber.Fiber] to call to invoke this repeat.
     +/
    Fiber fiber;

    // carryingFiber
    /++
        Returns [fiber] as a [kameloso.thread.CarryingFiber], blindly assuming
        it can be cast thus.

        Returns:
            [fiber], cast as a [kameloso.thread.CarryingFiber]![Repeat].
     +/
    CarryingFiber!This carryingFiber() pure inout @nogc @property
    {
        auto carrying = cast(CarryingFiber!This)fiber;
        assert(carrying, "Tried to get a `CarryingFiber!Repeat` out of a normal Fiber");
        return carrying;
    }

    // isCarrying
    /++
        Returns whether or not [fiber] is actually a
        [kameloso.thread.CarryingFiber]![Repeat].

        Returns:
            `true` if it is of such a subclass, `false` if not.
     +/
    bool isCarrying() const pure @nogc @property
    {
        return cast(CarryingFiber!This)fiber !is null;
    }

    // replay
    /++
        The [Replay] to repeat.
     +/
    Replay replay;

    // created
    /++
        UNIX timestamp of when this repeat event was created.
     +/
    long created;

    /++
        Constructor taking a [core.thread.fiber.Fiber] and a [Replay].
     +/
    this(Fiber fiber, Replay replay) @safe
    {
        import std.datetime.systime : Clock;
        created = Clock.currTime.toUnixTime;
        this.fiber = fiber;
        this.replay = replay;
    }
}


// filterResult
/++
    The tristate results from comparing a username with the admin or whitelist lists.
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
    In what way the contents of a [dialect.defs.IRCEvent] must start (be "prefixed")
    for an annotated function to be allowed to trigger.
 +/
enum PrefixPolicy
{
    /++
        The annotated event handler will not examine the [dialect.defs.IRCEvent.content]
        member at all and will always trigger, as long as all other annotations match.
     +/
    direct,

    /++
        The annotated event handler will only trigger if the [dialect.defs.IRCEvent.content]
        member starts with the [kameloso.kameloso.CoreSettings.prefix] (e.g. "!").
        All other annotations must also match.
     +/
    prefixed,

    /++
        The annotated event handler will only trigger if the [dialect.defs.IRCEvent.content]
        member starts with the bot's name, as if addressed to it.

        In [dialect.defs.IRCEvent.Type.QUERY] events this instead behaves as
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
        The annotated function will only be allowed to triger if the event
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
        Anyone not explicitly blacklisted (with a [dialect.defs.IRCClient.Class.blacklist]
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
        Only users with a [dialect.defs.IRCClient.Class.whitelist] classifier
        may trigger the annotated function.
     +/
    whitelist = 30,

    /++
        Only users with a [dialect.defs.IRCClient.Class.operator] classifier
        may trigger the annotated function.

        Note: this does not mean IRC "+o" operators.
     +/
    operator = 40,

    /++
        Only users with a [dialect.defs.IRCClient.Class.staff] classifier may
        trigger the annotated function. These are channel owners.
     +/
    staff = 50,

    /++
        Only users defined in the configuration file as an administrator may
        trigger the annotated function.
     +/
    admin = 100,
}


// replay
/++
    Convenience function that returns a [ReplayImpl] of the right type,
    *with* a subclass plugin reference attached.

    Params:
        subPlugin = Subclass [IRCPlugin] to call the function pointer `fn` with
            as first argument, when the WHOIS results return.
        event = [dialect.defs.IRCEvent] that instigated the WHOIS lookup.
        permissionsRequired = The permissions level policy to apply to the WHOIS results.
        fn = Function/delegate pointer to call upon receiving the results.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A [Replay] with template parameters inferred from the arguments
        passed to this function.

    See_Also:
        [Replay]
 +/
Replay replay(Fn, SubPlugin)
    (SubPlugin subPlugin,
    const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!(Fn, SubPlugin)(subPlugin, event, permissionsRequired, fn, caller);
}


// replay
/++
    Convenience function that returns a [ReplayImpl] of the right type,
    *without* a subclass plugin reference attached.

    Params:
        event = [dialect.defs.IRCEvent] that instigated the WHOIS lookup.
        permissionsRequired = The permissions level policy to apply to the WHOIS results.
        fn = Function/delegate pointer to call upon receiving the results.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A [Replay] with template parameters inferred from the arguments
        passed to this function.

    See_Also:
        [Replay]
 +/
Replay replay(Fn)
    (const ref IRCEvent event,
    const Permissions permissionsRequired,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!Fn(event, permissionsRequired, fn, caller);
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
    // GivenValues
    /++
        Aggregate of given values, to keep them in a separate namespace from the mutators/setters.
     +/
    static struct GivenValues
    {
        // acceptedEventTypes
        /++
            Array of types of [dialect.defs.IRCEvent] that the annotated event
            handler function should accept.
         +/
        IRCEvent.Type[] acceptedEventTypes;

        // permissionsRequired
        /++
            Permissions required of instigating user, below which the annotated
            event handler function should not be triggered.
         +/
        Permissions permissionsRequired = Permissions.ignore;

        // channelPolicy
        /++
            What kind of channel the annotated event handler function may be
            triggered in; homes or mere guest channels.
         +/
        ChannelPolicy channelPolicy = ChannelPolicy.home;

        // commands
        /++
            Array of [IRCEventHandler.Command]s the bot should pick up and listen for.
         +/
        Command[] commands;

        // regexes
        /++
            Array of [IRCEventHandler.Regex]es the bot should pick up and listen for.
         +/
        Regex[] regexes;

        // chainable
        /++
            Whether or not the annotated event handler function should allow other
            functions to fire after it. If not set (default false), it will
            terminate and move on to the next plugin after the function returns.
         +/
        bool chainable;

        // verbose
        /++
            Whether or not additional information should be output to the local
            terminal as the function is (or is not) triggered.
         +/
        bool verbose;

        // when
        /++
            Special instruction related to the order of which event handler functions
            within a plugin module are triggered.
         +/
        Timing when;
    }

    // given
    /++
        The given settings this instance of [IRCEventHandler] holds.
     +/
    GivenValues given;

    // onEvent
    /++
        Adds an [dialect.defs.IRCEvent.Type] to the array of types that the
        annotated event handler function should accept.

        Params:
            type = New [dialect.defs.IRCEvent.Type] to listen for.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref onEvent(const IRCEvent.Type type)
    {
        this.given.acceptedEventTypes ~= type;
        return this;
    }

    // permissionsRequired
    /++
        Sets the permission level required of an instigating user before the
        annotated event handler function is allowed to be triggered.

        Params:
            permissionsRequired = New [Permissions] permissions level.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref permissionsRequired(const Permissions permissionsRequired)
    {
        this.given.permissionsRequired = permissionsRequired;
        return this;
    }

    // channelPolicy
    /++
        Sets the type of channel the annotated event handler function should be
        allowed to be triggered in.

        Params:
            channelPolicy = New [ChannelPolicy] channel policy.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref channelPolicy(const ChannelPolicy channelPolicy)
    {
        this.given.channelPolicy = channelPolicy;
        return this;
    }

    // addCommand
    /++
        Appends an [IRCEventHandler.Command] to the array of commands that the bot
        should listen for to trigger the annotated event handler function.

        Params:
            command = New [IRCEventHandler.Command] to append to the commands array.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref addCommand(const Command command)
    {
        this.given.commands ~= command;
        return this;
    }

    // addRegex
    /++
        Appends an [IRCEventHandler.Regex] to the array of regular expressions
        that the bot should listen for to trigger the annotated event handler function.

        Params:
            regex = New [IRCEventHandler.Regex] to append to the regex array.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref addRegex(/*const*/ Regex regex)
    {
        this.given.regexes ~= regex;
        return this;
    }

    // chainable
    /++
        Sets whether or not the annotated function should allow other functions
        within the same plugin module to be triggered after it. If not (default false)
        it will signal the bot to proceed to the next plugin after this function returns.

        Params:
            chainable = Whether or not to allow further event handler functions
                to trigger within the same module (after this one returns).

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref chainable(const bool chainable)
    {
        this.given.chainable = chainable;
        return this;
    }

    // verbose
    /++
        Sets whether or not to have the bot plumbing give verbose information about
        what it does as it evaluates and executes the annotated function (or not).

        Params:
            verbose = Whether or not to enable verbose output.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref verbose(const bool verbose)
    {
        this.given.verbose = verbose;
        return this;
    }

    // when
    /++
        Sets a [Timing], used to order the evaluation and execution of event
        handler functions within a module, allowing the author to design subsets
        of functions that should be run before or after others.

        Params:
            when = [Timing] setting to give an order to the annotated event handler function.

        Returns:
            A `this` reference to the current struct instance.
     +/
    auto ref when(const Timing when)
    {
        this.given.when = when;
        return this;
    }

    // Command
    /++
        Embodies the notion of a chat command, e.g. `!hello`.
     +/
    static struct Command
    {
        // GivenValues
        /++
            Aggregate of given values, to keep them in a separate namespace from the mutators/setters.
         +/
        static struct GivenValues
        {
            // policy
            /++
                In what way the message is required to start for the annotated function to trigger.
             +/
            PrefixPolicy policy = PrefixPolicy.prefixed;

            // word
            /++
                The command word, without spaces.
            +/
            string word;

            // description
            /++
                Describes the functionality of the event handler function the parent
                [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Command].

                Specifically this is used to describe functions triggered by
                [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
             +/
            string description;

            // syntax
            /++
                Command usage syntax help string.
             +/
            string syntax;

            // hidden
            /++
                Whether this is a hidden command or if it should show up in help listings.
             +/
            bool hidden;
        }

        // given
        /++
            The given settings this instance of [IRCEventHandler.Command] holds.
         +/
        GivenValues given;

        // policy
        /++
            Sets what way this [IRCEventHandler.Command] should be expressed.

            Params:
                policy = New [PrefixPolicy] to dictate how the command word should
                    be expressed to be picked up by the bot.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref policy(const PrefixPolicy policy)
        {
            this.given.policy = policy;
            return this;
        }

        // word
        /++
            Assigns a word to trigger this [IRCEventHandler.Command].

            Params:
                word = New word string.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref word(const string word)
        {
            this.given.word = word;
            return this;
        }

        // description
        /++
            Sets a description of what the event handler function the parent
            [IRCEventHandler] annotates does, and by extension, what this
            [IRCEventHandler.Command] does.

            This is used to describe the command in help listings.

            Params:
                description = Command functionality/feature/purpose description
                    in natural language.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref description(const string description)
        {
            this.given.description = description;
            return this;
        }

        // syntax
        /++
            Describes the syntax with which this [IRCEventHandler.Command] should
            be used. Some text replacement is applied, such as `$command`.

            This is used to describe the command usage in help listings.

            Params:
                syntax = A brief syntax description.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref syntax(const string syntax)
        {
            this.given.syntax = syntax;
            return this;
        }

        // hidden
        /++
            Whether or not this particular [IRCEventHandler.Command] (but not
            necessarily that of all commands under this [IRCEventHandler]) should
            be included in help listings.

            This is used to allow for hidden command aliases.

            Params:
                syntax = A brief syntax description.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref hidden(const bool hidden)
        {
            this.given.hidden = hidden;
            return this;
        }
    }

    // Regex
    /++
        Embodies the notion of a chat command regular expression, e.g. `![Hh]ello+`.
     +/
    static struct Regex
    {
        import std.regex : StdRegex = Regex;

        // GivenValues
        /++
            Aggregate of given values, to keep them in a separate namespace from the mutators/setters.
         +/
        static struct GivenValues
        {
            // policy
            /++
                In what way the message is required to start for the annotated function to trigger.
             +/
            PrefixPolicy policy = PrefixPolicy.direct;

            // engine
            /++
                Regex engine to match incoming messages with.
             +/
            StdRegex!char engine;

            // expression
            /++
                The regular expression in string form.
             +/
            string expression;

            // description
            /++
                Describes the functionality of the event handler function the parent
                [IRCEventHandler] annotates, and by extension, this [IRCEventHandler.Regex].

                Specifically this is used to describe functions triggered by
                [IRCEventHandler.Command]s, in the help listing routine in [kameloso.plugins.chatbot].
             +/
            string description;

            // hidden
            /++
                Whether this is a hidden command or if it should show up in help listings.
             +/
            bool hidden;
        }

        // given
        /++
            The given settings this instance of [IRCEventHandler.Regex] holds.
         +/
        GivenValues given;

        // policy
        /++
            Sets what way this [IRCEventHandler.Command] should be expressed.

            Params:
                policy = New [PrefixPolicy] to dictate how the command word should
                    be expressed to be picked up by the bot.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref policy(const PrefixPolicy policy)
        {
            this.given.policy = policy;
            return this;
        }

        // expression
        /++
            The regular expession this [IRCEventHandler.Regex] embodies, in string form.

            Upon setting this a regex engine is also created.

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
        auto ref expression(const string expression)
        {
            import std.regex : regex;

            this.given.expression = expression;
            this.given.engine = expression.regex;
            return this;
        }

        // description
        /++
            Sets a description of what the event handler function the parent
            [IRCEventHandler] annotates does, and by extension, what this
            [IRCEventHandler.Regex] does.

            This is used to describe the command in help listings.

            Params:
                description = Command functionality/feature/purpose description
                    in natural language.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref description(const string description)
        {
            this.given.description = description;
            return this;
        }

        // hidden
        /++
            Whether or not this particular [IRCEventHandler.Regex] (but not
            necessarily that of all regexes under this [IRCEventHandler]) should
            be included in help listings.

            This is used to allow for hidden command aliases.

            Params:
                syntax = A brief syntax description.

            Returns:
                A `this` reference to the current struct instance.
         +/
        auto ref hidden(const bool hidden)
        {
            this.given.hidden = hidden;
            return this;
        }
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

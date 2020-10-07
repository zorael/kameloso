/++
    Contains the definition of an `IRCPlugin` and its ancilliaries, as well as
    mixins to fully implement it.

    Event handlers can then be module-level functions, annotated with
    `dialect.defs.IRCEvent.Type`s.

    Example:
    ---
    import kameloso.plugins.common.core;
    import kameloso.plugins.common.awareness;

    @(IRCEvent.Type.CHAN)
    @(ChannelPolicy.home)
    @(PrefixPolicy.prefixed)
    @BotCommand(PrivilegeLevel.anyone, "foo")
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

import kameloso.kameloso;
import dialect.defs;
import std.typecons : Flag, No, Yes;

public:


// IRCPlugin
/++
    Abstract `IRCPlugin` class.

    This is currently shared with all `service`-class "plugins".
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
        Metadata about a `BotCommand`- and/or `BotRegex`-annotated event handler.
     +/
    static struct CommandMetadata
    {
        // desc
        /++
            Description about what the command does, along with optional syntax.

            See_Also:
                Description
         +/
        Description desc;


        // hidden
        /++
            Whether or not the command should be hidden from view (but still
            possible to trigger).
         +/
        bool hidden;
    }


    // state
    /++
        An `IRCPluginState` instance containing variables and arrays that represent
        the current state of the plugin. Should generally be passed by reference.
     +/
    IRCPluginState state;


    // postprocess
    /++
        Executed to let plugins modify an event mid-parse.
     +/
    void postprocess(ref IRCEvent) @system;


    // onEvent
    /++
        Executed upon new IRC event parsed from the server.
     +/
    void onEvent(/*const*/ IRCEvent) @system;


    // initResources
    /++
        Executed when the plugin is requested to initialise its disk resources.
     +/
    void initResources() @system;


    // deserialiseConfigFrom
    /++
        Read serialised configuration text into the plugin's settings struct.

        Stores an associative array of `string[]`s of missing entries in its
        first `out string[][string]` parameter, and the invalid encountered
        entries in the second.
     +/
    void deserialiseConfigFrom(const string, out string[][string], out string[][string]);


    // serialiseConfigInto
    /++
        Executed when gathering things to put in the configuration file.
     +/
    bool serialiseConfigInto(ref Appender!string) const;


    // setSettingByName
    /++
        Executed during start if we want to change a setting by its string name.

        Returns:
            Boolean of whether the set succeeded or not.
     +/
    bool setSettingByName(const string, const string);


    // start
    /++
        Executed when connection has been established.
     +/
    void start() @system;


    // printSettings
    /++
        Executed when we want a plugin to print its Settings struct.
     +/
    void printSettings() @system const;


    // teardown
    /++
        Executed during shutdown of a connection session.
     +/
    void teardown() @system;


    // name
    /++
        Returns the name of the plugin, sliced off the module name.

        Returns:
            The string name of the plugin.
     +/
    string name() @property const pure nothrow @nogc;


    // commands
    /++
        Returns an array of the descriptions of the commands a plugin offers.

        Returns:
            An associative `CommandMetadata[string]` array.
     +/
    CommandMetadata[string] commands() pure nothrow @property const;


    // reload
    /++
        Reloads the plugin, where such is applicable.
     +/
    void reload() @system;


    // onBusMessage
    /++
        Executed when a bus message arrives from another plugin.
     +/
    void onBusMessage(const string, shared Sendable content) @system;


    // isEnabled
    /++
        Returns whether or not the plugin is enabled in its configuration section.

        Returns:
            true if the plugin should listen to events, false if not.
     +/
    bool isEnabled() const @property pure nothrow @nogc;
}


// IRCPluginImpl
/++
    Mixin that fully implements an `IRCPlugin`.

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
 +/
version(WithPlugins)
mixin template IRCPluginImpl(Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import core.thread : Fiber;

    /// Symbol needed for the mixin constraints to work.
    private static enum mixinSentinel = true;

    // Use a custom constraint to force the scope to be an IRCPlugin
    static if (!is(__traits(parent, mixinSentinel) : IRCPlugin))
    {
        import lu.traits : CategoryName;
        import std.format : format;

        alias pluginImplParent = __traits(parent, mixinSentinel);
        alias pluginImplParentInfo = CategoryName!pluginImplParent;

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
        Introspects the current plugin, looking for a `Settings`-annotated struct
        member that has a bool annotated with `Enabler`, which denotes it as the
        bool that toggles a plugin on and off.

        It then returns its value.

        Returns:
            `true` if the plugin is deemed enabled (or cannot be disabled),
            `false` if not.
     +/
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        import lu.traits : getSymbolsByUDA, isAnnotated;

        bool retval = true;

        top:
        foreach (immutable i, const ref member; this.tupleof)
        {
            static if (isAnnotated!(this.tupleof[i], Settings) ||
                (is(typeof(this.tupleof[i]) == struct) &&
                isAnnotated!(typeof(this.tupleof[i]), Settings)))
            {
                static if (getSymbolsByUDA!(typeof(this.tupleof[i]), Enabler).length)
                {
                    foreach (immutable n, const submember; this.tupleof[i].tupleof)
                    {
                        static if (isAnnotated!(this.tupleof[i].tupleof[n], Enabler))
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
        the annotated `PrivilegeLevel` of the handler in question. Wrapper function
        that merely calls `allowImpl`. The point behind it is to make something
        that can be overridden and still allow it to call the original logic (below).

        Params:
            event = `dialect.defs.IRCEvent` to allow, or not.
            privilegeLevel = `PrivilegeLevel` of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.
     +/
    pragma(inline, true)
    private FilterResult allow(const ref IRCEvent event, const PrivilegeLevel privilegeLevel)
    {
        return allowImpl(event, privilegeLevel);
    }


    // allowImpl
    /++
        Judges whether an event may be triggered, based on the event itself and
        the annotated `PrivilegeLevel` of the handler in question. Implementation function.

        Params:
            event = `dialect.defs.IRCEvent` to allow, or not.
            privilegeLevel = `PrivilegeLevel` of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.
     +/
    private FilterResult allowImpl(const ref IRCEvent event, const PrivilegeLevel privilegeLevel)
    {
        import std.typecons : Flag, No, Yes;

        version(TwitchSupport)
        {
            if (state.server.daemon == IRCServer.Daemon.twitch)
            {
                if (((privilegeLevel == PrivilegeLevel.anyone) ||
                    (privilegeLevel == PrivilegeLevel.registered)) &&
                    (event.sender.class_ != IRCUser.Class.blacklist))
                {
                    // We can't WHOIS on Twitch, and PrivilegeLevel.anyone is just
                    // PrivilegeLevel.ignore with an extra WHOIS for good measure.
                    // Also everyone is registered on Twitch, by definition.
                    return FilterResult.pass;
                }
            }
        }

        // PrivilegeLevel.ignore always passes, even for Class.blacklist.
        return (privilegeLevel == PrivilegeLevel.ignore) ? FilterResult.pass :
            filterSender(event, privilegeLevel, state.settings.preferHostmasks);
    }


    // onEvent
    /++
        Pass on the supplied `dialect.defs.IRCEvent` to `onEventImpl`.

        This is made a separate function to allow plugins to override it and
        insert their own code, while still leveraging `onEventImpl` for the
        actual dirty work.

        Params:
            event = Parsed `dialect.defs.IRCEvent` to pass onto `onEventImpl`.

        See_Also:
            onEventImpl
     +/
    pragma(inline, true)
    override public void onEvent(/*const*/ IRCEvent event) @system
    {
        return onEventImpl(event);
    }


    // onEventImpl
    /++
        Pass on the supplied `dialect.defs.IRCEvent` to module-level functions
        annotated with the matching `dialect.defs.IRCEvent.Type`s.

        It also does checks for `kameloso.plugins.common.core.ChannelPolicy`,
        `kameloso.plugins.common.core.PrivilegeLevel`, `kameloso.plugins.common.core.PrefixPolicy`,
        `kameloso.plugins.common.core.BotCommand`, `kameloso.plugins.common.core.BotRegex`
        etc; where such is applicable.

        Params:
            origEvent = Parsed `dialect.defs.IRCEvent` to dispatch to event handlers.
     +/
    private void onEventImpl(/*const*/ IRCEvent origEvent) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.common.awareness : Awareness;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA, isAnnotated;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;
        import std.typecons : Flag, No, Yes;

        if (!this.isEnabled) return;

        alias setupAwareness(alias T) = hasUDA!(T, Awareness.setup);
        alias earlyAwareness(alias T) = hasUDA!(T, Awareness.early);
        alias lateAwareness(alias T) = hasUDA!(T, Awareness.late);
        alias cleanupAwareness(alias T) = hasUDA!(T, Awareness.cleanup);
        alias isAwarenessFunction = templateOr!(setupAwareness, earlyAwareness,
            lateAwareness, cleanupAwareness);
        alias isNormalPluginFunction = templateNot!isAwarenessFunction;

        alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEvent.Type));

        enum NextStep
        {
            continue_,
            repeat,
            return_,
        }

        /++
            Process a function.
         +/
        NextStep process(alias fun)(ref IRCEvent event)
        {
            enum verbose = (isAnnotated!(fun, Verbose) || debug_) ?
                Yes.verbose :
                No.verbose;

            static if (verbose)
            {
                import lu.conv : Enum;
                import std.format : format;
                import std.stdio : writeln, writefln;

                enum name = "[%s] %s".format(__traits(identifier, thisModule),
                    __traits(identifier, fun));
            }

            /++
                Whether or not this event matched the type of one or more of
                this function's annotations.
             +/
            bool typeMatches;

            udaloop:
            foreach (immutable eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
            {
                static if (eventTypeUDA == IRCEvent.Type.UNSET)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated `@(IRCEvent.Type.UNSET)`, " ~
                        "which is not a valid event type.";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }
                else static if (eventTypeUDA == IRCEvent.Type.PRIVMSG)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated `@(IRCEvent.Type.PRIVMSG)`, " ~
                        "which is not a valid event type. Use `IRCEvent.Type.CHAN` " ~
                        "and/or `IRCEvent.Type.QUERY` instead";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }
                else static if (eventTypeUDA == IRCEvent.Type.WHISPER)
                {
                    import std.format : format;

                    enum pattern = "`%s` is annotated `@(IRCEvent.Type.WHISPER)`, " ~
                        "which is not a valid event type. Use `IRCEvent.Type.QUERY` instead";
                    static assert(0, pattern.format(fullyQualifiedName!fun));
                }
                else static if (eventTypeUDA == IRCEvent.Type.ANY)
                {
                    // UDA is `dialect.defs.IRCEvent.Type.ANY`, let pass
                    typeMatches = true;
                    break udaloop;
                }
                else
                {
                    if (eventTypeUDA != event.type)
                    {
                        // The current event does not match this function's
                        // particular UDA; continue to the next one
                        /*static if (verbose)
                        {
                            writeln("nope.");
                        }*/

                        continue;  // next Type UDA
                    }

                    typeMatches = true;

                    static if (
                        !hasUDA!(fun, BotCommand) &&
                        !hasUDA!(fun, BotRegex) &&
                        !isAnnotated!(fun, Chainable) &&
                        !isAnnotated!(fun, Terminating) &&
                        ((eventTypeUDA == IRCEvent.Type.CHAN) ||
                        (eventTypeUDA == IRCEvent.Type.QUERY) ||
                        (eventTypeUDA == IRCEvent.Type.ANY) ||
                        (eventTypeUDA == IRCEvent.Type.NUMERIC)))
                    {
                        import lu.conv : Enum;
                        import std.format : format;

                        enum wildcardPattern = "Note: `%s` is a wildcard " ~
                            "`IRCEvent.Type.%s` event but is not `Chainable` " ~
                            "nor `Terminating`";
                        pragma(msg, wildcardPattern.format(fullyQualifiedName!fun,
                            Enum!(IRCEvent.Type).toString(eventTypeUDA)));
                    }

                    static if (!hasUDA!(fun, PrivilegeLevel) && !isAwarenessFunction!fun)
                    {
                        with (IRCEvent.Type)
                        {
                            import lu.conv : Enum;

                            alias U = eventTypeUDA;

                            // Use this to detect potential additions to the whitelist below
                            /*import lu.string : beginsWith;

                            static if (!Enum!(IRCEvent.Type).toString(U).beginsWith("ERR_") &&
                                !Enum!(IRCEvent.Type).toString(U).beginsWith("RPL_"))
                            {
                                import std.format : format;

                                enum missingPrivilegePattern = "`%s` is annotated with " ~
                                    "`IRCEvent.Type.%s` but is missing a `PrivilegeLevel`";
                                pragma(msg, missingPrivilegeLevelPattern
                                    .format(fullyQualifiedName!fun,
                                    Enum!(IRCEvent.Type).toString(U)));
                            }*/

                            static if (
                                (U == CHAN) ||
                                (U == QUERY) ||
                                (U == EMOTE) ||
                                (U == JOIN) ||
                                (U == PART) ||
                                //(U == QUIT) ||
                                //(U == NICK) ||
                                (U == AWAY) ||
                                (U == BACK) //||
                                )
                            {
                                import std.format : format;

                                enum pattern = "`%s` is annotated with a user-facing " ~
                                    "`IRCEvent.Type.%s` but is missing a `PrivilegeLevel`";
                                static assert(0, pattern.format(fullyQualifiedName!fun,
                                    Enum!(IRCEvent.Type).toString(U)));
                            }
                        }
                    }

                    static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
                    {
                        alias U = eventTypeUDA;

                        static if (
                            (U != IRCEvent.Type.CHAN) &&
                            (U != IRCEvent.Type.QUERY) &&
                            (U != IRCEvent.Type.SELFCHAN) &&
                            (U != IRCEvent.Type.SELFQUERY))
                        {
                            import lu.conv : Enum;
                            import std.format : format;

                            enum pattern = "`%s` is annotated with a `BotCommand` " ~
                                "or `BotRegex` but is at the same time annotated " ~
                                "with a non-message `IRCEvent.Type.%s`";
                            static assert(0, pattern.format(fullyQualifiedName!fun,
                                Enum!(IRCEvent.Type).toString(U)));
                        }
                    }

                    break udaloop;
                }
            }

            // Invalid type, continue with the next function
            if (!typeMatches) return NextStep.continue_;

            static if (verbose)
            {
                writeln("-- ", name, " @ ", Enum!(IRCEvent.Type).toString(event.type));
            }

            static if (!hasUDA!(fun, ChannelPolicy) ||
                getUDAs!(fun, ChannelPolicy)[0] == ChannelPolicy.home)
            {
                import std.algorithm.searching : canFind;

                // Default policy if none given is `ChannelPolicy.home`

                static if (verbose)
                {
                    writeln("...ChannelPolicy.home");
                }

                if (!event.channel.length)
                {
                    // it is a non-channel event, like a `dialect.defs.IRCEvent.Type.QUERY`
                }
                else if (!state.bot.homeChannels.canFind(event.channel))
                {
                    static if (verbose)
                    {
                        writeln("...ignore non-home channel ", event.channel);
                    }

                    // channel policy does not match
                    return NextStep.continue_;  // next fun
                }
            }
            else
            {
                static if (verbose)
                {
                    writeln("...ChannelPolicy.any");
                }
            }

            static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
            {
                if (!event.content.length)
                {
                    // Event has a `BotCommand` or a `BotRegex`set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }
            }

            bool commandMatch;  // Whether or not a BotCommand or BotRegex matched

            static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
            {
                // Snapshot content and aux for later restoration
                immutable origContent = event.content;
                immutable origAux = event.aux;
            }

            // Evaluate each BotCommand UDAs with the current event
            static if (hasUDA!(fun, BotCommand))
            {
                foreach (immutable commandUDA; getUDAs!(fun, BotCommand))
                {
                    import lu.string : contains;

                    static if (!commandUDA.word.length)
                    {
                        import std.format : format;

                        enum pattern = "`%s` has an empty `BotCommand` word";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (commandUDA.word.contains(" "))
                    {
                        import std.format : format;

                        enum pattern = "`%s` has a `BotCommand` word " ~
                            "that has spaces in it";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }

                    static if (verbose)
                    {
                        writefln(`...BotCommand "%s"`, commandUDA.word);
                    }

                    if (!event.prefixPolicyMatches!verbose(commandUDA.policy,
                        state.client, state.settings.prefix))
                    {
                        static if (verbose)
                        {
                            writeln("...policy doesn't match; continue next BotCommand");
                        }

                        continue;  // next BotCommand UDA
                    }

                    import lu.string : strippedLeft;
                    import std.algorithm.comparison : equal;
                    import std.typecons : No, Yes;
                    import std.uni : asLowerCase;

                    // If we don't strip left as a separate step, nom won't alter
                    // event.content by ref (as it will be an rvalue).
                    event.content = event.content.strippedLeft;

                    immutable thisCommand = event.content
                        .nom!(Yes.inherit, Yes.decode)(' ');

                    if (thisCommand.asLowerCase.equal(commandUDA.word.asLowerCase))
                    {
                        static if (verbose)
                        {
                            writeln("...command matches!");
                        }

                        event.aux = thisCommand;
                        commandMatch = true;
                        break;  // finish this BotCommand
                    }
                    else
                    {
                        // Restore content to pre-nom state
                        event.content = origContent;
                    }
                }
            }

            // Iff no match from BotCommands, evaluate BotRegexes
            static if (hasUDA!(fun, BotRegex))
            {
                if (!commandMatch)
                {
                    foreach (immutable regexUDA; getUDAs!(fun, BotRegex))
                    {
                        import std.regex : Regex;

                        static if (!regexUDA.expression.length)
                        {
                            import std.format : format;
                            static assert(0, "`%s` has an empty `BotRegex` expression"
                                .format(fullyQualifiedName!fun));
                        }

                        static if (verbose)
                        {
                            writeln("BotRegex: `", regexUDA.expression, "`");
                        }

                        if (!event.prefixPolicyMatches!verbose(regexUDA.policy,
                            state.client, state.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("...policy doesn't match; continue next BotRegex");
                            }

                            continue;  // next BotRegex UDA
                        }

                        try
                        {
                            import std.regex : matchFirst;

                            const hits = event.content.matchFirst(regexUDA.engine);

                            if (!hits.empty)
                            {
                                static if (verbose)
                                {
                                    writeln("...expression matches!");
                                }

                                event.aux = hits[0];
                                commandMatch = true;
                                break;  // finish this BotRegex
                            }
                            else
                            {
                                static if (verbose)
                                {
                                    writefln(`...matching "%s" against expression "%s" failed.`,
                                        event.content, regexUDA.expression);
                                }
                            }
                        }
                        catch (Exception e)
                        {
                            static if (verbose)
                            {
                                writeln("...BotRegex exception: ", e.msg);
                                version(PrintStacktraces) writeln(e);
                            }
                            continue;  // next BotRegex
                        }
                    }
                }
            }

            static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
            {
                if (!commandMatch)
                {
                    // Bot{Command,Regex} exists but neither matched; skip
                    static if (verbose)
                    {
                        writeln("...neither BotCommand nor BotRegex matched; continue funloop");
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

            static if (hasUDA!(fun, PrivilegeLevel))
            {
                enum privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];

                static if (privilegeLevel != PrivilegeLevel.ignore)
                {
                    static if (!__traits(compiles, .hasMinimalAuthentication))
                    {
                        import std.format : format;

                        enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                            "mixin (needed for `PrivilegeLevel` checks)";
                        static assert(0, pattern.format(module_));
                    }
                }

                static if (verbose)
                {
                    writeln("...PrivilegeLevel.", Enum!PrivilegeLevel.toString(privilegeLevel));
                }

                immutable result = this.allow(event, privilegeLevel);

                static if (verbose)
                {
                    writeln("...allow result is ", Enum!FilterResult.toString(result));
                }

                /*if (result == FilterResult.pass)
                {
                    // Drop down
                }
                else*/ if (result == FilterResult.whois)
                {
                    import kameloso.plugins.common.base : enqueue;
                    import std.traits : fullyQualifiedName;

                    alias Params = staticMap!(Unqual, Parameters!fun);

                    static if (verbose)
                    {
                        writefln("...%s WHOIS", typeof(this).stringof);
                    }

                    static if (is(Params : AliasSeq!IRCEvent) || (arity!fun == 0))
                    {
                        this.enqueue(event, privilegeLevel, &fun, fullyQualifiedName!fun);
                        return NextStep.continue_;  // Next function
                    }
                    else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(typeof(this))))
                    {
                        this.enqueue(this, event, privilegeLevel, &fun, fullyQualifiedName!fun);
                        return NextStep.continue_;  // Next function
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
                    return NextStep.continue_;  // Next function
                }
                /*else
                {
                    assert(0);
                }*/
            }

            alias Params = staticMap!(Unqual, Parameters!fun);

            static if (verbose)
            {
                writeln("...calling!");
            }

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

            static if (isAnnotated!(fun, Chainable) ||
                (isAwarenessFunction!fun && !isAnnotated!(fun, Terminating)))
            {
                // onEvent found an event and triggered a function, but
                // it's Chainable and there may be more, so keep looking.
                // Alternatively it's an awareness function, which may be
                // sharing one or more annotations with another.
                return NextStep.continue_;
            }
            else /*static if (isAnnotated!(fun, Terminating))*/
            {
                // The triggered function is not Chainable so return and
                // let the main loop continue with the next plugin.
                return NextStep.return_;
            }
        }

        alias setupFuns = Filter!(setupAwareness, funs);
        alias earlyFuns = Filter!(earlyAwareness, funs);
        alias lateFuns = Filter!(lateAwareness, funs);
        alias cleanupFuns = Filter!(cleanupAwareness, funs);
        alias pluginFuns = Filter!(isNormalPluginFunction, funs);

        /// Sanitise and try again once on UTF/Unicode exceptions
        version(SanitizeAndRetryOnUnicodeException)
        static void sanitizeEvent(ref IRCEvent event)
        {
            import std.encoding : sanitize;
            import std.range : only;

            event.raw = sanitize(event.raw);
            event.channel = sanitize(event.channel);
            event.content = sanitize(event.content);
            event.aux = sanitize(event.aux);
            event.tags = sanitize(event.tags);
            event.errors ~= event.errors.length ?
                ". Sanitized" : "Sanitzed";

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

                    version(SanitizeAndRetryOnUnicodeException)
                    {
                        import core.exception : UnicodeException;
                        import std.utf : UTFException;

                        immutable isRecoverableException =
                            (cast(UTFException)e !is null) ||
                            (cast(UnicodeException)e !is null);

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
                    else
                    {
                        // noop, just rethrow
                        throw e;
                    }
                }
            }
        }

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
        import lu.traits : isAnnotated, isSerialisable;
        import std.traits : EnumMembers;

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
                static if (isAnnotated!(this.tupleof[i], Resource))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(state.settings.resourceDirectory, member)
                        .expandTilde;
                }
                else static if (isAnnotated!(this.tupleof[i], Configuration))
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
        Lets a plugin modify an `dialect.defs.IRCEvent` while it's begin
        constructed, before it's finalised and passed on to be handled.

        Params:
            event = The `dialect.defs.IRCEvent` in flight.
     +/
    override public void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, .postprocess))
        {
            import lu.traits : TakesParams;

            if (!this.isEnabled) return;

            static if (TakesParams!(.postprocess, typeof(this), IRCEvent))
            {
                .postprocess(this, event);
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
        all struct variables annotated `Settings`.

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
        out string[][string] missingEntries, out string[][string] invalidEntries)
    {
        import kameloso.config : readConfigInto;
        import lu.meld : MeldingStrategy, meldInto;
        import lu.traits : isAnnotated;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (isAnnotated!(this.tupleof[i], Settings) ||
                isAnnotated!(typeof(this.tupleof[i]), Settings)))
            {
                alias T = typeof(symbol);

                if (symbol != T.init)
                {
                    // This symbol has had configuration applied to it already
                    continue;
                }

                T tempSymbol;
                string[][string] theseMissingEntries;
                string[][string] theseInvalidEntries;

                configFile.readConfigInto(theseMissingEntries, theseInvalidEntries, tempSymbol);

                theseMissingEntries.meldInto(missingEntries);
                theseInvalidEntries.meldInto(invalidEntries);
                tempSymbol.meldInto!(MeldingStrategy.aggressive)(symbol);
            }
        }
    }


    // setSettingByName
    /++
        Change a plugin's `Settings`-annotated settings struct member by their
        string name.

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
        import lu.traits : isAnnotated;

        bool success;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (isAnnotated!(this.tupleof[i], Settings) ||
                isAnnotated!(typeof(this.tupleof[i]), Settings)))
            {
                success = symbol.setMemberByName(setting, value);
                if (success) break;
            }
        }

        return success;
    }


    // printSettings
    /++
        Prints the plugin's `Settings`-annotated settings struct.
     +/
    override public void printSettings() const
    {
        import kameloso.printing : printObject;
        import lu.traits : isAnnotated;

        foreach (immutable i, const ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (isAnnotated!(this.tupleof[i], Settings) ||
                isAnnotated!(typeof(this.tupleof[i]), Settings)))
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
        Appender!string sink;
        sink.reserve(128);
        serialiseConfigInto(sink);
        ---

        Params:
            sink = Reference `std.array.Appender` to fill with plugin-specific
                settings text.

        Returns:
            true if something was serialised into the passed `sink`; false if not.
     +/
    override public bool serialiseConfigInto(ref Appender!string sink) const
    {
        import lu.traits : isAnnotated;

        bool didSomething;

        foreach (immutable i, ref symbol; this.tupleof)
        {
            static if (is(typeof(this.tupleof[i]) == struct) &&
                (isAnnotated!(this.tupleof[i], Settings) ||
                isAnnotated!(typeof(this.tupleof[i]), Settings)))
            {
                import lu.serialisation : serialise;

                sink.serialise(symbol);
                didSomething = true;
                break;
            }
            else static if (isAnnotated!(this.tupleof[i], Settings))
            {
                import std.format : format;

                // Warn here but nowhere else about this.
                static assert(0, "`%s.%s.%s` is annotated `@Settings` but is not a `struct`"
                    .format(module_, typeof(this).stringof,
                    __traits(identifier, this.tupleof[i])));
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
        Collects all `BotCommand` command words and `BotRegex` regex expressions
        that this plugin offers at compile time, then at runtime returns them
        alongside their `Description`s and their visibility, as an associative
        array of `IRCPlugin.CommandMetadata`s keyed by command name strings.

        Returns:
            Associative array of tuples of all `Descriptions` and whether they
            are hidden, keyed by `BotCommand.word`s and `BotRegex.expression`s.
     +/
    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import lu.traits : getSymbolsByUDA, isAnnotated;
            import std.meta : AliasSeq, Filter;
            import std.traits : getUDAs, hasUDA, isSomeFunction;

            mixin("static import thisModule = " ~ module_ ~ ";");

            alias symbols = getSymbolsByUDA!(thisModule, BotCommand);
            alias funs = Filter!(isSomeFunction, symbols);

            IRCPlugin.CommandMetadata[string] commands;

            foreach (fun; funs)
            {
                foreach (immutable uda; AliasSeq!(getUDAs!(fun, BotCommand),
                    getUDAs!(fun, BotRegex)))
                {
                    static if (hasUDA!(fun, Description))
                    {
                        enum desc = getUDAs!(fun, Description)[0];
                        if (desc == Description.init) continue;

                        static if (is(typeof(uda) : BotCommand))
                        {
                            enum key = uda.word;
                        }
                        else /*static if (is(typeof(uda) : BotRegex))*/
                        {
                            enum key = `r"` ~ uda.expression ~ `"`;
                        }

                        commands[key] = IRCPlugin.CommandMetadata(desc, uda.hidden);

                        static if (uda.policy == PrefixPolicy.nickname)
                        {
                            static if (desc.syntax.length)
                            {
                                // Prefix the command with the bot's nickname,
                                // as that's how it's actually used.
                                commands[key].desc.syntax = "$nickname: " ~ desc.syntax;
                            }
                            else
                            {
                                // Define an empty nickname: command syntax
                                // to give hint about the nickname prefix
                                commands[key].desc.syntax = "$nickname: $command";
                            }
                        }
                    }
                    else
                    {
                        static if (!hasUDA!(fun, Description))
                        {
                            import std.format : format;
                            import std.traits : fullyQualifiedName;
                            pragma(msg, "Warning: `%s` is missing a `@Description` annotation"
                                .format(fullyQualifiedName!fun));
                        }
                    }
                }
            }

            return commands;
        }();

        // This is an associative array literal. We can't make it static immutable
        // because of AAs' runtime-ness. We could make it runtime immutable once
        // and then just the address, but this is really not a hotspot.
        // So just let it allocate when it wants.
        return this.isEnabled ? ctCommandsEnumLiteral : typeof(ctCommandsEnumLiteral).init;
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
    IRCPluginState state;

    TestPlugin p = new TestPlugin(state);
    assert(!p.isEnabled);

    p.testSettings.enuubled = true;
    assert(p.isEnabled);
}

version(WithPlugins)
version(unittest)
{
    // These need to be module-level.

    @Settings private struct TestSettings
    {
        @Enabler bool enuubled = false;
    }

    private final class TestPlugin : IRCPlugin
    {
        TestSettings testSettings;

        mixin IRCPluginImpl;
    }
}


// prefixPolicyMatches
/++
    Evaluates whether or not the message in an event satisfies the `PrefixPolicy`
    specified, as fetched from a `BotCommand` or `BotRegex` UDA.

    If it doesn't match, the `onEvent` routine shall consider the UDA as not
    matching and continue with the next one.

    Params:
        verbose = Whether or not to output verbose debug information to the local terminal.
        event = Reference to the mutable `dialect.defs.IRCEvent` we're considering.
        policy = Policy to apply.
        client = `dialect.defs.IRCClient` of the calling `IRCPlugin`'s `IRCPluginState`.
        prefix = The prefix as set in the program-wide settings.

    Returns:
        `true` if the message is in a context where the event matches the
        `policy`, `false` if not.
 +/
bool prefixPolicyMatches(Flag!"verbose" verbose = No.verbose)(ref IRCEvent event,
    const PrefixPolicy policy, const IRCClient client, const string prefix)
{
    import kameloso.common : stripSeparatedPrefix;
    import lu.string : beginsWith, nom;
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

            event.content.nom!(Yes.decode)(prefix);
        }
        else
        {
            version(PrefixedCommandsFallBackToNickname)
            {
                static if (verbose)
                {
                    writeln("did not start with prefix but falling back to nickname check");
                }

                goto case nickname;
            }
            else
            {
                static if (verbose)
                {
                    writeln("did not start with prefix, returning false");
                }

                return false;
            }
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
                .stripSeparatedPrefix!(Yes.demandSeparatingChars)(client.nickname);
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
    Decides if a sender meets a `PrivilegeLevel` and is allowed to trigger an event
    handler, or if a WHOIS query is needed to be able to tell.

    This requires the Persistence service to be active to work.

    Params:
        event = `dialect.defs.IRCEvent` to filter.
        level = The `PrivilegeLevel` context in which this user should be filtered.
        preferHostmasks = Whether to rely on hostmasks for user identification,
            or to use services account logins, which need to be issued WHOIS
            queries to divine.

    Returns:
        A `FilterResult` saying the event should `pass`, `fail`, or that more
        information about the sender is needed via a WHOIS call.
 +/
FilterResult filterSender(const ref IRCEvent event, const PrivilegeLevel level,
    const bool preferHostmasks) @safe
{
    import kameloso.constants : Timeout;
    import std.algorithm.searching : canFind;

    version(WithPersistenceService) {}
    else
    {
        pragma(msg, "WARNING: The Persistence service is disabled. " ~
            "Event triggers may or may not work. You get to keep the shards.");
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
        else if (isStaff && (level <= PrivilegeLevel.staff))
        {
            return FilterResult.pass;
        }
        else if (isOperator && (level <= PrivilegeLevel.operator))
        {
            return FilterResult.pass;
        }
        else if (isWhitelisted && (level <= PrivilegeLevel.whitelist))
        {
            return FilterResult.pass;
        }
        else if (/*event.sender.account.length &&*/ level <= PrivilegeLevel.registered)
        {
            return FilterResult.pass;
        }
        else if (isAnyone && (level <= PrivilegeLevel.anyone))
        {
            return whoisExpired ? FilterResult.whois : FilterResult.pass;
        }
        else if (level == PrivilegeLevel.ignore)
        {
            /*assert(0, "`filterSender` saw a `PrivilegeLevel.ignore` and the call " ~
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
        with (PrivilegeLevel)
        final switch (level)
        {
        case admin:
        case staff:
        case operator:
        case whitelist:
        case registered:
            // Unknown sender; WHOIS if old result expired, otherwise fail
            return whoisExpired ? FilterResult.whois : FilterResult.fail;

        case anyone:
            // Unknown sender; WHOIS if old result expired in mere curiosity, else just pass
            return whoisExpired ? FilterResult.whois : FilterResult.pass;

        case ignore:
            /*assert(0, "`filterSender` saw a `PrivilegeLevel.ignore` and the call " ~
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

    Plugin-specific state should be kept inside the `IRCPlugin` itself.
 +/
struct IRCPluginState
{
private:
    import kameloso.thread : ScheduledDelegate, ScheduledFiber;
    import std.concurrency : Tid;
    import core.thread : Fiber;

public:
    /++
        The current `dialect.defs.IRCClient`, containing information pertaining
        to the bot in the context of a client connected to an IRC server.
     +/
    IRCClient client;

    /++
        The current `dialect.defs.IRCServer`, containing information pertaining
        to the bot in the context of an IRC server.
     +/
    IRCServer server;

    /++
        The current `kameloso.kameloso.IRCBot`, containing information pertaining
        to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    /++
        The current program-wide `kameloso.kameloso.CoreSettings`.
     +/
    CoreSettings settings;

    /++
        The current program-wide `kameloso.kameloso.ConnectionSettings`.
     +/
    ConnectionSettings connSettings;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
        Queued `dialect.defs.IRCEvent`s to replay.

        The main loop iterates this after processing all on-event functions so
        as to know what nicks the plugin wants a WHOIS for. After the WHOIS
        response returns, the event bundled with the `Replay` will be replayed.
     +/
    Replay[][string] replays;

    /// Whether or not `replays` has elements (i.e. is not empty).
    bool hasReplays;

    /// This plugin's array of `Repeat`s to let the main loop play back.
    Repeat[] repeats;

    /++
        The list of awaiting `core.thread.fiber.Fiber`s, keyed by
        `dialect.defs.IRCEvent.Type`.
     +/
    Fiber[][] awaitingFibers;

    /++
        The list of awaiting `void delegate(const IRCEvent)` delegates, keyed by
        `dialect.defs.IRCEvent.Type`.
     +/
    void delegate(const IRCEvent)[][] awaitingDelegates;

    /// The list of scheduled `core.thread.fiber.Fiber`, UNIX time tuples.
    ScheduledFiber[] scheduledFibers;

    /// The list of scheduled delegate, UNIX time tuples.
    ScheduledDelegate[] scheduledDelegates;

    /++
        The UNIX timestamp of when the next scheduled
        `kameloso.thread.ScheduledFiber` or delegate should be triggered.
     +/
    long nextScheduledTimestamp;

    // updateSchedule
    /++
        Updates the saved UNIX timestamp of when the next scheduled
        `core.thread.fiber.Fiber` or delegate should be triggered.
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

    /// Whether or not `bot` was altered. Must be reset manually.
    bool botUpdated;

    /// Whether or not `client` was altered. Must be reset manually.
    bool clientUpdated;

    /// Whether or not `server` was altered. Must be reset manually.
    bool serverUpdated;

    /// Whether or not `settings` was altered. Must be reset manually.
    bool settingsUpdated;

    /// Pointer to the global abort flag.
    bool* abort;
}


// IRCPluginInitialisationException
/++
    Exception thrown when an IRC plugin failed to initialise itself or its resources.

    A normal `object.Exception`, which only differs in the sense that we can deduce
    what went wrong by its type.
 +/
final class IRCPluginInitialisationException : Exception
{
    /// Wraps normal Exception constructors.
    this(const string message, const string file = __FILE__, const int line = __LINE__,
        Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(message, file, line, nextInChain);
    }
}


// Replay
/++
    A queued event to be replayed upon a WHOIS query response.

    It is abstract; all objects must be of a concrete `ReplayImpl` type.
 +/
abstract class Replay
{
    /// Name of the caller function or similar context.
    string caller;

    /// Stored `dialect.defs.IRCEvent` to replay.
    IRCEvent event;

    /// `PrivilegeLevel` of the function to replay.
    PrivilegeLevel privilegeLevel;

    /// When this request was issued.
    long when;

    /// Replay the stored event.
    void trigger();

    /// Creates a new `Replay` with a timestamp of the current time.
    this() @safe
    {
        import std.datetime.systime : Clock;
        when = Clock.currTime.toUnixTime;
    }
}


// ReplayImpl
/++
    Implementation of the notion of a function call with a bundled payload
    `dialect.defs.IRCEvent`, used to replay a previous event.

    It functions like a Command pattern object in that it stores a payload and
    a function pointer, which we queue and issue a WHOIS query. When the response
    returns we trigger the object and the original `dialect.defs.IRCEvent`
    is replayed.

    Params:
        F = Some function type.
        Payload = Optional payload type.
 +/
private final class ReplayImpl(F, Payload = typeof(null)) : Replay
{
@safe:
    /// Stored function pointer/delegate.
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the `dialect.defs.IRCEvent`.
        Payload payload;


        /++
            Create a new `ReplayImpl` with the passed variables.

            Params:
                payload = Payload of templated type `Payload` to attach to this `ReplayImpl`.
                event = `dialect.defs.IRCEvent` to attach to this `ReplayImpl`.
                privilegeLevel = The privilege level required to replay the
                    passed function.
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
         +/
        this(Payload payload, IRCEvent event, PrivilegeLevel privilegeLevel,
            F fn, const string caller)
        {
            super();

            this.payload = payload;
            this.event = event;
            this.privilegeLevel = privilegeLevel;
            this.fn = fn;
            this.caller = caller;
        }
    }
    else
    {
        /++
            Create a new `ReplayImpl` with the passed variables.

            Params:
                payload = Payload of templated type `Payload` to attach to this `ReplayImpl`.
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
         +/
        this(IRCEvent event, PrivilegeLevel privilegeLevel, F fn, const string caller)
        {
            super();

            this.event = event;
            this.privilegeLevel = privilegeLevel;
            this.fn = fn;
            this.caller = caller;
        }
    }


    // trigger
    /++
        Call the passed function/delegate pointer, optionally with the stored
        `dialect.defs.IRCEvent` and/or `Payload`.
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
    PrivilegeLevel pl = PrivilegeLevel.admin;

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

    static void fn2(IRCEvent thisEvent) { }

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
    /// `core.thread.fiber.Fiber` to call to invoke this repeat.
    Fiber fiber;


    // carryingFiber
    /++
        Returns `fiber` as a `kameloso.thread.CarryingFiber`, blindly assuming
        it can be cast thus.

        Returns:
            `fiber`, cast as a `kameloso.thread.CarryingFiber`!`Repeat`.
     +/
    CarryingFiber!This carryingFiber() pure inout @nogc @property
    {
        auto carrying = cast(CarryingFiber!This)fiber;
        assert(carrying, "Tried to get a `CarryingFiber!Repeat` out of a normal Fiber");
        return carrying;
    }


    // isCarrying
    /++
        Returns whether or not `fiber` is actually a
        `kameloso.thread.CarryingFiber`!`Repeat`.

        Returns:
            `true` if it is of such a subclass, `false` if not.
     +/
    bool isCarrying() const pure @nogc @property
    {
        return cast(CarryingFiber!This)fiber !is null;
    }

    /// The `Replay` to repeat.
    Replay replay;

    /// UNIX timestamp of when this repeat event was created.
    long created;

    /// Constructor taking a `core.thread.fiber.Fiber` and a `Replay`.
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
    fail,   /// The user is not allowed to trigger this function.
    pass,   /// The user is allowed to trigger this function.

    /++
        We don't know enough to say whether the user is allowed to trigger this
        function, so do a WHOIS query and act based on the results.
     +/
    whois,
}


// PrefixPolicy
/++
    In what way the contents of a `dialect.defs.IRCEvent` must start (be "prefixed")
    for an annotated function to be allowed to trigger.
 +/
enum PrefixPolicy
{
    /++
        The annotated event handler will not examine the `dialect.defs.IRCEvent.content`
        member at all and will always trigger, as long as all other annotations match.
     +/
    direct,

    /++
        The annotated event handler will only trigger if the `dialect.defs.IRCEvent.content`
        member starts with the `kameloso.kameloso.CoreSettings.prefix` (e.g. "!").
        All other annotations must also match.
     +/
    prefixed,

    /++
        The annotated event handler will only trigger if the `dialect.defs.IRCEvent.content`
        member starts with the bot's name, as if addressed to it.

        In `dialect.defs.IRCEvent.Type.QUERY` events this instead behaves as
        `PrefixPolicy.direct`.
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
        The annotated function will be allowed to trigger regardless of channel.
     +/
    any,
}


// PrivilegeLevel
/++
    What level of privilege is needed to trigger an event handler.

    In any event handler context, the triggering user has a *level of privilege*.
    This decides whether or not they are allowed to trigger the function.
    Put simply this is the "barrier of entry" for event handlers.

    Privileges are set on a per-channel basis and are stored in the "users.json"
    file in the resource directory.
 +/
enum PrivilegeLevel
{
    /++
        Override privilege checks, allowing anyone to trigger the annotated function.
     +/
    ignore = 0,

    /++
        Anyone not explicitly blacklisted (with a `dialect.defs.IRCClient.Class.blacklist`
        classifier) may trigger the annotated function. As such, to know if they're
        blacklisted, unknown users will first be looked up with a WHOIS query
        before allowing the function to trigger.
     +/
    anyone = 1,

    /++
        Anyone logged onto services may trigger the annotated function.
     +/
    registered = 2,

    /++
        Only users with a `dialect.defs.IRCClient.Class.whitelist` classifier
        may trigger the annotated function.
     +/
    whitelist = 3,

    /++
        Only users with a `dialect.defs.IRCClient.Class.operator` classifier
        may trigger the annotated function.

        Note: this does not mean IRC "+o" operators.
     +/
    operator = 4,

    /++
        Only users with a `dialect.defs.IRCClient.Class.staff` classifier may
        trigger the annotated function. These are channel owners.
     +/
    staff = 5,

    /++
        Only users defined in the configuration file as an administrator may
        trigger the annotated function.
     +/
    admin = 10,
}


// replay
/++
    Convenience function that returns a `ReplayImpl` of the right type,
    *with* a subclass plugin reference attached.

    Params:
        subPlugin = Subclass `IRCPlugin` to call the function pointer `fn` with
            as first argument, when the WHOIS results return.
        event = `dialect.defs.IRCEvent` that instigated the WHOIS lookup.
        privilegeLevel = The privilege level policy to apply to the WHOIS results.
        fn = Function/delegate pointer to call upon receiving the results.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A `Replay` with template parameters inferred from the arguments
        passed to this function.
 +/
Replay replay(Fn, SubPlugin)(SubPlugin subPlugin, const ref IRCEvent event,
    const PrivilegeLevel privilegeLevel, Fn fn, const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!(Fn, SubPlugin)(subPlugin, event,
        privilegeLevel, fn, caller);
}


// replay
/++
    Convenience function that returns a `ReplayImpl` of the right type,
    *without* a subclass plugin reference attached.

    Params:
        event = `dialect.defs.IRCEvent` that instigated the WHOIS lookup.
        privilegeLevel = The privilege level policy to apply to the WHOIS results.
        fn = Function/delegate pointer to call upon receiving the results.
        caller = String name of the calling function, or something else that gives context.

    Returns:
        A `Replay` with template parameters inferred from the arguments
        passed to this function.
 +/
Replay replay(Fn)(const ref IRCEvent event, const PrivilegeLevel privilegeLevel,
    Fn fn, const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!Fn(event, privilegeLevel, fn, caller);
}


// BotCommand
/++
    Defines an IRC bot command, for people to trigger with messages.

    If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.prefixed`
    and look for `kameloso.kameloso.CoreSettings.prefix` at the beginning of
    messages, to prefix the command `word`. (Usually "`!`", making it "`!command`".)

    Example:
    ---
    @(IRCEvent.Type.CHAN)
    @(ChannelPolicy.home)
    @BotCommand(PrefixPolicy.prefixed, "foo")
    @BotCommand(PrefixPolicy.prefixed, "bar")
    void onCommandFooOrBar(MyPlugin plugin, const ref IRCEvent event)
    {
        // ...
    }
    ---
 +/
struct BotCommand
{
    /++
        In what way the message is required to start for the annotated function to trigger.
     +/
    PrefixPolicy policy = PrefixPolicy.prefixed;

    /++
        The command word, without spaces.
     +/
    string word;

    /++
        Whether this is a hidden command or if it should show up in help listings.
     +/
    bool hidden;

    /++
        Create a new `BotCommand` with the passed policy, trigger word, and hidden flag.
     +/
    this(const PrefixPolicy policy, const string word, const Flag!"hidden" hidden = No.hidden) pure
    {
        this.policy = policy;
        this.word = word;
        this.hidden = hidden;
    }

    /++
        Create a new `BotCommand` with a default `PrefixPolicy.prefixed` policy
        and the passed trigger word.
     +/
    this(const string word) pure
    {
        this.word = word;
    }
}


// BotRegex
/++
    Defines an IRC bot regular expression, for people to trigger with messages.

    If no `PrefixPolicy` is specified then it will default to `PrefixPolicy.direct`
    and try to match the regex on all messages, regardless of how they start.

    Example:
    ---
    @(IRCEvent.Type.CHAN)
    @(ChannelPolicy.home)
    @BotRegex(PrefixPolicy.direct, r"(?:^|\s)MonkaS(?:$|\s)")
    void onSawMonkaS(MyPlugin plugin, const ref IRCEvent event)
    {
        // ...
    }
    ---

 +/
struct BotRegex
{
private:
    import std.regex : Regex, regex;

public:
    /++
        In what way the message is required to start for the annotated function to trigger.
     +/
    PrefixPolicy policy = PrefixPolicy.direct;

    /++
        Regex engine to match incoming messages with.
     +/
    Regex!char engine;

    /++
        The regular expression in string form.
     +/
    string expression;

    /++
        Whether this is a hidden command or if it should show up in help listings.
     +/
    bool hidden;

    /++
        Creates a new `BotRegex` with the passed policy, regex expression and hidden flag.
     +/
    this(const PrefixPolicy policy, const string expression,
        const Flag!"hidden" hidden = No.hidden)
    {
        this.policy = policy;
        this.hidden = hidden;

        if (!expression.length) return;

        this.engine = expression.regex;
        this.expression = expression;
    }

    /++
        Creates a new `BotRegex` with the passed regex expression.
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
    Annotation denoting that an event-handling function should let other functions in
    the same module process after it.

    See_Also:
        Terminating
 +/
struct Chainable;


// Terminating
/++
    Annotation denoting that an event-handling function is the end of a chain,
    letting no other functions in the same module be triggered after it has been.

    This is not strictly necessary since anything non-`Chainable` is implicitly
    `Terminating`, but it's here to silence warnings and in hopes of the code
    becoming more self-documenting.

    See_Also:
        Chainable
 +/
struct Terminating;


// Verbose
/++
    Annotation denoting that we want verbose debug output of the plumbing when
    handling events, iterating through the module's event handler functions.
 +/
struct Verbose;


// Settings
/++
    Annotation denoting that a struct variable or struct type is to be considered
    as housing settings for a plugin, and should thus be serialised and saved in
    the configuration file.
 +/
struct Settings;


// Description
/++
    Describes an `dialect.defs.IRCEvent`-annotated handler function.

    This is used to describe functions triggered by `BotCommand`s, in the help
    listing routine in `kameloso.plugins.chatbot`.
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
    Annotation denoting that a variable is the basename of a resource file or directory.
 +/
struct Resource;


/++
    Annotation denoting that a variable is the basename of a configuration
    file or directory.
 +/
struct Configuration;


/++
    Annotation denoting that a variable enables and disables a plugin.
 +/
struct Enabler;

/++
    Contains the definition of an [IRCPlugin] and its ancilliaries, as well as
    mixins to fully implement it.

    Event handlers can then be module-level functions, annotated with
    [dialect.defs.IRCEvent.Type]s.

    Example:
    ---
    import kameloso.plugins.common.core;
    import kameloso.plugins.common.awareness;

    @(IRCEvent.Type.CHAN)
    @(ChannelPolicy.home)
    @(PermissionsRequired.anyone)
    @BotCommand(PrefixPolicy.prefixed, "foo")
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
        Metadata about a [kameloso.plugins.common.core.BotCommand]- and/or
        [kameloso.plugins.common.core.BotRegex]-annotated event handler.

        See_Also:
            [commands]
     +/
    static struct CommandMetadata
    {
        // desc
        /++
            Description about what the command does, along with optional syntax.

            See_Also:
                [kameloso.plugins.common.core.Description]
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
    private import kameloso.plugins.common.core : FilterResult, IRCPluginState, PermissionsRequired;
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
        the annotated [kameloso.plugins.common.core.PermissionsRequired] of the
        handler in question. Wrapper function that merely calls
        [kameloso.plugins.common.core.IRCPluginImpl.allowImpl]. The point behind it is to make something
        that can be overridden and still allow it to call the original logic (below).

        Params:
            event = [dialect.defs.IRCEvent] to allow, or not.
            perms = [kameloso.plugins.common.core.PermissionsRequired] of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.
     +/
    pragma(inline, true)
    private FilterResult allow(const ref IRCEvent event, const PermissionsRequired perms)
    {
        return allowImpl(event, perms);
    }


    // allowImpl
    /++
        Judges whether an event may be triggered, based on the event itself and
        the annotated [kameloso.plugins.common.core.PermissionsRequired] of the
        handler in question. Implementation function.

        Params:
            event = [dialect.defs.IRCEvent] to allow, or not.
            perms = [kameloso.plugins.common.core.PermissionsRequired] of the handler in question.

        Returns:
            `true` if the event should be allowed to trigger, `false` if not.

        See_Also:
            [kameloso.plugins.common.core.filterSender]
     +/
    private FilterResult allowImpl(const ref IRCEvent event, const PermissionsRequired perms)
    {
        import kameloso.plugins.common.core : filterSender;
        import std.typecons : Flag, No, Yes;

        version(TwitchSupport)
        {
            if (state.server.daemon == IRCServer.Daemon.twitch)
            {
                if (((perms == PermissionsRequired.anyone) ||
                    (perms == PermissionsRequired.registered)) &&
                    (event.sender.class_ != IRCUser.Class.blacklist))
                {
                    // We can't WHOIS on Twitch, and PermissionsRequired.anyone is just
                    // PermissionsRequired.ignore with an extra WHOIS for good measure.
                    // Also everyone is registered on Twitch, by definition.
                    return FilterResult.pass;
                }
            }
        }

        // PermissionsRequired.ignore always passes, even for Class.blacklist.
        return (perms == PermissionsRequired.ignore) ? FilterResult.pass :
            filterSender(event, perms, state.settings.preferHostmasks);
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
        onEventImpl2(event);
    }


    // onEventImpl
    /++
        Pass on the supplied [dialect.defs.IRCEvent] to module-level functions
        annotated with the matching [dialect.defs.IRCEvent.Type]s.

        It also does checks for [kameloso.plugins.common.core.ChannelPolicy],
        [kameloso.plugins.common.core.PermissionsRequired], [kameloso.plugins.common.core.PrefixPolicy],
        [kameloso.plugins.common.core.BotCommand], [kameloso.plugins.common.core.BotRegex]
        etc; where such is applicable.

        Params:
            origEvent = Parsed [dialect.defs.IRCEvent] to dispatch to event handlers.
     +/
    private void onEventImpl(/*const*/ IRCEvent origEvent) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.common.awareness : Awareness;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;
        import std.typecons : Flag, No, Yes;

        alias setupAwareness(alias T) = hasUDA!(T, Awareness.setup);
        alias earlyAwareness(alias T) = hasUDA!(T, Awareness.early);
        alias lateAwareness(alias T) = hasUDA!(T, Awareness.late);
        alias cleanupAwareness(alias T) = hasUDA!(T, Awareness.cleanup);
        alias isAwarenessFunction = templateOr!(setupAwareness, earlyAwareness,
            lateAwareness, cleanupAwareness);
        alias isNormalPluginFunction = templateNot!isAwarenessFunction;

        alias hasNewUDA(alias T) = hasUDA!(T, IRCEventHandler);
        alias hasNoNewUDA = templateNot!hasNewUDA;
        alias funs = Filter!(hasNoNewUDA, Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEvent.Type)));

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
            import kameloso.plugins.common.core : BotCommand, BotRegex,
                ChannelPolicy, Verbose, prefixPolicyMatches;

            enum verbose = cast(Flag!"verbose")(hasUDA!(fun, Verbose) || debug_);

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
                    // UDA is [dialect.defs.IRCEvent.Type.ANY], let pass
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
                        !hasUDA!(fun, Chainable) &&
                        !hasUDA!(fun, Terminating) &&
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

                    static if (!hasUDA!(fun, PermissionsRequired) && !isAwarenessFunction!fun)
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

                                enum missingPermsPattern = "`%s` is annotated with " ~
                                    "`IRCEvent.Type.%s` but is missing a `PermissionsRequired`";
                                pragma(msg, missingPermsPattern
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
                                    "`IRCEvent.Type.%s` but is missing a `PermissionsRequired`";
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

                        static if (hasUDA!(fun, BotCommand))
                        {
                            import lu.string : contains;

                            static if (getUDAs!(fun, BotCommand)[0].word.contains(' '))
                            {
                                import std.format : format;

                                enum pattern = "`%s` is annotated with a `BotCommand` whose " ~
                                    `command word "%s" contains a space character`;

                                static assert(0, pattern.format(fullyQualifiedName!fun,
                                    getUDAs!(fun, BotCommand)[0].word));
                            }
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

            static if (!hasUDA!(fun, ChannelPolicy))
            {
                // Default policy if none given is ChannelPolicy.home
                enum channelPolicy = ChannelPolicy.home;
            }
            else
            {
                enum channelPolicy = getUDAs!(fun, ChannelPolicy)[0];
            }

            static if (verbose)
            {
                writeln("...", Enum!ChannelPolicy.toString(channelPolicy));
            }

            if (!event.channel.length)
            {
                // it is a non-channel event, like an IRCEvent.Type.QUERY
            }
            else
            {
                import std.algorithm.searching : canFind;

                static if (channelPolicy == ChannelPolicy.home)
                {
                    immutable channelMatch = state.bot.homeChannels.canFind(event.channel);
                }
                else static if (channelPolicy == ChannelPolicy.guest)
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
                        writeln("...ignore non-matching channel ", event.channel);
                    }

                    // channel policy does not match
                    return NextStep.continue_;  // next fun
                }
            }

            static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
            {
                import lu.string : strippedLeft;
                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    // Event has a BotCommand or a BotRegex set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }

                // Snapshot content and aux for later restoration
                immutable origContent = event.content;
                immutable origAux = event.aux;

                /// Whether or not a [BotCommand] or [BotRegex] matched.
                bool commandMatch;
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
                    else static if (commandUDA.word.contains(' '))
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
                    import std.uni : asLowerCase, toLower;

                    // If we don't strip left as a separate step, nom won't alter
                    // event.content by ref (as it will be an rvalue).
                    event.content = event.content.strippedLeft;

                    immutable thisCommand = event.content
                        .nom!(Yes.inherit, Yes.decode)(' ');
                    enum lowerWord = commandUDA.word.toLower;

                    if (thisCommand.asLowerCase.equal(lowerWord))
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

            static if (hasUDA!(fun, PermissionsRequired))
            {
                enum perms = getUDAs!(fun, PermissionsRequired)[0];

                static if (perms != PermissionsRequired.ignore)
                {
                    static if (!__traits(compiles, .hasMinimalAuthentication))
                    {
                        import std.format : format;

                        enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                            "mixin (needed for `PermissionsRequired` checks)";
                        static assert(0, pattern.format(module_));
                    }
                }

                static if (verbose)
                {
                    writeln("...PermissionsRequired.", Enum!PermissionsRequired.toString(perms));
                }

                immutable result = this.allow(event, perms);

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
                        this.enqueue(event, perms, &fun, fullyQualifiedName!fun);

                        static if (hasUDA!(fun, Chainable) ||
                            (isAwarenessFunction!fun && !hasUDA!(fun, Terminating)))
                        {
                            return NextStep.continue_;
                        }
                        else /*static if (hasUDA!(fun, Terminating))*/
                        {
                            return NextStep.return_;
                        }
                    }
                    else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(typeof(this))))
                    {
                        this.enqueue(this, event, perms, &fun, fullyQualifiedName!fun);

                        static if (hasUDA!(fun, Chainable) ||
                            (isAwarenessFunction!fun && !hasUDA!(fun, Terminating)))
                        {
                            return NextStep.continue_;
                        }
                        else /*static if (hasUDA!(fun, Terminating))*/
                        {
                            return NextStep.return_;
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
                    static if (hasUDA!(fun, Chainable) ||
                        (isAwarenessFunction!fun && !hasUDA!(fun, Terminating)))
                    {
                        return NextStep.continue_;
                    }
                    else /*static if (hasUDA!(fun, Terminating))*/
                    {
                        return NextStep.return_;
                    }
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

            import kameloso.plugins.common.core : Chainable, Terminating;

            static if (hasUDA!(fun, Chainable) ||
                (isAwarenessFunction!fun && !hasUDA!(fun, Terminating)))
            {
                // onEvent found an event and triggered a function, but
                // it's Chainable and there may be more, so keep looking.
                // Alternatively it's an awareness function, which may be
                // sharing one or more annotations with another.
                return NextStep.continue_;
            }
            else /*static if (hasUDA!(fun, Terminating))*/
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

        tryProcess!setupFuns(origEvent);
        tryProcess!earlyFuns(origEvent);
        tryProcess!pluginFuns(origEvent);
        tryProcess!lateFuns(origEvent);
        tryProcess!cleanupFuns(origEvent);
    }


    // onEventImpl
    /++
        Pass on the supplied [dialect.defs.IRCEvent] to module-level functions
        annotated with the matching [dialect.defs.IRCEvent.Type]s.

        It also does checks for [kameloso.plugins.common.core.ChannelPolicy],
        [kameloso.plugins.common.core.PermissionsRequired], [kameloso.plugins.common.core.PrefixPolicy],
        [kameloso.plugins.common.core.BotCommand], [kameloso.plugins.common.core.BotRegex]
        etc; where such is applicable.

        Params:
            origEvent = Parsed [dialect.defs.IRCEvent] to dispatch to event handlers.
     +/
    private void onEventImpl2(/*const*/ IRCEvent origEvent) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.common.core : IRCEventHandler;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;

        enum isSetupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.setup);
        enum isEarlyFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.early);
        enum isLateFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.late);
        enum isCleanupFun(alias T) = (getUDAs!(T, IRCEventHandler)[0]._when == Timing.cleanup);
        alias hasSpecialTiming = templateOr!(isSetupFun, isEarlyFun,
            isLateFun, isCleanupFun);
        alias isNormalEventHandler = templateNot!hasSpecialTiming;

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

            alias handlerAnnotations = getUDAs!(fun, IRCEventHandler);

            static if (handlerAnnotations.length > 1)
            {
                import std.format;

                enum pattern = "`%s` is annotated with more than one `IRCEventHandler`";
                static assert(0, pattern.format(fullyQualifiedName!fun));
            }

            static immutable uda = handlerAnnotations[0];

            enum verbose = (uda._verbose || debug_);

            static if (verbose)
            {
                import lu.conv : Enum;
                import std.format : format;
                import std.stdio : writeln, writefln;

                enum name = "[%s] %s".format(__traits(identifier, thisModule),
                    __traits(identifier, fun));
            }

            if (!uda._eventTypes.canFind(event.type)) return NextStep.continue_;

            bool break_;

            static foreach (immutable eventType; uda._eventTypes)
            {{
                if (!break_)
                {
                    static if (eventType == IRCEvent.Type.UNSET)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                            "`@(IRCEvent.Type.UNSET)`, which is not a valid event type.";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (eventType == IRCEvent.Type.PRIVMSG)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                            "`@(IRCEvent.Type.PRIVMSG)`, which is not a valid event type. " ~
                            "Use `IRCEvent.Type.CHAN` and/or `IRCEvent.Type.QUERY` instead";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (eventType == IRCEvent.Type.WHISPER)
                    {
                        import std.format : format;

                        enum pattern = "`%s` is annotated with an `IRCEventHandler` accepting " ~
                            "`@(IRCEvent.Type.PRIVMSG)`, which is not a valid event type. " ~
                            "Use `IRCEvent.Type.QUERY` instead";
                        static assert(0, pattern.format(fullyQualifiedName!fun));
                    }
                    else static if (eventType == IRCEvent.Type.ANY)
                    {
                        // Let pass
                        break_ = true;
                    }
                    else
                    {
                        static if (uda._commands.length || uda._regexes.length)
                        {
                            alias U = eventType;

                            static if (
                                (U != IRCEvent.Type.CHAN) &&
                                (U != IRCEvent.Type.QUERY) &&
                                (U != IRCEvent.Type.SELFCHAN) &&
                                (U != IRCEvent.Type.SELFQUERY))
                            {
                                import lu.conv : Enum;
                                import std.format : format;

                                enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                                    "listening for a `Command` and/or `Regex`, but is at the " ~
                                    "same time accepting non-message `IRCEvent.Type.%s events`";
                                static assert(0, pattern.format(fullyQualifiedName!fun,
                                    Enum!(IRCEvent.Type).toString(U)));
                            }

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
                                    static if (!regex._expression.length)
                                    {
                                        import std.format : format;

                                        enum pattern = "`%s` is annotated with an `IRCEventHandler` " ~
                                            "listening for a `Regex` with an empty expression";
                                        static assert(0, pattern.format(fullyQualifiedName!fun));
                                    }
                                }
                            }
                        }

                        break_ = (eventType == event.type);
                    }
                }
            }}

            static if (verbose)
            {
                writeln("-- ", name, " @ ", Enum!(IRCEvent.Type).toString(event.type));
                writeln("   ...", Enum!ChannelPolicy.toString(uda._channelPolicy));
            }

            if (!event.channel.length)
            {
                // it is a non-channel event, like an IRCEvent.Type.QUERY
            }
            else
            {
                static if (uda._channelPolicy == ChannelPolicy.home)
                {
                    immutable channelMatch = state.bot.homeChannels.canFind(event.channel);
                }
                else static if (uda._channelPolicy == ChannelPolicy.guest)
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

            static if (uda._commands.length /*|| uda._regexes.length*/)
            {
                import lu.string : strippedLeft;

                event.content = event.content.strippedLeft;

                if (!event.content.length)
                {
                    // Event has a BotCommand or a BotRegex set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return NextStep.continue_;  // next function
                }

                // Snapshot content and aux for later restoration
                immutable origContent = event.content;
                immutable origAux = event.aux;

                /// Whether or not a [BotCommand] or [BotRegex] matched.
                bool commandMatch;
            }

            // Evaluate each BotCommand UDAs with the current event
            static if (uda._commands.length)
            {
                static foreach (immutable command; uda._commands)
                {{
                    if (!commandMatch)
                    {
                        static if (verbose)
                        {
                            writefln(`   ...Command "%s"`, command._word);
                        }

                        bool policyMismatch;

                        if (!event.prefixPolicyMatches2!verbose
                            (command._policy, state.client, state.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("   ...policy doesn't match; continue next BotCommand");
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
                            enum lowerWord = command._word.toLower;

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

            // Iff no match from BotCommands, evaluate BotRegexes
            static if (uda._regexes.length)
            {
                static foreach (immutable regex; uda._regexes)
                {{
                    // This reuses previous commandMatch, so a matched Command
                    // will prevent Regex lookups.

                    if (!commandMatch)
                    {
                        static if (verbose)
                        {
                            writeln("   ...Regex: `", regex._expression, "`");
                        }

                        bool policyMismatch;

                        if (!event.prefixPolicyMatches2!verbose
                            (regex._policy, state.client, state.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("   ...policy doesn't match; continue next BotRegex");
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

                                const hits = event.content.matchFirst(regex._engine);

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
                                            event.content, regex._expression);
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

            static if (uda._commands.length || uda._regexes.length)
            {
                if (!commandMatch)
                {
                    // Bot{Command,Regex} exists but neither matched; skip
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

            static if (uda._permissionsRequired != PermissionsRequired.ignore)
            {
                static if (!__traits(compiles, .hasMinimalAuthentication))
                {
                    import std.format : format;

                    enum pattern = "`%s` is missing a `MinimalAuthentication` " ~
                        "mixin (needed for `PermissionsRequired` checks)";
                    static assert(0, pattern.format(module_));
                }

                static if (verbose)
                {
                    writeln("   ...PermissionsRequired.",
                        Enum!PermissionsRequired.toString(uda._permissionsRequired));
                }

                immutable result = this.allow(event, uda._permissionsRequired);

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
                    import kameloso.plugins.common.base : enqueue;
                    import std.traits : fullyQualifiedName;

                    alias Params = staticMap!(Unqual, Parameters!fun);

                    static if (verbose)
                    {
                        writefln("   ...%s WHOIS", typeof(this).stringof);
                    }

                    static if (is(Params : AliasSeq!IRCEvent) || (arity!fun == 0))
                    {
                        this.enqueue(event, uda._permissionsRequired, &fun, fullyQualifiedName!fun);

                        static if (uda._chainable || uda._isAwareness)
                        {
                            rtToReturn = NextStep.continue_;
                        }
                        else
                        {
                            rtToReturn = NextStep.return_;
                        }
                    }
                    else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(typeof(this))))
                    {
                        this.enqueue(this, event, uda._permissionsRequired, &fun, fullyQualifiedName!fun);

                        static if (uda._chainable || uda._isAwareness)
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
                    static if (uda._chainable || uda._isAwareness)
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

            alias Params = staticMap!(Unqual, Parameters!fun);

            static if (verbose)
            {
                writeln("   ...calling!");
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

            static if (uda._chainable || uda._isAwareness)
            {
                // onEvent found an event and triggered a function, but
                // it's Chainable and there may be more, so keep looking.
                // Alternatively it's an awareness function, which may be
                // sharing one or more annotations with another.
                return NextStep.continue_;
            }
            else
            {
                // The triggered function is not Chainable so return and
                // let the main loop continue with the next plugin.
                return NextStep.return_;
            }
        }

        alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEventHandler));

        alias setupFuns = Filter!(isSetupFun, funs);
        alias earlyFuns = Filter!(isEarlyFun, funs);
        alias lateFuns = Filter!(isLateFun, funs);
        alias cleanupFuns = Filter!(isCleanupFun, funs);
        alias pluginFuns = Filter!(isNormalEventHandler, funs);

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
        Collects all [kameloso.plugins.common.core.BotCommand] command words and
        [kameloso.plugins.common.core.BotRegex] regex expressions
        that this plugin offers at compile time, then at runtime returns them
        alongside their [Description]s and their visibility, as an associative
        array of [kameloso.plugins.common.core.IRCPlugin.CommandMetadata]s
        keyed by command name strings.

        Returns:
            Associative array of tuples of all [kameloso.plugins.common.core.Descriptions]
            and whether they are hidden, keyed by [kameloso.plugins.common.core.BotCommand.word]s
            and [kameloso.plugins.common.core.BotRegex.expression]s.
     +/
    override public IRCPlugin.CommandMetadata[string] commands() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import kameloso.plugins.common.core : BotCommand, BotRegex, Description;
            import lu.traits : getSymbolsByUDA;
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
    specified, as fetched from a [BotCommand] or [BotRegex] UDA.

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
bool prefixPolicyMatches(Flag!"verbose" verbose = No.verbose)
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


bool prefixPolicyMatches2(bool verbose = false)
    (ref IRCEvent event,
    const PrefixPolicy policy,
    const IRCClient client,
    const string prefix)
{
    return prefixPolicyMatches!(cast(Flag!"verbose")verbose)(event, policy, client, prefix);
}

// filterSender
/++
    Decides if a sender meets a [PermissionsRequired] and is allowed to trigger an event
    handler, or if a WHOIS query is needed to be able to tell.

    This requires the Persistence service to be active to work.

    Params:
        event = [dialect.defs.IRCEvent] to filter.
        level = The [PermissionsRequired] context in which this user should be filtered.
        preferHostmasks = Whether to rely on hostmasks for user identification,
            or to use services account logins, which need to be issued WHOIS
            queries to divine.

    Returns:
        A [FilterResult] saying the event should `pass`, `fail`, or that more
        information about the sender is needed via a WHOIS call.
 +/
FilterResult filterSender(const ref IRCEvent event,
    const PermissionsRequired level,
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
        else if (isStaff && (level <= PermissionsRequired.staff))
        {
            return FilterResult.pass;
        }
        else if (isOperator && (level <= PermissionsRequired.operator))
        {
            return FilterResult.pass;
        }
        else if (isWhitelisted && (level <= PermissionsRequired.whitelist))
        {
            return FilterResult.pass;
        }
        else if (/*event.sender.account.length &&*/ level <= PermissionsRequired.registered)
        {
            return FilterResult.pass;
        }
        else if (isAnyone && (level <= PermissionsRequired.anyone))
        {
            return whoisExpired ? FilterResult.whois : FilterResult.pass;
        }
        else if (level == PermissionsRequired.ignore)
        {
            /*assert(0, "`filterSender` saw a `PermissionsRequired.ignore` and the call " ~
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

        with (PermissionsRequired)
        final switch (level)
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
            /*assert(0, "`filterSender` saw a `PermissionsRequired.ignore` and the call " ~
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
    /++
        The current [dialect.defs.IRCClient], containing information pertaining
        to the bot in the context of a client connected to an IRC server.
     +/
    IRCClient client;

    /++
        The current [dialect.defs.IRCServer], containing information pertaining
        to the bot in the context of an IRC server.
     +/
    IRCServer server;

    /++
        The current [kameloso.kameloso.IRCBot], containing information pertaining
        to the bot in the context of an IRC bot.
     +/
    IRCBot bot;

    /++
        The current program-wide [kameloso.kameloso.CoreSettings].
     +/
    CoreSettings settings;

    /++
        The current program-wide [kameloso.kameloso.ConnectionSettings].
     +/
    ConnectionSettings connSettings;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
        Queued [dialect.defs.IRCEvent]s to replay.

        The main loop iterates this after processing all on-event functions so
        as to know what nicks the plugin wants a WHOIS for. After the WHOIS
        response returns, the event bundled with the [Replay] will be replayed.
     +/
    Replay[][string] replays;

    /// Whether or not [replays] has elements (i.e. is not empty).
    bool hasReplays;

    /// This plugin's array of [Repeat]s to let the main loop play back.
    Repeat[] repeats;

    /++
        The list of awaiting [core.thread.fiber.Fiber]s, keyed by
        [dialect.defs.IRCEvent.Type].
     +/
    Fiber[][] awaitingFibers;

    /++
        The list of awaiting `void delegate(const IRCEvent)` delegates, keyed by
        [dialect.defs.IRCEvent.Type].
     +/
    void delegate(const IRCEvent)[][] awaitingDelegates;

    /// The list of scheduled [core.thread.fiber.Fiber], UNIX time tuples.
    ScheduledFiber[] scheduledFibers;

    /// The list of scheduled delegate, UNIX time tuples.
    ScheduledDelegate[] scheduledDelegates;

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

    /// Whether or not [bot] was altered. Must be reset manually.
    bool botUpdated;

    /// Whether or not [client] was altered. Must be reset manually.
    bool clientUpdated;

    /// Whether or not [server] was altered. Must be reset manually.
    bool serverUpdated;

    /// Whether or not [settings] was altered. Must be reset manually.
    bool settingsUpdated;

    /// Pointer to the global abort flag.
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
    /// Name of the caller function or similar context.
    string caller;

    /// Stored [dialect.defs.IRCEvent] to replay.
    IRCEvent event;

    /// [PermissionsRequired] of the function to replay.
    PermissionsRequired perms;

    /// When this request was issued.
    long when;

    /// Replay the stored event.
    void trigger();

    /// Creates a new [Replay] with a timestamp of the current time.
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
    /// Stored function pointer/delegate.
    F fn;

    static if (!is(Payload == typeof(null)))
    {
        /// Command payload aside from the [dialect.defs.IRCEvent].
        Payload payload;


        /++
            Create a new [ReplayImpl] with the passed variables.

            Params:
                payload = Payload of templated type `Payload` to attach to this [ReplayImpl].
                event = [dialect.defs.IRCEvent] to attach to this [ReplayImpl].
                perms = The permissions level required to replay the
                    passed function.
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
         +/
        this(Payload payload, IRCEvent event, PermissionsRequired perms,
            F fn, const string caller)
        {
            super();

            this.payload = payload;
            this.event = event;
            this.perms = perms;
            this.fn = fn;
            this.caller = caller;
        }
    }
    else
    {
        /++
            Create a new [ReplayImpl] with the passed variables.

            Params:
                payload = Payload of templated type `Payload` to attach to this [ReplayImpl].
                fn = Function pointer to call with the attached payloads when
                    the replay is triggered.
         +/
        this(IRCEvent event, PermissionsRequired perms, F fn, const string caller)
        {
            super();

            this.event = event;
            this.perms = perms;
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
    PermissionsRequired pl = PermissionsRequired.admin;

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
    /// [core.thread.fiber.Fiber] to call to invoke this repeat.
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

    /// The [Replay] to repeat.
    Replay replay;

    /// UNIX timestamp of when this repeat event was created.
    long created;

    /// Constructor taking a [core.thread.fiber.Fiber] and a [Replay].
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


// PermissionsRequired
/++
    What level of permissions is needed to trigger an event handler.

    In any event handler context, the triggering user has a *level of privilege*.
    This decides whether or not they are allowed to trigger the function.
    Put simply this is the "barrier of entry" for event handlers.

    Permissions are set on a per-channel basis and are stored in the "users.json"
    file in the resource directory.
 +/
enum PermissionsRequired
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
        perms = The permissions level policy to apply to the WHOIS results.
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
    const PermissionsRequired perms,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!(Fn, SubPlugin)(subPlugin, event, perms, fn, caller);
}


// replay
/++
    Convenience function that returns a [ReplayImpl] of the right type,
    *without* a subclass plugin reference attached.

    Params:
        event = [dialect.defs.IRCEvent] that instigated the WHOIS lookup.
        perms = The permissions level policy to apply to the WHOIS results.
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
    const PermissionsRequired perms,
    Fn fn,
    const string caller = __FUNCTION__) @safe
{
    return new ReplayImpl!Fn(event, perms, fn, caller);
}


// BotCommand
/++
    Defines an IRC bot command, for people to trigger with messages.

    If no [PrefixPolicy] is specified then it will default to [PrefixPolicy.prefixed]
    and look for [kameloso.kameloso.CoreSettings.prefix] at the beginning of
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

    See_Also:
        [BotRegex]
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
        Create a new [BotCommand] with the passed policy, trigger word, and hidden flag.
     +/
    this(const PrefixPolicy policy, const string word, const Flag!"hidden" hidden = No.hidden) pure
    {
        this.policy = policy;
        this.word = word;
        this.hidden = hidden;
    }

    /++
        Create a new [BotCommand] with a default [PrefixPolicy.prefixed] policy
        and the passed trigger word.
     +/
    this(const string word, const Flag!"hidden" hidden = No.hidden) pure
    {
        this.word = word;
    }
}


enum Timing
{
    unset,
    setup,
    early,
    late,
    cleanup
}


// IRCEventHandler
struct IRCEventHandler
{
    IRCEvent.Type[] _eventTypes;

    PermissionsRequired _permissionsRequired = PermissionsRequired.ignore;

    ChannelPolicy _channelPolicy = ChannelPolicy.home;

    Command[] _commands;

    Regex[] _regexes;

    bool _chainable;

    bool _verbose;

    bool _isAwareness;

    Timing _when;

    auto ref onEvent(const IRCEvent.Type eventType)
    {
        this._eventTypes ~= eventType;
        return this;
    }

    auto ref permissionsRequired(const PermissionsRequired permissionsRequired)
    {
        this._permissionsRequired = permissionsRequired;
        return this;
    }

    auto ref channelPolicy(const ChannelPolicy channelPolicy)
    {
        this._channelPolicy = channelPolicy;
        return this;
    }

    auto ref addCommand(const Command command)
    {
        this._commands ~= command;
        return this;
    }

    auto ref addRegex(/*const*/ Regex regex)
    {
        this._regexes ~= regex;
        return this;
    }

    auto ref chainable(const bool chainable)
    {
        this._chainable = chainable;
        return this;
    }

    auto ref verbose(const bool verbose)
    {
        this._verbose = verbose;
        return this;
    }

    auto ref isAwareness(const bool isAwareness)
    {
        this._isAwareness = isAwareness;
        return this;
    }

    auto ref when(const Timing when)
    {
        this._when = when;
        return this;
    }

    // Command
    static struct Command
    {
        /++
            In what way the message is required to start for the annotated function to trigger.
        +/
        PrefixPolicy _policy = PrefixPolicy.prefixed;

        /++
            The command word, without spaces.
        +/
        string _word;

        string _description;

        string _syntax;

        /++
            Whether this is a hidden command or if it should show up in help listings.
        +/
        bool _hidden;

        auto ref policy(const PrefixPolicy policy)
        {
            this._policy = policy;
            return this;
        }

        auto ref word(const string word)
        {
            this._word = word;
            return this;
        }

        auto ref description(const string description)
        {
            this._description = description;
            return this;
        }

        auto ref syntax(const string syntax)
        {
            this._syntax = syntax;
            return this;
        }

        auto ref hidden(const bool hidden)
        {
            this._hidden = hidden;
            return this;
        }
    }

    static struct Regex
    {
        import std.regex : StdRegex = Regex, regex;

        /++
            In what way the message is required to start for the annotated function to trigger.
         +/
        PrefixPolicy _policy = PrefixPolicy.direct;

        /++
            Regex engine to match incoming messages with.
         +/
        StdRegex!char _engine;

        /++
            The regular expression in string form.
         +/
        string _expression;

        string _description;

        /++
            Whether this is a hidden command or if it should show up in help listings.
         +/
        bool _hidden;

        auto ref policy(const PrefixPolicy policy)
        {
            this._policy = policy;
            return this;
        }

        auto ref expression(const string expression)
        {
            this._expression = expression;
            this._engine = expression.regex;
            return this;
        }

        auto ref description(const string description)
        {
            this._description = description;
            return this;
        }

        auto ref hidden(const bool hidden)
        {
            this._hidden = hidden;
            return this;
        }
    }
}


// BotRegex
/++
    Defines an IRC bot regular expression, for people to trigger with messages.

    If no [PrefixPolicy] is specified then it will default to [PrefixPolicy.direct]
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

    See_Also:
        [BotCommand]
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
        Creates a new [BotRegex] with the passed policy, regex expression and hidden flag.
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
        Creates a new [BotRegex] with the passed regex expression.
     +/
    this(const string expression, const Flag!"hidden" hidden = No.hidden)
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
        [Terminating]
 +/
enum Chainable;


// Terminating
/++
    Annotation denoting that an event-handling function is the end of a chain,
    letting no other functions in the same module be triggered after it has been.

    This is not strictly necessary since anything non-[Chainable] is implicitly
    [Terminating], but it's here to silence warnings and in hopes of the code
    becoming more self-documenting.

    See_Also:
        [Chainable]
 +/
enum Terminating;


// Verbose
/++
    Annotation denoting that we want verbose debug output of the plumbing when
    handling events, iterating through the module's event handler functions.
 +/
enum Verbose;


// Settings
/++
    Annotation denoting that a struct variable or struct type is to be considered
    as housing settings for a plugin, and should thus be serialised and saved in
    the configuration file.
 +/
enum Settings;


// Description
/++
    Describes an [dialect.defs.IRCEvent]-annotated handler function.

    This is used to describe functions triggered by [BotCommand]s, in the help
    listing routine in [kameloso.plugins.chatbot].
 +/
struct Description
{
    /// Description string.
    string line;

    /// Command usage syntax help string.
    string syntax;

    /// Creates a new [Description] with the passed [line] description text.
    this(const string line, const string syntax = string.init)
    {
        this.line = line;
        this.syntax = syntax;
    }
}


/++
    Annotation denoting that a variable is the basename of a resource file or directory.
 +/
enum Resource;


/++
    Annotation denoting that a variable is the basename of a configuration
    file or directory.
 +/
enum Configuration;


/++
    Annotation denoting that a variable enables and disables a plugin.
 +/
enum Enabler;

/++
 +  Contains the definition of an `IRCPlugin`, as well as a mixin `IRCPluginImpl`
 +  to fully implement one.
 +
 +  Event handlers can then be module-level functions, annotated with
 +  `dialect.defs.IRCEvent.Type`s.
 +
 +  Example:
 +  ---
 +  import kameloso.plugins.ircplugin;
 +  import kameloso.plugins.common;
 +  import kameloso.plugins.awareness;
 +
 +  @(IRCEvent.Type.CHAN)
 +  @(ChannelPolicy.home)
 +  @(PrefixPolicy.prefixed)
 +  @BotCommand(PrivilegeLevel.anyone, "foo")
 +  void onFoo(FooPlugin plugin, const IRCEvent event)
 +  {
 +      // ...
 +  }
 +
 +  mixin UserAwareness;
 +  mixin ChannelAwareness;
 +
 +  final class FooPlugin : IRCPlugin
 +  {
 +      // ...
 +
 +      mixin IRCPluginImpl;
 +  }
 +  ---
 +/
module kameloso.plugins.ircplugin;

private:

import kameloso.plugins.common;
import dialect.defs;

version = PrefixedCommandsFallBackToNickname;

public:


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

    /++
     +  Read serialised configuration text into the plugin's settings struct.
     +
     +  Stores an associative array of `string[]`s of missing entries in its
     +  first `out string[][string]` parameter, and the invalid encountered
     +  entries in the second.
     +/
    void deserialiseConfigFrom(const string, out string[][string], out string[][string]);

    import std.array : Appender;
    /// Executed when gathering things to put in the configuration file.
    bool serialiseConfigInto(ref Appender!string) const;

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
    string name() @property const pure nothrow @nogc;

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

    import kameloso.thread : Sendable;
    /// Executed when a bus message arrives from another plugin.
    void onBusMessage(const string, shared Sendable content) @system;

    /// Returns whether or not the plugin is enabled in its configuration section.
    bool isEnabled() const @property pure nothrow @nogc;
}


// IRCPluginImpl
/++
 +  Mixin that fully implements an `IRCPlugin`.
 +
 +  Uses compile-time introspection to call module-level functions to extend behaviour.
 +
 +  With UFCS, transparently emulates all such as being member methods of the
 +  mixing-in class.
 +
 +  Example:
 +  ---
 +  final class MyPlugin : IRCPlugin
 +  {
 +      @Settings MyPluginSettings myPluginSettings;
 +
 +      // ...implementation...
 +
 +      mixin IRCPluginImpl;
 +  }
 +  ---
 +/
version(WithPlugins)
mixin template IRCPluginImpl(bool debug_ = false, string module_ = __MODULE__)
{
    private import kameloso.plugins.common;
    private import core.thread : Fiber;

    /// Symbol needed for the mixin constraints to work.
    private static enum mixinSentinel = true;

    // Use a custom constraint to force the scope to be an IRCPlugin
    static if(!is(__traits(parent, mixinSentinel) : IRCPlugin))
    {
        import lu.traits : CategoryName;
        import std.format : format;

        alias pluginImplParent = __traits(parent, mixinSentinel);
        alias pluginImplParentInfo = CategoryName!pluginImplParent;

        static assert(0, ("%s `%s` mixes in `%s` but it is only supposed to be " ~
            "mixed into an `IRCPlugin` subclass")
            .format(pluginImplParentInfo.type, pluginImplParentInfo.fqn, "IRCPluginImpl"));
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

    /++
     +  This plugin's `IRCPluginState` structure. Has to be public for some things to work.
     +/
    public IRCPluginState privateState;


    // isEnabled
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
    pragma(inline)
    public bool isEnabled() const @property pure nothrow @nogc
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
                    foreach (immutable n, immutable submember; this.tupleof[i].tupleof)
                    {
                        static if (isAnnotated!(this.tupleof[i].tupleof[n], Enabler))
                        {
                            import std.traits : Unqual;
                            alias ThisEnabler = Unqual!(typeof(this.tupleof[i].tupleof[n]));

                            static assert(is(ThisEnabler : bool),
                                '`' ~ Unqual!(typeof(this)).stringof ~
                                "` has a non-bool `Enabler`: `" ~ ThisEnabler.stringof ~ '`');

                            retval = submember;
                            break top;
                        }
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
     +  Pass the passed arguments to `filterSender`, doing nothing otherwise.
     +
     +  Sadly we can't keep an `allow` around to override since calling it from
     +  inside the same mixin always seems to resolve the original. So instead,
     +  only have `allowImpl` and use introspection to determine whether to call
     +  that or any custom-defined `allow` in `typeof(this)`.
     +
     +  Params:
     +      event = `dialect.defs.IRCEvent` to allow, or not.
     +      privilegeLevel = `PrivilegeLevel` of the handler in question.
     +
     +  Returns:
     +      `true` if the event should be allowed to trigger, `false` if not.
     +/
    private FilterResult allowImpl(const IRCEvent event, const PrivilegeLevel privilegeLevel)
    {
        version(TwitchSupport)
        {
            if (privateState.server.daemon == IRCServer.Daemon.twitch)
            {
                if ((privilegeLevel == PrivilegeLevel.anyone) ||
                    (privilegeLevel == PrivilegeLevel.registered))
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
            filterSender(privateState, event, privilegeLevel,
                privateState.settings.preferHostmasks);
    }


    // onEvent
    /++
     +  Pass on the supplied `dialect.defs.IRCEvent` to `onEventImpl`.
     +
     +  This is made a separate function to allow plugins to override it and
     +  insert their own code, while still leveraging `onEventImpl` for the
     +  actual dirty work.
     +
     +  Params:
     +      event = Parse `dialect.defs.IRCEvent` to pass onto `onEventImpl`.
     +
     +  See_Also:
     +      onEventImpl
     +/
    public void onEvent(const IRCEvent event) @system
    {
        return onEventImpl(event);
    }


    // onEventImpl
    /++
     +  Pass on the supplied `dialect.defs.IRCEvent` to module-level functions
     +  annotated with the matching `dialect.defs.IRCEvent.Type`s.
     +
     +  It also does checks for `kameloso.plugins.common.ChannelPolicy`,
     +  `kameloso.plugins.common.PrivilegeLevel`, `kameloso.plugins.common.PrefixPolicy`,
     +  `kameloso.plugins.common.BotCommand`, `kameloso.plugins.common.BotRegex`
     +  etc; where such is applicable.
     +
     +  Params:
     +      event = Parsed `dialect.defs.IRCEvent` to dispatch to event handlers.
     +/
    private void onEventImpl(const IRCEvent event) @system
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.plugins.awareness : Awareness;
        import lu.string : contains, nom;
        import lu.traits : getSymbolsByUDA, isAnnotated;
        import std.meta : Filter, templateNot, templateOr;
        import std.traits : isSomeFunction, fullyQualifiedName, getUDAs, hasUDA;

        if (!isEnabled) return;

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

        /++
         +  Process a function.
         +/
        Next handle(alias fun)(const IRCEvent event)
        {
            enum verbose = isAnnotated!(fun, Verbose) || debug_;

            static if (verbose)
            {
                import lu.conv : Enum;
                import std.format : format;
                import std.stdio : stdout, writeln, writefln;

                enum name = "[%s] %s".format(__traits(identifier, thisModule),
                    __traits(identifier, fun));
            }

            /++
             +  Whether or not this event matched the type of one or more of
             +  this function's annotations.
             +/
            bool typeMatches;

            udaloop:
            foreach (immutable eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
            {
                static if (eventTypeUDA == IRCEvent.Type.UNSET)
                {
                    import std.format : format;
                    static assert(0, ("`%s` is annotated `@(IRCEvent.Type.UNSET)`, " ~
                        "which is not a valid event type.")
                        .format(fullyQualifiedName!fun));
                }
                else static if (eventTypeUDA == IRCEvent.Type.PRIVMSG)
                {
                    import std.format : format;
                    static assert(0, ("`%s` is annotated `@(IRCEvent.Type.PRIVMSG)`, " ~
                        "which is not a valid event type. Use `IRCEvent.Type.CHAN` " ~
                        "or `IRCEvent.Type.QUERY` instead")
                        .format(fullyQualifiedName!fun));
                }
                else static if (eventTypeUDA == IRCEvent.Type.WHISPER)
                {
                    import std.format : format;
                    static assert(0, ("`%s` is annotated `@(IRCEvent.Type.WHISPER)`, " ~
                        "which is not a valid event type. Use `IRCEvent.Type.QUERY` instead")
                        .format(fullyQualifiedName!fun));
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

                        pragma(msg, ("Note: `%s` is a wildcard `IRCEvent.Type.%s` event " ~
                            "but is not `Chainable` nor `Terminating`")
                            .format(fullyQualifiedName!fun,
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
                                pragma(msg, ("`%s` is annotated with " ~
                                    "`IRCEvent.Type.%s` but is missing a `PrivilegeLevel`")
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

                                static assert(0, ("`%s` is annotated with a user-facing " ~
                                    "`IRCEvent.Type.%s` but is missing a `PrivilegeLevel`")
                                    .format(fullyQualifiedName!fun,
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

                            static assert(0, ("`%s` is annotated with a `BotCommand` " ~
                                "or `BotRegex` but is at the same time annotated " ~
                                "with a non-message `IRCEvent.Type.%s`")
                                .format(fullyQualifiedName!fun,
                                Enum!(IRCEvent.Type).toString(U)));
                        }
                    }

                    break udaloop;
                }
            }

            // Invalid type, continue with the next function
            if (!typeMatches) return Next.continue_;

            static if (verbose)
            {
                writeln("-- ", name, " @ ", Enum!(IRCEvent.Type).toString(event.type));
                if (privateState.settings.flush) stdout.flush();
            }

            static if (!hasUDA!(fun, ChannelPolicy) ||
                getUDAs!(fun, ChannelPolicy)[0] == ChannelPolicy.home)
            {
                import std.algorithm.searching : canFind;

                // Default policy if none given is `ChannelPolicy.home`

                static if (verbose)
                {
                    writeln("...ChannelPolicy.home");
                    if (privateState.settings.flush) stdout.flush();
                }

                if (!event.channel.length)
                {
                    // it is a non-channel event, like a `dialect.defs.IRCEvent.Type.QUERY`
                }
                else if (!privateState.bot.homeChannels.canFind(event.channel))
                {
                    static if (verbose)
                    {
                        writeln("...ignore non-home channel ", event.channel);
                        if (privateState.settings.flush) stdout.flush();
                    }

                    // channel policy does not match
                    return Next.continue_;  // next fun
                }
            }
            else
            {
                static if (verbose)
                {
                    writeln("...ChannelPolicy.any");
                    if (privateState.settings.flush) stdout.flush();
                }
            }

            static if (hasUDA!(fun, BotCommand) || hasUDA!(fun, BotRegex))
            {
                if (!event.content.length)
                {
                    // Event has a `BotCommand` or a `BotRegex`set up but
                    // `event.content` is empty; cannot possibly be of interest.
                    return Next.continue_;  // next function
                }
            }

            IRCEvent mutEvent = event;  // mutable
            bool commandMatch;  // Whether or not a BotCommand or BotRegex matched

            // Evaluate each BotCommand UDAs with the current event
            static if (hasUDA!(fun, BotCommand))
            {
                foreach (immutable commandUDA; getUDAs!(fun, BotCommand))
                {
                    import lu.string : contains;

                    static if (!commandUDA.word.length)
                    {
                        import std.format : format;
                        static assert(0, "`%s` has an empty `BotCommand` word"
                            .format(fullyQualifiedName!fun));
                    }
                    else static if (commandUDA.word.contains(" "))
                    {
                        import std.format : format;
                        static assert(0, ("`%s` has a `BotCommand` word " ~
                            "that has spaces in it")
                            .format(fullyQualifiedName!fun));
                    }

                    static if (verbose)
                    {
                        writefln(`...BotCommand "%s"`, commandUDA.word);
                        if (privateState.settings.flush) stdout.flush();
                    }

                    // Reset between iterations as we nom the contents
                    mutEvent = event;

                    if (!mutEvent.prefixPolicyMatches!verbose(commandUDA.policy,
                        privateState.client, privateState.settings.prefix))
                    {
                        static if (verbose)
                        {
                            writeln("...policy doesn't match; continue next BotCommand");
                            if (privateState.settings.flush) stdout.flush();
                        }

                        continue;  // next BotCommand UDA
                    }

                    import lu.string : strippedLeft;
                    import std.algorithm.comparison : equal;
                    import std.typecons : No, Yes;
                    import std.uni : asLowerCase;

                    mutEvent.content = mutEvent.content.strippedLeft;
                    immutable thisCommand = mutEvent.content.nom!(Yes.inherit, Yes.decode)(' ');

                    if (thisCommand.asLowerCase.equal(commandUDA.word.asLowerCase))
                    {
                        static if (verbose)
                        {
                            writeln("...command matches!");
                            if (privateState.settings.flush) stdout.flush();
                        }

                        mutEvent.aux = thisCommand;
                        commandMatch = true;
                        break;  // finish this BotCommand
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
                            if (privateState.settings.flush) stdout.flush();
                        }

                        // Reset between iterations; BotCommands may have altered it
                        mutEvent = event;

                        if (!mutEvent.prefixPolicyMatches!verbose(regexUDA.policy,
                            privateState.client, privateState.settings.prefix))
                        {
                            static if (verbose)
                            {
                                writeln("...policy doesn't match; continue next BotRegex");
                                if (privateState.settings.flush) stdout.flush();
                            }

                            continue;  // next BotRegex UDA
                        }

                        try
                        {
                            import std.regex : matchFirst;

                            const hits = mutEvent.content.matchFirst(regexUDA.engine);

                            if (!hits.empty)
                            {
                                static if (verbose)
                                {
                                    writeln("...expression matches!");
                                    if (privateState.settings.flush) stdout.flush();
                                }

                                mutEvent.aux = hits[0];
                                commandMatch = true;
                                break;  // finish this BotRegex
                            }
                            else
                            {
                                static if (verbose)
                                {
                                    writefln(`...matching "%s" against expression "%s" failed.`,
                                        mutEvent.content, regexUDA.expression);
                                }
                            }
                        }
                        catch (Exception e)
                        {
                            static if (verbose)
                            {
                                writeln("...BotRegex exception: ", e.msg);
                                version(PrintStacktraces) writeln(e.toString);
                                if (privateState.settings.flush) stdout.flush();
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
                        if (privateState.settings.flush) stdout.flush();
                    }

                    return Next.continue_; // next function
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
                        static assert(0, ("`%s` is missing a `MinimalAuthentication` " ~
                            "mixin (needed for `PrivilegeLevel` checks)")
                            .format(module_));
                    }
                }

                static if (verbose)
                {
                    writeln("...PrivilegeLevel.", Enum!PrivilegeLevel.toString(privilegeLevel));
                    if (privateState.settings.flush) stdout.flush();
                }

                static if (__traits(hasMember, this, "allow") && isSomeFunction!(this.allow))
                {
                    import lu.traits : TakesParams;

                    static if (!TakesParams!(this.allow, IRCEvent, PrivilegeLevel))
                    {
                        import std.format : format;
                        static assert(0, ("Custom `allow` function in `%s` " ~
                            "has an invalid signature: `%s`")
                            .format(fullyQualifiedName!(typeof(this)), typeof(this.allow).stringof));
                    }

                    static if (verbose)
                    {
                        writeln("...custom allow!");
                        if (privateState.settings.flush) stdout.flush();
                    }

                    immutable result = this.allow(mutEvent, privilegeLevel);
                }
                else
                {
                    static if (verbose)
                    {
                        writeln("...built-in allow.");
                        if (privateState.settings.flush) stdout.flush();
                    }

                    immutable result = allowImpl(mutEvent, privilegeLevel);
                }

                static if (verbose)
                {
                    writeln("...result is ", Enum!FilterResult.toString(result));
                    if (privateState.settings.flush) stdout.flush();
                }

                with (FilterResult)
                final switch (result)
                {
                case pass:
                    // Drop down
                    break;

                case whois:
                    import kameloso.plugins.common : enqueue;
                    import std.traits : fullyQualifiedName;

                    alias Params = staticMap!(Unqual, Parameters!fun);
                    enum isIRCPluginParam(T) = is(T == IRCPlugin);

                    static if (verbose)
                    {
                        writefln("...%s WHOIS", typeof(this).stringof);
                        if (privateState.settings.flush) stdout.flush();
                    }

                    static if (is(Params : AliasSeq!IRCEvent) || (arity!fun == 0))
                    {
                        this.enqueue(mutEvent, privilegeLevel, &fun, fullyQualifiedName!fun);
                        return Next.continue_;  // Next function
                    }
                    else static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                        is(Params : AliasSeq!(typeof(this))))
                    {
                        this.enqueue(this, mutEvent, privilegeLevel, &fun, fullyQualifiedName!fun);
                        return Next.continue_;  // Next function
                    }
                    else static if (Filter!(isIRCPluginParam, Params).length)
                    {
                        import std.format : format;
                        static assert(0, ("`%s` takes a superclass `IRCPlugin` " ~
                            "parameter instead of a subclass `%s`")
                            .format(fullyQualifiedName!fun, typeof(this).stringof));
                    }
                    else
                    {
                        import std.format : format;
                        static assert(0, "`%s` has an unsupported function signature: `%s`"
                            .format(fullyQualifiedName!fun, typeof(fun).stringof));
                    }

                case fail:
                    return Next.continue_;  // Next function
                }
            }

            alias Params = staticMap!(Unqual, Parameters!fun);

            static if (verbose)
            {
                writeln("...calling!");
                if (privateState.settings.flush) stdout.flush();
            }

            static if (is(Params : AliasSeq!(typeof(this), IRCEvent)) ||
                is(Params : AliasSeq!(IRCPlugin, IRCEvent)))
            {
                fun(this, mutEvent);
            }
            else static if (is(Params : AliasSeq!(typeof(this))) ||
                (is(Params : AliasSeq!IRCPlugin) && isAwarenessFunction!fun))
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
            else static if (Filter!(isIRCPluginParam, Params).length)
            {
                import std.format : format;
                static assert(0, ("`%s` takes a superclass `IRCPlugin` " ~
                    "parameter instead of a subclass `%s`")
                    .format(fullyQualifiedName!fun, typeof(this).stringof));
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
                return Next.continue_;
            }
            else /*static if (isAnnotated!(fun, Terminating))*/
            {
                // The triggered function is not Chainable so return and
                // let the main loop continue with the next plugin.
                return Next.return_;
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
                        if (handle!fun(event) == continue_)
                        {
                            continue;
                        }
                        else
                        {
                            return;
                        }

                    case return_:
                        return;
                    }
                }
                catch (UTFException e)
                {
                    /*logger.warningf("tryCatchHandle UTFException on %s: %s",
                        __traits(identifier, fun), e.msg);*/

                    IRCEvent saneEvent = event;
                    sanitizeEvent(saneEvent);
                    handle!fun(saneEvent);
                }
                catch (UnicodeException e)
                {
                    /*logger.warningf("tryCatchHandle UnicodeException on %s: %s",
                        __traits(identifier, fun), e.msg);*/

                    IRCEvent saneEvent = event;
                    sanitizeEvent(saneEvent);
                    handle!fun(saneEvent);
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
     +  It passes execution to the module-level `initialise` if it exists.
     +
     +  There's no point in checking whether the plugin is enabled or not, as it
     +  will only be possible to change the setting after having created the
     +  plugin (and serialised settings into it).
     +
     +  Params:
     +      state = The aggregate of all plugin state variables, making
     +          this the "original state" of the plugin.
     +/
    public this(IRCPluginState state) @system
    {
        import lu.traits : isAnnotated, isSerialisable;
        import std.traits : EnumMembers;

        this.privateState = state;
        this.privateState.awaitingFibers = state.awaitingFibers.dup;
        this.privateState.awaitingFibers.length = EnumMembers!(IRCEvent.Type).length;
        this.privateState.replays = state.replays.dup;
        this.privateState.repeats = state.repeats.dup;
        this.privateState.scheduledFibers = state.scheduledFibers.dup;

        foreach (immutable i, ref member; this.tupleof)
        {
            static if (isSerialisable!member)
            {
                static if (isAnnotated!(this.tupleof[i], Resource))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(privateState.settings.resourceDirectory, member)
                        .expandTilde;
                }
                else static if (isAnnotated!(this.tupleof[i], Configuration))
                {
                    import std.path : buildNormalizedPath, expandTilde;
                    member = buildNormalizedPath(privateState.settings.configDirectory, member)
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
     +  Lets a plugin modify an `dialect.defs.IRCEvent` while it's begin
     +  constructed, before it's finalised and passed on to be handled.
     +
     +  Params:
     +      event = The `dialect.defs.IRCEvent` in flight.
     +/
    public void postprocess(ref IRCEvent event) @system
    {
        static if (__traits(compiles, .postprocess))
        {
            import lu.traits : TakesParams;

            if (!isEnabled) return;

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
     +  Writes plugin resources to disk, creating them if they don't exist.
     +/
    public void initResources() @system
    {
        static if (__traits(compiles, .initResources))
        {
            import lu.traits : TakesParams;

            if (!isEnabled) return;

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
     +  Loads configuration for this plugin from disk.
     +
     +  This does not proxy a call but merely loads configuration from disk for
     +  all struct variables annotated `Settings`.
     +
     +  "Returns" two associative arrays for missing entries and invalid
     +  entries via its two out parameters.
     +
     +  Params:
     +      configFile = String of the configuration file to read.
     +      missingEntries = Out reference of an associative array of string arrays
     +          of expected configuration entries that were missing.
     +      invalidEntries = Out reference of an associative array of string arrays
     +          of unexpected configuration entries that did not belong.
     +/
    public void deserialiseConfigFrom(const string configFile,
        out string[][string] missingEntries, out string[][string] invalidEntries)
    {
        import kameloso.config : readConfigInto;
        import lu.meld : MeldingStrategy, meldInto;
        import lu.traits : isAnnotated;

        foreach (immutable i, const ref symbol; this.tupleof)
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
     +  Change a plugin's `Settings`-annotated settings struct member by their
     +  string name.
     +
     +  This is used to allow for command-line argument to set any plugin's
     +  setting by only knowing its name.
     +
     +  Example:
     +  ---
     +  @Settings struct FooSettings
     +  {
     +      int bar;
     +  }
     +
     +  FooSettings settings;
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
    public bool setSettingByName(const string setting, const string value)
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
     +  Prints the plugin's `Settings`-annotated settings struct.
     +/
    public void printSettings() const
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

                printObject!(No.printAll)(symbol);
                break;
            }
        }
    }


    import std.array : Appender;

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
     +
     +  Returns:
     +      true if something was serialised into the passed `sink`; false if not.
     +/
    public bool serialiseConfigInto(ref Appender!string sink) const
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
     +  Runs early after-connect routines, immediately after connection has been
     +  established.
     +/
    public void start() @system
    {
        static if (__traits(compiles, .start))
        {
            import lu.traits : TakesParams;

            if (!isEnabled) return;

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
     +  De-initialises the plugin.
     +/
    public void teardown() @system
    {
        static if (__traits(compiles, .teardown))
        {
            import lu.traits : TakesParams;

            if (!isEnabled) return;

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
     +  Returns the name of the plugin. (Technically it's the name of the module.)
     +
     +  Returns:
     +      The module name of the mixing-in class.
     +/
    pragma(inline)
    public string name() @property const pure nothrow @nogc
    {
        mixin("static import thisModule = " ~ module_ ~ ";");
        return __traits(identifier, thisModule);
    }


    // commands
    /++
     +  Collects all `BotCommand` command words and `BotRegex` regex expressions
     +  that this plugin offers at compile time, then at runtime returns them
     +  alongside their `Description`s as an associative `Description[string]` array.
     +
     +  Returns:
     +      Associative array of all `Descriptions`, keyed by
     +      `BotCommand.word`s and `BotRegex.expression`s.
     +/
    public Description[string] commands() pure nothrow @property const
    {
        enum ctCommandsEnumLiteral =
        {
            import lu.traits : getSymbolsByUDA, isAnnotated;
            import std.meta : AliasSeq, Filter;
            import std.traits : getUDAs, hasUDA, isSomeFunction;

            mixin("static import thisModule = " ~ module_ ~ ";");

            alias symbols = getSymbolsByUDA!(thisModule, BotCommand);
            alias funs = Filter!(isSomeFunction, symbols);

            Description[string] descriptions;

            foreach (fun; funs)
            {
                foreach (immutable uda; AliasSeq!(getUDAs!(fun, BotCommand),
                    getUDAs!(fun, BotRegex)))
                {
                    static if (uda.hidden)
                    {
                        // Do nothing
                    }
                    else static if (hasUDA!(fun, Description))
                    {
                        static if (is(typeof(uda) : BotCommand))
                        {
                            enum key = uda.word;
                        }
                        else /*static if (is(typeof(uda) : BotRegex))*/
                        {
                            enum key = `r"` ~ uda.expression ~ `"`;
                        }

                        enum desc = getUDAs!(fun, Description)[0];
                        descriptions[key] = desc;

                        static if (uda.policy == PrefixPolicy.nickname)
                        {
                            static if (desc.syntax.length)
                            {
                                // Prefix the command with the bot's nickname,
                                // as that's how it's actually used.
                                descriptions[key].syntax = "$nickname: " ~ desc.syntax;
                            }
                            else
                            {
                                // Define an empty nickname: command syntax
                                // to give hint about the nickname prefix
                                descriptions[key].syntax = "$nickname: $command";
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

            return descriptions;
        }();

        // This is an associative array literal. We can't make it static immutable
        // because of AAs' runtime-ness. We could make it runtime immutable once
        // and then just the address, but this is really not a hotspot.
        // So just let it allocate when it wants.
        return isEnabled ? ctCommandsEnumLiteral : (Description[string]).init;
    }


    // state
    /++
     +  Accessor and mutator, returns a reference to the current private
     +  `IRCPluginState`.
     +
     +  This is needed to have `state` be part of the `IRCPlugin` *interface*,
     +  so `kameloso.d` can access the property, albeit indirectly.
     +/
    pragma(inline)
    public ref inout(IRCPluginState) state() inout pure nothrow @nogc @property
    {
        return this.privateState;
    }


    // periodically
    /++
     +  Calls `.periodically` on a plugin if the internal private timestamp says
     +  the interval since the last call has passed, letting the plugin do
     +  maintenance tasks.
     +
     +  Params:
     +      now = The current time expressed in UNIX time.
     +/
    public void periodically(const long now) @system
    {
        static if (__traits(compiles, .periodically))
        {
            if (now >= privateState.nextPeriodical)
            {
                import lu.traits : TakesParams;

                static if (TakesParams!(.periodically, typeof(this)))
                {
                    .periodically(this);
                }
                else static if (TakesParams!(.periodically, typeof(this), long))
                {
                    .periodically(this, now);
                }
                else
                {
                    import std.format : format;
                    static assert(0, "`%s.periodically` has an unsupported function signature: `%s`"
                        .format(module_, typeof(.periodically).stringof));
                }
            }
        }
    }


    // reload
    /++
     +  Reloads the plugin, where such makes sense.
     +
     +  What this means is implementation-defined.
     +/
    public void reload() @system
    {
        static if (__traits(compiles, .reload))
        {
            import lu.traits : TakesParams;

            if (!isEnabled) return;

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


    import kameloso.thread : Sendable;

    // onBusMessage
    /++
     +  Proxies a bus message to the plugin, to let it handle it (or not).
     +
     +  Params:
     +      header = String header for plugins to examine and decide if the
     +          message was meant for them.
     +      content = Wildcard content, to be cast to concrete types if the header matches.
     +/
    public void onBusMessage(const string header, shared Sendable content) @system
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
 +  Evaluates whether or not the message in an event satisfies the `PrefixPolicy`
 +  specified, as fetched from a `BotCommand` or `BotRegex` UDA.
 +
 +  If it doesn't match, the `onEvent` routine shall consider the UDA as not
 +  matching and continue with the next one.
 +
 +  Params:
 +      verbose = Whether or not to output verbose debug information to the local terminal.
 +      mutEvent = Reference to the mutable `dialect.defs.IRCEvent` we're considering.
 +      policy = Policy to apply.
 +      client = `dialect.defs.IRCClient` of the calling `IRCPlugin`'s `IRCPluginState`.
 +      prefix = The prefix as set in the program-wide settings.
 +
 +  Returns:
 +      `true` if the message is in a context where the event matches the
 +      `policy`, `false` if not.
 +/
bool prefixPolicyMatches(bool verbose = false)(ref IRCEvent mutEvent,
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

    with (mutEvent)
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
        if (prefix.length && content.beginsWith(prefix))
        {
            static if (verbose)
            {
                writefln("starts with prefix (%s)", prefix);
            }

            content.nom!(Yes.decode)(prefix);
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
        if (content.beginsWith('@'))
        {
            static if (verbose)
            {
                writeln("stripped away prepended '@'");
            }

            // Using @name to refer to someone is not
            // uncommon; allow for it and strip it away
            content = content[1..$];
        }

        if (content.beginsWith(client.nickname))
        {
            static if (verbose)
            {
                writeln("begins with nickname! stripping it");
            }

            content = content.stripSeparatedPrefix!(Yes.demandSeparatingChars)(client.nickname);
            // Drop down
        }
        else if (type == IRCEvent.Type.QUERY)
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
 +  Decides if a sender meets a `PrivilegeLevel` and is allowed to trigger an event
 +  handler, or if a WHOIS query is needed to be able to tell.
 +
 +  This requires the Persistence service to be active to work.
 +
 +  Params:
 +      state = Reference to the `IRCPluginState` of the invoking plugin.
 +      event = `dialect.defs.IRCEvent` to filter.
 +      level = The `PrivilegeLevel` context in which this user should be filtered.
 +      preferHostmasks = Whether to rely on hostmasks for user identification,
 +          or to use services account logins, which need to be issued WHOIS
 +          queries to divine.
 +
 +  Returns:
 +      A `FilterResult` saying the event should `pass`, `fail`, or that more
 +      information about the sender is needed via a WHOIS call.
 +/
FilterResult filterSender(const ref IRCPluginState state, const IRCEvent event,
    const PrivilegeLevel level, const bool preferHostmasks) @safe
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
        immutable isOperator = (class_ == IRCUser.Class.operator);
        immutable isWhitelisted = (class_ == IRCUser.Class.whitelist);
        immutable isAnyone = (class_ == IRCUser.Class.anyone);

        if (isAdmin)
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
                "to it could have been skippped");*/
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
                "to it could have been skippped");*/
            return FilterResult.pass;
        }
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
    import kameloso.common : CoreSettings, IRCBot;
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

    /++
     +  The current program-wide `kameloso.common.CoreSettings`.
     +/
    CoreSettings settings;

    /// Thread ID to the main thread.
    Tid mainThread;

    /// Hashmap of IRC user details.
    IRCUser[string] users;

    /// Hashmap of IRC channels.
    IRCChannel[string] channels;

    /++
     +  Queued `dialect.defs.IRCEvent`s to replay.
     +
     +  The main loop iterates this after processing all on-event functions so
     +  as to know what nicks the plugin wants a WHOIS for. After the WHOIS
     +  response returns, the event bundled with the `Replay` will be replayed.
     +/
    Replay[][string] replays;

    /// This plugin's array of `Repeat`s to let the main loop play back.
    Repeat[] repeats;

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
     +  `kameloso.thread.ScheduledFiber` should be triggered.
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

    /// Whether or not `settings` was altered. Must be reset manually.
    bool settingsUpdated;
}

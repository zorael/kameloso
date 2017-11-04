module kameloso.plugins.common;

import kameloso.common : Settings;
import kameloso.irc;
import std.typecons : Flag;


// IRCPlugin
/++
 +  Interface that all IRCPlugins must adhere to.
 +
 +  There will obviously be more functions but only these are absolutely needed.
 +  It is neccessary so that all plugins may be kept in one array, and foreached
 +  through when new events have been generated.
 +/
interface IRCPlugin
{
    /// Executed on update to the internal IRCBot struct
    void newBot(IRCBot);

    /// Executed on update to the internal Settings struct
    void newSettings(Settings);

    /// Executed upon new IRC event parsed from the server
    void onEvent(const IRCEvent);

    /// Executed during shutdown or plugin restart
    void teardown();
}


// IRCPluginState
/++
 +  An aggregate of all variables that make up the state of a given plugin.
 +
 +  This neatly tidies up the amount of top-level variables in each plugin
 +  module. This allows for making more or less all functions top-level
 +  functions, since any state could be passed to it with variables of this type.
 +/
struct IRCPluginState
{
    import std.concurrency : Tid;

    IRCBot bot;
    Settings settings;

    /// Thread ID to the main thread
    Tid mainThread;

    /// Hashmap of IRC user details
    IRCUser[string] users;

    /// Queued events to execute when a username triggers it
    bool delegate()[string] queue;
}


/// The results trie from comparing a username with the known list of friends
enum FilterResult { fail, pass, whois }


/// Whether an annotated event ignores, allows or requires the event to be
/// prefixed with the bot's nickname
enum NickPrefixPolicy { ignored, allowed, required, hardRequired }


/// What level of privilege is needed to trigger an event
enum PrivilegeLevel { anyone, friend, master }


/// Flag denoting that an event function should be more verbose than usual,
/// generating more terminal output.
alias Verbose = Flag!"verbose";

/++
 +  Flag denoting that the annotated event should never stop an event from
 +  being processed, but keep on running until it runs out of functions to
 +  iterate, or some other non-chaining function stops it.
 +/
alias Chainable = Flag!"chainable";


// Prefix
/++
 +  Describes how an on-text function is triggered.
 +
 +  The prefix policy decides to what extent the actual prefix string_ is required.
 +  It isn't needed for functions that don't trigger on text messages; this is
 +  merely to gather everything needed to have trigger "verb" commands.
 +/
struct Prefix
{
    /// The policy to which extent the prefix string_ is required
    NickPrefixPolicy nickPrefixPolicy;

    /// The prefix string, one word with no spaces
    string string_;
}


// doWhois
/++
 +  Ask the main thread to do a WHOIS call.
 +
 +  This way the plugins don't need to know of the server connection at all,
 +  at the slight cost of concurrency message passing overhead.
 +
 +  Params:
 +      event = A complete IRCEvent to queue for later processing.
 +/
void doWhois(IRCPluginState state, const IRCEvent event)
{
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    IRCEvent eventCopy = event;  // need mutable or the send will fail
    state.mainThread.send(ThreadMessage.Whois(), eventCopy);
}


// filterUser
/++
 +  Decides whether a nick is known good, known bad, or needs WHOIS.
 +
 +  This is used to tell whether a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return whois.
 +  If the user's NickServ login is in the list of friends (or equals the bot's
 +  master's), return pass. Else, return fail and deny use.
 +/
FilterResult filterUser(const IRCPluginState state, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    auto user = event.sender in state.users;

    if (!user) return FilterResult.whois;
    else if ((user.login == state.bot.master) ||
        state.bot.friends.canFind(user.login))
    {
        return FilterResult.pass;
    }
    else
    {
        return FilterResult.fail;
    }
}


// IRCPluginBasics
/++
 +  Mixin with the basics of any plugin.
 +
 +  Uses compile-time introspection to call top-level functions to extend behaviour;
 +      .initialise
 +      .onEvent
 +      .teardown
 +/
mixin template IRCPluginBasics()
{
    // onEvent
    /++
     +  Pass on the supplied IRCEvent to the top-level .onEvent.
     +
     +  Compile-time intropection detects whether it exists or not, and compiles
     +  into code optimised for the available handlers.
     +
     +  Params:
     +      event = the triggering IRCEvent.
     +/
    void onEvent(const IRCEvent event)
    {
        static if (__traits(compiles, .onEvent(IRCEvent.init)))
        {
            .onEvent(event);
        }
    }

    // this(IRCPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level .initialise() if it exists.
     +
     +  Params:
     +      origState = the aggregate of all plugin state variables, making
     +                  this the "original state" of the plugin.
     +/
    this(IRCPluginState state)
    {
        static if (__traits(compiles, .state = state))
        {
            // Plugin has a state variable; assign to it
            .state = state;
        }
        else static if (__traits(compiles, .settings = state.settings))
        {
            // No state variable but at least there are some Settings
            .settings = state.settings;
        }

        static if (__traits(compiles, .initialise()))
        {
            .initialise();
        }
    }

    // newBot
    /++
     +  Inherits a new IRCBot.
     +
     +  Invoked on all plugins when changes has been made to the bot.
     +
     +  Params:
     +      bot = the new bot to inherit
     +/
    void newBot(IRCBot bot)
    {
        static if (__traits(compiles, .state.bot = bot))
        {
            .state.bot = bot;
        }
    }

    // newSettings
    /++
     +  Inherits a new Settings copy.
     +
     +  Invoked on all plugins when settings have been changed.
     +
     +  Params:
     +      settings = new settings
     +/
    void newSettings(Settings settings)
    {
        static if (__traits(compiles, .state.settings = settings))
        {
            .state.settings = settings;
        }
        else static if (__traits(compiles, .settings = settings))
        {
            .settings = settings;
        }
    }

    // teardown
    /++
     +  Deinitialises the plugin.
     +
     +  It passes execution to the top-level .teardown() if it exists.
     +/
    void teardown()
    {
        static if (__traits(compiles, .teardown()))
        {
            .teardown();
        }
    }
}


// OnEventImpl
/++
 +  Dispatches IRCEvents to event handlers based on their UDAs.
 +
 +  Any top-level function with a signature of (void), (IRCEvent) or
 +  (string, IRCEvent) can be annotated with IRCEvent.Type UDAs, and onEvent
 +  will dispatch the correlating events to them as it is called.
 +
 +  Merely annotating a function with an IRCEvent.Type is enough to "register"
 +  it as an event handler for that type.
 +
 +  This produces optimised code with only very few runtime checks.
 +
 +  Params:
 +      module_ = name of the current module. Even though this is a mixin we
 +                can't tell by merely using __MODULE__; it is always
 +                kameloso.plugins.common.
 +      debug_ = flag denoting that more verbose code should be compiled in.
 +/
mixin template OnEventImpl(string module_, bool debug_ = false)
{
    void onEvent(const IRCEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.traits;

        foreach (fun; getSymbolsByUDA!(thisModule, IRCEvent.Type))
        {
            static if (isSomeFunction!fun)
            {
                foreach (eventTypeUDA; getUDAs!(fun, IRCEvent.Type))
                {
                    import kameloso.stringutils;

                    import std.stdio;
                    import std.typecons : Flag;

                    enum name = "%s : %s (%s)".format(module_,
                        __traits(identifier, fun), eventTypeUDA);

                    static if (hasUDA!(fun, Flag!"verbose"))
                    {
                        enum bool verbose = getUDAs!(fun, Flag!"verbose")[0];
                    }
                    else
                    {
                        enum verbose = false;
                    }

                    static if (eventTypeUDA == IRCEvent.Type.ANY)
                    {
                        // UDA is ANY, let pass
                    }
                    else
                    {
                        if (eventTypeUDA != event.type)
                        {
                            continue;
                        }

                        static if ((eventTypeUDA == IRCEvent.Type.CHAN) ||
                                (eventTypeUDA == IRCEvent.Type.JOIN) ||
                                (eventTypeUDA == IRCEvent.Type.PART) ||
                                (eventTypeUDA == IRCEvent.Type.QUIT))
                        {
                            import std.algorithm.searching : canFind;

                            if (!state.bot.homes.canFind(event.channel))
                            {
                                static if (verbose)
                                {
                                    writeln(name, " ignore invalid channel ",
                                            event.channel);
                                }
                                return;
                            }
                        }
                    }

                    IRCEvent mutEvent = event;  // mutable
                    string contextPrefix;

                    static if (hasUDA!(fun, Prefix))
                    {
                        bool matches;

                        foreach (configuredPrefix; getUDAs!(fun, Prefix))
                        {
                            if (matches)
                            {
                                static if (verbose)
                                {
                                    writeln(name, " MATCH! breaking");
                                }
                                break;
                            }

                            contextPrefix = string.init;

                            with (NickPrefixPolicy)
                            final switch (configuredPrefix.nickPrefixPolicy)
                            {
                            case ignored:
                                break;

                            case allowed:
                                if (event.content.beginsWith(state.bot.nickname))
                                {
                                    mutEvent.content = event.content
                                        .stripPrefix(state.bot.nickname);
                                }
                                break;

                            case required:
                                if (event.type == IRCEvent.Type.QUERY)
                                {
                                    static if (verbose)
                                    {
                                        writeln(name, "but it is a query, " ~
                                            "consider allowed");
                                    }
                                    goto case allowed;
                                }
                                goto case hardRequired;

                            case hardRequired:
                                if (event.content.beginsWith(state.bot.nickname) &&
                                   (event.content.length > state.bot.nickname.length))
                                {
                                    static if (verbose)
                                    {
                                        writefln("%s trailing character is '%s'", name,
                                            event.content[state.bot.nickname.length]);
                                    }

                                    switch (event.content[state.bot.nickname.length])
                                    {
                                    case ':':
                                    case ' ':
                                    case '!':
                                    case '?':
                                        // content begins with bot nickname,
                                        // followed by this non-nick character
                                        break;

                                    default:
                                        // content begins with bot nickname,
                                        // followed by something allowed in nicks:
                                        // [a-z] [A-Z] [0-9] _-\[]{}^`|
                                        continue;
                                    }
                                }
                                else
                                {
                                    continue;
                                }

                                // event.content guaranteed to begin with state.bot.nickname
                                mutEvent.content = event.content
                                                   .stripPrefix(state.bot.nickname);
                                break;
                            }

                            static if (configuredPrefix.string_.length)
                            {
                                import std.string : indexOf, toLower;

                                if (mutEvent.content.indexOf(" ") == -1)
                                {
                                    // single word, not a prefix
                                    contextPrefix = mutEvent.content;
                                    mutEvent.content = string.init;
                                }
                                else
                                {
                                    contextPrefix = mutEvent
                                        .content
                                        .nom!(Yes.decode)(" ")
                                        .toLower();
                                }

                                // case-sensitive check goes here
                                enum lowercasePrefix = configuredPrefix
                                    .string_
                                    .toLower();
                                matches = (contextPrefix == lowercasePrefix);

                                continue;
                            }
                            else
                            {
                                // Passed nick prefix tests
                                // No real prefix configured
                                // what the hell is this?

                                writefln("%s CONFUSED on %s but setting matches to true...",
                                         name, event.type);
                                matches = true;
                                break;
                            }
                        }

                        // We can't label the innermost foreach! So we have to
                        // runtime-skip here...
                        if (!matches) continue;
                    }

                    static if (hasUDA!(fun, PrivilegeLevel))
                    {
                        immutable privilegeLevel = getUDAs!(fun,
                            PrivilegeLevel)[0];

                        with (PrivilegeLevel)
                        final switch (privilegeLevel)
                        {
                        case friend:
                        case master:
                            immutable result = state.filterUser(event);

                            with (FilterResult)
                            final switch (result)
                            {
                            case pass:
                                if ((privilegeLevel == master) &&
                                    (state.users[event.sender].login !=
                                        state.bot.master))
                                {
                                    static if (verbose)
                                    {
                                        writefln("%s: %s passed privilege check but isn't master; continue",
                                                 name, event.sender);
                                    }
                                    continue;
                                }
                                break;

                            case whois:
                                return state.doWhois(event);

                            case fail:
                                static if (verbose)
                                {
                                    writefln("%s: %s failed privilege check; continue",
                                            name, event.sender);
                                }
                                continue;
                            }
                            break;

                        case anyone:
                            break;
                        }
                    }

                    import std.meta   : AliasSeq;
                    import std.traits : Parameters;

                    try
                    {
                        static if (is(Parameters!fun : AliasSeq!(const IRCEvent)))
                        {
                            fun(mutEvent);
                        }
                        else static if (!Parameters!fun.length)
                        {
                            fun();
                        }
                        else
                        {
                            static assert(false, "Unknown function signature: " ~
                                                 typeof(fun).stringof);
                        }
                    }
                    catch (Exception e)
                    {
                        logger.error(e.msg);
                    }

                    static if (hasUDA!(fun, Flag!"chainable") &&
                              (getUDAs!(fun, Flag!"chainable")[0]))
                    {
                        continue;
                    }
                    else
                    {
                        return;
                    }
                }
            }
        }
    }
}


// BasicEventHandlers
/++
 +  Rudimentary IRCEvent handlers.
 +
 +  Almost any plugin will need handlers for WHOISLOGIN, RPL_ENDOFWHOIS, PART,
 +  QUIT, and SELFNICK. This mixin provides those. If more elaborate ones are
 +  needed, additional functions can be written and annotated appropriately.
 +/
mixin template BasicEventHandlers(string module_ = __MODULE__)
{
    // onWhoisLoginMixin
    /++
     +  Records a user's NickServ login.
     +
     +  This function populates the user array.
     +
     +  Params:
     +      event = the triggering IRCEvent.
     +/
    @(IRCEvent.Type.WHOISLOGIN)
    @(IRCEvent.Type.HASTHISNICK)
    void onWhoisLoginMixin(const IRCEvent event)
    {
        state.users[event.target] = userFromEvent(event);
    }

    //onEndOfWhoisMixin
    /++
     +  Removes a user from the WHOIS queue.
     +
     +  When doing a WHOIS with the goal of replaying an event, the event is
     +  placed in a queue. If the reply lists a valid known-good NickServ login,
     +  it is replayed. If it is not a known-good login or if there is no login
     +  at all, it would live there forever, making up garbage.
     +
     +  As such, always remove the queued event at the end of the WHOIS.
     +  At that point, any valid events should have already been replayed.
     +
     +  Params:
     +      event = the triggering IRCEvent.
     +/
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onEndOfWhoisMixin(const IRCEvent event)
    {
        state.queue.remove(event.target);
    }

    // onLeaveMixin
    /++
     +  Remove a user from the user array.
     +
     +  This automatically deauthenticates them from the bot's service, as all
     +  track of them will have disappeared. A new WHOIS must be made then.
     +
     +  Params:
     +      event = the triggering IRCEvent.
     +/
    @(IRCEvent.Type.PART)
    @(IRCEvent.Type.QUIT)
    void onLeaveMixin(const IRCEvent event)
    {
        state.users.remove(event.sender);
    }

    // onSelfNickMixin
    /++
     +  Inherit a new nickname.
     +
     +  Params:
     +      event = the triggering IRCEvent.
     +/
    @(IRCEvent.Type.SELFNICK)
    void onSelfnickMixin(const IRCEvent event)
    {
        logger.info(module_, ": new nickname");
        state.bot.nickname = event.content;
    }

    // updateBot
    /++
     +  Takes a copy of the current bot state and concurrency-sends it to the
     +  main thread, propagating any changes up the stack and then down to all
     +  other plugins.
     +/
    void updateBot()
    {
        import std.concurrency : send;

        const botCopy = state.bot;
        state.mainThread.send(cast(shared)botCopy);
    }
}

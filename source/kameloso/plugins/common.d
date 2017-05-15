module kameloso.plugins.common;

import kameloso.irc;
import std.typecons : Flag;


// IrcPlugin
/++
 +  Interface that all IrcPlugins must adhere to.
 +
 +  There will obviously be more functions but only these are absolutely needed.
 +  It is neccessary so that all plugins may be kept in one array, and foreached through
 +  when new events have been generated.
 +/
interface IrcPlugin
{
    void newBot(IrcBot);

    void status();

    void onEvent(const IrcEvent);

    void teardown();
}


// IrcPluginState
/++
 +  An aggregate of all variables that make up the state of a given plugin.
 +
 +  This neatly tidies up the amount of top-level variables in each plugin module.
 +  This allows for making more or less all functions top-level functions, since any state
 +  could be passed to it with variables of this type.
 +/
struct IrcPluginState
{
    import std.concurrency : Tid;

    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;
}


/// The results trie from comparing a username with the known list of friends
enum FilterResult { fail, pass, whois }


/// Whether an annotated event ignores, allows or requires the event to be prefixed with
/// the bot's nickname
enum NickPrefixPolicy { ignored, allowed, required }


/// What level of privilege is needed to trigger an event
enum PrivilegeLevel { anyone, friend, master }


/// Flag denoting that an event function should be more verbose than usual, generating
/// more terminal output.
alias Verbose = Flag!"verbose";


/// Flag denoting that the annotated event should never stop an event from being processed,
/// but keep on running until it runs out of functions to iterate, or some other
/// non-chaining function stops it.
alias Chainable = Flag!"chainable";


// Prefix
/++
 +  Describes how an on-text function is triggered.
 +
 +  The prefix policy decides to what extent the actual prefix string_ is required.
 +  It isn't needed for functions that don't trigger on text messages; this is merely to
 +  collect and gather everything needed to have trigger "verb" commands.
 +/
struct Prefix
{
    /// The policy to which extent the prefix string_ is required
    NickPrefixPolicy nickPrefixPolicy;

    /// The prefix string, one word with no spaces
    string string_;
}


/// A short name tag to annotate an on-event function with, labeling it.
struct Label
{
    string name;
}


// doWhois
/++
 +  Ask the main thread to do a WHOIS call.
 +
 +  This way the plugins don't need to know of the server connection at all, at the slight cost
 +  of concurrency message passing overhead.
 +
 +  Params:
 +      event = A complete IrcEvent to queue for later processing.
 +/
void doWhois(IrcPluginState state, const IrcEvent event)
{
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    const eventCopy = event;
    state.mainThread.send(ThreadMessage.Whois(), cast(shared)eventCopy);
}


/// filterUser
/++
 +  Decides whether a nick is known good, known bad, or needs WHOIS.
 +
 +  This is used to tell whether a user is allowed to use the bot's services.
 +  If the user is not in the in-memory user array, return whois.
 +  If the user's NickServ login is in the list of friends (or equals the bot's master's),
 +  return pass. Else, return fail and deny use.
 +/
FilterResult filterUser(const IrcPluginState state, const IrcEvent event)
{
    import std.algorithm.searching : canFind;

    auto user = event.sender in state.users;

    if (!user) return FilterResult.whois;
    else if ((user.login == state.bot.master) || state.bot.friends.canFind(user.login))
    {
        return FilterResult.pass;
    }
    else
    {
        return FilterResult.fail;
    }
}


// IrcPluginBasics
/++
 +  The basics of any plugin.
 +
 +  Uses compile-time introspection to call top-level functions to extend behaviour;
 +      .initialise
 +      .onEvent
 +      .teardown
 +/
mixin template IrcPluginBasics()
{
    // onEvent
    /++
     +  Pass on the supplied IrcEvent to the top-level .onEvent.
     +
     +  Compile-time intropection detects whether it exists or not, and compiles optimised
     +  code with no run-time checks.
     +
     +  Params:
     +      event = the triggering IrcEvent.
     +/
    void onEvent(const IrcEvent event)
    {
        static if (__traits(compiles, .onEvent(IrcEvent.init)))
        {
            .onEvent(event);
        }
    }

    // this(IrcPluginState)
    /++
     +  Basic constructor for a plugin.
     +
     +  It passes execution to the top-level .initialise() if it exists.
     +
     +  Params:
     +      origState = the aggregate of all plugin state variables, making this the
     +          "original state" of the plugin.
     +/
    this(IrcPluginState origState)
    {
        state = origState;

        static if (__traits(compiles, .initialise()))
        {
            .initialise();
        }
    }

    // newBot
    /++
     +  Inherits a new IrcBot.
     +
     +  Invoked on all plugins when changes has been made to the bot.
     +
     +  Params:
     +      bot = the new bot to inherit
     +/
    void newBot(IrcBot bot)
    {
        state.bot = bot;
    }

    // status
    /++
     +  Prints the current state of the plugin.
     +
     +  This is for debugging purposes.
     +/
    void status()
    {
        writeln(Foreground.lightcyan, "--[ ", typeof(this).stringof);
        printObject(state);
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
 +  Dispatches IrcEvents to event handlers based on their UDAs.
 +
 +  Any top-level function with a signature of (void), (IrcEvent) or (string, IrcEvent)
 +  can be annotated with IrcEvent.Type UDAs, and onEvent will dispatch the correlating
 +  events to them as it is called. Merely annotating a function with IrcEvent.Type is
 +  enough to "register" it as an event handler for that type.
 +
 +  This produces optimised code with only very few runtime checks.
 +
 +  Params:
 +      module_ = name of the current module. Even though this is a mixin we can't tell
 +          by merely using __MODULE__; it is always kameloso.plugins.common.
 +      debug_ = flag denoting that more verbose code should be compiled in.
 +/
mixin template OnEventImpl(string module_, bool debug_ = false)
{
    /// Ditto
    void onEvent(const IrcEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.stringutils;
        import std.traits : getSymbolsByUDA, getUDAs, hasUDA, isSomeFunction;

        foreach (fun; getSymbolsByUDA!(thisModule, IrcEvent.Type))
        {
            static if (isSomeFunction!fun)
            {
                foreach (eventTypeUDA; getUDAs!(fun, IrcEvent.Type))
                {
                    static if (hasUDA!(fun, Label))
                    {
                        import std.format : format;

                        enum name = "%s.%s(%s)"
                            .format(module_, getUDAs!(fun, Label)[0].name, eventTypeUDA);
                    }

                    import std.typecons : Flag;

                    static if (hasUDA!(fun, Verbose))
                    {
                        //import std.stdio : writefln, writeln;
                        enum verbose = getUDAs!(fun, Verbose)[0] == Verbose.yes;
                    }
                    else
                    {
                        enum verbose = false;
                    }

                    static if (eventTypeUDA == IrcEvent.Type.ANY)
                    {
                        // UDA is ANY, let pass
                    }
                    else
                    {
                        if (eventTypeUDA != event.type)
                        {
                            continue;
                        }

                        static if ((eventTypeUDA == IrcEvent.Type.CHAN) ||
                                (eventTypeUDA == IrcEvent.Type.JOIN) ||
                                (eventTypeUDA == IrcEvent.Type.PART) ||
                                (eventTypeUDA == IrcEvent.Type.QUIT))
                        {
                            import std.algorithm.searching : canFind;

                            if (!state.bot.homes.canFind(event.channel))
                            {
                                static if (verbose)
                                {
                                    writeln(name, " ignore invalid channel ", event.channel);
                                }
                                return;
                            }
                        }
                    }

                    IrcEvent mutEvent = event;  // mutable
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
                                mutEvent.content = event.content.stripPrefix(state.bot.nickname);
                                break;

                            case required:
                                if (event.type == IrcEvent.Type.QUERY)
                                {
                                    static if (verbose)
                                    {
                                        writeln(name, "but it is a query, consider allowed");
                                    }
                                    goto case allowed;
                                }

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
                                        // content begins with bot nickname, followed by this
                                        // non-nick character
                                        break;

                                    default:
                                        // content begins with bot nickname, followed by something
                                        // allowed in nicks: [a-z] [A-Z] [0-9] _-\[]{}^`|
                                        continue;
                                    }
                                }
                                else
                                {
                                    continue;
                                }

                                mutEvent.content = event.content
                                    .stripPrefix!(CheckIfBeginsWith.no)(state.bot.nickname);
                                break;
                            }

                            static if (configuredPrefix.string_.length)
                            {
                                import std.string : indexOf, toLower;

                                // case-sensitive check goes here
                                enum configuredPrefixLowercase = configuredPrefix.string_.toLower();

                                if (mutEvent.content.indexOf(" ") == -1)
                                {
                                    // single word, not a prefix
                                    contextPrefix = mutEvent.content;
                                    mutEvent.content = string.init;
                                }
                                else
                                {
                                    contextPrefix = mutEvent.content.nom!(Decode.yes)(" ").toLower();
                                }

                                matches = (contextPrefix == configuredPrefixLowercase);
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

                        // We can't label the innermost foreach! So we have to runtime-skip here...
                        if (!matches) continue;
                    }

                    static if (hasUDA!(fun, PrivilegeLevel))
                    {
                        immutable privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];

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
                                    (state.users[event.sender].login != state.bot.master))
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
                                    writeln("%s: %s failed privilege check; continue",
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

                    static if (is(Parameters!fun : AliasSeq!(const string, const IrcEvent)))
                    {
                        fun(contextPrefix, mutEvent);
                    }
                    else static if (is(Parameters!fun : AliasSeq!(const IrcEvent)))
                    {
                        fun(mutEvent);
                    }
                    else static if (!Parameters!fun.length)
                    {
                        fun();
                    }
                    else
                    {
                        static assert(false, "Unknown function signature: " ~ typeof(fun).stringof);
                    }

                    static if (hasUDA!(fun, Chainable) &&
                              (getUDAs!(fun, Chainable)[0] == Chainable.yes))
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
 +  Rudimentary IrcEvent handlers.
 +
 +  Almost any plugin will need handlers for WHOISLOGIN, RPL_ENDOFWHOIS, PART, QUIT, and SELFNICK.
 +  This mixin provides those. If more elaborate ones are needed, additional functions can be
 +  written and annotated appropriately.
 +/
mixin template BasicEventHandlers(string module_ = __MODULE__)
{
    //import std.stdio : writeln;

    // onWhoisLogin
    /++
     +  Records a user's NickServ login.
     +
     +  This function populates the user array.
     +
     +  Params:
     +      event = the triggering IrcEvent.
     +/
    @(Label("whoislogin"))
    @(IrcEvent.Type.WHOISLOGIN)
    void onWhoisLogin(const IrcEvent event)
    {
        state.users[event.target] = userFromEvent(event);
    }

    //onEndOfWhois
    /++
     +  Removes a user from the WHOIS queue.
     +
     +  When doing a WHOIS with the goal of replaying an event, the event is placed in a queue.
     +  If the reply lists a valid known-good NickServ login, it is replayed.
     +  If it is not a known-good login or if there is no login at all, it would live there
     +  forever, making up garbage.
     +
     +  As such, always remove the queued event at the end of the WHOIS. At that point,
     +  any valid events should have already been replayed.
     +
     +  Params:
     +      event = the triggering IrcEvent.
     +/
    @(Label("endofwhois"))
    @(IrcEvent.Type.RPL_ENDOFWHOIS)
    void onEndOfWhois(const IrcEvent event)
    {
        state.queue.remove(event.target);
    }

    // onLeave
    /++
     +  Remove a user from the user array.
     +
     +  This automatically deauthenticates them from the bot's service, as all track of them
     +  will have disappeared. A new WHOIS must be made then.
     +
     +  Params:
     +      event = the triggering IrcEvent.
     +/
    @(Label("part/quit"))
    @(IrcEvent.Type.PART)
    @(IrcEvent.Type.QUIT)
    void onLeave(const IrcEvent event)
    {
        state.users.remove(event.sender);
    }

    // onSelfNick
    /++
     +  Inherit a new nickname.
     +
     +  Params:
     +      event = the triggering IrcEvent.
     +/
    @(Label("selfnick"))
    @(IrcEvent.Type.SELFNICK)
    void onSelfNick(const IrcEvent event)
    {
        if (state.bot.nickname == event.content)
        {
            writeln(Foreground.lightred, "saw SELFNICK but already had that nick...");
        }
        else
        {
            writeln(Foreground.lightcyan, module_, ": new nickname");
            state.bot.nickname = event.content;
        }
    }
}

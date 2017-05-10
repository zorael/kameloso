module kameloso.plugins.common;

import kameloso.irc;

import std.stdio : writeln, writefln;
import std.typecons : Flag;


/++
 +  Interface that all IrcPlugins must adhere to. There will obviously be more functions
 +  but only these are absolutely needed. It is neccessary so that all plugins may be kept
 +  in one array, and foreached through when new events have been generated.
 +/
interface IrcPlugin
{
    void newBot(IrcBot);

    void status();

    void onEvent(const IrcEvent);

    void teardown();
}


struct IrcPluginState
{
    import std.concurrency : Tid;

    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;
}


enum FilterResult { fail, pass, whois }
enum NickPrefixPolicy { ignored, allowed, required }
enum PrivilegeLevel { anyone, friend, master }


/// Annotates that an event function should be more verbose than usual, generating
/// more terminal output
alias Verbose = Flag!"verbose";


/// Denotes that the annotated event should never stop an event from being processed,
/// but keep on running until it runs out of functions to iterate, or some other
/// non-chaining function stops it.
alias Chainable = Flag!"chainable";

struct Prefix
{
    NickPrefixPolicy nickPrefixPolicy;
    string string_;
}


struct Label
{
    string name;
}

// doWhois
/++
 +  Ask the main thread to do a WHOIS call. That way the plugins don't need to know of the
 +  Connection at all, at the cost of message passing overhead.
 +
 +  Params:
 +      event = A complete IrcEvent to queue for later processing.
 +/
void doWhois(IrcPluginState state, const IrcEvent event)
{
    import kameloso.common : ThreadMessage;
    import std.concurrency : send;

    with (state)
    {
        writeln("Missing user information on ", event.sender);
        const eventCopy = event;
        shared sEvent = cast(shared)eventCopy;
        mainThread.send(ThreadMessage.Whois(), sEvent);
    }
}


FilterResult filterUser(const IrcPluginState state, const IrcEvent event)
{
    import std.algorithm.searching : canFind;

    with (state)
    {
        // Queries are always aimed toward the bot, but the user must be whitelisted
        auto user = event.sender in users;

        if (!user) return FilterResult.whois;
        else if ((user.login == bot.master) || bot.friends.canFind(user.login))
        {
            // master or friend
            return FilterResult.pass;
        }
        else
        {
            return FilterResult.fail;
        }
    }
}


mixin template IrcPluginBasics()
{
    void onEvent(const IrcEvent event)
    {
        static if (__traits(compiles, .onEvent(IrcEvent.init)))
        {
            .onEvent(event);
        }
    }

    this(IrcPluginState origState)
    {
        state = origState;

        static if (__traits(compiles, .initialise()))
        {
            .initialise();
        }
    }

    void newBot(IrcBot bot)
    {
        state.bot = bot;
    }

    void status()
    {
        writeln("----[ ", typeof(this).stringof);
        printObject(state);
    }

    void teardown() {
        static if (__traits(compiles, .teardown()))
        {
            .teardown();
        }
    }
}


mixin template OnEventImpl(string module_, bool debug_ = false)
{
    void onEvent(const IrcEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.stringutils;
        import std.traits : getSymbolsByUDA, hasUDA, getUDAs, isSomeFunction;

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

                            if (!state.bot.channels.canFind(event.channel))
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

mixin template BasicEventHandlers()
{
    @(Label("whoislogin"))
    @(IrcEvent.Type.WHOISLOGIN)
    void onWhoisLogin(const IrcEvent event)
    {
        state.users[event.target] = userFromEvent(event);
    }


    @(Label("endofwhois"))
    @(IrcEvent.Type.RPL_ENDOFWHOIS)
    void onEndOfWhois(const IrcEvent event)
    {
        state.queue.remove(event.target);
    }


    @(Label("part/quit"))
    @(IrcEvent.Type.PART)
    @(IrcEvent.Type.QUIT)
    void onLeave(const IrcEvent event)
    {
        state.users.remove(event.sender);
    }


    @(Label("selfnick"))
    @(IrcEvent.Type.SELFNICK)
    void onSelfNick(const IrcEvent event)
    {
        if (state.bot.nickname == event.content)
        {
            writeln("saw SELFNICK but already had that nick...");
        }
        else
        {
            state.bot.nickname = event.content;
        }
    }
}

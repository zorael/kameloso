module kameloso.plugins.common;

import kameloso.irc;

import std.stdio : writeln, writefln;
import std.typecons : Flag;
import std.algorithm : canFind;
import std.traits : isSomeFunction;


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


alias RequirePrefix = Flag!"requirePrefix";


enum FilterResult { fail, pass, whois }
enum NickPrefixPolicy { ignored, allowed, required }
enum PrivilegeLevel { anyone, friend, master }

struct Chainable {}


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
void doWhois(ref IrcPluginState state, const IrcEvent event)
{
    import kameloso.common : ThreadMessage;
    import std.stdio : writeln;
    import std.concurrency : send;

    with (state)
    {
        writeln("Missing user information on ", event.sender);
        shared sEvent = cast(shared)event;
        mainThread.send(ThreadMessage.Whois(), sEvent);
    }
}


void onBasicEvent(ref IrcPluginState state, const IrcEvent event)
{
    with (state)
    with (IrcEvent.Type)
    switch (event.type)
    {
    case WHOISLOGIN:
        // Register the user
        state.users[event.target] = userFromEvent(event);
        break;

    case RPL_ENDOFWHOIS:
        queue.remove(event.target);
        break;

    case PART:
    case QUIT:
        users.remove(event.sender);
        break;

    case SELFNICK:
        if (bot.nickname == event.content)
        {
            writefln("%s saw SELFNICK but already had that nick...", __MODULE__);
        }

        bot.nickname = event.content;
        break;

    default:
        // Not so interesting
        break;
    }
}



FilterResult filterUser(IrcPluginState state, const IrcEvent event)
{
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


FilterResult filterChannel(RequirePrefix requirePrefix = RequirePrefix.no)
    (IrcPluginState state, const IrcEvent event)
{
    with (state)
    {
        if (!bot.channels.canFind(event.channel))
        {
            // Channel is not relevant
            return FilterResult.fail;
        }
        else
        {
            // Channel is relevant
            static if (requirePrefix)
            {
                import kameloso.stringutils : beginsWith;

                if (event.content.beginsWith(bot.nickname) &&
                   (event.content.length > bot.nickname.length) &&
                   (event.content[bot.nickname.length] == ':'))
                {
                    return FilterResult.pass;
                }
                else
                {
                    return FilterResult.fail;
                }
            }
            else
            {
                return FilterResult.pass;
            }
        }
    }
}


mixin template IrcPluginBasics()
{
    void onEvent(const IrcEvent event)
    {
        //return event.onEvent();
        return .onEvent(event);
    }

    this(IrcPluginState origState)
    {
        state = origState;

        static if (__traits(compiles, this.initialise()))
        {
            this.initialise();
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


mixin template onEventImpl(string module_, bool debug_ = false)
{
    void onEvent(const IrcEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import kameloso.stringutils;
        import std.traits; // : getSymbolsByUDA, hasUDA, getUDAs, isSomeFunction, Unqual;
        import std.string : indexOf, toLower;

        foreach (fun; getSymbolsByUDA!(thisModule, IrcEvent.Type))
        {
            static if (isSomeFunction!fun)
            {
                foreach (eventTypeUDA; getUDAs!(fun, IrcEvent.Type))
                {
                    if (eventTypeUDA != event.type) continue;

                    static if (eventTypeUDA == IrcEvent.Type.CHAN)
                    {
                        import std.algorithm : canFind;

                        if (!state.bot.channels.canFind(event.channel))
                        {
                            //writeln("ignore invalid channel ", event.channel);
                            return;
                        }
                    }

                    IrcEvent mutEvent = event;  // mutable
                    string contextPrefix;

                    version(none)
                    static if (hasUDA!(fun, Label))
                    {
                        import std.format : format;

                        enum name2 = module_ ~ "." ~ getUDAs!(fun, Label)[0].name;
                        //pragma(msg, "%s:%s (%s)".format(module_, name, eventTypeUDA));
                        writefln("[%s] considered...", name2);
                    }

                    static if (hasUDA!(fun, Prefix))
                    {
                        bool matches;

                        foreach (configuredPrefix; getUDAs!(fun, Prefix))
                        {
                            if (matches)
                            {
                                //writeln("MATCH! breaking");
                                break;
                            }

                            contextPrefix = string.init;

                            with (NickPrefixPolicy)
                            final switch (configuredPrefix.nickPrefixPolicy)
                            {
                            case ignored:
                                break;

                            case allowed:
                                mutEvent.content = event.content.stripPrefix!true(state.bot.nickname);
                                break;

                            case required:
                                if (event.type == IrcEvent.Type.QUERY)
                                {
                                    //writeln("but it is a query, consider allowed");
                                    goto case allowed;
                                }

                                if (event.content.beginsWith(state.bot.nickname) &&
                                   (event.content.length > state.bot.nickname.length))
                                {
                                    //writefln("trailing character is '%s'", event.content[state.bot.nickname.length]);

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

                                mutEvent.content = event.content.stripPrefix!false(state.bot.nickname);
                                break;
                            }

                            static if (configuredPrefix.string_.length)
                            {
                                // case-sensitive check goes here
                                enum configuredPrefixLowercase = configuredPrefix.string_.toLower();
                                //string thisPrefix;

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

                                /*writefln("'%s' == '%s': %s", contextPrefix, configuredPrefixLowercase,
                                    (contextPrefix == configuredPrefixLowercase));*/

                                matches = (contextPrefix == configuredPrefixLowercase);
                                continue;
                            }
                            else
                            {
                                // Passed nick prefix tests
                                // No real prefix configured
                                // what the hell is this?
                                writeln("CONFUSED but setting matches to true...");
                                matches = true;
                                break;
                            }
                        }

                        // We can't label the innermost foreach! So we have to runtime-skip here...
                        // if (skip) continue;
                        if (!matches) continue;
                    }

                    static if (hasUDA!(fun, PrivilegeLevel))
                    {
                        immutable privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];
                        //enum udaType = Unqual!(typeof(privilegeLevel)).stringof;
                        //writeln(udaType, ".", privilegeLevel);

                        with (PrivilegeLevel)
                        //final switch (getUDAs!(fun, PrivilegeLevel)[0])
                        final switch (privilegeLevel)
                        {
                        case friend:
                        case master:
                            immutable result = state.filterUser(event);
                            //enum resultType = Unqual!(typeof(result)).stringof;
                            //writeln(resultType, ".", result);

                            with (FilterResult)
                            final switch (result)
                            {
                            case pass:
                                if ((privilegeLevel == master) &&
                                    (state.users[event.sender].login != state.bot.master))
                                {
                                    writeln(event.sender, " passed privilege check but isn't master; continue");
                                    continue;
                                }
                                break;

                            case whois:
                                return state.doWhois(event);

                            case fail:
                                writeln(event.sender, " failed privilege check");
                                continue;
                            }
                            break;

                        case anyone:
                            break;
                        }
                    }

                    version(none)
                    static if (hasUDA!(fun, Label))
                    {
                        import std.format : format;

                        enum name = module_ ~ "." ~ getUDAs!(fun, Label)[0].name;
                        //pragma(msg, "%s:%s (%s)".format(module_, name, eventTypeUDA));
                        writefln("[%s] triggered!", name);
                    }

                    import std.meta   : AliasSeq;
                    import std.traits : Parameters;

                    static if (is(Parameters!fun : AliasSeq!(const string, const IrcEvent)))
                    {
                        //writeln("context prefix: '", contextPrefix, "'");
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

                    static if (hasUDA!(fun, Chainable)) continue;
                    else
                    {
                        return;
                    }
                }
            }
        }
    }
}

mixin template basicEventHandlers()
{
    //@(Description("whoislogin", "Catch a whois-login event to update the list of tracked users"))
    @(Label("whoislogin"))
    @(IrcEvent.Type.WHOISLOGIN)
    void onWhoisLogin(const IrcEvent event)
    {
        state.users[event.target] = userFromEvent(event);
    }


    //@(Description("endofwhois", "Catch an end-of-whois event to remove queued events"))
    @(Label("endofwhois"))
    @(IrcEvent.Type.RPL_ENDOFWHOIS)
    void onEndOfWhois(const IrcEvent event)
    {
        state.queue.remove(event.target);
    }


    //@(Description("part/quit", "Catch a part event to remove the nickname from the list of tracked users"))
    @(Label("part/quit"))
    @(IrcEvent.Type.PART)
    @(IrcEvent.Type.QUIT)
    void onLeave(const IrcEvent event)
    {
        state.users.remove(event.sender);
    }


    //@(Description("selfnick", "Catch a selfnick event to properly update the bot's (nickname) state"))
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

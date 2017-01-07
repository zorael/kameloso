module kameloso.plugins.common;

import kameloso.irc;

import std.typecons : Flag;
import std.algorithm : canFind;
import std.stdio;


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
    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;
}


alias RequirePrefix = Flag!"requirePrefix";


enum FilterResult { fail, pass, whois }


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

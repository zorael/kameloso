module kameloso.plugins.common;

import kameloso.irc;

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
    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;
}


/// This makes use of the onEvent2 template more self-explanatory
alias QueryOnly = Flag!"queryOnly";


// doWhois
/++
 +  Ask the main thread to do a WHOIS call. That way the plugins don't need to know of the
 +  Connection at all, at the cost of message passing overhead.
 +
 +  Params:
 +      event = A complete IrcEvent to queue for later processing.
 +/
void doWhois(ref IrcPluginState state, const IrcEvent event,
              scope void delegate(const IrcEvent) dg)
{
    import kameloso.common : ThreadMessage;
    import std.stdio : writeln, writefln;
    import std.concurrency : send;
    import std.algorithm.searching : canFind;

    writefln("Missing user information on %s", event.sender);
    
    bool queuedCommand()
    {
        auto newUser = event.sender in state.users;

        if ((newUser.login == state.bot.master) || state.bot.friends.canFind(newUser.login))
        {
            writeln("plugin common replaying old event:");
            writeln(event.toString);
            dg(event);
            return true;
        }
        
        return false;
    }

    state.queue[event.sender] = &queuedCommand;

    state.mainThread.send(ThreadMessage.Whois(), event.sender);
}


// onEventGeneric
/++
 +  Common code to decide whether a query or channel event should be reacted to.
 +  The same code was being used in both the Chatbot and the Admin plugins, so
 +  by breaking it out into a template here we get to reuse the code.
 +
 +  Params:
 +      queryOnly = If QueryOnly.yes then channel messages will be ignored.
 +      ref state = A reference to a plugin's internal state, which includes
 +                  things like user arrays and thread IDs.
 +      onCommand = The delegate to execute if the logic says the event is interesting.
 +/
void onEventGeneric(QueryOnly queryOnly = QueryOnly.no)
    (ref IrcPluginState state, const IrcEvent event, void delegate(const IrcEvent) onCommand)
{
    import kameloso.stringutils;
    import std.algorithm.searching : canFind;

    with (IrcEvent.Type)
    switch (event.type)
    {
    case WHOISLOGIN:
        // Save user to users, then replay any queued commands.
        state.users[event.target] = userFromEvent(event);
        //users[event.target].lastWhois = Clock.currTime;

        if (auto oldCommand = event.target in state.queue)
        {
            if ((*oldCommand)())
            {
                // The command returned true; remove it from the queue
                state.queue.remove(event.target);
            }
        }

        break;

    case QUERY:
        // Queries are always aimed toward the bot, but the user must be whitelisted
        auto user = event.sender in state.users;

        if (!user) return state.doWhois(event, onCommand);
        else if ((user.login == state.bot.master) || state.bot.friends.canFind(user.login))
        {
            // master or friend
            return onCommand(event);
        }
        break;

    case CHAN:
        /*
            * Not all channel messages are of interest; only those starting with the bot's
            * nickname, those from whitelisted users, and those in channels marked as active.
            */

        if (!state.bot.channels.canFind(event.channel))
        {
            // Channel is not relevant
            return;
        }
        else
        {
            static if (queryOnly == QueryOnly.no)
            {
                if (!event.content.beginsWith(state.bot.nickname) ||
                   (event.content.length <= state.bot.nickname.length) ||
                   (event.content[state.bot.nickname.length] != ':'))
                {
                    // Not aimed at the bot
                    return;
                }
            }
        }

        auto user = event.sender in state.users;

        if (!user)
        {
            // No known user, relevant channel
            return state.doWhois(event, onCommand);
        }

        // User exists in users database
        if (user.login == state.bot.master)
        {
            // User is master, all is ok
            return onCommand(event);
        }
        else if (state.bot.friends.canFind(user.login))
        {
            // User is whitelisted, all is ok
            return onCommand(event);
        }
        else
        {
            // Known bad user
            return;
        }

    case PART:
    case QUIT:
        state.users.remove(event.sender);
        break;

    default:
        break;
    }
}
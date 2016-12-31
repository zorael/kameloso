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

    with (state)
    {
        writefln("Missing user information on %s", event.sender);

        bool queuedCommand()
        {
            auto newUser = event.sender in users;

            if ((newUser.login == bot.master) || bot.friends.canFind(newUser.login))
            {
                writeln("plugin common replaying old event:");
                writeln(event.toString);
                dg(event);
                return true;
            }

            return false;
        }

        queue[event.sender] = &queuedCommand;

        mainThread.send(ThreadMessage.Whois(), event.sender);
    }
}


// onEventImpl
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
void onEventImpl(QueryOnly queryOnly = QueryOnly.no)
    (ref IrcPluginState state, const IrcEvent event,
     scope void delegate(const IrcEvent) onCommand)
{
    import std.algorithm.searching : canFind;

    with (state)
    with (IrcEvent.Type)
    switch (event.type)
    {
    case CHAN:
    // The Admin plugin only cares about Queries
    static if (queryOnly == QueryOnly.no)
    {
        /*
         * Not all channel messages are of interest; only those starting with the bot's
         * nickname, those from whitelisted users, and those in channels marked as active.
         */

        if (!bot.channels.canFind(event.channel))
        {
            // Channel is not relevant
            return;
        }
        else
        {
            import kameloso.stringutils : beginsWith;

            if (event.content.beginsWith(bot.nickname) &&
               (event.content.length > bot.nickname.length) &&
               (event.content[bot.nickname.length] == ':'))
            {
                // Drop down
            }
            else
            {
                // Not aimed at bot
                return;
            }
        }

        auto user = event.sender in users;

        if (!user)
        {
            // No known user, relevant channel
            return state.doWhois(event, onCommand);
        }

        // User exists in users database
        if (user.login == bot.master)
        {
            // User is master, all is ok
            return onCommand(event);
        }
        else if (bot.friends.canFind(user.login))
        {
            // User is whitelisted, all is ok
            return onCommand(event);
        }
        else
        {
            // Known bad user
            return;
        }
    }
    else
    {
        // Don't fall down
        break;
    }

    case QUERY:
        // Queries are always aimed toward the bot, but the user must be whitelisted
        auto user = event.sender in users;

        if (!user) return state.doWhois(event, onCommand);
        else if ((user.login == bot.master) || bot.friends.canFind(user.login))
        {
            // master or friend
            return onCommand(event);
        }
        break;

    case WHOISLOGIN:
        // Save user to users, then replay any queued commands.
        users[event.target] = userFromEvent(event);
        //users[event.target].lastWhois = Clock.currTime;

        if (auto oldCommand = event.target in queue)
        {
            if ((*oldCommand)())
            {
                // The command returned true; remove it from the queue
                queue.remove(event.target);
            }
        }

        break;

    case RPL_ENDOFWHOIS:
        // If there's still a queued command at this point, WHOISLOGIN was never triggered
        users.remove(event.target);
        break;

    case PART:
    case QUIT:
        users.remove(event.sender);
        break;

    default:
        break;
    }
}
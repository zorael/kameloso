module kameloso.plugins.common;

import kameloso.irc;


/++
 +  Interface that all IrcPlugins must adhere to. There will obviously be more functions
 +  but only these are absolutely needed. It is neccessary so that all plugins may be kept
 +  in one array, and foreached through when new events have been generated.
 +/
interface IrcPlugin
{
    void newBot(IrcBot);

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
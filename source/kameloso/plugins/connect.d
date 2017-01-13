module kameloso.plugins.connect;

import kameloso.constants;
import kameloso.stringutils;
import kameloso.common;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.concurrency;

private:

IrcPluginState state;


/// Makes a shared copy of the current IrcBot and sends it to the main thread for propagation
void updateBot()
{
    shared botCopy = cast(shared)(state.bot);
    state.mainThread.send(botCopy);
}


// onEvent
/++
    +  Called once for every IrcEvent generated. Whether the event is of interest to the plugin
    +  is up to the plugin itself to decide.
    +
    +  Params:
    +      event = The IrcEvent to react to.
    +/
void onEvent(const IrcEvent event)
{
    import std.format : format;
    import std.algorithm.iteration : joiner;

    with (state)
    with (IrcEvent.Type)
    switch (event.type)
    {
    case NOTICE:
        if (!bot.server.length && event.content.beginsWith("***"))
        {
            bot.server = event.sender;
            updateBot();

            mainThread.send(ThreadMessage.Sendline(),
                "NICK %s".format(bot.nickname));
            mainThread.send(ThreadMessage.Sendline(),
                "USER %s * 8 : %s".format(bot.ident, bot.user));
        }
        else if (event.isFromNickserv)
        {
            // There's no point authing if there's no bot password
            if (!bot.password.length) return;

            if (event.content.beginsWith(cast(string)NickServLines.acceptance))
            {
                if (!bot.channels.length || bot.finishedLogin) break;

                mainThread.send(ThreadMessage.Sendline(),
                        "JOIN :%s".format(bot.channels.joiner(",")));
                bot.finishedLogin = true;
                updateBot();
            }
        }
        break;

    case WELCOME:
        // The Welcome message is the first point at which we *know* our nickname
        bot.nickname = event.target;
        updateBot();
        break;

    case RPL_ENDOFMOTD:
        // FIXME: Deadlock if a password exists but there is no challenge
        if (bot.password.length)
        {
            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ@services. :IDENTIFY %s %s"
                .format(bot.login, bot.password));

            // Fake it
            writefln("--> PRIVMSG NickServ@services. :IDENTIFY %s hunter2", bot.login);
        }
        else
        {
            mainThread.send(ThreadMessage.Sendline(),
                "JOIN :%s".format(bot.channels.joiner(",")));
            bot.finishedLogin = true;
            updateBot();
            break;
        }

        break;

    case ERR_NICKNAMEINUSE:
        bot.nickname ~= altNickSign;
        updateBot();

        mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(bot.nickname));
        break;

    default:
        break;
    }
}


void connectPluginWorker(shared IrcPluginState origState)
{
    state = cast(IrcPluginState)origState;

    mixin ircPluginWorkerReceiveLoop!state receiveLoop;
    receiveLoop.exec();
}


public:

// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server. This is mostly
 +  a matter of sending USER and NICK at the starting "handshake", but also incorporates
 +  logic to authenticate with NickServ.
 +/
final class ConnectPlugin(Multithreaded multithreaded) : IrcPlugin
{
    mixin IrcPluginBasics!(connectPluginWorker);
}

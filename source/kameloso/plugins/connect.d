module kameloso.plugins.connect;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.stringutils;
import kameloso.irc;

import std.stdio  : writeln, writefln;
import std.format : format;
import std.concurrency;

private:

IrcPluginState state;


/// Makes a shared copy of the current IrcBot and sends it to the main thread for propagation
void updateBot()
{
    IrcBot botCopy = state.bot;
    state.mainThread.send(cast(shared)botCopy);
}

//@(Description("notice", "Catch a NOTICE event as received when connecting"))
@(Label("notice"))
@(IrcEvent.Type.NOTICE)
void onNotice(const IrcEvent event)
{
    if (!state.bot.server.length && event.content.beginsWith("***"))
    {
        state.bot.server = event.sender;
        updateBot();

        state.mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(state.bot.nickname));
        state.mainThread.send(ThreadMessage.Sendline(),
            "USER %s * 8 : %s".format(state.bot.ident, state.bot.user));
    }
    else if (event.isFromNickserv)
    {
        // There's no point authing if there's no bot password
        if (!state.bot.password.length) return;

        if (event.content.beginsWith(cast(string)NickServLines.acceptance))
        {
            if (!state.bot.channels.length || state.bot.finishedLogin) return;

            state.mainThread.send(ThreadMessage.Sendline(),
                    "JOIN :%s".format(state.bot.channels.joiner(",")));
            state.bot.finishedLogin = true;
            updateBot();
        }
    }
}


//@(Description("welcome", "Catch a WELCOME event and update the bot state's nickname"))
@(Label("welcome"))
@(IrcEvent.Type.WELCOME)
void onWelcome(const IrcEvent event)
{
    state.bot.nickname = event.target;
    updateBot();
}

//@(Description("motdend", "Catch an ENDOFMOTD event and start final login sequences"))
@(Label("welcome"))
@(IrcEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(const IrcEvent event)
{
    import std.algorithm.iteration : joiner;

    // FIXME: Deadlock if a password exists but there is no challenge
    // the fix is a timeout
    if (state.bot.password.length)
    {
        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ@services. :IDENTIFY %s %s"
            .format(state.bot.login, state.bot.password));

        // Fake it
        writefln("--> PRIVMSG NickServ@services. :IDENTIFY %s hunter2", state.bot.login);
    }
    else
    {
        state.mainThread.send(ThreadMessage.Sendline(),
            "JOIN :%s".format(state.bot.channels.joiner(",")));
        state.bot.finishedLogin = true;
        updateBot();
    }
}

//@(Description("nickinuse", "Catch a NICKNAMEINUSE error and change the bot nick"))
@(Label("nickinuse"))
@(IrcEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse(const IrcEvent event)
{
    state.bot.nickname ~= altNickSign;
    updateBot();

    state.mainThread.send(ThreadMessage.Sendline(),
        "NICK %s".format(state.bot.nickname));
}
// onEvent
/++
    +  Called once for every IrcEvent generated. Whether the event is of interest to the plugin
    +  is up to the plugin itself to decide.
    +
    +  Params:
    +      event = The IrcEvent to react to.
    +/
version(none)
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


// -------------------------------------- FIX THIS COPYPASTE

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
    // writeln("[!] on selfnick");
    if (state.bot.nickname == event.content)
    {
        writefln("%s saw SELFNICK but already had that nick...", __MODULE__);
    }
    else
    {
        state.bot.nickname = event.content;
    }
}

// -------------------------------------- FIX THIS COPYPASTE

mixin onEventImpl!__MODULE__;


public:

// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server. This is mostly
 +  a matter of sending USER and NICK at the starting "handshake", but also incorporates
 +  logic to authenticate with NickServ.
 +/
final class ConnectPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}

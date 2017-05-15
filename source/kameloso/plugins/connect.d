module kameloso.plugins.connect;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;


// updateBot TODO: deduplicate
/++
 +  Takes a copy of the current bot state and concurrency-sends it to the main thread,
 +  propagating any changes up the stack and then down to all other plugins.
 +/
void updateBot()
{
    const botCopy = state.bot;
    state.mainThread.send(cast(shared)botCopy);
}


// onNotice
/++
 +  Performs login and channel-joining when connecting.
 +
 +  This may be Freenode-specific and may need extension to work with other servers.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("notice")
@(IrcEvent.Type.NOTICE)
void onNotice(const IrcEvent event)
{
    import std.format : format;

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

            import std.algorithm.iteration : joiner;

            state.mainThread.send(ThreadMessage.Sendline(),
                    "JOIN :%s".format(state.bot.channels.joiner(",")));
            state.bot.finishedLogin = true;
            updateBot();
        }
    }
}


// onWelcome
/++
 +  Gets the final nickname from a WELCOME event and propagates it via the main thread to
 +  all other plugins.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("welcome")
@(IrcEvent.Type.WELCOME)
void onWelcome(const IrcEvent event)
{
    state.bot.nickname = event.target;
    updateBot();
}


// onEndOfMotd
/++
 +  Joins channels at the end of the MOTD, and tries to authenticate with NickServ if applicable.
 +
 +  This may be Freenode-specific and may need extension to work with other servers.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("endofmotd")
@(IrcEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(const IrcEvent event)
{
    import std.algorithm.iteration : joiner;
    import std.format : format;
    //import std.stdio : writefln;

    // FIXME: Deadlock if a password exists but there is no challenge
    // the fix is a timeout
    if (state.bot.password.length)
    {
        state.mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG NickServ@services. :IDENTIFY %s %s"
            .format(state.bot.login, state.bot.password));

        // Don't show the bot's password in the clear, fake it
        writefln(Foreground.white, "--> PRIVMSG NickServ@services. :IDENTIFY %s hunter2",
            state.bot.login);
    }
    else
    {
        state.mainThread.send(ThreadMessage.Sendline(),
            "JOIN :%s".format(state.bot.channels.joiner(",")));
        state.bot.finishedLogin = true;
        updateBot();
    }
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates the change
 +  via the main thread to all other plugins.
 +/
@Label("nickinuse")
@(IrcEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse()
{
    import std.format : format;

    state.bot.nickname ~= altNickSign;
    updateBot();

    state.mainThread.send(ThreadMessage.Sendline(),
        "NICK %s".format(state.bot.nickname));
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

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

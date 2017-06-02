module kameloso.plugins.connect;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;
import std.format : format;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

bool serverPingedAtConnect;


@Label("onSelfjoin")
@(IRCEvent.Type.SELFJOIN)
void onSelfjoin(const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!state.bot.channels.canFind(event.channel))
    {
        state.bot.channels ~= event.channel;
        updateBot();
    }
}


@Label("onSelfPart")
@(IRCEvent.Type.SELFPART)
void onSelfpart(const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : canFind;

    if (!state.bot.channels.canFind(event.channel))
    {
        writeln(Foreground.lightred, "Tried to remove a channel that wasn't there: ", event.channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(event.channel);
    updateBot();
}


void joinChannels()
{
    import std.algorithm.iteration : joiner;

    with (state)
    {
        if (bot.homes.length)
        {
            bot.finishedAuth = true;
            updateBot();
        }
        else if (!bot.channels.length)
        {
            writeln(Foreground.red, "No channels, no purpose...");
            return;
        }

        import std.algorithm.sorting : merge;

        // FIXME: line should split if it reaches 512 characters
        mainThread.send(ThreadMessage.Sendline(),
            "JOIN :%s".format(merge(bot.homes, bot.channels).joiner(",")));
    }
}


// onWelcome
/++
 +  Gets the final nickname from a WELCOME event and propagates it via the main thread to
 +  all other plugins.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("welcome")
@(IRCEvent.Type.WELCOME)
void onWelcome(const IRCEvent event)
{
    state.bot.finishedRegistering = true;

    if (!state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
    }

    state.bot.nickname = event.target;
    updateBot();
}


@Label("toconnecttype")
@(IRCEvent.Type.TOCONNECTTYPE)
void onToConnectType(const IRCEvent event)
{
    if (serverPingedAtConnect) return;

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(event.content, event.aux));
}


@Label("onping")
@(IRCEvent.Type.PING)
void onPing(const IRCEvent event)
{
    serverPingedAtConnect = true;
    state.mainThread.send(ThreadMessage.Pong(), event.sender);
}


// onEndOfMotd
/++
 +  Joins channels at the end of the MOTD, and tries to authenticate with NickServ if applicable.
 +
 +  This may be Freenode-specific and may need extension to work with other servers.
 +/
@Label("endofmotd")
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd()
{
    // FIXME: Deadlock if a password exists but there is no challenge
    // the fix is a timeout

    with (state)
    {
        if (!bot.authPassword.length)
        {
            joinChannels();
            return;
        }

        if (bot.startedAuth) return;

        bot.startedAuth = true;

        with (IRCServer.Network)
        switch (bot.server.network)
        {
        case quakenet:
            // Special service nick (Q), otherwise takes both auth login and password

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG Q@CServe.quakenet.org :AUTH %s %s"
                .format(bot.authLogin, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG Q@CServe.quakenet.org :AUTH ",
                bot.authLogin, " hunter2");

            break;

        case rizon:
        case swiftirc:
            // Only accepts password, no auth nickname

            if (bot.nickname != bot.origNickname)
            {
                writefln(Foreground.lightred,
                    "Cannot auth on this network when you have changed your nickame (%s != %s)",
                    bot.nickname, bot.origNickname);

                joinChannels();
                return;
            }

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY " ~ bot.authPassword);

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY hunter2");

            break;

        case freenode:
        case irchighway:
            // Accepts auth login

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(bot.authLogin, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                bot.authLogin, " hunter2");

            break;

        case efnet:
        case ircnet:
            // No registration available
            return;

        default:
            /*writeln(Foreground.lightred, "Probably need to AUTH manually");

            writeln(Foreground.lightred, "Would try to auth but the service " ~
                "wouldn't understand being passed both login and password...");
            writeln(Foreground.lightred, "DEBUG: trying anyway");*/

            writeln(Foreground.lightred, "Unsure of what AUTH approach to use.");

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(bot.authLogin, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                bot.authLogin, " hunter2");

            break;
        }
    }
}


@Label("onacceptance")
@(IRCEvent.Type.AUTHACCEPTANCE)
void onAcceptance()
{
    if (state.bot.finishedAuth) return;

    state.bot.finishedAuth = true;
    joinChannels();
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates the change
 +  via the main thread to all other plugins.
 +/
@Label("nickinuse")
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse()
{
    state.bot.nickname ~= altNickSign;
    updateBot();

    state.mainThread.send(ThreadMessage.Sendline(),
        "NICK %s".format(state.bot.nickname));
}


@Label("oninvite")
@(IRCEvent.Type.INVITE)
void onInvite(const IRCEvent event)
{
    if (!state.settings.joinOnInvite)
    {
        writeln(Foreground.lightcyan, "settings.joinOnInvite is false so not joining");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "JOIN :" ~ event.channel);
}


@Label("onregistrationevent")
@(IRCEvent.Type.NOTICE)
@(IRCEvent.Type.CAP)
void onRegistrationEvent(const IRCEvent event)
{
    if (state.bot.finishedRegistering) return;

    if ((event.type == IRCEvent.Type.CAP) && (event.aux == "LS"))
    {
        /++
         + The END subcommand signals to the server that capability negotiation
         + is complete and requests that the server continue with client registration.
         + If the client is already registered, this command MUST be ignored by the server.
         +
         + Clients that support capabilities but do not wish to enter negotiation SHOULD
         + send CAP END upon connection to the server.
         +
         + http://ircv3.net/specs/core/capability-negotiation-3.1.html
         +/

        state.mainThread.send(ThreadMessage.Quietline(), "CAP END");
    }

    if (event.sender.length && !state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
        updateBot();
    }
}


void register()
{
    with (state)
    {
        if (bot.startedRegistering) return;

        bot.startedRegistering = true;
        updateBot();

        mainThread.send(ThreadMessage.Quietline(), "CAP LS");

        if (bot.pass.length)
        {
            mainThread.send(ThreadMessage.Quietline(),
                "PASS " ~ bot.pass);

            // fake it
            writeln(Foreground.white, "--> PASS hunter2");
        }
        else
        {
            if (bot.server.network == IRCServer.Network.twitch)
            {
                writeln(Foreground.lightred, "You *need* a password to join this server");
            }
        }

        mainThread.send(ThreadMessage.Sendline(),
            "USER %s * 8 : %s".format(bot.ident, bot.user));
        mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(bot.nickname));
    }
}

void initialise()
{
    register();
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
final class ConnectPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

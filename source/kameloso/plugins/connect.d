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

/// Flag whether the server has sent at least one PING
bool serverPinged;


// onSelfJoin
/++
 +  Adds a channel to the list of joined channels in the IRCBot struct, and
 +  propagates the event to all plugins.
 +
 +  Fires when the bot joins a channel.
 +
 +  Params:
 +      event = the triggering IRCevent.
 +/
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


// onSelfpart
/++
 +  Removes a channel from the list of joined channels.
 +
 +  Fires when the bot leaves a channel.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("onSelfpart")
@(IRCEvent.Type.SELFPART)
void onSelfpart(const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : canFind;

    if (!state.bot.channels.canFind(event.channel))
    {
        logger.warning("Tried to remove a channel that wasn't there: ",
                       event.channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(event.channel);
    updateBot();
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the IRCBot object.
 +/
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
            logger.warning( "No channels, no purpose...");
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
 +  Gets the final nickname from a WELCOME event and propagates it via the main
 +  thread to all other plugins.
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


// onToConnectType
/++
 +  Responds to IRCEvent.Type.TOCONNECTTYPE events by sending the text supplied
 +  as content in the IRCEvent, to the server.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("toconnecttype")
@(IRCEvent.Type.TOCONNECTTYPE)
void onToConnectType(const IRCEvent event)
{
    if (serverPinged) return;

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(event.content, event.aux));
}


// onPing
/++
 +  Pongs the server upon PING.
 +
 +  We make sure to ping with the sender as target, and not the neccessarily
 +  the server as saved in the IRCServer struct. For example, TOCONNECTTYPE
 +  generally wants you to ping a random number or string.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("onping")
@(IRCEvent.Type.PING)
void onPing(const IRCEvent event)
{
    serverPinged = true;
    state.mainThread.send(ThreadMessage.Pong(), event.sender);

    if (state.bot.startedAuth && !state.bot.finishedAuth)
    {
        logger.info("Auth timed out. Joining channels");
        state.bot.finishedAuth = true;
        joinChannels();
        updateBot();
    }
}


// onEndOfMotd
/++
 +  Joins channels at the end of the MOTD, and tries to authenticate with
 +  such services if applicable.
 +/
@Label("endofmotd")
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd()
{
    with (state)
    {
        if (!bot.authPassword.length)
        {
            // No password set up; join channels and be done
            joinChannels();
            return;
        }

        // Auth started from elsewhere
        if (bot.startedAuth)
        {
            logger.log("auth started elsewhere...");
            return;
        }

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

            string login = bot.authLogin;

            if (!bot.authLogin.length)
            {
                logger.log("No auth login on Freenode! Trying ", bot.origNickname);
                login = bot.origNickname;
            }

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(login, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                login, " hunter2");

            break;

        case efnet:
        case ircnet:
            // No registration available
            return;

        default:
            logger.log("Unsure of what AUTH approach to use.");

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s %s"
                .format(bot.authLogin, bot.authPassword));

            writeln(Foreground.white, "--> PRIVMSG NickServ :IDENTIFY ",
                bot.authLogin, " hunter2");

            break;
        }
    }
}


// onAcceptance
/++
 +  Flag authentication as finished and join channels.
 +
 +  Fires when an authentication service sends a message with a known acceptance
 +  text, signifying successful login.
 +/
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
 +  Appends a single character to the end of the bot's nickname, and propagates
 +  the change via the main thread to all other plugins.
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


// onInvite
/++
 +  Join the supplied channels if not already in them.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("oninvite")
@(IRCEvent.Type.INVITE)
void onInvite(const IRCEvent event)
{
    if (!state.settings.joinOnInvite)
    {
        logger.log("settings.joinOnInvite is false so not joining");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "JOIN :" ~ event.channel);
}


// onRegistrationEvent
/++
 +  Handle CAP exchange.
 +
 +  This is a neccessary step to register with some IRC server; the capabilities
 +  have to be requested (CAP LS), and the negotiations need to be ended
 +  (CAP END).
 +/
@Label("onregistrationevent")
@(IRCEvent.Type.NOTICE)
@(IRCEvent.Type.CAP)
void onRegistrationEvent(const IRCEvent event)
{
    if (state.bot.finishedRegistering) return;

    if ((event.type == IRCEvent.Type.CAP) && (event.aux == "LS"))
    {
        /++
         +  The END subcommand signals to the server that capability negotiation
         +  is complete and requests that the server continue with client
         +  registration. If the client is already registered, this command
         +  MUST be ignored by the server.
         +
         +  Clients that support capabilities but do not wish to enter negotiation
         +  SHOULD send CAP END upon connection to the server.
         +
         +  http://ircv3.net/specs/core/capability-negotiation-3.1.html
         +/

        state.mainThread.send(ThreadMessage.Quietline(), "CAP END");
    }

    if (event.sender.length && !state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
        updateBot();
    }
}


// register
/++
 +  Register with/log onto an IRC server.
 +/
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
                logger.warning("You *need* a password to join this server");
            }
        }

        mainThread.send(ThreadMessage.Sendline(),
            "USER %s * 8 : %s".format(bot.ident, bot.user));
        mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(bot.nickname));
    }
}


// initialise
/++
 +  Register with the server.
 +
 +  This initialisation event fires immediately after a successful connect, and
 +  so instead of waiting for something from the server to trigger our
 +  registration procedure (notably NOTICEs about our IDENT and hostname), we
 +  preemptively register. It seems to work.
 +/
void initialise()
{
    register();
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server.
 +
 +  This is mostly a matter of sending USER and NICK during registration,
 +  but also incorporates logic to authenticate with nick auth services.
 +/
final class ConnectPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

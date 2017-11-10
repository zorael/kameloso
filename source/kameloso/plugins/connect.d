module kameloso.plugins.connect;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.array : Appender;
import std.concurrency : send;
import std.format : format;
import std.stdio;

private:


struct ConnectOptions
{
    bool sasl = true;
    bool joinOnInvite = false;
}

/// All Connect plugin options gathered
ConnectOptions connectOptions;

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
@(IRCEvent.Type.SELFPART)
void onSelfpart(const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    immutable index = state.bot.channels.countUntil(event.channel);

    if (index == -1)
    {
        logger.warning("Tried to remove a channel that wasn't there: ",
                       event.channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(index);
    updateBot();
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the IRCBot object.
 +/
void joinChannels()
{
    with (state)
    {
        if (bot.homes.length)
        {
            bot.finishedAuth = true;
            updateBot();
        }
        else if (!bot.channels.length)
        {
            logger.warning("No channels, no purpose...");
            return;
        }

        import std.algorithm.iteration : joiner, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.range : chain;

        // FIXME: line should split if it reaches 512 characters
        // Needs .array or .dup, sort() will sort in-place and reorder homes
        auto chanlist = chain(bot.homes, bot.channels)
            .array
            .sort()
            .uniq
            .joiner(",");

        mainThread.send(ThreadMessage.Sendline(), "JOIN :%s".format(chanlist));
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
@(IRCEvent.Type.WELCOME)
void onWelcome(const IRCEvent event)
{
    state.bot.finishedRegistering = true;

    if (!state.bot.server.resolvedAddress.length)
    {
        // Must resolve here too if the server doesn't negotiate CAP
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
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(const IRCEvent event)
{
    with (IRCServer.Network)
    with (state)
    {
        if (!bot.authPassword.length)
        {
            // No password set up; join channels and be done
            // EFnet has no nick registration services
            state.bot.finishedAuth = true;
            joinChannels();
            return;
        }

        if (bot.finishedAuth) return;

        bot.startedAuth = true;

        final switch (bot.server.network)
        {
        case quakenet:
            // Special service nick (Q), otherwise takes both auth login and password

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG Q@CServe.quakenet.org :AUTH %s %s"
                .format(bot.authLogin, bot.authPassword));

            logger.trace("--> PRIVMSG Q@CServe.quakenet.org :AUTH ",
                bot.authLogin, " hunter2");

            break;

        case rizon:
        case swiftirc:
        case dalnet:
            // Only accepts password, no auth nickname

            if (bot.nickname != bot.origNickname)
            {
                logger.warningf("Cannot auth on this network when you have " ~
                    "changed your nickname (%s != %s)",
                    bot.nickname, bot.origNickname);

                joinChannels();
                return;
            }

            immutable nickserv = (bot.server.network == dalnet) ?
                "NickServ@services.dal.net" : "NickServ";

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG %s :IDENTIFY %s".format(nickserv, bot.authPassword));

            logger.trace("--> PRIVMSG %s :IDENTIFY hunter2".format(nickserv));

            break;

        case freenode:
        case irchighway:
        case unreal:
        case gamesurge:
            // Accepts auth login
            // GameSurge is AuthServ

            string login = bot.authLogin;

            if (!bot.authLogin.length)
            {
                logger.log("No auth login specified! Trying ", bot.origNickname);
                login = bot.origNickname;
            }

            immutable service = (bot.server.network == gamesurge) ?
                "AuthServ@Services.GameSurge.net" : "NickServ";

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG %s :IDENTIFY %s %s"
                .format(service, login, bot.authPassword));

            logger.trace("--> PRIVMSG %s :IDENTIFY %s hunter2"
                .format(service, login));

            break;

        case efnet:
        case ircnet:
        case undernet:
        case twitch:
            // No registration available; join channels and be done
            state.bot.finishedAuth = true;
            joinChannels();
            break;

        case unknown:
            logger.log("Unsure of what AUTH approach to use.");

            if (bot.authLogin.length)
            {
                mainThread.send(ThreadMessage.Quietline(),
                    "PRIVMSG NickServ :IDENTIFY %s %s"
                    .format(bot.authLogin, bot.authPassword));
            }

            mainThread.send(ThreadMessage.Quietline(),
                "PRIVMSG NickServ :IDENTIFY %s"
                .format(bot.authPassword));

            logger.trace("--> PRIVMSG NickServ :IDENTIFY ",
                bot.authLogin, " hunter2");

            logger.trace("--> PRIVMSG NickServ :IDENTIFY hunter2");

            break;
        }
    }
}


// onAuthEnd
/++
 +  Flag authentication as finished and join channels.
 +
 +  Fires when an authentication service sends a message with a known success,
 +  invalid or rejected auth text, signifying completed login.
 +/
@(IRCEvent.Type.AUTH_SUCCESS)
@(IRCEvent.Type.AUTH_FAILURE)
void onAuthEnd()
{
    // This can be before registration ends in case of SASL
    if (state.bot.finishedAuth || !state.bot.finishedRegistering) return;

    state.bot.finishedAuth = true;
    logger.info("Joining channels");
    joinChannels();
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates
 +  the change via the main thread to all other plugins.
 +/
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
@(IRCEvent.Type.INVITE)
void onInvite(const IRCEvent event)
{
    if (!connectOptions.joinOnInvite)
    {
        logger.log("Invited, but joinOnInvite is false so not joining");
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
@(IRCEvent.Type.CAP)
void onRegistrationEvent(const IRCEvent event)
{
    with (state)
    switch (event.aux)
    {
    case "LS":
        // Specialcase some Twitch capabilities
        import std.algorithm.iteration : splitter;

        bool tryingSASL;

        foreach (const cap; event.content.splitter(' '))
        {
            switch (cap)
            {
            case "sasl":
                if (!connectOptions.sasl) continue;
                mainThread.send(ThreadMessage.Sendline(), "CAP REQ :sasl");
                tryingSASL = true;
                break;

            case "twitch.tv/membership":
            case "twitch.tv/tags":
            case "twitch.tv/commands":
                // Twitch-specific capabilites
                mainThread.send(ThreadMessage.Sendline(), "CAP REQ :" ~ cap);
                break;

            default:
                // logger.warning("Unhandled capability: ", cap);
                break;
            }
        }

        if (!tryingSASL)
        {
            // No SASL request in action, safe to end handshake
            // See onSASLSuccess for info on CAP END
            state.mainThread.send(ThreadMessage.Sendline(), "CAP END");
        }

        break;
    case "ACK":
        switch (event.content)
        {
        case "sasl":
            mainThread.send(ThreadMessage.Sendline(), "AUTHENTICATE PLAIN");
            break;

        /*case "twitch.tv/membership":
        case "twitch.tv/tags":
        case "twitch.tv/commands":
            // Uncomment if we ever need this
            break;*/

        default:
            //logger.warning("Unhandled capability ACK: ", event.content);
            break;
        }
        break;

    default:
        // logger.warning("Unhandled capability type: ", event.aux);
        break;
    }

    if (event.sender.length && !state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
        updateBot();
    }
}


@(IRCEvent.Type.NOTICE)
void onNotice(const IRCEvent event)
{
    if (!state.bot.finishedRegistering) return;

    if (event.sender.length && !state.bot.server.resolvedAddress.length)
    {
        state.bot.server.resolvedAddress = event.sender;
        updateBot();
    }
}


@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(const IRCEvent event)
{
    with (state)
    {
        import std.base64 : Base64;

        immutable authLogin = bot.authLogin.length ? bot.authLogin : bot.origNickname;
        immutable authToken = "%s%c%s%c%s"
            .format(bot.origNickname, '\0', authLogin, '\0', bot.authPassword);
        immutable encoded = Base64.encode(cast(ubyte[])authToken);

        mainThread.send(ThreadMessage.Quietline(), "AUTHENTICATE " ~ encoded);
        logger.trace("--> AUTHENTICATE hunter2");
    }
}


@(IRCEvent.Type.SASL_SUCCESS)
void onSASLSuccess()
{
    // Naïve, revisit
    state.bot.finishedRegistering = true;
    state.bot.finishedAuth = true;

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

    state.mainThread.send(ThreadMessage.Sendline(), "CAP END");
}


@(IRCEvent.Type.SASL_FAILURE)
void onSASLFailure()
{
    // End CAP but don't flag as finished auth
    state.bot.finishedRegistering = true;

    // See onSASLSuccess for info on CAP END
    state.mainThread.send(ThreadMessage.Sendline(), "CAP END");
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

        mainThread.send(ThreadMessage.Sendline(), "CAP LS");

        if (bot.pass.length)
        {
            mainThread.send(ThreadMessage.Quietline(),
                "PASS " ~ bot.pass);

            // fake it
            logger.trace("--> PASS hunter2");
        }
        else
        {
            if (bot.server.network == IRCServer.Network.twitch)
            {
                logger.warning("You *need* a password to join this server");
                mainThread.send(ThreadMessage.Quit());
                return;
            }
        }

        mainThread.send(ThreadMessage.Sendline(),
            "USER %s * 8 : %s".format(bot.ident, bot.user));
        mainThread.send(ThreadMessage.Sendline(),
            "NICK " ~ bot.nickname);
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

void loadConfig(const string configFile)
{
    import kameloso.config2 : readConfig;
    configFile.readConfig(connectOptions);
}


void addToConfig(ref Appender!string sink)
{
    import kameloso.config2;
    sink.serialise(connectOptions);
}


public:

mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;


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

module kameloso.plugins.connect;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : ThreadMessage, logger;

import std.concurrency : send;
import std.format : format;
import std.stdio;

private:


struct ConnectSettings
{
    import kameloso.common : Separator;

    bool sasl = true;
    bool joinOnInvite = false;
    bool exitOnSASLFailure = false;

    @Separator(";")
    string[] sendAfterConnect;
}

/// All Connect plugin settings gathered
@Settings ConnectSettings connectSettings;

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Flag whether the server has sent at least one PING
bool serverPinged;


// onSelfpart
/++
 +  Removes a channel from the list of joined channels.
 +
 +  Fires when the bot leaves a channel, one way or another.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
void onSelfpart(const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    with (state)
    {
        immutable index = bot.channels.countUntil(event.channel);

        if (index != -1)
        {
            bot.channels = bot.channels.remove(index);
            bot.updated = true;
        }
        else
        {
            immutable homeIndex = bot.homes.countUntil(event.channel);

            if (homeIndex != -1)
            {
                logger.warning("Leaving a home...");
                bot.homes = bot.homes.remove(homeIndex);
                bot.updated = true;
            }
            else
            {
                logger.warning("Tried to remove a channel that wasn't there: ",
                    event.channel);
            }
        }
    }
}


@(IRCEvent.Type.SELFJOIN)
void onSelfjoin(const IRCEvent event)
{
    if (state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    state.mainThread.send(ThreadMessage.Sendline(), "WHO " ~ event.channel);
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
            bot.updated = true;
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
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(const IRCEvent event)
{
    with (state)
    {
        bot.finishedRegistering = true;

        if (!bot.server.resolvedAddress.length)
        {
            // Must resolve here too if the server doesn't negotiate CAP
            bot.server.resolvedAddress = event.sender.address;
        }

        bot.nickname = event.target.nickname;
        bot.updated = true;
    }
}


// onToConnectType
/++
 +  Responds to IRCEvent.Type.TOCONNECTTYPE events by sending the text supplied
 +  as content in the IRCEvent, to the server.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.ERR_BADPING)
void onToConnectType(const IRCEvent event)
{
    if (serverPinged) return;

    state.mainThread.send(ThreadMessage.Sendline(), event.content);
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
    immutable target = (event.content.length) ?
        event.content : event.sender.address;

    with (state)
    {
        mainThread.send(ThreadMessage.Pong(), target);

        if (bot.startedAuth && !bot.finishedAuth)
        {
            logger.log("Auth timed out. Joining channels");
            bot.finishedAuth = true;
            bot.updated = true;
            joinChannels();
        }
    }
}


void tryAuth()
{
    string service = "NickServ";
    string verb = "IDENTIFY";

    // Specialcase networks
    switch (state.bot.server.network)
    {
    case "DALnet":
        service = "NickServ@services.dal.net";
        break;

    case "GameSurge":
        service = "AuthServ@Services.GameSurge.net";
        break;

    case "EFNet":
        // Can't auth
        return;

    case "QuakeNet":
        service = "Q@CServe.quakenet.org";
        verb = "AUTH";
        break;

    default:
        break;
    }

    state.bot.startedAuth = true;
    state.bot.updated = true;

    with (state)
    with (IRCServer.Daemon)
    switch (bot.server.daemon)
    {
    case rizon:
    case unreal:
    case hybrid:
    case bahamut:
        // Only accepts password, no auth nickname
        if (bot.nickname != bot.origNickname)
        {
            logger.warningf("Cannot auth when you have changed your nickname " ~
                "(%s != %s)", bot.nickname, bot.origNickname);

            joinChannels();
            return;
        }

        mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG %s :%s %s"
            .format(service, verb, bot.authPassword));
        logger.trace("--> PRIVMSG %s :%s hunter2"
            .format(service, verb));
        break;

    case quakenet:
    case ircdseven:
    case u2:
        // Accepts auth login
        // GameSurge is AuthServ

        string login = bot.authLogin;

        if (!bot.authLogin.length)
        {
            logger.log("No auth login specified! Trying ", bot.origNickname);
            login = bot.origNickname;
        }

        mainThread.send(ThreadMessage.Quietline(),
            "PRIVMSG %s :%s %s %s"
            .format(service, verb, login, bot.authPassword));
        logger.trace("--> PRIVMSG %s :%s %s hunter2"
            .format(service, verb, login));
        break;

    case twitch:
        // No registration available
        bot.finishedAuth = true;
        return;

    default:
        logger.warning("Unsure of what AUTH approach to use.");
        logger.log("Need information about what approach succeeded!");

        if (bot.authLogin.length) goto case ircdseven;
        else
        {
            goto case bahamut;
        }
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
    with (state)
    {
        if (bot.authPassword.length && !bot.finishedAuth) tryAuth();

        if (bot.finishedAuth || (bot.server.daemon == IRCServer.Daemon.twitch))
        {
            // tryAuth finished early with an unsuccessful login
            logger.log("Joining channels");
            joinChannels();
        }

        // Run commands defined in the settings
        foreach (immutable line; connectSettings.sendAfterConnect)
        {
            import std.string : strip;

            mainThread.send(ThreadMessage.Sendline(), line.strip());
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
@(IRCEvent.Type.RPL_LOGGEDIN)
@(IRCEvent.Type.AUTH_FAILURE)
void onAuthEnd()
{
    with (state)
    {
        // This can be before registration ends in case of SASL
        if (bot.finishedAuth || !bot.finishedRegistering) return;

        bot.finishedAuth = true;
        bot.updated = true;
        logger.log("Joining channels");
        joinChannels();
    }
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname, and propagates
 +  the change via the main thread to all other plugins.
 +/
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse()
{
    import kameloso.constants : altNickSign;

    with (state)
    {
        bot.nickname ~= altNickSign;
        bot.updated = true;

        mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(bot.nickname));
    }
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
    if (!connectSettings.joinOnInvite)
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
    /// http://ircv3.net/irc
    /// https://blog.irccloud.com/ircv3

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
                if (!connectSettings.sasl || !bot.authPassword.length) continue;
                mainThread.send(ThreadMessage.Sendline(), "CAP REQ :sasl");
                tryingSASL = true;
                break;

            case "twitch.tv/membership":
            case "twitch.tv/tags":
            case "twitch.tv/commands":
                // Twitch-specific capabilites
            case "account-notify":
            case "extended-join":
            //case "identify-msg":
            case "multi-prefix":
                // Freenode
            case "away-notify":
            case "chghost":
            case "invite-notify":
            //case "multi-prefix":  // dup
            case "userhost-in-names":
                // Rizon
            //case "unrealircd.org/plaintext-policy":
            //case "unrealircd.org/link-security":
            //case "sts":
            //case "extended-join":  // dup
            //case "chghost":  // dup
            case "cap-notify":
            //case "userhost-in-names":  // dup
            //case "multi-prefix":  // dup
            //case "away-notify":  // dup
            //case "account-notify":  // dup
            //case "tls":
                // UnrealIRCd
            case "znc.in/self-message":
                // znc SELFCHAN/SELFQUERY events
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
            mainThread.send(ThreadMessage.Sendline(), "CAP END");
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

    with(state)
    if (event.sender.nickname.length && !bot.server.resolvedAddress.length)
    {
        bot.server.resolvedAddress = event.sender.nickname;
        bot.updated = true;
    }
}


@(IRCEvent.Type.NOTICE)
void onNotice(const IRCEvent event)
{
    with (state)
    {
        if (!bot.finishedRegistering) return;

        if (event.sender.nickname.length && !bot.server.resolvedAddress.length)
        {
            bot.server.resolvedAddress = event.sender.nickname;
            bot.updated = true;
        }
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


@(IRCEvent.Type.RPL_SASLSUCCESS)
void onSASLSuccess()
{
    with (state)
    {
        // Naïve, revisit
        bot.finishedRegistering = true;
        bot.finishedAuth = true;
        bot.updated = true;

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

        mainThread.send(ThreadMessage.Sendline(), "CAP END");
    }
}


@(IRCEvent.Type.ERR_SASLFAIL)
void onSASLFailure()
{
    with (state)
    {
        if (connectSettings.exitOnSASLFailure)
        {
            mainThread.send(ThreadMessage.Quit(), "SASL Negotiation Failure");
            return;
        }

        // End CAP but don't flag as finished auth
        bot.finishedRegistering = true;
        bot.updated = true;

        // See onSASLSuccess for info on CAP END
        mainThread.send(ThreadMessage.Sendline(), "CAP END");
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
        bot.updated = true;

        mainThread.send(ThreadMessage.Sendline(), "CAP LS 302");

        if (bot.pass.length)
        {
            mainThread.send(ThreadMessage.Quietline(),
                "PASS " ~ bot.pass);

            // fake it
            logger.trace("--> PASS hunter2");
        }
        else
        {
            if (bot.server.daemon == IRCServer.Daemon.twitch)
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
void start()
{
    register();
}


mixin BasicEventHandlers;

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

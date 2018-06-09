/++
 +  The Connect service handles logging onto IRC servers after having connected,
 +  as well as managing authentication to services.
 +
 +  It has no commands; everything in it is reactionary, with no special
 +  awareness mixed in.
 +
 +  It is fairly mandatory as *something* needs to register us on the server and
 +  log in. Without it, you will simply time out.
 +/
module kameloso.plugins.connect;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : ThreadMessage, logger;

import std.concurrency : prioritySend;
import std.format : format;
import std.typecons : Flag, No, Yes;

private:


// ConnectSettings
/++
 +  ConnectService settings.
 +/
struct ConnectSettings
{
    import kameloso.uda : Separator;

    /// Whether to use SASL authentication or not.
    bool sasl = true;

    /// Whether to join channels upon being invited to them.
    bool joinOnInvite = false;

    /// Whether to abort and exit if SASL authentication fails.
    bool exitOnSASLFailure = false;

    /// Lines to send after successfully connecting and registering.
    @Separator(";")
    string[] sendAfterConnect;
}


/// Shorthand alias to `kameloso.ircdefs.IRCBot.Status`.
alias Status = IRCBot.Status;


// onSelfpart
/++
 +  Removes a channel from the list of joined channels.
 +
 +  Fires when the bot leaves a channel, one way or another.
 +/
@(IRCEvent.Type.SELFPART)
@(IRCEvent.Type.SELFKICK)
@(ChannelPolicy.any)
void onSelfpart(ConnectService service, const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    with (service.state)
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
            }
            else
            {
                logger.error("Tried to remove a channel that wasn't there: ",
                    event.channel);
            }
        }
    }
}


// onSelfjoin
/++
 +  Records a channel in the `channels` array in the `kameloso.ircdefs.IRCBot`
 +  of the current `ConnectService`'s `kameloso.plugins.common.IRCPluginState`
 +  upon joining it.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    with (service.state)
    {
        if (!bot.channels.canFind(event.channel) && !bot.homes.canFind(event.channel))
        {
            // Track new channel in the channels array
            bot.channels ~= event.channel;
            bot.updated = true;
        }
    }
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the arrays in
 +  `kameloso.ircdefs.IRCBot` of the current `ConnectService`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
void joinChannels(ConnectService service)
{
    with (service.state)
    {
        if (!bot.homes.length && !bot.channels.length)
        {
            logger.error("No channels, no purpose...");
            return;
        }

        import std.algorithm.iteration : joiner, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.conv : to;
        import std.range : chain;

        // FIXME: line should split if it reaches 512 characters
        // Needs .array or .dup, sort() will sort in-place and reorder homes
        immutable chanlist = chain(bot.homes, bot.channels)
            .array
            .sort()
            .uniq
            .joiner(",")
            .array
            .to!string;

        service.join(chanlist);
    }
}


// onToConnectType
/++
 +  Responds to `ERR_BADPING` events by sending the text (supplied as content in
 +  the `kameloso.ircdefs.IRCEvent`) to the server.
 +
 +  "Also known as `ERR_NEEDPONG` (Unreal/Ultimate) for use during registration,
 +  however it's not used in Unreal (and might not be used in Ultimate either)."
 +
 +  Encountered at least once, on a private server.
 +/
@(IRCEvent.Type.ERR_BADPING)
void onToConnectType(ConnectService service, const IRCEvent event)
{
    if (service.serverPinged) return;

    service.raw(event.content);
}


// onPing
/++
 +  Pongs the server upon `PING`.
 +
 +  We make sure to ping with the sender as target, and not the neccessarily
 +  the server as saved in the `kameloso.ircdefs.IRCServer`` struct. For
 +  example, `ERR_BADPING` (or is it `ERR_NEEDPONG`?) generally wants you to
 +  ping a random number or string.
 +/
@(IRCEvent.Type.PING)
void onPing(ConnectService service, const IRCEvent event)
{
    service.serverPinged = true;
    immutable target = (event.content.length) ? event.content : event.sender.address;

    with (service.state)
    {
        mainThread.prioritySend(ThreadMessage.Pong(), target);

        if (bot.authentication == Status.started)
        {
            logger.log("Auth timed out. Joining channels ...");
            bot.authentication = Status.finished;
            bot.updated = true;
            service.joinChannels();
        }
    }
}


// tryAuth
/++
 +  Tries to authenticate with services.
 +
 +  The command to send vary greatly between server daemons (and networks), so
 +  use some heuristics and try the best guess.
 +/
void tryAuth(ConnectService service)
{
    string serviceNick = "NickServ";
    string verb = "IDENTIFY";

    with (service.state)
    {
        import kameloso.common : decode64;
        import kameloso.string : beginsWith;

        immutable password = bot.authPassword.beginsWith("base64:") ?
            decode64(bot.authPassword[7..$]) : bot.authPassword;

        // Specialcase networks
        switch (bot.server.network)
        {
        case "DALnet":
            serviceNick = "NickServ@services.dal.net";
            break;

        case "GameSurge":
            serviceNick = "AuthServ@Services.GameSurge.net";
            break;

        case "EFNet":
            // No registration available
            bot.authentication = Status.finished;
            bot.updated = true;
            return;

        case "QuakeNet":
            serviceNick = "Q@CServe.quakenet.org";
            verb = "AUTH";
            break;

        default:
            break;
        }

        bot.authentication = Status.started;
        bot.updated = true;

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

                bot.authentication = Status.finished;
                bot.updated = true;
                service.joinChannels();
                return;
            }

            service.query!(Yes.quiet)(serviceNick, "%s %s".format(verb, password));
            logger.tracef("--> PRIVMSG %s :%s hunter2", serviceNick, verb);
            break;

        case snircd:
        case ircdseven:
        case u2:
            // Accepts auth login
            // GameSurge is AuthServ

            string account = bot.authLogin;

            if (!bot.authLogin.length)
            {
                logger.log("No account specified! Trying ", bot.origNickname);
                account = bot.origNickname;
            }

            service.query!(Yes.quiet)(serviceNick, "%s %s %s".format(verb, account, password));
            logger.tracef("--> PRIVMSG %s :%s %s hunter2", serviceNick, verb, account);
            break;

        case rusnet:
            // Doesn't want a PRIVMSG
            service.raw!(No.quiet)("NICKSERV IDENTIFY " ~ password);  // FIXME
            logger.tracef("--> NICKSERV IDENTIFY hunter2");
            break;

        case twitch:
            // No registration available
            bot.authentication = Status.finished;
            bot.updated = true;
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
}


// onEndOfMotd
/++
 +  Joins channels at the end of the `MOTD`, and tries to authenticate with
 +  services if applicable.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(ConnectService service)
{
    with (service.state)
    {
        if (bot.authPassword.length && (bot.authentication == Status.notStarted))
        {
            service.tryAuth();
        }

        if ((bot.authentication == Status.finished) ||
            !bot.authPassword.length ||
            (bot.server.daemon == IRCServer.Daemon.twitch))
        {
            // tryAuth finished early with an unsuccessful login, else
            // `bot.authentication` would be set much later.
            // Twitch servers can't auth so join immediately
            logger.log("Joining channels ...");
            service.joinChannels();
        }

        // Run commands defined in the settings
        foreach (immutable line; service.connectSettings.sendAfterConnect)
        {
            import kameloso.string : stripped;
            service.raw(line.stripped);
        }
    }
}


// onAuthEnd
/++
 +  Flags authentication as finished and join channels.
 +
 +  Fires when an authentication service sends a message with a known success,
 +  invalid or rejected auth text, signifying completed login.
 +/
@(IRCEvent.Type.RPL_LOGGEDIN)
@(IRCEvent.Type.AUTH_FAILURE)
void onAuthEnd(ConnectService service)
{
    with (service.state)
    {
        bot.authentication = Status.finished;
        bot.updated = true;

        // This can be before registration ends in case of SASL
        // return if still registering
        if (bot.registration == Status.started) return;

        logger.log("Joining channels ...");
        service.joinChannels();
    }
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname and flags the
 +  bot as updated, so as to propagate the change to all other plugins.
 +/
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse(ConnectService service)
{
    with (service.state)
    {
        if (service.state.bot.registration == IRCBot.Status.started)
        {
            if (service.renamedDuringRegistration)
            {
                import std.conv : text;
                import std.random : uniform;

                bot.nickname ~= uniform(0, 10).text;
            }
            else
            {
                import kameloso.constants : altNickSign;
                bot.nickname ~= altNickSign;
                service.renamedDuringRegistration = true;
            }

            bot.updated = true;
            service.raw("NICK " ~ bot.nickname);
        }
    }
}


// onErroneousNickname
/++
 +  Aborts a registration attempt and quits if the requested nickname is too
 +  long or contains invalid characters.
 +/
@(IRCEvent.Type.ERR_ERRONEOUSNICKNAME)
void onBadNick(ConnectService service)
{
    if (service.state.bot.registration == IRCBot.Status.started)
    {
        // Mid-registration and invalid nickname; abort
        logger.error("Your nickname is too long or contains invalid characters");
        service.state.mainThread.prioritySend(ThreadMessage.Quit(), "Invalid nickname");
    }
}


// onInvite
/++
 +  Upon being invited to a channel, joins it if the settings say we should.
 +/
@(IRCEvent.Type.INVITE)
@(ChannelPolicy.any)
void onInvite(ConnectService service, const IRCEvent event)
{
    if (!service.connectSettings.joinOnInvite)
    {
        logger.log("Invited, but joinOnInvite is false so not joining");
        return;
    }

    service.join(event.channel);
}


// onRegistrationEvent
/++
 +  Handles server capability exchange.
 +
 +  This is a neccessary step to register with some IRC server; the capabilities
 +  have to be requested (`CAP LS`), and the negotiations need to be ended
 +  (`CAP END`).
 +/
@(IRCEvent.Type.CAP)
void onRegistrationEvent(ConnectService service, const IRCEvent event)
{
    /// http://ircv3.net/irc
    /// https://blog.irccloud.com/ircv3

    with (service.state)
    switch (event.aux)
    {
    case "LS":
        import std.algorithm.iteration : splitter;

        bool tryingSASL;

        foreach (const cap; event.content.splitter(' '))
        {
            switch (cap)
            {
            case "sasl":
                if (!service.connectSettings.sasl || !bot.authPassword.length) continue;
                service.raw!(Yes.quiet)("CAP REQ :sasl");
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
                service.raw!(Yes.quiet)("CAP REQ :" ~ cap);
                break;

            default:
                //logger.warning("Unhandled capability: ", cap);
                break;
            }
        }

        if (!tryingSASL)
        {
            // No SASL request in action, safe to end handshake
            // See onSASLSuccess for info on CAP END
            service.raw!(Yes.quiet)("CAP END");
        }
        break;

    case "ACK":
        switch (event.content)
        {
        case "sasl":
            service.raw("AUTHENTICATE PLAIN");
            break;

        default:
            //logger.warning("Unhandled capability ACK: ", event.content);
            break;
        }
        break;

    default:
        //logger.warning("Unhandled capability type: ", event.aux);
        break;
    }
}


// onSASLAuthenticate
/++
 +  Constructs a SASL plain authentication token from the bot's
 +  `kameloso.ircdefs.IRCBot.authLogin` and
 +  `kameloso.ircdefs.IRCBot.authPassword`, then sends it to the server, during
 +  registration.
 +
 +  A SASL plain authentication token is composed like so:
 +
 +     `base64(authLogin \0 authLogin \0 authPassword)`
 +
 +  ...where `kameloso.ircdefs.IRCBot.authLogin` is the services account name
 +  and `kameloso.ircdefs.IRCBot.authPassword` is the account password.
 +/
@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(ConnectService service)
{
    with (service.state.bot)
    {
        import kameloso.common : decode64;
        import kameloso.string : beginsWith;
        import std.base64 : Base64;

        authentication = Status.started;
        updated = true;

        immutable authLogin = authLogin.length ? authLogin : origNickname;
        immutable password = authPassword.beginsWith("base64:") ? decode64(authPassword[7..$]) : authPassword;
        immutable authToken = "%s%c%s%c%s".format(authLogin, '\0', authLogin, '\0', password);
        immutable encoded = Base64.encode(cast(ubyte[])authToken);

        //mainThread.send(ThreadMessage.Quietline(), "AUTHENTICATE " ~ encoded);
        service.raw!(Yes.quiet)("AUTHENTICATE " ~ encoded);
        logger.trace("--> AUTHENTICATE hunter2");
    }
}


// onSASLSuccess
/++
 +  On SASL authentication success, calls a `CAP END` to finish the `CAP`
 +  negotiations.
 +
 +  Flags the bot as having finished registering and authing, allowing the main
 +  loop to pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.RPL_SASLSUCCESS)
void onSASLSuccess(ConnectService service)
{
    with (service.state)
    {
        bot.authentication = Status.finished;
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

        service.raw!(Yes.quiet)("CAP END");
    }
}


// onSASLFailure
/++
 +  On SASL authentication failure, calls a `CAP END` to finish the `CAP`
 +  negotiations and finish registration.
 +
 +  Flags the bot as having finished registering, allowing the main loop to
 +  pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.ERR_SASLFAIL)
void onSASLFailure(ConnectService service)
{
    with (service.state)
    {
        if (service.connectSettings.exitOnSASLFailure)
        {
            service.quit("SASL Negotiation Failure");
            return;
        }

        // Auth failed and will fail even if we try NickServ, so flag as
        // finished auth and invoke `CAP END`
        bot.authentication = Status.finished;
        bot.updated = true;

        // See `onSASLSuccess` for info on `CAP END`
        service.raw!(Yes.quiet)("CAP END");
    }
}


// onWelcome
/++
 +  Marks registratino as completed upon `RPL_WELCOME` (numeric 001).
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(ConnectService service)
{
    with (service.state)
    {
        bot.registration = IRCBot.Status.finished;
        bot.updated = true;
    }
}


// onISUPPORT
/++
 +  Requests an UTF-8 codepage after we've figured out that the server supports
 +  changing such.
 +
 +  Currenly only RusNet is known to support codepages. If more show up,
 +  consider creating an `IRCServer.hasCodepages` bool and set it if `CODEPAGES`
 +  is included in `RPL_MYINFO`.
 +/
@(IRCEvent.Type.RPL_ISUPPORT)
void onISUPPORT(ConnectService service)
{
    if (service.state.bot.server.daemon == IRCServer.Daemon.rusnet)
    {
        service.raw!(Yes.quiet)("CODEPAGE UTF-8");
    }
}


// register
/++
 +  Registers with/logs onto an IRC server.
 +/
void register(ConnectService service)
{
    with (service.state)
    {
        bot.registration = Status.started;
        bot.updated = true;

        service.raw!(Yes.quiet)("CAP LS 302");

        if (bot.pass.length)
        {
            service.raw!(Yes.quiet)("PASS " ~ bot.pass);

            // fake it
            logger.trace("--> PASS hunter2");
        }
        else
        {
            if (bot.server.daemon == IRCServer.Daemon.twitch)
            {
                logger.error("You *need* a password to join this server");
                service.quit();
                return;
            }
        }

        service.raw("USER %s * 8 : %s".format(bot.ident, bot.user));
        service.raw("NICK " ~ bot.nickname);
    }
}


// initialise
/++
 +  Registers with the server.
 +
 +  This initialisation event fires immediately after a successful connect, and
 +  so instead of waiting for something from the server to trigger our
 +  registration procedure (notably `NOTICE`s about our `IDENT` and hostname),
 +  we preemptively register.
 +
 +  It seems to work.
 +/
void start(ConnectService service)
{
    register(service);
}


mixin MinimalAuthentication;

public:


// ConnectService
/++
 +  A collection of functions and state needed to connect to an IRC server.
 +
 +  This is mostly a matter of sending `USER` and `NICK` during registration,
 +  but also incorporates logic to authenticate with services.
 +/
final class ConnectService : IRCPlugin
{
    /// All Connect service settings gathered.
    @Settings ConnectSettings connectSettings;

    /// Whether the server has sent at least one `PING`.
    bool serverPinged;

    /// Whether or not the bot has renamed itself during registration
    bool renamedDuringRegistration;

    alias auth = .tryAuth;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

/++
 +  The Connect service handles logging onto IRC servers after having connected,
 +  as well as managing authentication to services. It also manages responding
 +  to `PING`.
 +
 +  It has no commands; everything in it is reactionary, with no special
 +  awareness mixed in.
 +
 +  It is fairly mandatory as *something* needs to register us on the server and
 +  log in. Without it, you will simply time out.
 +/
module kameloso.plugins.connect;

version(WithPlugins):

private:

import kameloso.plugins.common;
import kameloso.irc : IRCClient;
import kameloso.ircdefs;
import kameloso.common : logger, settings;
import kameloso.thread : ThreadMessage;

import std.format : format;
import std.typecons : Flag, No, Yes;


// ConnectSettings
/++
 +  Settings for a `ConnectService`.
 +/
struct ConnectSettings
{
    import kameloso.uda : CannotContainComments, Separator;

    /// Whether to join channels upon being invited to them.
    bool joinOnInvite = false;

    /// Whether to use SASL authentication or not.
    bool sasl = true;

    /// Whether to abort and exit if SASL authentication fails.
    bool exitOnSASLFailure = false;

    /// Lines to send after successfully connecting and registering.
    @Separator(";")
    @CannotContainComments
    string[] sendAfterConnect;
}


/// Progress of a process.
enum Progress
{
    notStarted, /// Process not yet started, init state.
    started,    /// Process started but has yet to finish.
    finished,   /// Process finished.
}


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
    import std.algorithm.mutation : SwapStrategy, remove;
    import std.algorithm.searching : countUntil;
    import std.uni : toLower;

    with (service.state)
    {
        immutable channel = event.channel.toLower;

        immutable index = client.channels.countUntil(channel);

        if (index != -1)
        {
            client.channels = client.channels.remove!(SwapStrategy.unstable)(index);
            client.updated = true;
        }
        else
        {
            immutable homeIndex = client.homes.countUntil(channel);

            if (homeIndex != -1)
            {
                logger.warning("Leaving a home ...");
            }
            else
            {
                // On Twitch SELFPART may occur on untracked channels
                //logger.warning("Tried to remove a channel that wasn't there: ", event.channel);
            }
        }
    }
}


// onSelfjoin
/++
 +  Records a channel in the `channels` array in the `kameloso.irc.IRCClient` of
 +  the current `ConnectService`'s `kameloso.plugins.common.IRCPluginState` upon
 +  joining it.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : canFind;
    import std.uni : toLower;

    with (service.state)
    {
        immutable channel = event.channel.toLower;
        if (!client.channels.canFind(channel) && !client.homes.canFind(channel))
        {
            // Track new channel in the channels array
            client.channels ~= channel;
            client.updated = true;
        }
    }
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the arrays in
 +  `kameloso.irc.IRCClient` of the current `ConnectService`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +/
void joinChannels(ConnectService service)
{
    with (service.state)
    {
        if (!client.homes.length && !client.channels.length)
        {
            logger.warning("No channels, no purpose ...");
            return;
        }

        string infotint, logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        import kameloso.string : plurality;
        import std.algorithm.iteration : uniq;
        import std.algorithm.sorting : sort;
        import std.array : array, join;
        import std.range : chain, walkLength;

        // FIXME: line should split if it reaches 512 characters
        // Needs .array or .dup, sort() will sort in-place and reorder homes
        auto chanlist = chain(client.homes, client.channels)
            .array
            .sort()
            .uniq;

        immutable numChans = chanlist.walkLength;

        logger.logf("Joining %s%d%s %s ...", infotint, numChans, logtint,
            numChans.plurality("channel", "channels"));

        service.join(chanlist.join(","));
    }
}


// onToConnectType
/++
 +  Responds to `ERR_BADPING` events by sending the text supplied as content in
 +  the `kameloso.ircdefs.IRCEvent` to the server.
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
 +  the server as saved in the `kameloso.ircdefs.IRCServer` struct. For
 +  example, `ERR_BADPING` (or is it `ERR_NEEDPONG`?) generally wants you to
 +  ping a random number or string.
 +/
@(IRCEvent.Type.PING)
void onPing(ConnectService service, const IRCEvent event)
{
    import std.concurrency : prioritySend;

    service.serverPinged = true;

    immutable target = event.content.length ? event.content : event.sender.address;
    service.state.mainThread.prioritySend(ThreadMessage.Pong(), target);

    if (!service.joinedChannels && (service.authentication == Progress.started))
    {
        logger.log("Auth timed out.");
        service.authentication = Progress.finished;
        service.joinChannels();
        service.joinedChannels = true;
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
        import kameloso.string : beginsWith, decode64;
        immutable password = client.authPassword.beginsWith("base64:") ?
            decode64(client.authPassword[7..$]) : client.authPassword;

        // Specialcase networks
        switch (client.server.network)
        {
        case "DALnet":
            serviceNick = "NickServ@services.dal.net";
            break;

        case "GameSurge":
            serviceNick = "AuthServ@Services.GameSurge.net";
            break;

        case "EFNet":
            // No registration available
            service.authentication = Progress.finished;
            return;

        case "QuakeNet":
            serviceNick = "Q@CServe.quakenet.org";
            verb = "AUTH";
            break;

        default:
            break;
        }

        string infotint, logtint, warningtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
                warningtint = (cast(KamelosoLogger)logger).warningtint;
            }
        }

        service.authentication = Progress.started;

        with (IRCServer.Daemon)
        switch (client.server.daemon)
        {
        case rizon:
        case unreal:
        case hybrid:
        case bahamut:
            // Only accepts password, no auth nickname
            if (client.nickname != client.origNickname)
            {
                logger.warningf("Cannot auth when you have changed your nickname. " ~
                    "(%s%s%s != %1$s%4$s%3$s)", logtint, client.nickname, warningtint, client.origNickname);

                service.authentication = Progress.finished;
                return;
            }

            service.query!(Yes.quiet)(serviceNick, "%s %s".format(verb, password));
            if (!settings.hideOutgoing) logger.tracef("--> PRIVMSG %s :%s hunter2", serviceNick, verb);
            break;

        case snircd:
        case ircdseven:
        case u2:
            // Accepts auth login
            // GameSurge is AuthServ
            string account = client.authLogin;

            if (!client.authLogin.length)
            {
                logger.logf("No account specified! Trying %s%s%s ...", infotint, client.origNickname, logtint);
                account = client.origNickname;
            }

            service.query!(Yes.quiet)(serviceNick, "%s %s %s".format(verb, account, password));
            if (!settings.hideOutgoing) logger.tracef("--> PRIVMSG %s :%s %s hunter2", serviceNick, verb, account);
            break;

        case rusnet:
            // Doesn't want a PRIVMSG
            service.raw!(Yes.quiet)("NICKSERV IDENTIFY " ~ password);
            if (!settings.hideOutgoing) logger.trace("--> NICKSERV IDENTIFY hunter2");
            break;

        case twitch:
            // No registration available
            service.authentication = Progress.finished;
            return;

        default:
            logger.warning("Unsure of what AUTH approach to use.");
            logger.info("Please report information about what approach succeeded!");

            if (client.authLogin.length)
            {
                goto case ircdseven;
            }
            else
            {
                goto case bahamut;
            }
        }
    }
}


// onEndOfMotd
/++
 +  Joins channels at the end of the message of the day (`MOTD`), and tries to
 +  authenticate with services if applicable.
 +
 +  Some servers don't have a `MOTD`, so act on `IRCEvent.Type.ERR_NOMOTD` as
 +  well.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(ConnectService service)
{
    if (service.state.client.authPassword.length && (service.authentication == Progress.notStarted))
    {
        service.tryAuth();
    }

    if (!service.joinedChannels && ((service.authentication == Progress.finished) ||
        !service.state.client.authPassword.length || (service.state.client.server.daemon == IRCServer.Daemon.twitch)))
    {
        // tryAuth finished early with an unsuccessful login, else
        // `service.authentication` would be set much later.
        // Twitch servers can't auth so join immediately
        // but don't do anything if we already joined channels.
        service.joinChannels();
        service.joinedChannels = true;
    }

    if (!service.sentAfterConnect)
    {
        if (service.connectSettings.sendAfterConnect.length)
        {
            foreach (immutable line; service.connectSettings.sendAfterConnect)
            {
                import kameloso.string : stripped;
                import std.array : replace;

                immutable processed = line
                    .stripped
                    .replace("$nickname", service.state.client.nickname)
                    .replace("$origserver", service.state.client.server.address)
                    .replace("$server", service.state.client.server.resolvedAddress);

                service.raw(processed);
            }
        }

        service.sentAfterConnect = true;
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
    service.authentication = Progress.finished;

    // This can be before registration ends in case of SASL
    // return if still registering
    if (service.registration == Progress.started) return;

    if (!service.joinedChannels)
    {
        service.joinChannels();
        service.joinedChannels = true;
    }
}


// onAuthEndNotice
/++
 +  Flags authentication as finished and join channels.
 +
 +  Some networks/daemons (like RusNet) send the "authentication complete"
 +  message as a `IRCEvent.Type.NOTICE` from `NickServ`, not a
 +  `IRCEvent.Type.PRIVMSG`.
 +
 +  Whitelist more nicknames as we discover them. Also English only for now but
 +  can be easily extended.
 +/
@(IRCEvent.Type.NOTICE)
void onAuthEndNotice(ConnectService service, const IRCEvent event)
{
    import kameloso.string : beginsWith;

    if ((event.sender.nickname == "NickServ") &&
        event.content.beginsWith("Password accepted for nick"))
    {
        if (!service.joinedChannels)
        {
            service.joinChannels();
            service.joinedChannels = true;
        }
    }
}


// onNickInUse
/++
 +  Modifies the nickname by appending characters to the end of it.
 +
 +  Flags the client as updated, so as to propagate the change to all other
 +  plugins.
 +/
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse(ConnectService service)
{
    if (service.registration == Progress.started)
    {
        if (service.renamedDuringRegistration)
        {
            import std.conv : text;
            import std.random : uniform;

            service.state.client.nickname ~= uniform(0, 10).text;
        }
        else
        {
            import kameloso.constants : altNickSign;
            service.state.client.nickname ~= altNickSign;
            service.renamedDuringRegistration = true;
        }

        service.state.client.updated = true;
        service.raw("NICK " ~ service.state.client.nickname);
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
    import std.concurrency : prioritySend;

    if (service.registration == Progress.started)
    {
        // Mid-registration and invalid nickname; abort
        logger.error("Your nickname is too long or contains invalid characters.");
        service.state.mainThread.prioritySend(ThreadMessage.Quit(), "Invalid nickname");
    }
}


// onBanned
/++
 +  Quits the program if we're banned.
 +
 +  There's no point in reconnecting.
 +/
@(IRCEvent.Type.ERR_YOUREBANNEDCREEP)
void onBanned(ConnectService service)
{
    import std.concurrency : prioritySend;

    logger.error("You are banned!");
    service.state.mainThread.prioritySend(ThreadMessage.Quit(), "Banned");
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
        string infotint, logtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                infotint = (cast(KamelosoLogger)logger).infotint;
                logtint = (cast(KamelosoLogger)logger).logtint;
            }
        }

        logger.logf("Invited, but the %sjoinOnInvite%s setting is false so not joining.", infotint, logtint);
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

    if (service.registration == Progress.finished)
    {
        // It's possible to call CAP LS after registration, and that would start
        // this whole process anew. So stop if we have registered.
        return;
    }

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
                if (!service.connectSettings.sasl || !service.state.client.authPassword.length) continue;
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
 +  `kameloso.irc.IRCClient.authLogin` and `kameloso.irc.IRCClient.authPassword`,
 +  then sends it to the server, during registration.
 +
 +  A SASL plain authentication token is composed like so:
 +
 +     `base64(authLogin \0 authLogin \0 authPassword)`
 +
 +  ...where `kameloso.irc.IRCClient.authLogin` is the services account name and
 +  `kameloso.irc.IRCClient.authPassword` is the account password.
 +/
@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(ConnectService service)
{
    with (service.state.client)
    {
        import kameloso.string : beginsWith, decode64;
        import std.base64 : Base64;

        service.authentication = Progress.started;

        immutable authLogin = authLogin.length ? authLogin : origNickname;
        immutable password = authPassword.beginsWith("base64:") ? decode64(authPassword[7..$]) : authPassword;
        immutable authToken = "%s%c%s%c%s".format(authLogin, '\0', authLogin, '\0', password);
        immutable encoded = Base64.encode(cast(ubyte[])authToken);

        service.raw!(Yes.quiet)("AUTHENTICATE " ~ encoded);
        if (!settings.hideOutgoing) logger.trace("--> AUTHENTICATE hunter2");
    }
}


// onSASLSuccess
/++
 +  On SASL authentication success, calls a `CAP END` to finish the `CAP`
 +  negotiations.
 +
 +  Flags the client as having finished registering and authing, allowing the
 +  main loop to pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.RPL_SASLSUCCESS)
void onSASLSuccess(ConnectService service)
{
    service.authentication = Progress.finished;

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


// onSASLFailure
/++
 +  On SASL authentication failure, calls a `CAP END` to finish the `CAP`
 +  negotiations and finish registration.
 +
 +  Flags the client as having finished registering, allowing the main loop to
 +  pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.ERR_SASLFAIL)
void onSASLFailure(ConnectService service)
{
    if (service.connectSettings.exitOnSASLFailure)
    {
        service.quit("SASL Negotiation Failure");
        return;
    }

    // Auth failed and will fail even if we try NickServ, so flag as
    // finished auth and invoke `CAP END`
    service.authentication = Progress.finished;

    // See `onSASLSuccess` for info on `CAP END`
    service.raw!(Yes.quiet)("CAP END");
}


// onWelcome
/++
 +  Marks registratino as completed upon `RPL_WELCOME` (numeric 001).
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(ConnectService service)
{
    service.registration = Progress.finished;
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
    if (service.state.client.server.daemon == IRCServer.Daemon.rusnet)
    {
        service.raw!(Yes.quiet)("CODEPAGE UTF-8");
    }
}


// onReconnect
/++
 +  Disconnects and reconnects to the server.
 +
 +  This is a "benign" disconnect. We need to reconnect preemptively instead of
 +  waiting for the server to disconnect us, as it would otherwise constitute
 +  an error and the program would exit if
 +  `kameloso.common.CoreSettings.exitOnFailure` is set.
 +/
@(IRCEvent.Type.RECONNECT)
version(TwitchSupport)
void onReconnect(ConnectService service)
{
    import std.concurrency : send;
    logger.info("Reconnecting upon request.");
    service.state.mainThread.send(ThreadMessage.Reconnect());
}


// register
/++
 +  Registers with/logs onto an IRC server.
 +/
void register(ConnectService service)
{
    with (service.state)
    {
        service.registration = Progress.started;

        service.raw!(Yes.quiet)("CAP LS 302");

        if (client.pass.length)
        {
            service.raw!(Yes.quiet)("PASS " ~ client.pass);

            // fake it
            if (!settings.hideOutgoing) logger.trace("--> PASS hunter2");
        }
        else
        {
            if (client.server.daemon == IRCServer.Daemon.twitch)
            {
                logger.error("You *need* a pass to join this server.");
                service.quit();
                return;
            }
        }

        service.raw("USER %s * 8 : %s".format(client.ident, client.user));
        service.raw("NICK " ~ client.nickname);
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


// onBusMessage
/++
 +  Receives and handles a bus message from another plugin.
 +
 +  So far only reauthenticates with services, on demand.
 +/
import kameloso.thread : Sendable;
void onBusMessage(ConnectService service, const string header, shared Sendable content)
{
    import kameloso.thread : BusMessage;

    //logger.log("Connect received bus message: ", header);

    if (header == "auth")
    {
        service.tryAuth();
    }
}


public:


// ConnectService
/++
 +  A collection of functions and state needed to connect and stay connected to
 +  an IRC server, as well as authenticate with services.
 +
 +  This is mostly a matter of sending `USER` and `NICK` during registration,
 +  but also incorporates logic to authenticate with services.
 +/
final class ConnectService : IRCPlugin
{
    /// All Connect service settings gathered.
    @Settings ConnectSettings connectSettings;

    /// At what step we're currently at with regards to authentication.
    Progress authentication;

    /// At what step we're currently at with regards to registration.
    Progress registration;

    /// Whether the server has sent at least one `PING`.
    bool serverPinged;

    /// Whether or not the bot has renamed itself during registration.
    bool renamedDuringRegistration;

    /// Whether or not the bot has joined its channels at least once.
    bool joinedChannels;

    /// Whether or not the bot has sent configured commands after connect.
    bool sentAfterConnect;

    mixin IRCPluginImpl;
    mixin MessagingProxy;
}

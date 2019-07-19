/++
 +  The Connect service handles logging onto IRC servers after having connected,
 +  as well as managing authentication to services. It also manages responding
 +  to `PING` requests.
 +
 +  It has no commands; everything in it is reactionary, with no special
 +  awareness mixed in.
 +
 +  It is fairly mandatory as *something* needs to register us on the server and
 +  log in. Without it, you will simply time out.
 +/
module kameloso.plugins.connect;

version(WithPlugins):
version(WithConnectService):

private:

import kameloso.plugins.common;
import kameloso.irc.defs;
import kameloso.common : logger, settings;
import kameloso.thread : ThreadMessage;
import kameloso.messaging;

import std.format : format;
import std.typecons : Flag, No, Yes;


// ConnectSettings
/++
 +  Settings for a `ConnectService`.
 +/
struct ConnectSettings
{
    import kameloso.uda : CannotContainComments, Separator;

    /++
     +  Whether or not to join channels upon being invited to them.
     +
     +  If version TwitchSupport and on Twitch servers, instead follows raids
     +  by joining channels as raids start, and leaving them as they end.
     +/
    bool joinOnInvite = false;

    /// Whether to use SASL authentication or not.
    bool sasl = true;

    /// Whether or not to abort and exit if SASL authentication fails.
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

    with (service.state)
    {
        immutable index = client.channels.countUntil(event.channel);

        if (index != -1)
        {
            client.channels = client.channels.remove!(SwapStrategy.unstable)(index);
            client.updated = true;
        }
        else
        {
            immutable homeIndex = client.homes.countUntil(event.channel);

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
 +  Records a channel in the `channels` array in the `kameloso.irc.common.IRCClient` of
 +  the current `ConnectService`'s `kameloso.plugins.common.IRCPluginState` upon joining it.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    with (service.state)
    {
        if (!client.homes.canFind(event.channel) && !client.channels.canFind(event.channel))
        {
            // Track new channel in the channels array
            client.channels ~= event.channel;
            client.updated = true;
        }
    }
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the arrays in
 +  `kameloso.irc.common.IRCClient` of the current `ConnectService`'s
 +  `kameloso.plugins.common.IRCPluginState`.
 +
 +  Params:
 +      service = The current `ConnectService`.
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

        import kameloso.messaging : joinChannel = join;
        import kameloso.string : plurality;
        import std.algorithm.iteration : uniq;
        import std.algorithm.sorting : sort;
        import std.array : join;
        import std.range : walkLength;

        auto homelist = client.homes.sort().uniq;
        auto chanlist = client.channels.sort().uniq;
        immutable numChans = homelist.walkLength() + chanlist.walkLength();

        logger.logf("Joining %s%d%s %s ...", infotint, numChans, logtint,
            numChans.plurality("channel", "channels"));

        // Join in two steps so homes don't get shoved away by the channels
        // FIXME: line should split if it reaches 512 characters
        if (client.homes.length) joinChannel(service.state, homelist.join(","), string.init, true);
        if (client.channels.length) joinChannel(service.state, chanlist.join(","), string.init, true);
    }
}


// onToConnectType
/++
 +  Responds to `ERR_NEEDPONG` events by sending the text supplied as content in
 +  the `kameloso.irc.defs.IRCEvent` to the server.
 +
 +  "Also known as `ERR_NEEDPONG` (Unreal/Ultimate) for use during registration,
 +  however it's not used in Unreal (and might not be used in Ultimate either)."
 +
 +  Encountered at least once, on a private server.
 +/
@(IRCEvent.Type.ERR_NEEDPONG)
void onToConnectType(ConnectService service, const IRCEvent event)
{
    if (service.serverPinged) return;

    raw(service.state, event.content);
}


// onPing
/++
 +  Pongs the server upon `PING`.
 +
 +  We make sure to ping with the sender as target, and not the necessarily
 +  the server as saved in the `kameloso.irc.defs.IRCServer` struct. For
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
}


// tryAuth
/++
 +  Tries to authenticate with services.
 +
 +  The command to send vary greatly between server daemons (and networks), so
 +  use some heuristics and try the best guess.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +/
void tryAuth(ConnectService service)
{
    string serviceNick = "NickServ";
    string verb = "IDENTIFY";

    with (service.state)
    {
        import kameloso.string : beginsWith, decode64;
        immutable password = client.password.beginsWith("base64:") ?
            decode64(client.password[7..$]) : client.password;

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
        case "WNet1":
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

            query(service.state, serviceNick, "%s %s".format(verb, password), true);
            if (!settings.hideOutgoing) logger.tracef("--> PRIVMSG %s :%s hunter2", serviceNick, verb);
            break;

        case snircd:
        case ircdseven:
        case u2:
            // Accepts auth login
            // GameSurge is AuthServ
            string account = client.account;

            if (!client.account.length)
            {
                logger.logf("No account specified! Trying %s%s%s ...", infotint, client.origNickname, logtint);
                account = client.origNickname;
            }

            query(service.state, serviceNick, "%s %s %s".format(verb, account, password), true);
            if (!settings.hideOutgoing) logger.tracef("--> PRIVMSG %s :%s %s hunter2", serviceNick, verb, account);
            break;

        case rusnet:
            // Doesn't want a PRIVMSG
            raw(service.state, "NICKSERV IDENTIFY " ~ password, true);
            if (!settings.hideOutgoing) logger.trace("--> NICKSERV IDENTIFY hunter2");
            break;

        version(TwitchSupport)
        {
            case twitch:
                // No registration available
                service.authentication = Progress.finished;
                return;
        }

        default:
            logger.warning("Unsure of what AUTH approach to use.");
            logger.info("Please report information about what approach succeeded!");

            if (client.account.length)
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
 +  Some servers don't have a `MOTD`, so act on
 +  `kameloso.irc.defs.IRCEvent.Type.ERR_NOMOTD` as well.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(ConnectService service)
{
    if (service.state.client.password.length &&
        (service.authentication == Progress.notStarted) &&
        (service.state.client.server.daemon != IRCServer.Daemon.twitch))
    {
        service.tryAuth();
    }

    if (!service.joinedChannels && ((service.authentication == Progress.finished) ||
        !service.state.client.password.length ||
        (service.state.client.server.daemon == IRCServer.Daemon.twitch)))
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

                raw(service.state, processed);
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
 +  message as a `kameloso.irc.defs.IRCEvent.Type.NOTICE` from `NickServ`, not a
 +  `kameloso.irc.defs.IRCEvent.Type.PRIVMSG`.
 +
 +  Whitelist more nicknames as we discover them. Also English only for now but
 +  can be easily extended.
 +/
@(IRCEvent.Type.NOTICE)
void onAuthEndNotice(ConnectService service, const IRCEvent event)
{
    version(TwitchSupport)
    {
        if (service.state.client.server.daemon == IRCServer.Daemon.twitch) return;
    }

    import kameloso.string : beginsWith;

    if ((event.sender.nickname == "NickServ") &&
        event.content.beginsWith("Password accepted for nick"))
    {
        service.authentication = Progress.finished;

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
 +  Flags the client as updated, so as to propagate the change to all other plugins.
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
        raw(service.state, "NICK " ~ service.state.client.nickname);
    }
}


// onBadNick
/++
 +  Aborts a registration attempt and quits if the requested nickname is too
 +  long or contains invalid characters.
 +/
@(IRCEvent.Type.ERR_ERRONEOUSNICKNAME)
void onBadNick(ConnectService service)
{
    if (service.registration == Progress.started)
    {
        // Mid-registration and invalid nickname; abort
        logger.error("Your nickname is too long or contains invalid characters.");
        quit(service.state, "Invalid nickname");
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
    logger.error("You are banned!");
    quit(service.state, "Banned");
}


// onPasswordMismatch
/++
 +  Quits the program if we supplied a bad `pass`.
 +
 +  There's no point in reconnecting.
 +/
@(IRCEvent.Type.ERR_PASSWDMISMATCH)
void onPasswordMismatch(ConnectService service)
{
    if (service.registration != Progress.started)
    {
        // Unsure if this ever happens, but don't quit if we're actually registered
        return;
    }

    logger.error("Password mismatch!");
    quit(service.state, "Incorrect password");
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

    join(service.state, event.channel);
}


// onCapabilityNegotiation
/++
 +  Handles server capability exchange.
 +
 +  This is a necessary step to register with some IRC server; the capabilities
 +  have to be requested (`CAP LS`), and the negotiations need to be ended
 +  (`CAP END`).
 +/
@(IRCEvent.Type.CAP)
void onCapabilityNegotiation(ConnectService service, const IRCEvent event)
{
    /// http://ircv3.net/irc
    /// https://blog.irccloud.com/ircv3

    if (service.registration == Progress.finished)
    {
        // It's possible to call CAP LS after registration, and that would start
        // this whole process anew. So stop if we have registered.
        return;
    }
    else if (service.capabilityNegotiation == Progress.finished)
    {
        // If CAP LS is called after initial negotiation, leave it alone
        return;
    }

    service.capabilityNegotiation = Progress.started;

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
                if (!service.connectSettings.sasl || !service.state.client.password.length) continue;
                raw(service.state, "CAP REQ :sasl", true);
                tryingSASL = true;
                break;

            version(TwitchSupport)
            {
                case "twitch.tv/membership":
                case "twitch.tv/tags":
                case "twitch.tv/commands":
                    // Twitch-specific capabilities
                    // Drop down
                    goto case;
            }

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
                raw(service.state, "CAP REQ :" ~ cap, true);
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
            raw(service.state, "CAP END", true);

            if (service.capabilityNegotiation == Progress.started)
            {
                // Gate this behind a Progress.started check, in case the fallback
                // Fiber negotiating nick if no CAP response already fired
                service.capabilityNegotiation = Progress.finished;
                service.negotiateNick();
            }
        }
        break;

    case "ACK":
        switch (event.content)
        {
        case "sasl":
            raw(service.state, "AUTHENTICATE PLAIN", true);
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
 +  `kameloso.irc.common.IRCClient.account` and `kameloso.irc.common.IRCClient.password`,
 +  then sends it to the server, during registration.
 +
 +  A SASL plain authentication token is composed like so:
 +
 +     `base64(account \0 account \0 password)`
 +
 +  ...where `kameloso.irc.common.IRCClient.account` is the services account name and
 +  `kameloso.irc.common.IRCClient.password` is the account password.
 +/
@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(ConnectService service)
{
    with (service.state.client)
    {
        import kameloso.string : beginsWith, decode64, encode64;

        service.authentication = Progress.started;

        immutable account_ = account.length ? account : origNickname;
        immutable password_ = password.beginsWith("base64:") ? decode64(password[7..$]) : password;
        immutable authToken = "%s%c%s%c%s".format(account_, '\0', account_, '\0', password_);
        immutable encoded = encode64(authToken);

        raw(service.state, "AUTHENTICATE " ~ encoded, true);
        if (!settings.hideOutgoing) logger.trace("--> AUTHENTICATE hunter2");

        // If we're still authenticating by the next PING, abort and join channels.

        void dg()
        {
            if (!service.joinedChannels && (service.authentication == Progress.started))
            {
                logger.log("Auth timed out.");
                service.authentication = Progress.finished;
                service.joinChannels();
                service.joinedChannels = true;
            }
        }

        import core.thread : Fiber;

        Fiber fiber = new Fiber(&dg);
        service.awaitEvent(fiber, IRCEvent.Type.PING);
    }
}


// onSASLSuccess
/++
 +  On SASL authentication success, calls a `CAP END` to finish the `CAP` negotiations.
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
     +
     +  Notes: Some servers don't ignore post-registration CAP.
     +/

    raw(service.state, "CAP END", true);
    service.capabilityNegotiation = Progress.finished;
    service.negotiateNick();
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
        quit(service.state, "SASL Negotiation Failure");
        return;
    }

    // Auth failed and will fail even if we try NickServ, so flag as
    // finished auth and invoke `CAP END`
    service.authentication = Progress.finished;

    // See `onSASLSuccess` for info on `CAP END`
    raw(service.state, "CAP END", true);
    service.capabilityNegotiation = Progress.finished;
    service.negotiateNick();
}


// onNoCapabilities
/++
 +  Ends capability negotiation and negotiates nick if the server doesn't seem
 +  to support capabilities (e.g SwiftIRC).
 +/
@(IRCEvent.Type.ERR_NOTREGISTERED)
void onNoCapabilities(ConnectService service, const IRCEvent event)
{
    if (event.aux == "CAP")
    {
        service.capabilityNegotiation = Progress.finished;
        service.negotiateNick();
    }
}


// onWelcome
/++
 +  Marks registration as completed upon `RPL_WELCOME` (numeric 001).
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(ConnectService service, const IRCEvent event)
{
    service.registration = Progress.finished;
    service.nickNegotiation = Progress.finished;

    if (event.target.nickname.length && (service.state.client.nickname != event.target.nickname))
    {
        service.state.client.nickname = event.target.nickname;
        service.state.client.updated = true;
    }

    version(TwitchSupport) {}
    else
    {
        // No Twitch support built in
        import std.algorithm.searching : endsWith;

        if (service.state.client.server.address.endsWith(".twitch.tv"))
        {
            logger.warning("This bot was not built with Twitch support enabled. " ~
                "Expect errors and general uselessness.");
        }
    }
}


// onISUPPORT
/++
 +  Requests an UTF-8 codepage after we've figured out that the server supports changing such.
 +
 +  Currently only RusNet is known to support codepages. If more show up,
 +  consider creating an `IRCServer.hasCodepages` bool and set it if `CODEPAGES`
 +  is included in `RPL_MYINFO`.
 +/
@(IRCEvent.Type.RPL_ISUPPORT)
void onISUPPORT(ConnectService service)
{
    if (service.state.client.server.daemon == IRCServer.Daemon.rusnet)
    {
        raw(service.state, "CODEPAGE UTF-8", true);
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
version(TwitchSupport)
@(IRCEvent.Type.RECONNECT)
void onReconnect(ConnectService service)
{
    import std.concurrency : send;
    logger.info("Reconnecting upon server request.");
    service.state.mainThread.send(ThreadMessage.Reconnect());
}


// onTwitchRaid
/++
 +  On Twitch raid start, join the raided channel.
 +
 +  Don't join if we're already in it.
 +/
version(TwitchSupport)
@(IRCEvent.Type.TWITCH_RAID)
@(ChannelPolicy.any)
void onTwitchRaid(ConnectService service, const IRCEvent event)
{
    if (!service.connectSettings.joinOnInvite) return;

    import kameloso.messaging : join;
    import std.algorithm.searching : canFind;

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

    immutable raidingChannel = '#' ~ event.sender.account;

    if (service.followedTwitchRaids.byValue.canFind(raidingChannel))
    {
        // It's a raided channel that's raiding something; don't recurse
        logger.log("Not following the raid since it originated from a raided channel.");
        return;
    }

    service.followedTwitchRaids[raidingChannel] = event.channel;

    if (!service.state.client.channels.canFind(event.channel))
    {
        logger.logf("Following the raid; joining %s%s%s ...", infotint, event.channel, logtint);
        join(service.state, event.channel);
    }
}


// onTwitchUnraid
/++
 +  When a Twitch raid ends on a channel, leave it if we joined it because of a raid.
 +
 +  Don't leave if there are duplicate raids and one or more still remain.
 +/
version(TwitchSupport)
@(IRCEvent.Type.TWITCH_UNRAID)
@(ChannelPolicy.any)
void onTwitchUnraid(ConnectService service, const IRCEvent event)
{
    if (!service.connectSettings.joinOnInvite) return;

    // If there's an entry for the triggering channel raiding another channel,
    // leave that channel and remove the entry from the associative array.
    // Don't leave if another channel is also raiding it.

    immutable raidingChannel = '#' ~ event.sender.account;

    if (const raidedChannel = raidingChannel in service.followedTwitchRaids)
    {
        import kameloso.messaging : part;
        import std.algorithm.iteration : filter;
        import std.algorithm.searching : canFind;
        import std.array : array;
        import std.format : format;

        assert((*raidedChannel == event.channel), "Raid channel mismatch! %s != %s"
            .format(*raidedChannel, event.channel));

        // We could introduce an extra indentation and make the channels.canFind
        // occur before the filtering, but the channel not being there is such
        // a rare case there's no point.

        immutable numDuplicateRaids = service.followedTwitchRaids
            .byValue
            .filter!(value => value == *raidedChannel)
            .array
            .length;

        if (service.state.client.channels.canFind(*raidedChannel) && (numDuplicateRaids == 1))
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

            logger.logf("Leaving %s%s%s as we joined it by following a raid.",
                infotint, *raidedChannel, logtint);
            part(service.state, *raidedChannel);
        }

        service.followedTwitchRaids.remove(raidingChannel);
    }
}


// register
/++
 +  Registers with/logs onto an IRC server.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +/
void register(ConnectService service)
{
    import std.algorithm.searching : endsWith;

    with (service.state)
    {
        version(TwitchSupport)
        {
            if (!client.pass.length && client.server.address.endsWith(".twitch.tv"))
            {
                // client.server.daemon is always Daemon.unset at this point
                logger.error("You *need* a pass to join this server.");
                quit(service.state, "Authentication failure (missing pass)");
                return;
            }
        }

        service.registration = Progress.started;
        raw(service.state, "CAP LS 302", true);

        if (client.pass.length)
        {
            raw(service.state, "PASS " ~ client.pass, true);
            if (!settings.hideOutgoing) logger.trace("--> PASS hunter2");  // fake it
        }

        // Nick negotiation after CAP END
        // If CAP is not supported, go ahead and negotiate nick after n seconds

        enum secsToWaitForCAP = 5;

        void dg()
        {
            if (service.capabilityNegotiation == Progress.notStarted)
            {
                //logger.info("Does the server not support capabilities?");
                // Don't flag CAP as negotiated, let CAP triggers trigger late if they want to
                //service.capabilityNegotiation = Progress.finished;
                service.negotiateNick();
            }
        }

        import core.thread : Fiber;

        Fiber fiber = new Fiber(&dg);
        service.delayFiber(fiber, secsToWaitForCAP);
    }
}


// negotiateNick
/++
 +  Negotiate nickname and user with the server, during registration.
 +/
void negotiateNick(ConnectService service)
{
    if ((service.registration == Progress.finished) ||
        (service.nickNegotiation != Progress.notStarted)) return;

    import std.format : format;

    service.nickNegotiation = Progress.started;

    raw(service.state, "USER %s * 8 : %s".format(service.state.client.ident,
        service.state.client.realName));
    raw(service.state, "NICK " ~ service.state.client.nickname);
}


// start
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


// teardown
/++
 +  Upon teardown, remove channels that we only joined because of following Twitch raids
 +  from the channels array, so that we don't rejoin them as normal unraided
 +  channels if we're reconnecting.
 +
 +  Without this, temporarily raided channels become permanent ones between reconnects.
 +/
version(TwitchSupport)
void teardown(ConnectService service)
{
    import std.algorithm.searching : countUntil;
    import std.algorithm.mutation : SwapStrategy, remove;

    if (!service.followedTwitchRaids.length) return;

    foreach (immutable raidedChannel; service.followedTwitchRaids)
    {
        immutable channelIndex = service.state.client.channels.countUntil(raidedChannel);

        // Another raid may have already made us leave this channel
        if (channelIndex == -1) continue;

        service.state.client.channels = service.state.client.channels
            .remove!(SwapStrategy.unstable)(channelIndex);
    }

    // We made changes to the client, let it be known
    service.state.client.updated = true;
}


import kameloso.thread : BusMessage, Sendable;

// onBusMessage
/++
 +  Receives a passed `kameloso.thread.BusMessage` with the "`connect`" header,
 +  and calls functions based on the payload message.
 +
 +  This is used to let other plugins trigger re-authentication with services.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +      header = String header describing the passed content payload.
 +      content = Message content.
 +/
void onBusMessage(ConnectService service, const string header, shared Sendable content)
{
    if (header != "connect") return;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    if (message.payload == "auth")
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
private:
    /// All Connect service settings gathered.
    @Settings ConnectSettings connectSettings;

    /// At what step we're currently at with regards to authentication.
    Progress authentication;

    /// At what step we're currently at with regards to registration.
    Progress registration;

    /// At what step we're currently at with regards to capabilities.
    Progress capabilityNegotiation;

    /// At what step we're currently at with regards to nick negotiation.
    Progress nickNegotiation;

    /// Whether or not the server has sent at least one `PING`.
    bool serverPinged;

    /// Whether or not the bot has renamed itself during registration.
    bool renamedDuringRegistration;

    /// Whether or not the bot has joined its channels at least once.
    bool joinedChannels;

    /// Whether or not the bot has sent configured commands after connect.
    bool sentAfterConnect;

    version(TwitchSupport)
    {
        /// Channels raided by channels raiding.
        string[string] followedTwitchRaids;
    }

    mixin IRCPluginImpl;
}

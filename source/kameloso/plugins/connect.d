/++
 +  The Connect service handles logging onto IRC servers after having connected,
 +  as well as managing authentication to services. It also manages responding
 +  to `dialect.defs.IRCEvent.Type.PING` requests, and capability negotiations.
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

import kameloso.plugins.core;
import kameloso.common : Tint, logger;
import kameloso.messaging;
import kameloso.thread : ThreadMessage;
import dialect.defs;
import std.format : format;
import std.typecons : Flag, No, Yes;


// ConnectSettings
/++
 +  Settings for a `ConnectService`.
 +/
@Settings struct ConnectSettings
{
    import lu.uda : CannotContainComments, Separator, Unserialisable;

    /// Whether or not to join channels upon being invited to them.
    bool joinOnInvite = false;

    /// Whether to use SASL authentication or not.
    @Unserialisable bool sasl = true;

    /// Whether or not to abort and exit if SASL authentication fails.
    bool exitOnSASLFailure = false;

    /// Lines to send after successfully connecting and registering.
    @Separator(";;")
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

    immutable index = service.state.bot.guestChannels.countUntil(event.channel);

    if (index != -1)
    {
        service.state.bot.guestChannels = service.state.bot.guestChannels
            .remove!(SwapStrategy.unstable)(index);
        service.state.botUpdated = true;
    }
    else
    {
        immutable homeIndex = service.state.bot.homeChannels.countUntil(event.channel);

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


// onSelfjoin
/++
 +  Records a channel in the `channels` array in the `dialect.defs.IRCClient` of
 +  the current `ConnectService`'s `kameloso.plugins.core.IRCPluginState` upon joining it.
 +
 +  Additionally records our given IDENT identifier. This is likely the first event
 +  after connection that carries us as a user, so we can only catch it as early
 +  as here.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (!service.state.client.ident.length)
    {
        service.state.client.ident = event.sender.ident;
        service.state.clientUpdated = true;
    }

    if (!service.state.bot.homeChannels.canFind(event.channel) &&
        !service.state.bot.guestChannels.canFind(event.channel))
    {
        // Track new channel in the channels array
        service.state.bot.guestChannels ~= event.channel;
        service.state.botUpdated = true;
    }
}


// joinChannels
/++
 +  Joins all channels listed as home channels *and* guest channels in the arrays in
 +  `kameoso.common.IRCBot` of the current `ConnectService`'s
 +  `kameloso.plugins.core.IRCPluginState`.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +/
void joinChannels(ConnectService service)
{
    if (!service.state.bot.homeChannels.length && !service.state.bot.guestChannels.length)
    {
        logger.warning("No channels, no purpose ...");
        return;
    }

    import kameloso.messaging : joinChannel = join;
    import lu.string : plurality;
    import std.algorithm.iteration : uniq;
    import std.algorithm.sorting : sort;
    import std.array : join;
    import std.range : walkLength;

    auto homelist = service.state.bot.homeChannels.sort.uniq;
    auto guestlist = service.state.bot.guestChannels.sort.uniq;
    immutable numChans = homelist.walkLength() + guestlist.walkLength();

    logger.logf("Joining %s%d%s %s ...", Tint.info, numChans, Tint.log,
        numChans.plurality("channel", "channels"));

    // Join in two steps so home channels don't get shoved away by guest channels
    // FIXME: line should split if it reaches 512 characters
    if (service.state.bot.homeChannels.length) joinChannel(service.state,
        homelist.join(","), string.init, Yes.quiet);

    if (service.state.bot.guestChannels.length) joinChannel(service.state,
        guestlist.join(","), string.init, Yes.quiet);
}


// onToConnectType
/++
 +  Responds to `dialect.defs.IRCEvent.Type.ERR_NEEDPONG` events by sending
 +  the text supplied as content in the `dialect.defs.IRCEvent` to the server.
 +
 +  "Also known as `dialect.defs.IRCEvent.Type.ERR_NEEDPONG` (Unreal/Ultimate)
 +  for use during registration, however it's not used in Unreal (and might not
 +  be used in Ultimate either)."
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
 +  Pongs the server upon `dialect.defs.IRCEvent.Type.PING`.
 +
 +  Ping with the sender as target, and not the necessarily
 +  the server as saved in the `dialect.defs.IRCServer` struct. For
 +  example, `dialect.defs.IRCEvent.Type.ERR_NEEDPONG` generally wants you to
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

    import lu.string : beginsWith, decode64;
    immutable password = service.state.bot.password.beginsWith("base64:") ?
        decode64(service.state.bot.password[7..$]) : service.state.bot.password;

    // Specialcase networks
    switch (service.state.server.network)
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

    service.authentication = Progress.started;

    with (IRCServer.Daemon)
    switch (service.state.server.daemon)
    {
    case rizon:
    case unreal:
    case hybrid:
    case bahamut:
        // Only accepts password, no auth nickname
        if (service.state.client.nickname != service.state.client.origNickname)
        {
            logger.warningf("Cannot auth when you have changed your nickname. " ~
                "(%s%s%s != %1$s%4$s%3$s)", Tint.log, service.state.client.nickname,
                Tint.warning, service.state.client.origNickname);

            service.authentication = Progress.finished;
            return;
        }

        query(service.state, serviceNick, "%s %s"
            .format(verb, password), Yes.quiet);

        if (!service.state.settings.hideOutgoing)
        {
            logger.tracef("--> PRIVMSG %s :%s hunter2", serviceNick, verb);
        }
        break;

    case snircd:
    case ircdseven:
    case u2:
        // Accepts auth login
        // GameSurge is AuthServ
        string account = service.state.bot.account;

        if (!service.state.bot.account.length)
        {
            logger.logf("No account specified! Trying %s%s%s ...",
                Tint.info, service.state.client.origNickname, Tint.log);
            account = service.state.client.origNickname;
        }

        query(service.state, serviceNick, "%s %s %s"
            .format(verb, account, password), Yes.quiet);

        if (!service.state.settings.hideOutgoing)
        {
            logger.tracef("--> PRIVMSG %s :%s %s hunter2", serviceNick, verb, account);
        }
        break;

    case rusnet:
        // Doesn't want a PRIVMSG
        raw(service.state, "NICKSERV IDENTIFY " ~ password, Yes.quiet);

        if (!service.state.settings.hideOutgoing)
        {
            logger.trace("--> NICKSERV IDENTIFY hunter2");
        }
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

        if (service.state.bot.account.length)
        {
            goto case ircdseven;
        }
        else
        {
            goto case bahamut;
        }
    }

    // If we're still authenticating after n seconds, abort and join channels.
    delayJoinsAfterFailedAuth(service);
}


// delayJoinsAfterFailedAuth
/++
 +  Creates and schedules a `core.thread.fiber.Fiber` (in a `kameloso.thread.ScheduledFiber`)
 +  that joins channels after having failed to authenticate for n seconds.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +/
void delayJoinsAfterFailedAuth(ConnectService service)
{
    import kameloso.plugins.common.delayawait : delay;
    import core.thread : Fiber;

    enum secsBetweenRegistrationFinishedChecks = 5;

    void dg()
    {
        if (service.authentication == Progress.notStarted)
        {
            logger.log("Timed out waiting to authenticate.");
            service.authentication = Progress.finished;
        }

        while (service.registration != Progress.finished)
        {
            delay(service, secsBetweenRegistrationFinishedChecks, Yes.yield);
        }

        if (!service.joinedChannels)
        {
            service.joinChannels();
            service.joinedChannels = true;
        }
    }

    delay(service, &dg, service.authenticationGracePeriod);
}


// onNotRegistered
/++
 +  Requeues joining channels if we receive an
 +  `dalect.defs.IRCEvent.Type.ERR_NOTREGISTERED` error.
 +
 +  This can happen if the authentication process turns out to be particularly slow.
 +  Recover by schedling to join channels again later.
 +/
@(IRCEvent.Type.ERR_NOTREGISTERED)
void onNotRegistered(ConnectService service)
{
    logger.info("Did we try to join too early?");
    service.joinedChannels = false;
    service.delayJoinsAfterFailedAuth();
}


version(TwitchSupport)
{
    alias ChainableOnTwitch = Chainable;
}
else
{
    import std.meta : AliasSeq;
    alias ChainableOnTwitch = AliasSeq!();
}

// onEndOfMotd
/++
 +  Joins channels at the end of the message of the day (`MOTD`), and tries to
 +  authenticate with services if applicable.
 +
 +  Some servers don't have a `MOTD`, so act on
 +  `dialect.defs.IRCEvent.Type.ERR_NOMOTD` as well.
 +/
@ChainableOnTwitch
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(ConnectService service)
{
    if (service.state.bot.password.length &&
        (service.authentication == Progress.notStarted) &&
        (service.state.server.daemon != IRCServer.Daemon.twitch))
    {
        service.tryAuth();
    }

    if (!service.sentAfterConnect)
    {
        foreach (immutable unstripped; service.connectSettings.sendAfterConnect)
        {
            import lu.string : strippedLeft;
            import std.array : replace;

            immutable line = unstripped.strippedLeft;
            if (!line.length) continue;

            immutable processed = line
                .replace("$nickname", service.state.client.nickname)
                .replace("$origserver", service.state.server.address)
                .replace("$server", service.state.server.resolvedAddress);

            raw(service.state, processed);
        }

        service.sentAfterConnect = true;
    }

    if (!service.joinedChannels && ((service.authentication == Progress.finished) ||
        !service.state.bot.password.length ||
        (service.state.server.daemon == IRCServer.Daemon.twitch)))
    {
        // tryAuth finished early with an unsuccessful login, else
        // `service.authentication` would be set much later.
        // Twitch servers can't auth so join immediately
        // but don't do anything if we already joined channels.
        service.joinChannels();
        service.joinedChannels = true;
    }
}


// onEndOfMotdTwitch
/++
 +  Upon having connected, registered and logged onto the Twitch servers,
 +  disable outgoing colours and warn about having a `.` or `/` prefix.
 +
 +  Twitch chat doesn't do colours, so ours would only show up like `00kameloso`.
 +  Furthermore, Twitch's own commands are prefixed with a dot `.` and/or a slash `/`,
 +  so we can't use that ourselves.
 +/
version(TwitchSupport)
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotdTwitch(ConnectService service)
{
    import lu.string : beginsWith;

    if (service.state.server.daemon != IRCServer.Daemon.twitch) return;

    service.state.settings.colouredOutgoing = false;
    service.state.settingsUpdated = true;

    immutable prefix = service.state.settings.prefix;

    if (prefix.beginsWith(".") || prefix.beginsWith("/"))
    {
        logger.warningf(`WARNING: A prefix of "%s%s%s" will *not* work on Twitch servers, ` ~
            `as %1$s.%3$s and %1$s/%3$s are reserved for Twitch's own commands.`,
            Tint.log, prefix, Tint.warning);
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
    if (service.registration != Progress.finished) return;

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
 +  message as a `dialect.defs.IRCEvent.Type.NOTICE` from `NickServ`, not a
 +  `dialect.defs.IRCEvent.Type.PRIVMSG`.
 +
 +  Whitelist more nicknames as we discover them. Also English only for now but
 +  can be easily extended.
 +/
@ChainableOnTwitch
@(IRCEvent.Type.NOTICE)
void onAuthEndNotice(ConnectService service, const IRCEvent event)
{
    version(TwitchSupport)
    {
        if (service.state.server.daemon == IRCServer.Daemon.twitch) return;
    }

    import lu.string : beginsWith;

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


// onTwitchAuthFailure
/++
 +  On Twitch, if the OAuth pass is wrong or malformed, abort and exit the program.
 +/
version(TwitchSupport)
@(IRCEvent.Type.NOTICE)
void onTwitchAuthFailure(ConnectService service, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.algorithm.searching : endsWith;
    import std.concurrency : prioritySend;
    import std.typecons : Flag, No, Yes;

    //if (service.state.server.daemon != IRCServer.Daemon.twitch) return;
    if (!service.state.server.address.endsWith(".twitch.tv")) return;

    switch (event.content)
    {
    case "Improperly formatted auth":
        if (!service.state.bot.pass.length)
        {
            logger.error("You *need* a pass to join this server.");
            logger.logf("Run the program with %s--set twitchbot.keygen%s to generate a new one.",
                Tint.info, Tint.log);
        }
        else
        {
            logger.error("Client pass is malformed, cannot authenticate. " ~
                "Please make sure it is entered correctly.");
        }
        break;

    case "Login authentication failed":
        logger.error("Incorrect client pass. Please make sure it is valid and has not expired.");
        logger.logf("Run the program with %s--set twitchbot.keygen%s to generate a new one.",
            Tint.info, Tint.log);
        break;

    case "Login unsuccessful":
        logger.error("Client pass probably has insufficient privileges.");
        break;

    default:
        // Just some notice; return
        return;
    }

    // Exit and let the user tend to it.
    service.state.mainThread.prioritySend(ThreadMessage.Quit(), event.content, No.quiet);
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
            import kameloso.constants : KamelosoDefaultStrings;
            service.state.client.nickname ~= KamelosoDefaultStrings.altNickSign;
            service.renamedDuringRegistration = true;
        }

        service.state.clientUpdated = true;
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
        logger.error("Your nickname is invalid. (reserved, too long, or contains invalid characters)");
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


// onPassMismatch
/++
 +  Quits the program if we supplied a bad `dialect.IRCbot.pass`.
 +
 +  There's no point in reconnecting.
 +/
@(IRCEvent.Type.ERR_PASSWDMISMATCH)
void onPassMismatch(ConnectService service)
{
    if (service.registration != Progress.started)
    {
        // Unsure if this ever happens, but don't quit if we're actually registered
        return;
    }

    logger.error("Pass mismatch!");
    quit(service.state, "Incorrect pass");
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
        logger.logf("Invited, but the %sjoinOnInvite%s setting is false so not joining.",
            Tint.info, Tint.log);
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
    import lu.string : strippedRight;

    // - http://ircv3.net/irc
    // - https://blog.irccloud.com/ircv3

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
    immutable content = event.content.strippedRight;

    switch (event.aux)
    {
    case "LS":
        import std.algorithm.iteration : splitter;

        bool tryingSASL;

        foreach (const cap; content.splitter(' '))
        {
            switch (cap)
            {
            case "sasl":
                if (service.state.connSettings.ssl &&
                    (service.state.connSettings.privateKeyFile.length ||
                    service.state.connSettings.certFile.length))
                {
                    // Proceed
                }
                else if (service.connectSettings.sasl &&
                    service.state.bot.password.length)
                {
                    // Likewise
                }
                else
                {
                    // Abort
                    continue;
                }

                raw(service.state, "CAP REQ :sasl", Yes.quiet);
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
                raw(service.state, "CAP REQ :" ~ cap, Yes.quiet);
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
            raw(service.state, "CAP END", Yes.quiet);

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
        switch (content)
        {
        case "sasl":
            immutable mechanism = (service.state.connSettings.ssl &&
                (service.state.connSettings.privateKeyFile.length ||
                service.state.connSettings.certFile.length)) ?
                    "AUTHENTICATE EXTERNAL" :
                    "AUTHENTICATE PLAIN";
            raw(service.state, mechanism, Yes.quiet);
            break;

        default:
            //logger.warning("Unhandled capability ACK: ", content);
            break;
        }
        break;

    case "NAK":
        switch (content)
        {
        case "sasl":
            if (service.connectSettings.exitOnSASLFailure)
            {
                quit(service.state, "SASL Negotiation Failure");
                return;
            }

            // SASL refused, safe to end handshake? Too early?
            // Consider making this a Fiber that triggers after say, 5 seconds
            // That should give other CAPs time to process
            raw(service.state, "CAP END", Yes.quiet);

            if (service.capabilityNegotiation == Progress.started)
            {
                // As above
                service.capabilityNegotiation = Progress.finished;
                service.negotiateNick();
            }
            break;

        default:
            //logger.warning("Unhandled capability NAK: ", content);
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
 +  Attempts to authenticate via SASL, with the EXTERNAL mechanism if a private
 +  key and/or certificate is set in the configuration file, and by PLAIN otherwise.
 +/
@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(ConnectService service)
{
    import lu.string : beginsWith, decode64, encode64;
    import std.base64 : Base64Exception;

    service.authentication = Progress.started;

    if (service.state.connSettings.ssl &&
        (service.state.connSettings.privateKeyFile.length ||
        service.state.connSettings.certFile.length) &&
        (service.saslExternal == Progress.notStarted))
    {
        service.saslExternal = Progress.started;
        raw(service.state, "AUTHENTICATE +");
        return;
    }

    immutable plainSuccess = trySASLPlain(service);
    if (!plainSuccess) return service.onSASLFailure();

    // If we're still authenticating after n seconds, abort and join channels.
    delayJoinsAfterFailedAuth(service);
}


// trySASLPlain
/++
 +  Constructs a SASL plain authentication token from the bot's
 +  `kameloso.common.IRCbot.account` and `dialect.defs.IRCbot.password`,
 +  then sends it to the server, during registration.
 +
 +  A SASL plain authentication token is composed like so:
 +
 +     `base64(account \0 account \0 password)`
 +
 +  ...where `dialect.defs.IRCbot.account` is the services account name and
 +  `dialect.defs.IRCbot.password` is the account password.
 +
 +  Params:
 +      service = The current `ConnectService`.
 +/
bool trySASLPlain(ConnectService service)
{
    import lu.string : beginsWith, decode64, encode64;
    import std.base64 : Base64Exception;

    try
    {
        immutable account_ = service.state.bot.account.length ?
            service.state.bot.account :
            service.state.client.origNickname;

        immutable password_ = service.state.bot.password.beginsWith("base64:") ?
            decode64(service.state.bot.password[7..$]) :
            service.state.bot.password;

        immutable authToken = "%s%c%s%c%s".format(account_, '\0', account_, '\0', password_);
        immutable encoded = encode64(authToken);

        raw(service.state, "AUTHENTICATE " ~ encoded, Yes.quiet);
        if (!service.state.settings.hideOutgoing) logger.trace("--> AUTHENTICATE hunter2");
        return true;
    }
    catch (Base64Exception e)
    {
        logger.error("Could not authenticate: malformed password");
        version(PrintStacktraces) logger.trace(e.info);
        return false;
    }
}


// onSASLSuccess
/++
 +  On SASL authentication success, calls a `CAP END` to finish the
 +  `dialect.defs.IRCEvent.Type.CAP` negotiations.
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
     +  - http://ircv3.net/specs/core/capability-negotiation-3.1.html
     +
     +  Notes: Some servers don't ignore post-registration CAP.
     +/

    raw(service.state, "CAP END", Yes.quiet);
    service.capabilityNegotiation = Progress.finished;
    service.negotiateNick();
}


// onSASLFailure
/++
 +  On SASL authentication failure, calls a `CAP END` to finish the
 +  `dialect.defs.IRCEvent.Type.CAP` negotiations and finish registration.
 +
 +  Flags the client as having finished registering, allowing the main loop to
 +  pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.ERR_SASLFAIL)
void onSASLFailure(ConnectService service)
{
    if ((service.saslExternal == Progress.started) && service.state.bot.password.length)
    {
        // Fall back to PLAIN
        service.saslExternal = Progress.finished;
        raw(service.state, "AUTHENTICATE PLAIN", Yes.quiet);
        return;
    }

    if (service.connectSettings.exitOnSASLFailure)
    {
        quit(service.state, "SASL Negotiation Failure");
        return;
    }

    // Auth failed and will fail even if we try NickServ, so flag as
    // finished auth and invoke `CAP END`
    service.authentication = Progress.finished;

    // See `onSASLSuccess` for info on `CAP END`
    raw(service.state, "CAP END", Yes.quiet);
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
 +  Marks registration as completed upon `dialect.defs.IRCEvent.Type.RPL_WELCOME`
 +  (numeric `001`).
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(ConnectService service, const IRCEvent event)
{
    service.registration = Progress.finished;
    service.nickNegotiation = Progress.finished;

    if (event.target.nickname.length && (service.state.client.nickname != event.target.nickname))
    {
        service.state.client.nickname = event.target.nickname;
        service.state.clientUpdated = true;
    }

    version(TwitchSupport) {}
    else
    {
        // No Twitch support built in
        import std.algorithm.searching : endsWith;

        if (service.state.server.address.endsWith(".twitch.tv"))
        {
            logger.warning("This bot was not built with Twitch support enabled. " ~
                "Expect errors and general uselessness.");
        }
    }
}


// onISUPPORT
/++
 +  Requests a UTF-8 codepage if it seems that the server supports changing such.
 +
 +  Currently only RusNet is known to support codepages.
 +/
@(IRCEvent.Type.RPL_ISUPPORT)
void onISUPPORT(ConnectService service, const IRCEvent event)
{
    import lu.string : contains;

    if (event.content.contains("CODEPAGES"))
    {
        raw(service.state, "CODEPAGE UTF-8", Yes.quiet);
    }
}


// onReconnect
/++
 +  Disconnects and reconnects to the server.
 +
 +  This is a "benign" disconnect. We need to reconnect preemptively instead of
 +  waiting for the server to disconnect us, as it would otherwise constitute
 +  an error and the program would exit if
 +  `kameloso.common.CoreSettings.endlesslyConnect` isn't set.
 +/
version(TwitchSupport)
@(IRCEvent.Type.RECONNECT)
void onReconnect(ConnectService service)
{
    import std.concurrency : send;

    logger.info("Reconnecting upon server request.");
    service.state.mainThread.send(ThreadMessage.Reconnect());
}


// onUnknownCommand
/++
 +  Warns the user if the server does not seem to support WHOIS queries, suggesting
 +  that they enable hostmasks mode instead.
 +/
@(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
void onUnknownCommand(ConnectService service, const IRCEvent event)
{
    if (service.serverSupportsWHOIS && (event.aux == "WHOIS"))
    {
        logger.error("Error: This server does not seem to support user accounts.");
        logger.errorf("Consider enabling %sCore%s.%1$spreferHostmasks%2$s.",
            Tint.log, Tint.warning);
        logger.error("As it is, functionality will be greatly limited.");
        service.serverSupportsWHOIS = false;
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

    service.registration = Progress.started;
    raw(service.state, "CAP LS 302", Yes.quiet);

    if (service.state.bot.pass.length)
    {
        version(TwitchSupport)
        {
            //import lu.string : beginsWith;  // for !bot.pass.beginsWith("oauth:")
            import std.algorithm : endsWith;

            immutable serverIsTwitch = service.state.server.address.endsWith(".twitch.tv");
            immutable pass = ((service.state.bot.pass.length == 30) && serverIsTwitch) ?
                ("oauth:" ~ service.state.bot.pass) :
                service.state.bot.pass;

            raw(service.state, "PASS " ~ pass, Yes.quiet);

            if (serverIsTwitch)
            {
                import std.uni : toLower;

                // Make sure we have an account and it is lowercase
                // so we can rely on it (on Twitch)

                if (!service.state.bot.account.length)
                {
                    service.state.bot.account = service.state.client.nickname.toLower;
                }
                else
                {
                    service.state.bot.account = service.state.bot.account.toLower;
                }

                // Just flag as updated, even if nothing changed, to save us a string compare
                service.state.botUpdated = true;
            }
        }
        else
        {
            raw(service.state, "PASS " ~ service.state.bot.pass, Yes.quiet);
        }

        if (!service.state.settings.hideOutgoing) logger.trace("--> PASS hunter2");  // fake it
    }

    import core.thread : Fiber;

    version(TwitchSupport)
    {
        // If we register too early on Twitch servers we won't get a
        // GLOBALUSERSTATE event, and thus miss out on stuff like colour information.
        // Delay negotiation until we see the CAP ACK of twitch.tv/tags.

        if (service.state.server.address.endsWith(".twitch.tv"))
        {
            import kameloso.thread : CarryingFiber;

            void dg()
            {
                while (true)
                {
                    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
                    assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
                    assert((thisFiber.payload.type == IRCEvent.Type.CAP),
                        "Twitch nick negotiation delegate triggered on unknown type");

                    if ((thisFiber.payload.aux == "ACK") &&
                        (thisFiber.payload.content == "twitch.tv/tags"))
                    {
                        // tag capabilities negotiated, safe to register
                        return service.negotiateNick();
                    }

                    // Wrong kind of CAP event; yield and retry.
                    Fiber.yield();
                }
            }

            import kameloso.plugins.common.delayawait : await;

            Fiber fiber = new CarryingFiber!IRCEvent(&dg, 32_768);
            await(service, fiber, IRCEvent.Type.CAP);
            return;
        }
    }

    // Nick negotiation after CAP END
    // If CAP is not supported, go ahead and negotiate nick after n seconds

    enum secsToWaitForCAP = 2;

    void dgTimered()
    {
        if (service.capabilityNegotiation == Progress.notStarted)
        {
            //logger.info("Does the server not support capabilities?");
            service.negotiateNick();
        }
    }

    import kameloso.plugins.common.delayawait : delay;
    delay(service, &dgTimered, secsToWaitForCAP);
}


// negotiateNick
/++
 +  Negotiate nickname and user with the server, during registration.
 +/
void negotiateNick(ConnectService service)
{
    if ((service.registration == Progress.finished) ||
        (service.nickNegotiation != Progress.notStarted)) return;

    import kameloso.common : replaceTokens;
    import std.algorithm.searching : endsWith;
    import std.format : format;

    service.nickNegotiation = Progress.started;

    if (!service.state.server.address.endsWith(".twitch.tv"))
    {
        // Twitch doesn't require USER, only PASS and NICK
        /+
            Command: USER
            Parameters: <user> <mode> <unused> <realname>

            The <mode> parameter should be a numeric, and can be used to
            automatically set user modes when registering with the server.  This
            parameter is a bitmask, with only 2 bits having any signification: if
            the bit 2 is set, the user mode 'w' will be set and if the bit 3 is
            set, the user mode 'i' will be set.

            https://tools.ietf.org/html/rfc2812#section-3.1.3

            The available modes are as follows:
                a - user is flagged as away;
                i - marks a users as invisible;
                w - user receives wallops;
                r - restricted user connection;
                o - operator flag;
                O - local operator flag;
                s - marks a user for receipt of server notices.
         +/
        raw(service.state, "USER %s 8 * :%s".format(service.state.client.user,
            service.state.client.realName.replaceTokens(service.state.client)));
    }

    raw(service.state, "NICK " ~ service.state.client.nickname);
}


// start
/++
 +  Registers with the server.
 +
 +  This initialisation event fires immediately after a successful connect, and
 +  so instead of waiting for something from the server to trigger our
 +  registration procedure (notably `dialect.defs.IRCEvent.Type.NOTICE`s
 +  about our `IDENT` and hostname), we preemptively register.
 +
 +  It seems to work.
 +/
void start(ConnectService service)
{
    register(service);
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
    else
    {
        logger.error("[connect] Unimplemented bus message verb: ", message.payload);
    }
}


public:


// ConnectService
/++
 +  The Connect service is a collection of functions and state needed to connect
 +  and stay connected to an IRC server, as well as authenticate with services.
 +
 +  This is mostly a matter of sending `USER` and `NICK` during registration,
 +  but also incorporates logic to authenticate with services, and capability
 +  negotiations.
 +/
final class ConnectService : IRCPlugin
{
private:
    /// All Connect service settings gathered.
    ConnectSettings connectSettings;

    /++
     +  How many seconds we should wait before we tire of waiting for authentication
     +  responses and just start joining channels.
     +/
    enum authenticationGracePeriod = 15;

    /// At what step we're currently at with regards to authentication.
    Progress authentication;

    /// At what step we're currently at with regards to SASL EXTERNAL authentication.
    Progress saslExternal;

    /// At what step we're currently at with regards to registration.
    Progress registration;

    /// At what step we're currently at with regards to capabilities.
    Progress capabilityNegotiation;

    /// At what step we're currently at with regards to nick negotiation.
    Progress nickNegotiation;

    /// Whether or not the server has sent at least one `dialect.defs.IRCEvent.Type.PING`.
    bool serverPinged;

    /// Whether or not the bot has renamed itself during registration.
    bool renamedDuringRegistration;

    /// Whether or not the bot has joined its channels at least once.
    bool joinedChannels;

    /// Whether or not the bot has sent configured commands after connect.
    bool sentAfterConnect;

    /// Whether or not the server seems to be supporting WHOIS queries.
    bool serverSupportsWHOIS = true;

    mixin IRCPluginImpl;
}

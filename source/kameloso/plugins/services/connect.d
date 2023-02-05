/++
    The Connect service handles logging onto IRC servers after having connected,
    as well as managing authentication to services. It also manages responding
    to [dialect.defs.IRCEvent.Type.PING|PING] requests, and capability negotiations.

    The actual connection logic is in the [kameloso.net] module.

    See_Also:
        [kameloso.net]
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.services.connect;

version(WithConnectService):

private:

import kameloso.plugins.common.core;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// ConnectSettings
/++
    Settings for a [ConnectService].
 +/
@Settings struct ConnectSettings
{
private:
    import lu.uda : CannotContainComments, /*Separator,*/ Unserialisable;

    /++
        What to use as delimiter to separate [sendAfterConnect] into different
        lines to send to the server.

        This is to compensate for not being able to use [lu.uda.Separator] and a
        `string[]` (because it doesn't work well with getopt).
     +/
    enum sendAfterConnectSeparator = ";;";

public:
    /++
        Whether or not to try to regain nickname if there was a collision and
        we had to rename ourselves, when registering.
     +/
    bool regainNickname = true;

    /// Whether or not to join channels upon being invited to them.
    bool joinOnInvite = false;

    /// Whether to use SASL authentication or not.
    @Unserialisable bool sasl = true;

    /// Whether or not to abort and exit if SASL authentication fails.
    bool exitOnSASLFailure = false;

    /// Lines to send after successfully connecting and registering.
    //@Separator(";;")
    @CannotContainComments
    string sendAfterConnect;
}


/// Progress of a process.
enum Progress
{
    notStarted, /// Process not yet started, init state.
    inProgress, /// Process started but has yet to finish.
    finished,   /// Process finished.
}


// onSelfpart
/++
    Removes a channel from the list of joined channels.

    Fires when the bot leaves a channel, one way or another.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFPART)
    .onEvent(IRCEvent.Type.SELFKICK)
    .channelPolicy(ChannelPolicy.any)
)
void onSelfpart(ConnectService service, const ref IRCEvent event)
{
    import std.algorithm.searching : canFind;

    version(TwitchSupport)
    {
        if (service.state.server.daemon == IRCServer.Daemon.twitch)
        {
            service.currentActualChannels.remove(event.channel);
        }
    }

    if (service.state.bot.homeChannels.canFind(event.channel))
    {
        logger.warning("Leaving a home...");
    }
}


// joinChannels
/++
    Joins all channels listed as home channels *and* guest channels in the arrays in
    [kameloso.pods.IRCBot|IRCBot] of the current [ConnectService]'s
    [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

    Params:
        service = The current [ConnectService].
 +/
void joinChannels(ConnectService service)
{
    scope(exit) service.joinedChannels = true;

    if (!service.state.bot.homeChannels.length && !service.state.bot.guestChannels.length)
    {
        logger.warning("No channels, no purpose...");
        return;
    }

    import kameloso.messaging : joinChannel = join;
    import lu.string : plurality;
    import std.algorithm.iteration : filter, uniq;
    import std.algorithm.sorting : sort;
    import std.array : array, join;
    import std.range : walkLength;

    auto homelist = service.state.bot.homeChannels
        .filter!(channelName => (channelName != "-"))
        .array
        .sort
        .uniq;

    auto guestlist = service.state.bot.guestChannels
        .filter!(channelName => (channelName != "-"))
        .array
        .sort
        .uniq;

    immutable numChans = homelist.walkLength() + guestlist.walkLength();

    enum pattern = "Joining <i>%d</> %s...";
    logger.logf(pattern, numChans, numChans.plurality("channel", "channels"));

    // Join in two steps so home channels don't get shoved away by guest channels
    if (service.state.bot.homeChannels.length) joinChannel(service.state,
        homelist.join(','), string.init, Yes.quiet);

    if (service.state.bot.guestChannels.length) joinChannel(service.state,
        guestlist.join(','), string.init, Yes.quiet);

    version(TwitchSupport)
    {
        import kameloso.plugins.common.delayawait : delay;

        /+
            If, on Twitch, an invalid channel was supplied as a home or a guest
            channel, it will just silently not join it but leave us thinking it has
            (since the entry in `homeChannels`/`guestChannels` will still be there).
            Check whether we actually joined them all, after a short delay, and
            if not, sync the arrays.
         +/

        // Early return if we're not on Twitch to spare us a level of indentation
        if (service.state.server.daemon != IRCServer.Daemon.twitch) return;

        void delayedChannelCheckDg()
        {
            import std.range : chain;

            // See if we actually managed to join all channels
            auto allChannels = chain(service.state.bot.homeChannels, service.state.bot.guestChannels);
            string[] missingChannels;

            foreach (immutable channel; allChannels)
            {
                if (channel !in service.currentActualChannels)
                {
                    // We failed to join a channel for some reason. No such user?
                    missingChannels ~= channel;
                }
            }

            if (missingChannels.length)
            {
                enum pattern = "Timed out waiting to join channels: %-(<l>%s</>, %)";
                logger.warningf(pattern, missingChannels);
            }
        }

        delay(service, &delayedChannelCheckDg, service.channelCheckDelay);
    }
}


// onSelfjoin
/++
    Records us as having joined a channel, when we join one. This is to allow
    us to notice when we silently fail to join something, on Twitch. As it's
    limited to there, gate it behind version `TwitchSupport`.
 +/
version(TwitchSupport)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(ChannelPolicy.any)
)
void onSelfjoin(ConnectService service, const ref IRCEvent event)
{
    if (service.state.server.daemon == IRCServer.Daemon.twitch)
    {
        service.currentActualChannels[event.channel] = true;
    }
}


// onToConnectType
/++
    Responds to [dialect.defs.IRCEvent.Type.ERR_NEEDPONG|ERR_NEEDPONG] events by sending
    the text supplied as content in the [dialect.defs.IRCEvent|IRCEvent] to the server.

    "Also known as [dialect.defs.IRCEvent.Type.ERR_NEEDPONG|ERR_NEEDPONG] (Unreal/Ultimate)
    for use during registration, however it's not used in Unreal (and might not
    be used in Ultimate either)."

    Encountered at least once, on a private server.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_NEEDPONG)
)
void onToConnectType(ConnectService service, const ref IRCEvent event)
{
    immediate(service.state, event.content, Yes.quiet);
}


// onPing
/++
    Pongs the server upon [dialect.defs.IRCEvent.Type.PING|PING].

    Ping with the sender as target, and not the necessarily
    the server as saved in the [dialect.defs.IRCServer|IRCServer] struct. For
    example, [dialect.defs.IRCEvent.Type.ERR_NEEDPONG|ERR_NEEDPONG] generally
    wants you to ping a random number or string.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.PING)
)
void onPing(ConnectService service, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;

    immutable target = event.content.length ? event.content : event.sender.address;
    service.state.mainThread.prioritySend(ThreadMessage.pong(target));
}


// tryAuth
/++
    Tries to authenticate with services.

    The command to send vary greatly between server daemons (and networks), so
    use some heuristics and try the best guess.

    Params:
        service = The current [ConnectService].
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

    service.authentication = Progress.inProgress;

    with (IRCServer.Daemon)
    switch (service.state.server.daemon)
    {
    case rizon:
    case unreal:
    case hybrid:
    case bahamut:
        import std.conv : text;

        // Only accepts password, no auth nickname
        if (service.state.client.nickname != service.state.client.origNickname)
        {
            enum pattern = "Cannot auth when you have changed your nickname. " ~
                "(<l>%s</> != <l>%s</>)";
            logger.warningf(pattern, service.state.client.nickname,
                service.state.client.origNickname);

            service.authentication = Progress.finished;
            return;
        }

        query(service.state, serviceNick, text(verb, ' ', password), Yes.quiet);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
        {
            enum pattern = "--> PRIVMSG %s :%s hunter2";
            logger.tracef(pattern, serviceNick, verb);
        }
        break;

    case snircd:
    case ircdseven:
    case u2:
    case solanum:
        import std.conv : text;

        // Accepts auth login
        // GameSurge is AuthServ
        string account = service.state.bot.account;

        if (!service.state.bot.account.length)
        {
            enum pattern = "No account specified! Trying <i>%s</>...";
            logger.logf(pattern, service.state.client.origNickname);
            account = service.state.client.origNickname;
        }

        query(service.state, serviceNick, text(verb, ' ', account, ' ', password), Yes.quiet);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
        {
            enum pattern = "--> PRIVMSG %s :%s %s hunter2";
            logger.tracef(pattern, serviceNick, verb, account);
        }
        break;

    case rusnet:
        // Doesn't want a PRIVMSG
        raw(service.state, "NICKSERV IDENTIFY " ~ password, Yes.quiet);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
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

    import kameloso.plugins.common.delayawait : delay;

    void delayedJoinDg()
    {
        // If we're still authenticating after n seconds, abort and join channels.

        if (service.authentication == Progress.inProgress)
        {
            logger.warning("Authentication timed out.");
            service.authentication = Progress.finished;
        }

        if (!service.joinedChannels)
        {
            service.joinChannels();
        }
    }

    delay(service, &delayedJoinDg, service.authenticationGracePeriod);
}


// onAuthEnd
/++
    Flags authentication as finished and join channels.

    Fires when an authentication service sends a message with a known success,
    invalid or rejected auth text, signifying completed login.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.AUTH_SUCCESS)
    .onEvent(IRCEvent.Type.AUTH_FAILURE)
)
void onAuthEnd(ConnectService service, const ref IRCEvent event)
{
    service.authentication = Progress.finished;

    if (service.registration == Progress.finished)
    {
        if (!service.joinedChannels)
        {
            service.joinChannels();
        }
    }
}


// onTwitchAuthFailure
/++
    On Twitch, if the OAuth pass is wrong or malformed, abort and exit the program.
    Only deal with it if we're currently registering.

    If the bot was compiled without Twitch support, mention this and quit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.NOTICE)
)
void onTwitchAuthFailure(ConnectService service, const ref IRCEvent event)
{
    import std.algorithm.searching : endsWith;
    import std.typecons : Flag, No, Yes;

    if ((service.state.server.daemon != IRCServer.Daemon.unset) ||
        !service.state.server.address.endsWith(".twitch.tv"))
    {
        // Not early Twitch registration
        return;
    }

    // We're registering on Twitch and we got a NOTICE, probably an error

    version(TwitchSupport)
    {
        switch (event.content)
        {
        case "Improperly formatted auth":
            if (!service.state.bot.pass.length)
            {
                logger.error("Missing Twitch authentication token.");
            }
            else
            {
                logger.error("Twitch authentication token is malformed. " ~
                    "Make sure it is entered correctly.");
            }
            break;  // drop down

        case "Login authentication failed":
            logger.error("Twitch authentication token is invalid or has expired.");
            break;  // drop down

        case "Login unsuccessful":
            logger.error("Twitch authentication token probably has insufficient privileges.");
            break;  // drop down

        default:
            // Just some notice; return
            return;
        }

        // Do this here since it should be output in all cases except for the
        // default, which just returns anyway and skips this.
        enum message = "Run the program with <i>--set twitch.keygen</> to generate a new one.";
        logger.log(message);

        // Exit and let the user tend to it.
        quit!(Yes.priority)(service.state, event.content, No.quiet);
    }
    else
    {
        switch (event.content)
        {
        case "Improperly formatted auth":
        case "Login authentication failed":
        case "Login unsuccessful":
            logger.error("The bot was not compiled with Twitch support enabled.");
            return quit!(Yes.priority)(service.state, "Missing Twitch support", No.quiet);

        default:
            return;
        }
    }
}


// onNickInUse
/++
    Modifies the nickname by appending characters to the end of it.

    Don't modify [IRCPluginState.client.nickname] as the nickname only changes
    when the [dialect.defs.IRCEvent.Type.RPL_LOGGEDIN|RPL_LOGGEDIN] event actually occurs.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_NICKNAMEINUSE)
    .onEvent(IRCEvent.Type.ERR_NICKCOLLISION)
)
void onNickInUse(ConnectService service)
{
    import std.conv : text;
    import std.random : uniform;

    if (service.registration == Progress.inProgress)
    {
        if (!service.renameDuringRegistration.length)
        {
            import kameloso.constants : KamelosoDefaults;
            service.renameDuringRegistration = service.state.client.nickname ~
                KamelosoDefaults.altNickSeparator;
        }

        service.renameDuringRegistration ~= uniform(0, 10).text;
        immediate(service.state, "NICK " ~ service.renameDuringRegistration);
    }
}


// onBadNick
/++
    Aborts a registration attempt and quits if the requested nickname is too
    long or contains invalid characters.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_ERRONEOUSNICKNAME)
)
void onBadNick(ConnectService service)
{
    if (service.registration == Progress.inProgress)
    {
        // Mid-registration and invalid nickname; abort

        if (service.renameDuringRegistration.length)
        {
            logger.error("Your nickname was taken and an alternative nickname " ~
                "could not be successfully generated.");
        }
        else
        {
            logger.error("Your nickname is invalid: it is reserved, too long, or contains invalid characters.");
        }

        quit(service.state, "Invalid nickname");
    }
}


// onBanned
/++
    Quits the program if we're banned.

    There's no point in reconnecting.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_YOUREBANNEDCREEP)
)
void onBanned(ConnectService service)
{
    logger.error("You are banned!");
    quit(service.state, "Banned");
}


// onPassMismatch
/++
    Quits the program if we supplied a bad [kameloso.pods.IRCBot.pass|IRCBot.pass].

    There's no point in reconnecting.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_PASSWDMISMATCH)
)
void onPassMismatch(ConnectService service)
{
    if (service.registration != Progress.inProgress)
    {
        // Unsure if this ever happens, but don't quit if we're actually registered
        return;
    }

    logger.error("Pass mismatch!");
    quit(service.state, "Incorrect pass");
}


// onInvite
/++
    Upon being invited to a channel, joins it if the settings say we should.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.INVITE)
    .channelPolicy(ChannelPolicy.any)
)
void onInvite(ConnectService service, const ref IRCEvent event)
{
    if (!service.connectSettings.joinOnInvite)
    {
        enum message = "Invited, but <i>joinOnInvite</> is set to false.";
        logger.log(message);
        return;
    }

    join(service.state, event.channel);
}


// onCapabilityNegotiation
/++
    Handles server capability exchange.

    This is a necessary step to register with some IRC server; the capabilities
    have to be requested (`CAP LS`), and the negotiations need to be ended
    (`CAP END`).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CAP)
)
void onCapabilityNegotiation(ConnectService service, const ref IRCEvent event)
{
    import lu.string : strippedRight;

    // http://ircv3.net/irc
    // https://blog.irccloud.com/ircv3

    if (service.registration == Progress.finished)
    {
        // It's possible to call CAP LS after registration, and that would start
        // this whole process anew. So stop if we have registered.
        return;
    }

    service.capabilityNegotiation = Progress.inProgress;

    immutable content = event.content.strippedRight;

    switch (event.aux[0])
    {
    case "LS":
        import std.algorithm.iteration : splitter;
        import std.array : Appender;

        Appender!(string[]) capsToReq;
        capsToReq.reserve(8);  // guesstimate

        foreach (immutable rawCap; content.splitter(' '))
        {
            import lu.string : beginsWith, contains, nom;

            string slice = rawCap;  // mutable
            immutable cap = slice.nom!(Yes.inherit)('=');
            immutable sub = slice;

            switch (cap)
            {
            case "sasl":
                // Error: `switch` skips declaration of variable acceptsExternal
                // https://issues.dlang.org/show_bug.cgi?id=21427
                // feep[work] | the quick workaround is to wrap the switch body in a {}
                {
                    immutable acceptsExternal = !sub.length || sub.contains("EXTERNAL");
                    immutable acceptsPlain = !sub.length || sub.contains("PLAIN");
                    immutable hasKey = (service.state.connSettings.privateKeyFile.length ||
                        service.state.connSettings.certFile.length);

                    if (service.state.connSettings.ssl && acceptsExternal && hasKey)
                    {
                        // Proceed
                    }
                    else if (service.connectSettings.sasl && acceptsPlain &&
                        service.state.bot.password.length)
                    {
                        // Likewise
                    }
                    else
                    {
                        // Abort
                        continue;
                    }
                }
                goto case;

            version(TwitchSupport)
            {
                case "twitch.tv/membership":
                case "twitch.tv/tags":
                case "twitch.tv/commands":
                    // Twitch-specific capabilities
                    // Drop down
                    goto case;
            }

            case "account-tag":  // @account=blahblahj;
            //case "echo-message":  // Outgoing messages are received as incoming
            //case "solanum.chat/identify-msg":  // Tag just saying "identified"
            //case "solanum.chat/realhost":   // Includes user's real host/ip

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
            //case "cap-notify":  // Implicitly enabled by CAP LS 302
            //case "userhost-in-names":  // dup
            //case "multi-prefix":  // dup
            //case "away-notify":  // dup
            //case "account-notify":  // dup
            //case "tls":
                // UnrealIRCd
            case "znc.in/self-message":
                // znc SELFCHAN/SELFQUERY events

                capsToReq ~= cap;
                ++service.requestedCapabilitiesRemaining;
                break;

            default:
                //logger.warning("Unhandled capability: ", cap);
                break;
            }
        }

        if (capsToReq.data.length)
        {
            import std.algorithm.iteration : joiner;
            import std.conv : text;
            immediate(service.state, text("CAP REQ :", capsToReq.data.joiner(" ")), Yes.quiet);
        }
        break;

    case "ACK":
        import std.algorithm.iteration : splitter;

        foreach (cap; content.splitter(" "))
        {
            switch (cap)
            {
            case "sasl":
                immutable hasKey = (service.state.connSettings.privateKeyFile.length ||
                    service.state.connSettings.certFile.length);
                immutable mechanism = (service.state.connSettings.ssl && hasKey) ?
                    "AUTHENTICATE EXTERNAL" :
                    "AUTHENTICATE PLAIN";
                immediate(service.state, mechanism, Yes.quiet);
                break;

            default:
                //logger.warning("Unhandled capability ACK: ", cap);
                --service.requestedCapabilitiesRemaining;
                break;
            }
        }
        break;

    case "NAK":
        import std.algorithm.iteration : splitter;

        foreach (cap; content.splitter(" "))
        {
            switch (cap)
            {
            case "sasl":
                if (service.connectSettings.exitOnSASLFailure)
                {
                    quit(service.state, "SASL Negotiation Failure");
                    return;
                }
                break;

            default:
                //logger.warning("Unhandled capability NAK: ", cap);
                --service.requestedCapabilitiesRemaining;
                break;
            }
        }
        break;

    default:
        //logger.warning("Unhandled capability type: ", event.aux[0]);
        break;
    }

    if (!service.requestedCapabilitiesRemaining &&
        (service.capabilityNegotiation == Progress.inProgress))
    {
        service.capabilityNegotiation = Progress.finished;
        immediate(service.state, "CAP END", Yes.quiet);

        if (!service.issuedNICK)
        {
            negotiateNick(service);
        }
    }
}


// onSASLAuthenticate
/++
    Attempts to authenticate via SASL, with the EXTERNAL mechanism if a private
    key and/or certificate is set in the configuration file, and by PLAIN otherwise.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SASL_AUTHENTICATE)
)
void onSASLAuthenticate(ConnectService service)
{
    service.authentication = Progress.inProgress;

    immutable hasKey = (service.state.connSettings.privateKeyFile.length ||
        service.state.connSettings.certFile.length);

    if (service.state.connSettings.ssl && hasKey &&
        (service.saslExternal == Progress.notStarted))
    {
        service.saslExternal = Progress.inProgress;
        immediate(service.state, "AUTHENTICATE +");
        return;
    }

    immutable plainSuccess = trySASLPlain(service);

    if (!plainSuccess)
    {
        service.onSASLFailure();
    }
}


// trySASLPlain
/++
    Constructs a SASL plain authentication token from the bot's
    [kameloso.pods.IRCBot.account|IRCBot.account] and
    [kameloso.pods.IRCBot.password|IRCBot.password],
    then sends it to the server, during registration.

    A SASL plain authentication token is composed like so:

        `base64(account \0 account \0 password)`

    ...where [kameloso.pods.IRCBot.account|IRCBot.account] is the services
    account name and [kameloso.pods.IRCBot.password|IRCBot.password] is the
    account password.

    Params:
        service = The current [ConnectService].
 +/
auto trySASLPlain(ConnectService service)
{
    import lu.string : beginsWith, decode64, encode64;
    import std.base64 : Base64Exception;
    import std.conv : text;

    try
    {
        immutable account_ = service.state.bot.account.length ?
            service.state.bot.account :
            service.state.client.origNickname;

        immutable password_ = service.state.bot.password.beginsWith("base64:") ?
            decode64(service.state.bot.password[7..$]) :
            service.state.bot.password;

        immutable authToken = text(account_, '\0', account_, '\0', password_);
        immutable encoded = encode64(authToken);

        immediate(service.state, "AUTHENTICATE " ~ encoded, Yes.quiet);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
        {
            logger.trace("--> AUTHENTICATE hunter2");
        }
        return true;
    }
    catch (Base64Exception e)
    {
        enum pattern = "Could not authenticate: malformed password (<l>%s</>)";
        logger.errorf(pattern, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
        return false;
    }
}


// onSASLSuccess
/++
    On SASL authentication success, calls a `CAP END` to finish the
    [dialect.defs.IRCEvent.Type.CAP|CAP] negotiations.

    Flags the client as having finished registering and authing, allowing the
    main loop to pick it up and propagate it to all other plugins.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_SASLSUCCESS)
)
void onSASLSuccess(ConnectService service)
{
    service.authentication = Progress.finished;

    /++
        The END subcommand signals to the server that capability negotiation
        is complete and requests that the server continue with client
        registration. If the client is already registered, this command
        MUST be ignored by the server.

        Clients that support capabilities but do not wish to enter negotiation
        SHOULD send CAP END upon connection to the server.

        - http://ircv3.net/specs/core/capability-negotiation-3.1.html

        Notes: Some servers don't ignore post-registration CAP.
     +/

    if (!--service.requestedCapabilitiesRemaining &&
        (service.capabilityNegotiation == Progress.inProgress))
    {
        service.capabilityNegotiation = Progress.finished;
        immediate(service.state, "CAP END", Yes.quiet);

        if ((service.registration == Progress.inProgress) && !service.issuedNICK)
        {
            negotiateNick(service);
        }
    }
}


// onSASLFailure
/++
    On SASL authentication failure, calls a `CAP END` to finish the
    [dialect.defs.IRCEvent.Type.CAP|CAP] negotiations and finish registration.

    Flags the client as having finished registering, allowing the main loop to
    pick it up and propagate it to all other plugins.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_SASLFAIL)
)
void onSASLFailure(ConnectService service)
{
    if ((service.saslExternal == Progress.inProgress) && service.state.bot.password.length)
    {
        // Fall back to PLAIN
        service.saslExternal = Progress.finished;
        immediate(service.state, "AUTHENTICATE PLAIN", Yes.quiet);
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

    if (!--service.requestedCapabilitiesRemaining &&
        (service.capabilityNegotiation == Progress.inProgress))
    {
        service.capabilityNegotiation = Progress.finished;
        immediate(service.state, "CAP END", Yes.quiet);

        if ((service.registration == Progress.inProgress) && !service.issuedNICK)
        {
            negotiateNick(service);
        }
    }
}


// onWelcome
/++
    Marks registration as completed upon [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME]
    (numeric `001`).

    Additionally performs post-connect routines (authenticates if not already done,
    and send-after-connect).
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(ConnectService service)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : endsWith;

    service.registration = Progress.finished;
    service.renameDuringRegistration = string.init;

    version(WithPingMonitor) startPingMonitorFiber(service);

    alias separator = ConnectSettings.sendAfterConnectSeparator;
    auto toSendRange = service.connectSettings.sendAfterConnect.splitter(separator);

    foreach (immutable unstripped; toSendRange)
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

    if (service.state.server.address.endsWith(".twitch.tv"))
    {
        import kameloso.plugins.common.delayawait : await, unawait;

        if (service.state.settings.preferHostmasks &&
            !service.state.settings.force)
        {
            // We already infer account by username on Twitch;
            // hostmasks mode makes no sense there. So disable it.
            service.state.settings.preferHostmasks = false;
            service.state.updates |= typeof(service.state.updates).settings;
        }

        static immutable IRCEvent.Type[2] endOfMotdEventTypes =
        [
            IRCEvent.Type.RPL_ENDOFMOTD,
            IRCEvent.Type.ERR_NOMOTD,
        ];

        void twitchWarningDg(IRCEvent)
        {
            scope(exit) unawait(service, &twitchWarningDg, endOfMotdEventTypes[]);

            version(TwitchSupport)
            {
                import lu.string : beginsWith;

                /+
                    Upon having connected, registered and logged onto the Twitch servers,
                    disable outgoing colours and warn about having a `.` or `/` prefix.

                    Twitch chat doesn't do colours, so ours would only show up like `00kameloso`.
                    Furthermore, Twitch's own commands are prefixed with a dot `.` and/or a slash `/`,
                    so we can't use that ourselves.
                 +/

                if (service.state.server.daemon != IRCServer.Daemon.twitch) return;

                service.state.settings.colouredOutgoing = false;
                service.state.updates |= typeof(service.state.updates).settings;

                if (service.state.settings.prefix.beginsWith(".") ||
                    service.state.settings.prefix.beginsWith("/"))
                {
                    enum pattern = `WARNING: A prefix of "<l>%s</>" will *not* work on Twitch servers, ` ~
                        "as <l>.</> and <l>/</> are reserved for Twitch's own commands.";
                    logger.warningf(pattern, service.state.settings.prefix);
                }
            }
            else
            {
                // No Twitch support built in
                if (service.state.server.address.endsWith(".twitch.tv"))
                {
                    logger.warning("This bot was not built with Twitch support enabled. " ~
                        "Expect errors and general uselessness.");
                }
            }
        }

        await(service, &twitchWarningDg, endOfMotdEventTypes[]);
    }
    else
    {
        // Not on Twitch
        if (service.connectSettings.regainNickname && !service.state.bot.hasGuestNickname &&
            (service.state.client.nickname != service.state.client.origNickname))
        {
            import kameloso.plugins.common.delayawait : delay;
            import kameloso.constants : BufferSize;
            import core.thread : Fiber;

            void regainDg()
            {
                // Concatenate the verb once
                immutable squelchVerb = "squelch " ~ service.state.client.origNickname;

                while (service.state.client.nickname != service.state.client.origNickname)
                {
                    import kameloso.messaging : raw;

                    version(WithPrinterPlugin)
                    {
                        import kameloso.thread : ThreadMessage, sendable;
                        import std.concurrency : send;
                        service.state.mainThread.send(
                            ThreadMessage.busMessage("printer", sendable(squelchVerb)));
                    }

                    raw(service.state, "NICK " ~ service.state.client.origNickname,
                        Yes.quiet, Yes.background);
                    delay(service, service.nickRegainPeriodicity, Yes.yield);
                }
            }

            auto regainFiber = new Fiber(&regainDg, BufferSize.fiberStack);
            delay(service, regainFiber, service.nickRegainPeriodicity);
        }
    }
}


// onSelfnickSuccessOrFailure
/++
    Resets [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin] squelching upon a
    successful or failed nick change. This so as to be squelching as little as possible.
 +/
version(WithPrinterPlugin)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFNICK)
    .onEvent(IRCEvent.Type.ERR_NICKNAMEINUSE)
)
void onSelfnickSuccessOrFailure(ConnectService service)
{
    import kameloso.thread : ThreadMessage, sendable;
    import std.concurrency : send;
    service.state.mainThread.send(
        ThreadMessage.busMessage("printer", sendable("unsquelch " ~ service.state.client.origNickname)));
}


// onQuit
/++
    Regains nickname if the holder of the one we wanted during registration quit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(ConnectService service, const ref IRCEvent event)
{
    if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
        service.connectSettings.regainNickname &&
        (event.sender.nickname == service.state.client.origNickname))
    {
        // The regain Fiber will end itself when it is next triggered
        enum pattern = "Attempting to regain nickname <l>%s</>...";
        logger.infof(pattern, service.state.client.origNickname);
        raw(service.state, "NICK " ~ service.state.client.origNickname, No.quiet, No.background);
    }
}


// onEndOfMotd
/++
    Joins channels and prints some Twitch warnings on end of MOTD.

    Do this then instead of on [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME]
    for better timing, and to avoid having the message drown in MOTD.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMotd(ConnectService service)
{
    // Gather information about ourselves
    if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
        !service.state.client.ident.length)
    {
        whois!(Yes.priority)(service.state, service.state.client.nickname, Yes.force, Yes.quiet);
    }

    version(TwitchSupport)
    {
        if (service.state.server.daemon == IRCServer.Daemon.twitch)
        {
            service.serverSupportsWHOIS = false;
        }
    }

    if (service.state.server.network.length &&
        service.state.bot.password.length &&
        (service.authentication == Progress.notStarted) &&
        (service.state.server.daemon != IRCServer.Daemon.twitch))
    {
        tryAuth(service);
    }
    else if (((service.authentication == Progress.finished) ||
        !service.state.bot.password.length ||
        (service.state.server.daemon == IRCServer.Daemon.twitch)) &&
        !service.joinedChannels)
    {
        // tryAuth finished early with an unsuccessful login, else
        // `service.authentication` would be set much later.
        // Twitch servers can't auth so join immediately
        // but don't do anything if we already joined channels.
        service.joinChannels();
    }
}


// onWHOISUser
/++
    Catch information about ourselves (notably our `IDENT`) from `WHOIS` results.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOISUSER)
)
void onWHOISUser(ConnectService service, const ref IRCEvent event)
{
    if (event.target.nickname != service.state.client.nickname) return;

    if (service.state.client.ident != event.target.ident)
    {
        service.state.client.ident = event.target.ident;
        service.state.updates |= typeof(service.state.updates).client;
    }
}


// onISUPPORT
/++
    Requests a UTF-8 codepage if it seems that the server supports changing such.

    Currently only RusNet is known to support codepages.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ISUPPORT)
)
void onISUPPORT(ConnectService service, const ref IRCEvent event)
{
    import lu.string : contains;

    if (event.content.contains("CODEPAGES"))
    {
        raw(service.state, "CODEPAGE UTF-8", Yes.quiet);
    }
}


// onReconnect
/++
    Disconnects and reconnects to the server.

    This is a "benign" disconnect. We need to reconnect preemptively instead of
    waiting for the server to disconnect us, as it would otherwise constitute an error.
 +/
version(TwitchSupport)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RECONNECT)
)
void onReconnect(ConnectService service)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;

    logger.info("Reconnecting upon server request.");
    service.state.mainThread.send(ThreadMessage.reconnect());
}


// onUnknownCommand
/++
    Warns the user if the server does not seem to support WHOIS queries, suggesting
    that they enable hostmasks mode instead.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
)
void onUnknownCommand(ConnectService service, const ref IRCEvent event)
{
    if (service.serverSupportsWHOIS && !service.state.settings.preferHostmasks && (event.aux[0] == "WHOIS"))
    {
        logger.error("Error: This server does not seem to support user accounts.");
        enum message = "Consider enabling <l>Core</>.<l>preferHostmasks</>.";
        logger.error(message);
        logger.error("As it is, functionality will be greatly limited.");
        service.serverSupportsWHOIS = false;
    }
}


// startPingMonitorFiber
/++
    Starts a monitor Fiber that sends a [dialect.defs.IRCEvent.Type.PING|PING]
    if we haven't received one from the server for a while. This is to ensure
    that dead connections are properly detected.

    Requires version `WithPingMonitor`. It's not completely obvious whether or not
    this is worth including, so make it opt-in for now.

    Params:
        service = The current [ConnectService].
 +/
version(WithPingMonitor)
void startPingMonitorFiber(ConnectService service)
{
    import kameloso.plugins.common.delayawait : await, delay, removeDelayedFiber;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import core.thread : Fiber;
    import core.time : seconds;

    static immutable pingMonitorPeriodicity = 600.seconds;

    void pingMonitorDg()
    {
        static immutable periodicitySeconds = pingMonitorPeriodicity.total!"seconds";
        static immutable timeToAllowForPingResponse = 30.seconds;
        static immutable briefWait = 1.seconds;
        long lastPongTimestamp;
        uint strikes;

        enum StrikeBreakpoints
        {
            ping = 3,
            reconnect = 5,
        }

        while (true)
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: " ~ typeof(thisFiber).stringof);
            immutable thisEvent = thisFiber.payload;

            with (IRCEvent.Type)
            switch (thisEvent.type)
            {
            case UNSET:
                import std.datetime.systime : Clock;

                // Triggered by timer
                immutable nowInUnix = Clock.currTime.toUnixTime;

                if ((nowInUnix - lastPongTimestamp) >= periodicitySeconds)
                {
                    import kameloso.thread : ThreadMessage;
                    import std.concurrency : prioritySend;

                    /+
                        Skip first 3 strikes, helps when resuming from suspend and similar,
                        then allow for two PINGs with `timeToAllowForPingResponse` in between.
                        Finally, if all else failed, reconnect.
                     +/
                    ++strikes;

                    if (strikes <= StrikeBreakpoints.ping)
                    {
                        delay(service, briefWait, Yes.yield);
                        continue;
                    }
                    else if (strikes <= StrikeBreakpoints.reconnect)
                    {
                        // Timeout. Send a preemptive ping
                        service.state.mainThread.prioritySend(ThreadMessage.ping(service.state.server.resolvedAddress));
                        delay(service, timeToAllowForPingResponse, Yes.yield);
                        continue;
                    }
                    else /*if (strikes > StrikeBreakpoints.reconnect)*/
                    {
                        // All failed, reconnect
                        service.state.mainThread.prioritySend(ThreadMessage.reconnect);
                        return;
                    }
                }
                else
                {
                    // Early trigger, either interleaved with a PONG or due to preemptive PING
                    // Remove current delay and re-delay at when the next PING check should be
                    removeDelayedFiber(service);
                    immutable elapsed = (nowInUnix - lastPongTimestamp);
                    immutable remaining = (periodicitySeconds - elapsed);
                    delay(service, remaining.seconds, Yes.yield);
                }
                continue;

            case PING:
            case PONG:
                // Triggered by PING *or* PONG response from our preemptive PING
                // Update and remove delay, so we can drop down and re-delay it
                lastPongTimestamp = thisEvent.time;
                strikes = 0;
                removeDelayedFiber(service);
                break;

            default:
                assert(0, "Impossible case hit in pingMonitorDg");
            }

            delay(service, pingMonitorPeriodicity, Yes.yield);
        }
    }

    static immutable IRCEvent.Type[2] pingPongTypes =
    [
        IRCEvent.Type.PING,
        IRCEvent.Type.PONG,
    ];

    Fiber pingMonitorFiber = new CarryingFiber!IRCEvent(&pingMonitorDg, BufferSize.fiberStack);
    await(service, pingMonitorFiber, pingPongTypes[]);
    delay(service, pingMonitorFiber, pingMonitorPeriodicity);
}


// register
/++
    Registers with/logs onto an IRC server.

    Params:
        service = The current [ConnectService].
 +/
void register(ConnectService service)
{
    import lu.string : beginsWith;
    import std.algorithm.searching : canFind, endsWith;
    import std.uni : toLower;

    service.registration = Progress.inProgress;

    // Server networks we know to support capabilities
    static immutable capabilityServerWhitelistPrefix =
    [
        "efnet.",
    ];

    // Ditto
    static immutable capabilityServerWhitelistSuffix =
    [
        ".libera.chat",
        ".freenode.net",
        ".twitch.tv",
        ".acc.umu.se",
        ".irchighway.net",
        ".oftc.net",
        ".rizon.net",
        ".snoonet.org",
        ".spotchat.org",
        ".swiftirc.net",
        ".efnet.org",
        ".netbsd.se",
        ".geekshed.net",
        ".moep.net",
        ".esper.net",
        ".europnet.org",
    ];

    // Server networks we know to not support capabilities
    static immutable capabilityServerBlacklistSuffix =
    [
        ".quakenet.org",
        ".dal.net",
        ".gamesurge.net",
        ".geveze.org",
        ".ircnet.net",
        ".undernet.org",
        ".team17.com",
        ".link-net.be",
    ];

    immutable serverToLower = service.state.server.address.toLower;
    immutable serverWhitelisted = capabilityServerWhitelistSuffix
        .canFind!((a,b) => b.endsWith(a))(serverToLower) ||
        capabilityServerWhitelistPrefix
            .canFind!((a,b) => b.beginsWith(a))(serverToLower);
    immutable serverBlacklisted = !serverWhitelisted &&
        capabilityServerBlacklistSuffix
            .canFind!((a,b) => b.endsWith(a))(serverToLower);

    if (!serverBlacklisted || service.state.settings.force)
    {
        immediate(service.state, "CAP LS 302", Yes.quiet);
    }

    version(TwitchSupport)
    {
        import std.algorithm : endsWith;
        immutable serverIsTwitch = service.state.server.address.endsWith(".twitch.tv");
    }

    if (service.state.bot.pass.length)
    {
        static string decodeIfPrefixedBase64(const string encoded)
        {
            import lu.string : beginsWith, decode64;
            import std.base64 : Base64Exception;

            if (encoded.beginsWith("base64:"))
            {
                try
                {
                    return decode64(encoded[7..$]);
                }
                catch (Base64Exception _)
                {
                    // says "base64:" but can't be decoded
                    // Something's wrong but be conservative about it.
                    return encoded;
                }
            }
            else
            {
                return encoded;
            }
        }

        immutable decoded = decodeIfPrefixedBase64(service.state.bot.pass);

        version(TwitchSupport)
        {
            if (serverIsTwitch)
            {
                import lu.string : beginsWith;
                service.state.bot.pass = decoded.beginsWith("oauth:") ? decoded : ("oauth:" ~ decoded);
            }
        }

        if (!service.state.bot.pass.length) service.state.bot.pass = decoded;
        service.state.updates |= typeof(service.state.updates).bot;

        immediate(service.state, "PASS " ~ service.state.bot.pass, Yes.quiet);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
        {
            version(TwitchSupport)
            {
                if (!serverIsTwitch)
                {
                    // fake it
                    logger.trace("--> PASS hunter2");
                }
            }
            else
            {
                // Ditto
                logger.trace("--> PASS hunter2");
            }
        }
    }

    version(TwitchSupport)
    {
        if (serverIsTwitch)
        {
            import std.uni : toLower;

            // Make sure nickname is lowercase so we can rely on it as account name
            service.state.client.nickname = service.state.client.nickname.toLower;
            service.state.updates |= typeof(service.state.updates).client;
        }
    }

    if (serverWhitelisted)
    {
        // CAP should work, nick will be negotiated after CAP END
    }
    else if (serverBlacklisted && !service.state.settings.force)
    {
        // No CAP, do NICK right away
        negotiateNick(service);
    }
    else
    {
        import kameloso.plugins.common.delayawait : delay;

        // Unsure, so monitor CAP progress
        void capMonitorDg()
        {
            if (service.capabilityNegotiation == Progress.notStarted)
            {
                logger.warning("CAP timeout. Does the server not support capabilities?");
                negotiateNick(service);
            }
        }

        delay(service, &capMonitorDg, service.capLSTimeout);
    }
}


// negotiateNick
/++
    Negotiate nickname and user with the server, during registration.
 +/
void negotiateNick(ConnectService service)
{
    import std.algorithm.searching : endsWith;

    immutable serverIsTwitch = service.state.server.address.endsWith(".twitch.tv");

    if (!serverIsTwitch)
    {
        import kameloso.string : replaceTokens;
        import std.format : format;

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
        enum pattern = "USER %s 8 * :%s";
        immutable message = pattern.format(service.state.client.user,
            service.state.client.realName.replaceTokens(service.state.client));
        immediate(service.state, message, Yes.quiet);
    }

    immediate(service.state, "NICK " ~ service.state.client.nickname,
        serverIsTwitch ? Yes.quiet : No.quiet);
    service.issuedNICK = true;
}


// start
/++
    Registers with the server.

    This initialisation event fires immediately after a successful connect, and
    so instead of waiting for something from the server to trigger our
    registration procedure (notably [dialect.defs.IRCEvent.Type.NOTICE]s
    about our `IDENT` and hostname), we preemptively register.

    It seems to work.
 +/
void start(ConnectService service)
{
    register(service);
}


import kameloso.thread : BusMessage, Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.BusMessage|BusMessage] with the "`connect`" header,
    and calls functions based on the payload message.

    This is used to let other plugins trigger re-authentication with services.

    Params:
        service = The current [ConnectService].
        header = String header describing the passed content payload.
        content = Message content.
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


mixin PluginRegistration!(ConnectService, -30.priority);

public:


// ConnectService
/++
    The Connect service is a collection of functions and state needed to connect
    and stay connected to an IRC server, as well as authenticate with services.

    This is mostly a matter of sending `USER` and `NICK` during registration,
    but also incorporates logic to authenticate with services, and capability
    negotiations.
 +/
final class ConnectService : IRCPlugin
{
private:
    import core.time : seconds;

    /// All Connect service settings gathered.
    ConnectSettings connectSettings;

    /++
        How many seconds we should wait before we tire of waiting for authentication
        responses and just start joining channels.
     +/
    static immutable authenticationGracePeriod = 15.seconds;

    /++
        How many seconds to wait for a response to the request for the list of
        capabilities the server has. After these many seconds, it will just
        normally negotiate nickname and log in.
     +/
    static immutable capLSTimeout = 15.seconds;

    /++
        How often to attempt to regain nickname, in seconds, if there was a collision
        and we had to rename ourselves during registration.
     +/
    static immutable nickRegainPeriodicity = 600.seconds;

    /++
        After how much time we should check whether or not we managed to join all channels.
     +/
    static immutable channelCheckDelay = 15.seconds;

    /// At what step we're currently at with regards to authentication.
    Progress authentication;

    /// At what step we're currently at with regards to SASL EXTERNAL authentication.
    Progress saslExternal;

    /// At what step we're currently at with regards to registration.
    Progress registration;

    /// At what step we're currently at with regards to capabilities.
    Progress capabilityNegotiation;

    /// Whether or not we have issued a NICK command during registration.
    bool issuedNICK;

    /++
        Temporary: the nickname that we had to rename to, to successfully
        register on the server.

        This is to avoid modifying [dialect.defs.IRCClient.nickname|IRCClient.nickname]
        before the nickname is actually changed, yet still carry information about the
        incremental rename throughout calls of [onNickInUse].
     +/
    string renameDuringRegistration;

    /// Whether or not the bot has joined its channels at least once.
    bool joinedChannels;

    version(TwitchSupport)
    {
        /++
            Which channels we are actually in. In most cases this will be the union
            of our home and our guest channels, except when it isn't.
         +/
        bool[string] currentActualChannels;
    }

    /// Whether or not the server seems to be supporting WHOIS queries.
    bool serverSupportsWHOIS = true;

    /// Number of capabilities requested but still not awarded.
    uint requestedCapabilitiesRemaining;

    mixin IRCPluginImpl;
}

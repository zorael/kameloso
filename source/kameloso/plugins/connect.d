module kameloso.plugins.connect;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common : ThreadMessage, logger;

import std.concurrency : prioritySend, send;
import std.format : format;

import std.stdio;

private:


// ConnectSettings
/++
 +  Connection settings, gathered in a struct.
 +
 +  ------------
 +  struct ConnectSetting
 +  {
 +      bool sasl = true;
 +      bool joinOnInvite = false;
 +      bool exitOnSASLFailure = false;
 +      string[] sendAfterConnect;
 +  }
 +  ------------
 +/
struct ConnectSettings
{
    import kameloso.common : Separator;

    /// Flag to use SASL authrentication
    bool sasl = true;

    /// Flag to join channels upon being invited to them
    bool joinOnInvite = false;

    /// Flag to abort and exit if SASL authentication fails
    bool exitOnSASLFailure = false;

    /// Lines to send after successfully connecting and registering
    @Separator(";")
    string[] sendAfterConnect;
}


/// Shorthand alias to `IRCBot.Status`
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
void onSelfpart(ConnectPlugin plugin, const IRCEvent event)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    with (plugin.state)
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
                logger.error("Tried to remove a channel that wasn't there: ",
                    event.channel);
            }
        }
    }
}


// onSelfjoin
/++
 +  Record a channel in the `bot.channels` array upon successfully joining it.
 +
 +  Separate this from the `WHO` calls in `onEndOfNames` so that this can be
 +  kept `ChannelPolicy.any` and that `ChannelPolicy.homeOnly`.
 +/
@(IRCEvent.Type.SELFJOIN)
@(ChannelPolicy.any)
void onSelfjoin(ConnectPlugin plugin, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    with (plugin.state)
    {
        if (!bot.channels.canFind(event.channel) &&
            !bot.homes.canFind(event.channel))
        {
            // Track new channel in the channels array
            bot.channels ~= event.channel;
            bot.updated = true;
        }
    }
}


// onEndOfNames
/++
 +  Query `WHO` on a channel after its list of names ends, to get the services
 +  login names of everyone in it.
 +
 +  Bugs: If it joins too many (home) channels at once, you will be kicked due
 +        to flooding and possibly tempbanned. Consider disabling if you have a
 +        lot of homes.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(ChannelPolicy.homeOnly)
void onEndOfNames(ConnectPlugin plugin, const IRCEvent event)
{
    with (plugin.state)
    {
        if (bot.server.daemon == IRCServer.Daemon.twitch) return;

        mainThread.send(ThreadMessage.Throttleline(), "WHO " ~ event.channel);
    }
}


// joinChannels
/++
 +  Joins all channels listed as homes *and* channels in the `IRCBot` object.
 +/
void joinChannels(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        if (!bot.homes.length && !bot.channels.length)
        {
            logger.error("No channels, no purpose...");
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


// onToConnectType
/++
 +  Responds to `ERR_BADPING` events by sending the text (supplied as content in
 +  the `IRCEvent`) to the server.
 +/
@(IRCEvent.Type.ERR_BADPING)
void onToConnectType(ConnectPlugin plugin, const IRCEvent event)
{
    if (plugin.serverPinged) return;

    plugin.state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


// onPing
/++
 +  Pongs the server upon `PING`.
 +
 +  We make sure to ping with the sender as target, and not the neccessarily
 +  the server as saved in the IRCServer struct. For example, `ERR_BADPING`
 +  generally wants you to ping a random number or string.
 +/
@(IRCEvent.Type.PING)
void onPing(ConnectPlugin plugin, const IRCEvent event)
{
    plugin.serverPinged = true;
    immutable target = (event.content.length) ?
        event.content : event.sender.address;

    with (plugin.state)
    {
        mainThread.prioritySend(ThreadMessage.Pong(), target);

        if (bot.authStatus == Status.started)
        {
            logger.log("Auth timed out. Joining channels ...");
            bot.authStatus = Status.finished;
            bot.updated = true;
            plugin.joinChannels();
        }
    }
}


// tryAuth
/++
 +  Try to authenticate with services.
 +
 +  The command to send vary greatly between server daemons (and networks), so
 +  use some heuristics and try the best guess.
 +/
void tryAuth(ConnectPlugin plugin)
{
    string service = "NickServ";
    string verb = "IDENTIFY";

    with (plugin.state)
    {
        // Specialcase networks
        switch (bot.server.network)
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

        bot.authStatus = Status.started;
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

                bot.authStatus = Status.finished;
                bot.updated = true;
                plugin.joinChannels();
                return;
            }

            mainThread.prioritySend(ThreadMessage.Quietline(),
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

            mainThread.prioritySend(ThreadMessage.Quietline(),
                "PRIVMSG %s :%s %s %s"
                .format(service, verb, login, bot.authPassword));
            logger.trace("--> PRIVMSG %s :%s %s hunter2"
                .format(service, verb, login));
            break;

        case twitch:
            // No registration available
            bot.authStatus = Status.finished;
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
 +  such services if applicable.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        if (bot.authPassword.length && (bot.authStatus == Status.notStarted))
        {
            plugin.tryAuth();
        }

        if ((bot.authStatus == Status.finished) ||
            (bot.server.daemon == IRCServer.Daemon.twitch))
        {
            // tryAuth finished early with an unsuccessful login, else
            // `bot.authStatus` would be set much later.
            // Twitch servers can't auth so join immediately
            logger.log("Joining channels ...");
            plugin.joinChannels();
        }

        // Run commands defined in the settings
        foreach (immutable line; plugin.connectSettings.sendAfterConnect)
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
void onAuthEnd(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        bot.authStatus = Status.finished;
        bot.updated = true;

        // This can be before registration ends in case of SASL
        // return if still registering
        if (bot.registerStatus == Status.started) return;

        logger.log("Joining channels ...");
        plugin.joinChannels();
    }
}


// onNickInUse
/++
 +  Appends a single character to the end of the bot's nickname and flags the
 +  bot as updated, so as to propagate the change to all other plugins.
 +/
@(IRCEvent.Type.ERR_NICKNAMEINUSE)
void onNickInUse(ConnectPlugin plugin)
{
    import kameloso.constants : altNickSign;

    with (plugin.state)
    {
        bot.nickname ~= altNickSign;
        bot.updated = true;

        mainThread.send(ThreadMessage.Sendline(),
            "NICK %s".format(bot.nickname));
    }
}


// onInvite
/++
 +  Upon being invited to a channel, join it if the settings say we should.
 +/
@(IRCEvent.Type.INVITE)
@(ChannelPolicy.any)
void onInvite(ConnectPlugin plugin, const IRCEvent event)
{
    if (!plugin.connectSettings.joinOnInvite)
    {
        logger.log("Invited, but joinOnInvite is false so not joining");
        return;
    }

    plugin.state.mainThread.send(ThreadMessage.Sendline(),
        "JOIN :" ~ event.channel);
}


// onRegistrationEvent
/++
 +  Handle `CAP` exchange.
 +
 +  This is a neccessary step to register with some IRC server; the capabilities
 +  have to be requested (`CAP LS`), and the negotiations need to be ended
 +  (`CAP END`).
 +/
@(IRCEvent.Type.CAP)
void onRegistrationEvent(ConnectPlugin plugin, const IRCEvent event)
{
    /// http://ircv3.net/irc
    /// https://blog.irccloud.com/ircv3

    with (plugin.state)
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
                if (!plugin.connectSettings.sasl || !bot.authPassword.length) continue;
                mainThread.send(ThreadMessage.Quietline(), "CAP REQ :sasl");
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
                mainThread.send(ThreadMessage.Quietline(), "CAP REQ :" ~ cap);
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
            mainThread.send(ThreadMessage.Quietline(), "CAP END");
        }
        break;

    case "ACK":
        switch (event.content)
        {
        case "sasl":
            mainThread.send(ThreadMessage.Sendline(), "AUTHENTICATE PLAIN");
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
 +  Constructs a SASL authentication token from the bot's `authLogin` and
 +  `authPassword`, then sends it to the server, during registration.
 +
 +  A SASL authentication token is composed like so:

 +     `base64(nickname \0 authLogin \0 authPassword`)

 +  ...where `nickname` is the bot's wanted nickname, `authLogin` is the
 +  services login name and `authPassword` is the services login password.
 +/
@(IRCEvent.Type.SASL_AUTHENTICATE)
void onSASLAuthenticate(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        import std.base64 : Base64;

        bot.authStatus = Status.started;
        bot.updated = true;

        immutable authLogin = bot.authLogin.length ? bot.authLogin : bot.origNickname;
        immutable authToken = "%s%c%s%c%s"
            .format(bot.origNickname, '\0', authLogin, '\0', bot.authPassword);
        immutable encoded = Base64.encode(cast(ubyte[])authToken);

        mainThread.send(ThreadMessage.Quietline(), "AUTHENTICATE " ~ encoded);
        logger.trace("--> AUTHENTICATE hunter2");
    }
}


// onSASLSuccess
/++
 +  On SASL authentication success, call a `CAP END` to finish the `CAP`
 +  negotiations.
 +
 +  Flag the bot as having finished registering and authing, allowing the main
 +  loop to pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.RPL_SASLSUCCESS)
void onSASLSuccess(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        bot.authStatus = Status.finished;
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

        mainThread.send(ThreadMessage.Quietline(), "CAP END");
    }
}


// onSASLFailure
/++
 +  On SASL authentication failure, call a `CAP END` to finish the `CAP`
 +  negotiations and finish registration.
 +
 +  Flag the bot as haing finished registering, allowing the main loop to
 +  pick it up and propagate it to all other plugins.
 +/
@(IRCEvent.Type.ERR_SASLFAIL)
void onSASLFailure(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        if (plugin.connectSettings.exitOnSASLFailure)
        {
            mainThread.send(ThreadMessage.Quit(), "SASL Negotiation Failure");
            return;
        }

        // Auth failed and will fail even if we try NickServ, so flag as
        // finished auth and invoke `CAP END`
        bot.authStatus = Status.finished;
        bot.updated = true;

        // See `onSASLSuccess` for info on `CAP END`
        mainThread.send(ThreadMessage.Quietline(), "CAP END");
    }
}


// onWelcome
/++
 +  On RPL_WELCOME (001) the registration will be completed, so mark it as such.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        bot.registerStatus = IRCBot.Status.finished;
        bot.updated = true;
    }
}


// register
/++
 +  Register with/log onto an IRC server.
 +/
void register(ConnectPlugin plugin)
{
    with (plugin.state)
    {
        bot.registerStatus = Status.started;
        bot.updated = true;

        mainThread.send(ThreadMessage.Quietline(), "CAP LS 302");

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
                logger.error("You *need* a password to join this server");
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
 +  registration procedure (notably `NOTICE`s about our `IDENT` and hostname),
 +  we preemptively register.
 +
 +  It seems to work.
 +/
void start(IRCPlugin plugin)
{
    register(cast(ConnectPlugin)plugin);
}


mixin BasicEventHandlers;

public:


// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server.
 +
 +  This is mostly a matter of sending `USER` and `NICK` during registration,
 +  but also incorporates logic to authenticate with services.
 +/
final class ConnectPlugin : IRCPlugin
{
    /// All Connect plugin settings gathered
    @Settings ConnectSettings connectSettings;

    /// Flag whether the server has sent at least one `PING`
    bool serverPinged;

    mixin IRCPluginImpl;
}

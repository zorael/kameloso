/++
    The Connect service handles logging onto IRC servers after having connected,
    as well as managing authentication to services. It also manages responding
    to [dialect.defs.IRCEvent.Type.PING|PING] requests, and capability negotiations.

    The actual connection logic is in the [kameloso.net] module.

    See_Also:
        [kameloso.net],
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.services.connect;

version(WithConnectService):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.common : logger;
import kameloso.messaging;
import kameloso.thread : Sendable;
import dialect.defs;
import core.thread.fiber : Fiber;


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

    /++
        Whether or not to join channels upon being invited to them.
     +/
    bool joinOnInvite = false;

    /++
        Whether to use SASL authentication or not.
     +/
    @Unserialisable bool sasl = true;

    /++
        Whether or not to abort and exit if SASL authentication fails.
     +/
    bool exitOnSASLFailure = false;

    /++
        In what way channels should be rejoined upon reconnecting, or upon re-execution.
     +/
    ChannelRejoinBehaviour rejoinBehaviour = ChannelRejoinBehaviour.merge;

    /++
        Lines to send after successfully connecting and registering.
     +/
    //@Separator(";;")
    @CannotContainComments string sendAfterConnect;

    /++
        How much time to allow between incoming PINGs before suspecting something is wrong.
     +/
    @Unserialisable int maxPingPeriodAllowed = 660;
}


/++
    Manners in which ways channels should be rejoined upon reconnecting,
    or upon re-execution.

    Its name is intentionally kept short to improve the visuals of calling the
    program with `--settings`.
 +/
enum Rejoin
{
    /++
        Home channels and guest channels are merged with channels carried from
        previous connections/executions, and all of them are joined.
     +/
    merge,

    /++
        Home channels are merged with channels carried from previous
        connections/executions, and all of them are joined. Guest channels are excluded.
     +/
    mergeHomes,

    /++
        Home channels and guest channels are joined, but channels carried from
        previous connections/executions are ignored.
     +/
    original,

    /++
        Channels carried from previous connections/executions are joined, but
        home and guest channels as defined in the configuration file are ignored.
     +/
    carryPrevious,
}


/++
    More descriptive name for [Rejoin].
 +/
alias ChannelRejoinBehaviour = Rejoin;


/++
    Progress of a process.
 +/
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
void onSelfpart(ConnectService service, const IRCEvent event)
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
    Joins all channels that should be joined, as per the [ConnectSettings.rejoinBehaviour]
    setting.

    * If [Rejoin.merge|ChannelRejoinBehaviour.merge], it will join all home channels
      all guest channels *and* any channels carried over from previous connections
      (or executions).
    * If [Rejoin.mergeHomes|ChannelRejoinBehaviour.mergeHomes|, it will join all
      channels carried over from previous connections *and* all home channels as
      defined in the configuration file, but ignore guest channels.
    * If [Rejoin.original|ChannelRejoinBehaviour.original], it will join all home
      channels and all guest channels, but ignore any carried channels.
    * If [Rejoin.carryPrevious|ChannelRejoinBehaviour.carryPrevious], it will join
      all carried channels and ignore home and guest channels.

    Params:
        service = The current [ConnectService].
 +/
void joinChannels(ConnectService service)
{
    import lu.string : plurality;

    scope(exit) service.transient.joinedChannels = true;

    void printDefeat()
    {
        logger.warning("No channels, no purpose...");
    }

    /+
        Filters out empty strings and the empty array marker, sorts the array
        and removes duplicates.
     +/
    static auto filterSortUniq(string[] array_)
    {
        import kameloso.constants : MagicStrings;
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        alias pred = (string channelName) =>
            (channelName != "-") &&
            (channelName != MagicStrings.emptyArrayMarker);

        return array_
            .filter!pred
            .array
            .sort
            .uniq
            .array;
    }

    /+
        Joins the channels in the (keys of the) passed associative array.
     +/
    void joinArray(const string[] channelList)
    {
        import kameloso.messaging : Message;
        import std.array : join;
        static import kameloso.messaging;

        if (!channelList.length) return;

        enum properties = Message.Property.quiet;
        kameloso.messaging.join(
            service.state,
            channelList.join(','),
            string.init,
            properties);
    }

    /+
        Removes entries from the first ref array that are also in the second const array.
     +/
    void removeArrayEntriesAlsoIn(
        ref string[] first,
        const string[] second)
    {
        foreach (immutable channelName; second)
        {
            import std.algorithm.searching : countUntil;

            immutable firstPos = first.countUntil(channelName);

            if (firstPos != -1)
            {
                import std.algorithm.mutation : SwapStrategy, remove;
                first = first.remove!(SwapStrategy.unstable)(firstPos);
            }
        }
    }

    const homeArray = filterSortUniq(service.state.bot.homeChannels);
    auto guestArray = filterSortUniq(service.state.bot.guestChannels);
    auto overrideArray = filterSortUniq(service.state.bot.channelOverride);

    removeArrayEntriesAlsoIn(guestArray, homeArray);
    removeArrayEntriesAlsoIn(overrideArray, homeArray);
    removeArrayEntriesAlsoIn(overrideArray, guestArray);

    version(TwitchSupport)
    {
        import std.range : chain;
        /+
            Collect all channels we're supposed to join into a single array,
            to be able to check later (down below) if we actually joined them all.
         +/
        string[] allChannels;
    }

    /+
        Prints a message about joining channels, and how many of them were
        carried over from a previous connection.
     +/
    void printJoiningMessage(
        const size_t numChans,
        const size_t carried)
    {
        if (carried > 0)
        {
            enum pattern = "Joining <i>%d</> %s (of which <i>%d</> %s " ~
                "carried over from the previous connection)...";
            logger.logf(
                pattern,
                numChans,
                numChans.plurality("channel", "channels"),
                overrideArray.length,
                overrideArray.length.plurality("was", "were"));
        }
        else
        {
            enum pattern = "Joining <i>%d</> %s...";
            logger.logf(
                pattern,
                numChans,
                numChans.plurality("channel", "channels"));
        }
    }

    with (ChannelRejoinBehaviour)
    final switch (service.connectSettings.rejoinBehaviour)
    {
    case merge:
        /+
            Merge home, guest and override channels into a single list, and
            join them all.
         +/
        immutable numChans = (homeArray.length + guestArray.length + overrideArray.length);
        if (!numChans) return printDefeat();

        printJoiningMessage(numChans, overrideArray.length);
        joinArray(homeArray);
        joinArray(guestArray);
        joinArray(overrideArray);

        version(TwitchSupport) allChannels = homeArray ~ guestArray ~ overrideArray;
        break;

    case mergeHomes:
        /+
            Merge home and override channels into a single list, and join them
            all. (Skip the guest channel list.)
         +/
        immutable numChans = (homeArray.length + overrideArray.length);
        if (!numChans) return printDefeat();

        printJoiningMessage(numChans, overrideArray.length);
        joinArray(homeArray);
        //joinArray(guestArray);
        joinArray(overrideArray);

        version(TwitchSupport) allChannels = homeArray ~ /*guestArray ~*/ overrideArray;
        break;

    case original:
        /+
            Join the home and guest channels, and ignore the override list.
         +/
        immutable numChans = (homeArray.length + guestArray.length);
        if (!numChans) return printDefeat();

        printJoiningMessage(numChans, overrideArray.length);
        joinArray(homeArray);
        joinArray(guestArray);
        //joinArray(overrideArray);

        version(TwitchSupport) allChannels = homeArray ~ guestArray; // ~ overrideArray;
        break;

    case carryPrevious:
        /+
            Join the override list, and ignore the home and guest channels.
         +/
        if (!overrideArray.length)
        {
            enum emptyMessage = "An empty channel set was passed from a previous connection.";
            enum changeMessage = "Consider changing the <l>connect</>.<l>rejoinBehaviour</> configuration setting.";
            logger.warning(emptyMessage);
            logger.warning(changeMessage);
            return printDefeat();
        }

        printJoiningMessage(overrideArray.length, overrideArray.length);
        //joinArray(homeArray);
        //joinArray(guestArray);
        joinArray(overrideArray);

        version(TwitchSupport) allChannels = /*homeArray ~ guestArray ~*/ overrideArray;
        break;
    }

    version(TwitchSupport)
    {
        import kameloso.plugins.common.scheduling : delay;

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
            string[] missingChannels;  // mutable

            foreach (immutable channelName; allChannels)
            {
                if (channelName !in service.currentActualChannels)
                {
                    // We failed to join a channel for some reason. No such user?
                    missingChannels ~= channelName;
                }
            }

            if (missingChannels.length)
            {
                enum pattern = "Timed out waiting to join channels: %-(<l>%s</>, %)";
                logger.warningf(pattern, missingChannels);
            }
        }

        delay(service, &delayedChannelCheckDg, ConnectService.Timings.channelCheckDelay);
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
void onSelfjoin(ConnectService service, const IRCEvent event)
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
void onToConnectType(ConnectService service, const IRCEvent event)
{
    enum properties = Message.Property.quiet;
    immediate(service.state, event.content, properties);
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
void onPing(ConnectService service, const IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    immutable target = event.content.length ? event.content : event.sender.address;
    service.state.priorityMessages ~= ThreadMessage.pong(target);
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
    import kameloso.plugins.common.scheduling : delay;
    import lu.string : decode64;
    import std.algorithm.searching : startsWith;

    string serviceNick = "NickServ";  // mutable, default value
    string verb = "IDENTIFY";  // ditto
    immutable password = service.state.bot.password.startsWith("base64:") ?
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
        service.transient.progress.authentication = Progress.finished;
        return;

    case "QuakeNet":
        serviceNick = "Q@CServe.quakenet.org";
        verb = "AUTH";
        break;

    default:
        break;
    }

    service.transient.progress.authentication = Progress.inProgress;

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
            logger.warningf(
                pattern,
                service.state.client.nickname,
                service.state.client.origNickname);

            service.transient.progress.authentication = Progress.finished;
            return;
        }

        enum properties = Message.Property.quiet;
        immutable message = text(verb, ' ', password);
        query(service.state, serviceNick, message, properties);

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

        enum properties = Message.Property.quiet;
        immutable message = text(verb, ' ', account, ' ', password);
        query(service.state, serviceNick, message, properties);

        if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
        {
            enum pattern = "--> PRIVMSG %s :%s %s hunter2";
            logger.tracef(pattern, serviceNick, verb, account);
        }
        break;

    case rusnet:
        /+
            This fails to compile on <2.097 compilers.
            "Error: switch skips declaration of variable kameloso.plugins.services.connect.tryAuth.message"
            Worrisome, but work around the issue for now by adding braces.
         +/
        {
            // Doesn't want a PRIVMSG
            enum properties = Message.Property.quiet;
            immutable message = "NICKSERV IDENTIFY " ~ password;
            raw(service.state, message, properties);

            if (!service.state.settings.hideOutgoing && !service.state.settings.trace)
            {
                logger.trace("--> NICKSERV IDENTIFY hunter2");
            }
        }
        break;

    version(TwitchSupport)
    {
        case twitch:
            // No registration available
            service.transient.progress.authentication = Progress.finished;
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

    void delayedJoinDg()
    {
        // If we're still authenticating after n seconds, abort and join channels.

        if (service.transient.progress.authentication == Progress.inProgress)
        {
            logger.warning("Authentication timed out.");
            service.transient.progress.authentication = Progress.finished;
        }

        if (!service.transient.joinedChannels)
        {
            joinChannels(service);
        }
    }

    delay(service, &delayedJoinDg, ConnectService.Timings.authenticationGracePeriod);
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
void onAuthEnd(ConnectService service, const IRCEvent event)
{
    service.transient.progress.authentication = Progress.finished;

    if (service.transient.progress.registration == Progress.finished)
    {
        if (!service.transient.joinedChannels)
        {
            joinChannels(service);
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
void onTwitchAuthFailure(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : endsWith;

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
        enum properties = Message.Property.priority;
        quit(service.state, event.content, properties);
    }
    else
    {
        switch (event.content)
        {
        case "Improperly formatted auth":
        case "Login authentication failed":
        case "Login unsuccessful":
            logger.error("The bot was not compiled with Twitch support enabled.");
            enum properties = Message.Property.priority;
            enum message = "Missing Twitch support";
            return quit(service.state, message, properties);

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
    import std.conv : to;
    import std.random : uniform;

    if (service.transient.progress.registration == Progress.inProgress)
    {
        if (!service.transient.renameDuringRegistration.length)
        {
            import kameloso.constants : KamelosoDefaults;
            service.transient.renameDuringRegistration = service.state.client.nickname ~
                KamelosoDefaults.altNickSeparator;
        }

        service.transient.renameDuringRegistration ~= uniform(0, 10).to!string;
        immutable message = "NICK " ~ service.transient.renameDuringRegistration;
        immediate(service.state, message);
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
    if (service.transient.progress.registration == Progress.inProgress)
    {
        // Mid-registration and invalid nickname; abort

        if (service.transient.renameDuringRegistration.length)
        {
            logger.error("Your nickname was taken and an alternative nickname " ~
                "could not be successfully generated.");
        }
        else
        {
            logger.error("Your nickname is invalid: it is reserved, too long, or contains invalid characters.");
        }

        enum message = "Invalid nickname";
        quit(service.state, message);
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
    enum message = "Banned";
    quit(service.state, message);
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
    if (service.transient.progress.registration != Progress.inProgress)
    {
        // Unsure if this ever happens, but don't quit if we're actually registered
        return;
    }

    logger.error("Pass mismatch!");
    enum message = "Incorrect pass";
    quit(service.state, message);
}


// onInvite
/++
    Upon being invited to a channel, joins it if the settings say we should.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.INVITE)
    .channelPolicy(ChannelPolicy.any)
)
void onInvite(ConnectService service, const IRCEvent event)
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
void onCapabilityNegotiation(ConnectService service, const IRCEvent event)
{
    // http://ircv3.net/irc
    // https://blog.irccloud.com/ircv3

    if (service.transient.progress.registration == Progress.finished)
    {
        // It's possible to call CAP LS after registration, and that would start
        // this whole process anew. So stop if we have registered.
        return;
    }

    service.transient.progress.capabilityNegotiation = Progress.inProgress;

    switch (event.content)
    {
    case "LS":
        import std.algorithm.iteration : splitter;
        import std.array : Appender;

        Appender!(string[]) capsToReq;
        capsToReq.reserve(8);  // guesstimate

        foreach (immutable rawCap; event.aux[])
        {
            import lu.string : advancePast;
            import std.algorithm.searching : startsWith;
            import std.string : indexOf;

            if (!rawCap.length) continue;

            string slice = rawCap;  // mutable
            immutable cap = slice.advancePast('=', inherit: true);
            immutable sub = slice;

            switch (cap)
            {
            case "sasl":
                // Error: `switch` skips declaration of variable acceptsExternal
                // https://issues.dlang.org/show_bug.cgi?id=21427
                // feep[work] | the quick workaround is to wrap the switch body in a {}
                {
                    immutable acceptsExternal = !sub.length || (sub.indexOf("EXTERNAL") != -1);
                    immutable acceptsPlain = !sub.length || (sub.indexOf("PLAIN") != -1);
                    immutable hasKey =
                        (service.state.connSettings.privateKeyFile.length ||
                        service.state.connSettings.certFile.length);

                    if (service.state.connSettings.ssl && acceptsExternal && hasKey)
                    {
                        // Proceed
                    }
                    else if (
                        service.connectSettings.sasl &&
                        acceptsPlain &&
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
                ++service.transient.requestedCapabilitiesRemaining;
                break;

            default:
                //logger.warning("Unhandled capability: ", cap);
                break;
            }
        }

        if (capsToReq[].length)
        {
            import std.algorithm.iteration : joiner;
            import std.conv : text;

            enum properties = Message.Property.quiet;
            immutable message = text("CAP REQ :", capsToReq[].joiner(" "));
            immediate(service.state, message, properties);
        }
        break;

    case "ACK":
        import std.algorithm.iteration : splitter;

        foreach (cap; event.aux[])
        {
            if (!cap.length) continue;

            switch (cap)
            {
            case "sasl":
                enum properties = Message.Property.quiet;
                immutable hasKey = (service.state.connSettings.privateKeyFile.length ||
                    service.state.connSettings.certFile.length);
                immutable mechanism = (service.state.connSettings.ssl && hasKey) ?
                    "AUTHENTICATE EXTERNAL" :
                    "AUTHENTICATE PLAIN";
                immediate(service.state, mechanism, properties);
                break;

            default:
                //logger.warning("Unhandled capability ACK: ", cap);
                --service.transient.requestedCapabilitiesRemaining;
                break;
            }
        }
        break;

    case "NAK":
        import std.algorithm.iteration : splitter;

        foreach (cap; event.aux[])
        {
            if (!cap.length) continue;

            switch (cap)
            {
            case "sasl":
                if (service.connectSettings.exitOnSASLFailure)
                {
                    enum message = "SASL Negotiation Failure";
                    return quit(service.state, message);
                }
                break;

            default:
                //logger.warning("Unhandled capability NAK: ", cap);
                --service.transient.requestedCapabilitiesRemaining;
                break;
            }
        }
        break;

    default:
        //logger.warning("Unhandled capability type: ", event.content);
        break;
    }

    if (!service.transient.requestedCapabilitiesRemaining &&
        (service.transient.progress.capabilityNegotiation == Progress.inProgress))
    {
        service.transient.progress.capabilityNegotiation = Progress.finished;
        enum properties = Message.Property.quiet;
        enum message = "CAP END";
        immediate(service.state, message, properties);

        if (!service.transient.issuedNICK)
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
    service.transient.progress.authentication = Progress.inProgress;

    immutable hasKey = (service.state.connSettings.privateKeyFile.length ||
        service.state.connSettings.certFile.length);

    if (service.state.connSettings.ssl && hasKey &&
        (service.transient.progress.saslExternal == Progress.notStarted))
    {
        service.transient.progress.saslExternal = Progress.inProgress;
        enum message = "AUTHENTICATE +";
        return immediate(service.state, message);
    }

    immutable plainSuccess = trySASLPlain(service);

    if (!plainSuccess)
    {
        onSASLFailure(service);
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
    import lu.string : decode64, encode64;
    import std.algorithm.searching : startsWith;
    import std.base64 : Base64Exception;
    import std.conv : text;

    try
    {
        immutable account_ = service.state.bot.account.length ?
            service.state.bot.account :
            service.state.client.origNickname;

        immutable password_ = service.state.bot.password.startsWith("base64:") ?
            decode64(service.state.bot.password[7..$]) :
            service.state.bot.password;

        immutable authToken = text(account_, '\0', account_, '\0', password_);
        immutable encoded = encode64(authToken);
        immutable message = "AUTHENTICATE " ~ encoded;

        enum properties = Message.Property.quiet;
        immediate(service.state, message, properties);

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
    service.transient.progress.authentication = Progress.finished;

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

    if (!--service.transient.requestedCapabilitiesRemaining &&
        (service.transient.progress.capabilityNegotiation == Progress.inProgress))
    {
        service.transient.progress.capabilityNegotiation = Progress.finished;
        enum properties = Message.Property.quiet;
        enum message = "CAP END";
        immediate(service.state, message, properties);

        if ((service.transient.progress.registration == Progress.inProgress) &&
            !service.transient.issuedNICK)
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
    if ((service.transient.progress.saslExternal == Progress.inProgress) &&
        service.state.bot.password.length)
    {
        // Fall back to PLAIN
        service.transient.progress.saslExternal = Progress.finished;
        enum properties = Message.Property.quiet;
        enum message = "AUTHENTICATE PLAIN";
        return immediate(service.state, message, properties);
    }

    if (service.connectSettings.exitOnSASLFailure)
    {
        enum message = "SASL Negotiation Failure";
        return quit(service.state, message);
    }

    // Auth failed and will fail even if we try NickServ, so flag as
    // finished auth and invoke `CAP END`
    service.transient.progress.authentication = Progress.finished;

    if (!--service.transient.requestedCapabilitiesRemaining &&
        (service.transient.progress.capabilityNegotiation == Progress.inProgress))
    {
        service.transient.progress.capabilityNegotiation = Progress.finished;
        enum properties = Message.Property.quiet;
        enum message = "CAP END";
        immediate(service.state, message, properties);

        if ((service.transient.progress.registration == Progress.inProgress) &&
            !service.transient.issuedNICK)
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
    .fiber(true)
)
void onWelcome(ConnectService service)
{
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : endsWith;

    service.transient.progress.registration = Progress.finished;
    service.transient.renameDuringRegistration = string.init;

    version(WithPingMonitor) startPingMonitor(service);

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
        import kameloso.plugins.common.scheduling : await, unawait;

        if (service.state.settings.preferHostmasks &&
            !service.state.settings.force)
        {
            // We already infer account by username on Twitch;
            // hostmasks mode makes no sense there. So disable it.
            service.state.settings.preferHostmasks = false;
            service.state.updates |= typeof(service.state.updates).settings;
        }

        static immutable IRCEvent.Type[2] endOfMOTDEventTypes =
        [
            IRCEvent.Type.RPL_ENDOFMOTD,
            IRCEvent.Type.ERR_NOMOTD,
        ];

        scope(exit) unawait(service, endOfMOTDEventTypes[]);
        await(service, endOfMOTDEventTypes[], yield: true);

        version(TwitchSupport)
        {
            import std.algorithm.searching : startsWith;

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

            if (service.state.settings.prefix.startsWith(".") ||
                service.state.settings.prefix.startsWith("/"))
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
                enum message = "This bot was not built with Twitch support enabled. " ~
                    "Expect errors and general uselessness.";
                logger.warning(message);
            }
        }
    }
    else /*if (!service.state.server.address.endsWith(".twitch.tv"))*/
    {
        import kameloso.plugins.common.scheduling : delay;
        import kameloso.constants : BufferSize;
        import core.thread.fiber : Fiber;

        /+
            If the server doesn't issue an end-of-MOTD event, the bot will softlock
            and channels will never be joined. So as a backup, call onEndOfMOTD
            after a timeout, forcing the bot to continue. Internally onEndOfMOTD
            will return early if it has already been invoked once.
         +/
        void endOfMOTDDg()
        {
            if (!service.transient.sawEndOfMOTD)
            {
                logger.warning("Server did not issue an end-of-MOTD event; forcing continuation.");
                onEndOfMOTD(service);
            }
        }

        auto endOfMOTDFiber = new Fiber(&endOfMOTDDg, BufferSize.fiberStack);
        delay(service, endOfMOTDFiber, ConnectService.Timings.endOfMOTDTimeout);

        if (service.connectSettings.regainNickname && !service.state.bot.hasGuestNickname &&
            (service.state.client.nickname != service.state.client.origNickname))
        {
            delay(service, ConnectService.Timings.nickRegainPeriodicity, yield: true);

            // Concatenate the verb once
            immutable squelchVerb = "squelch " ~ service.state.client.origNickname;

            while (service.state.client.nickname != service.state.client.origNickname)
            {
                import kameloso.messaging : raw;

                version(WithPrinterPlugin)
                {
                    import kameloso.thread : ThreadMessage, boxed;
                    auto threadMessage = ThreadMessage.busMessage("printer", boxed(squelchVerb));
                    service.state.messages ~= threadMessage;

                }

                enum properties = (Message.Property.quiet | Message.Property.background);
                immutable message = "NICK " ~ service.state.client.origNickname;
                raw(service.state, message, properties);
                delay(service, ConnectService.Timings.nickRegainPeriodicity, yield: true);
            }

            // All done
        }
    }
}


// onSelfnickSuccessOrFailure
/++
    Resets [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin] squelching upon a
    successful or failed nick change. This so as to be squelching as little as possible.
 +/
version(WithPrinterPlugin)
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFNICK)
    .onEvent(IRCEvent.Type.ERR_NICKNAMEINUSE)
)
void onSelfnickSuccessOrFailure(ConnectService service)
{
    import kameloso.thread : ThreadMessage, boxed;
    auto message = ThreadMessage.busMessage("printer", boxed("unsquelch " ~ service.state.client.origNickname));
    service.state.messages ~= message;

}


// onQuit
/++
    Regains nickname if the holder of the one we wanted during registration quit.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(ConnectService service, const IRCEvent event)
{
    if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
        service.connectSettings.regainNickname &&
        (event.sender.nickname == service.state.client.origNickname))
    {
        // The regain fiber will end itself when it is next triggered
        enum pattern = "Attempting to regain nickname <l>%s</>...";
        logger.infof(pattern, service.state.client.origNickname);
        immutable message = "NICK " ~ service.state.client.origNickname;
        raw(service.state, message);
    }
}


// onEndOfMOTD
/++
    Joins channels and prints some Twitch warnings on end of MOTD.

    Do this then instead of on [dialect.defs.IRCEvent.Type.RPL_WELCOME|RPL_WELCOME]
    for better timing, and to avoid having the message drown in MOTD.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFMOTD)
    .onEvent(IRCEvent.Type.ERR_NOMOTD)
)
void onEndOfMOTD(ConnectService service)
{
    // Make sure this function is only processed once
    if (service.transient.sawEndOfMOTD) return;

    service.transient.sawEndOfMOTD = true;

    // Gather information about ourselves
    if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
        !service.state.client.ident.length)
    {
        enum properties =
            Message.Property.forced |
            Message.Property.quiet |
            Message.Property.priority;
        whois(service.state, service.state.client.nickname, properties);
    }

    version(TwitchSupport)
    {
        if (service.state.server.daemon == IRCServer.Daemon.twitch)
        {
            service.transient.serverSupportsWHOIS = false;
        }
    }

    if (service.state.server.network.length &&
        service.state.bot.password.length &&
        (service.transient.progress.authentication == Progress.notStarted) &&
        (service.state.server.daemon != IRCServer.Daemon.twitch))
    {
        tryAuth(service);
    }
    else if (((service.transient.progress.authentication == Progress.finished) ||
        !service.state.bot.password.length ||
        (service.state.server.daemon == IRCServer.Daemon.twitch)) &&
        !service.transient.joinedChannels)
    {
        // tryAuth finished early with an unsuccessful login, else
        // `service.transient.progress.authentication` would be set much later.
        // Twitch servers can't auth so join immediately
        // but don't do anything if we already joined channels.
        joinChannels(service);
    }
}


// onWHOISUser
/++
    Catch information about ourselves (notably our `IDENT`) from `WHOIS` results.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOISUSER)
)
void onWHOISUser(ConnectService service, const IRCEvent event)
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
void onISUPPORT(ConnectService service, const IRCEvent event)
{
    import std.algorithm.searching : canFind;

    if (event.aux[].canFind("CODEPAGES"))
    {
        enum properties = Message.Property.quiet;
        enum message = "CODEPAGE UTF-8";
        raw(service.state, message, properties);
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
    logger.info("Reconnecting upon server request.");
    service.state.priorityMessages ~= ThreadMessage.reconnect;
}


// onUnknownCommand
/++
    Warns the user if the server does not seem to support WHOIS queries, suggesting
    that they enable hostmasks mode instead.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
)
void onUnknownCommand(ConnectService service, const IRCEvent event)
{
    if (service.transient.serverSupportsWHOIS &&
        !service.state.settings.preferHostmasks &&
        (event.aux[0] == "WHOIS"))
    {
        logger.error("Error: This server does not seem to support user accounts.");
        enum message = "Consider enabling <l>Core</>.<l>preferHostmasks</>.";
        logger.error(message);
        logger.error("As it is, functionality will be greatly limited.");
        service.transient.serverSupportsWHOIS = false;
    }
}


// startPingMonitor
/++
    Starts a looping monitor that sends a [dialect.defs.IRCEvent.Type.PING|PING]
    if we haven't received one from the server for a while. This is to ensure
    that dead connections are properly detected.

    Note: Must be called from within a [core.thread.fiber.Fiber|Fiber].

    Params:
        service = The current [ConnectService].
 +/
void startPingMonitor(ConnectService service)
in (Fiber.getThis(), "Tried to call `startPingMonitor` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : await, delay, unawait, undelay;
    import kameloso.thread : CarryingFiber;
    import core.time : seconds;

    if (service.connectSettings.maxPingPeriodAllowed <= 0) return;

    immutable pingMonitorPeriodicity = service.connectSettings.maxPingPeriodAllowed.seconds;

    static immutable timeToAllowForPingResponse = 30.seconds;
    static immutable briefWait = 1.seconds;
    long lastPongTimestamp;
    uint strikes;

    enum StrikeBreakpoints
    {
        wait = 2,
        ping = 3,
    }

    static immutable IRCEvent.Type[2] pingPongTypes =
    [
        IRCEvent.Type.PING,
        IRCEvent.Type.PONG,
    ];

    scope(exit) unawait(service, pingPongTypes[]);
    scope(exit) undelay(service);
    await(service, pingPongTypes[], yield: false);
    delay(service, pingMonitorPeriodicity, yield: true);

    while (true)
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
        assert(thisFiber, "Incorrectly cast fiber: " ~ typeof(thisFiber).stringof);
        immutable thisEvent = thisFiber.payload;

        with (IRCEvent.Type)
        switch (thisEvent.type)
        {
        case UNSET:
            import std.datetime.systime : Clock;

            // Triggered by timer
            immutable nowInUnix = Clock.currTime.toUnixTime();

            if ((nowInUnix - lastPongTimestamp) >= service.connectSettings.maxPingPeriodAllowed)
            {
                import kameloso.thread : ThreadMessage;

                /+
                    Skip first two strikes; helps when resuming from suspend and similar,
                    then allow for a PING with `timeToAllowForPingResponse` as timeout.
                    Finally, if all else failed, reconnect.
                 +/
                ++strikes;

                if (strikes <= StrikeBreakpoints.wait)
                {
                    if (service.state.settings.trace && (strikes > 1))
                    {
                        logger.warning("Server is suspiciously quiet.");
                    }
                    delay(service, briefWait, yield: true);
                    continue;
                }
                else if (strikes == StrikeBreakpoints.ping)
                {
                    // Timeout. Send a preemptive ping
                    logger.warning("Sending preemptive ping.");
                    service.state.priorityMessages ~= ThreadMessage.ping(service.state.server.resolvedAddress);
                    delay(service, timeToAllowForPingResponse, yield: true);
                    continue;
                }
                else /*if (strikes > StrikeBreakpoints.ping)*/
                {
                    // All failed, reconnect
                    logger.warning("No response from server. Reconnecting.");
                    service.state.priorityMessages ~= ThreadMessage.reconnect;
                    return;
                }
            }
            else
            {
                // Early trigger, either interleaved with a PONG or due to preemptive PING
                // Remove current delay and re-delay at when the next PING check should be
                undelay(service);
                immutable elapsed = (nowInUnix - lastPongTimestamp);
                immutable remaining = (service.connectSettings.maxPingPeriodAllowed - elapsed);
                delay(service, remaining.seconds, yield: true);
            }
            continue;

        case PING:
        case PONG:
            // Triggered by PING *or* PONG response from our preemptive PING
            // Update and remove delay, so we can drop down and re-delay it
            lastPongTimestamp = thisEvent.time;
            strikes = 0;
            undelay(service);
            break;

        default:
            assert(0, "Impossible case hit in pingMonitorDg");
        }

        delay(service, pingMonitorPeriodicity, yield: true);
    }
}


// register
/++
    Registers with/logs onto an IRC server.

    Params:
        service = The current [ConnectService].
 +/
void register(ConnectService service)
{
    import std.algorithm.searching : canFind, endsWith, startsWith;
    import std.uni : toLower;

    service.transient.progress.registration = Progress.inProgress;

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
            .canFind!((a,b) => b.startsWith(a))(serverToLower);
    immutable serverBlacklisted = !serverWhitelisted &&
        capabilityServerBlacklistSuffix
            .canFind!((a,b) => b.endsWith(a))(serverToLower);

    if (!serverBlacklisted || service.state.settings.force)
    {
        enum properties = Message.Property.quiet;
        enum message = "CAP LS 302";
        immediate(service.state, message, properties);
    }

    version(TwitchSupport)
    {
        import std.algorithm.searching : endsWith;
        immutable serverIsTwitch = service.state.server.address.endsWith(".twitch.tv");
    }

    if (service.state.bot.pass.length)
    {
        static string decodeIfPrefixedBase64(const string encoded)
        {
            import lu.string : decode64;
            import std.algorithm.searching : startsWith;
            import std.base64 : Base64Exception;

            if (encoded.startsWith("base64:"))
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
                import std.algorithm.searching : startsWith;
                service.state.bot.pass = decoded.startsWith("oauth:") ? decoded : ("oauth:" ~ decoded);
            }
        }

        if (!service.state.bot.pass.length) service.state.bot.pass = decoded;
        service.state.updates |= typeof(service.state.updates).bot;

        enum properties = Message.Property.quiet;
        immutable message = "PASS " ~ service.state.bot.pass;
        immediate(service.state, message, properties);

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
        import kameloso.plugins.common.scheduling : delay;

        // Unsure, so monitor CAP progress
        void capMonitorDg()
        {
            if (service.transient.progress.capabilityNegotiation == Progress.notStarted)
            {
                logger.warning("CAP timeout. Does the server not support capabilities?");
                negotiateNick(service);
            }
        }

        delay(service, &capMonitorDg, ConnectService.Timings.capLSTimeout);
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
        enum properties = Message.Property.quiet;
        enum pattern = "USER %s 8 * :%s";
        immutable message = pattern.format(
            service.state.client.user,
            service.state.client.realName.replaceTokens(service.state.client));
        immediate(service.state, message, properties);
    }

    immutable properties = serverIsTwitch ?
        Message.Property.quiet :
        Message.Property.none;
    immutable message = "NICK " ~ service.state.client.nickname;
    immediate(service.state, message, properties);
    service.transient.issuedNICK = true;
}


// setup
/++
    Registers with the server.

    This initialisation event fires immediately after a successful connect, and
    so instead of waiting for something from the server to trigger our
    registration procedure (notably [dialect.defs.IRCEvent.Type.NOTICE]s
    about our `IDENT` and hostname), we preemptively register.

    It seems to work.
 +/
void setup(ConnectService service)
{
    register(service);
}


// onBusMessage
/++
    Receives a passed [kameloso.thread.Boxed|Boxed] instance with the "`connect`" header,
    and calls functions based on the payload message.

    This is used to let other plugins trigger re-authentication with services.

    Params:
        service = The current [ConnectService].
        header = String header describing the passed content payload.
        content = Message content.
 +/
void onBusMessage(ConnectService service, const string header, /*shared*/ Sendable content)
{
    import kameloso.thread : Boxed;

    if (header != "connect") return;

    const message = cast(Boxed!string)content;

    if (!message)
    {
        enum pattern = "The <l>%s</> plugin received an invalid bus message: expected type <l>%s";
        logger.errorf(pattern, service.name, typeof(message).stringof);
        return;
    }

    immutable verb = message.payload;

    switch (verb)
    {
    case "auth":
        tryAuth(service);
        break;

    default:
        enum pattern = "[connect] Unimplemented bus message verb: <l>%s";
        logger.errorf(pattern, verb);
        break;
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
    /++
        Transient state variables, aggregated in a struct.
     +/
    static struct TransientState
    {
        /++
            All [Progress]es gathered.
         +/
        static struct Progresses
        {
            /++
                At what step we're currently at with regards to authentication.
             +/
            Progress authentication;

            /++
                At what step we're currently at with regards to SASL EXTERNAL authentication.
             +/
            Progress saslExternal;

            /++
                At what step we're currently at with regards to registration.
             +/
            Progress registration;

            /++
                At what step we're currently at with regards to capabilities.
             +/
            Progress capabilityNegotiation;
        }

        /++
            All [Progress]es gathered.
         +/
        Progresses progress;

        /++
            Whether or not we have issued a NICK command during registration.
         +/
        bool issuedNICK;

        /++
            Temporary: the nickname that we had to rename to, to successfully
            register on the server.

            This is to avoid modifying [dialect.defs.IRCClient.nickname|IRCClient.nickname]
            before the nickname is actually changed, yet still carry information about the
            incremental rename throughout calls of [onNickInUse].
         +/
        string renameDuringRegistration;

        /++
            Whether or not the bot has joined its channels at least once.
         +/
        bool joinedChannels;

        /++
            Whether or not the server seems to be supporting WHOIS queries.
         +/
        bool serverSupportsWHOIS = true;

        /++
            Number of capabilities requested but still not awarded.
         +/
        uint requestedCapabilitiesRemaining;

        /++
            Whether or not we have seen end-of-MOTD events, signifying a
            successful registration and login.
         +/
        bool sawEndOfMOTD;
    }

    /++
        All timings gathered.
     +/
    static struct Timings
    {
        private import core.time : seconds;

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
        static immutable channelCheckDelay = 60.seconds;

        /++
            How long to wait for an end-of-MOTD event before we assume the server
            doesn't support it.
         +/
        static immutable endOfMOTDTimeout = 15.seconds;
    }

    /++
        All Connect service settings gathered.
     +/
    ConnectSettings connectSettings;

    /++
        Transient state of this [ConnectService] instance.
     +/
    TransientState transient;

    version(TwitchSupport)
    {
        /++
            Which channels we are actually in. In most cases this will be the union
            of our home and our guest channels, except when it isn't.
         +/
        bool[string] currentActualChannels;
    }

    mixin IRCPluginImpl;
}

/++
    The Channel Query service queries channels for information about them (in
    terms of topic and modes) as well as their lists of participants. It does this
    shortly after having joined a channel, as a service to all other plugins,
    so they don't each have to independently do it themselves.

    It is qualified as a service, so while it is not technically mandatory, it
    is highly recommended if you plan on mixing in
    [kameloso.plugins.common.awareness.ChannelAwareness|ChannelAwareness] into
    your plugins.

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.services.chanquery;

version(WithChanQueryService):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;
import dialect.defs;


version(OmniscientQueries)
{
    /++
        The [kameloso.plugins.common.ChannelPolicy|ChannelPolicy] to mix in
        awareness with depending on whether version `OmniscientQueries` is set or not.
     +/
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    enum omniscientChannelPolicy = ChannelPolicy.home;
}


// ChannelState
/++
    Different states which tracked channels can be in.

    This is to keep track of which channels have been queried, which are
    currently queued for being queried, etc. It is checked by bitmask, so a
    channel can have several channel states.
 +/
enum ChannelState : ubyte
{
    unset      = 1 << 0,  /// Initial value, invalid state.
    topicKnown = 1 << 1,  /// Topic has been sent once, it is known.
    queued     = 1 << 2,  /// Channel queued to be queried.
    queried    = 1 << 3,  /// Channel has been queried.
}


// startChannelQueries
/++
    Queries channels for information about them and their users.

    Checks an internal list of channels once every [dialect.defs.IRCEvent.Type.PING|PING],
    and if one we inhabit hasn't been queried, queries it.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.PING)
    .fiber(true)
)
void startChannelQueries(ChanQueryService service)
{
    import kameloso.plugins.common.scheduling : await, delay, unawait, undelay;
    import kameloso.thread : CarryingFiber, ThreadMessage, boxed;
    import kameloso.messaging : Message, mode, raw;
    import std.datetime.systime : Clock;
    import std.string : representation;
    import core.thread.fiber : Fiber;
    import core.time : seconds;

    if (service.transient.querying) return;  // Try again next PING

    string[] querylist;
    foreach (immutable channelName, ref state; service.channelStates)
    {
        if (state & (ChannelState.queried | ChannelState.queued))
        {
            // Either already queried or queued to be
            continue;
        }

        state |= ChannelState.queued;
        querylist ~= channelName;
    }

    // Continue anyway if eagerLookups
    if (!querylist.length && !service.state.settings.eagerLookups) return;

    auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
    assert(thisFiber, "Incorrectly cast fiber: `" ~ typeof(thisFiber).stringof ~ '`');
    service.transient.querying = true;  // "Lock"

    scope(exit)
    {
        service.transient.queriedAtLeastOnce = true;
        service.transient.querying = false;  // "Unlock"
    }

    chanloop:
    foreach (immutable i, immutable channelName; querylist)
    {
        if (channelName !in service.channelStates) continue;

        if (i > 0)
        {
            // Delay between runs after first since aMode probes don't delay at end
            delay(service, ChanQueryService.timeBetweenQueries, yield: true);
        }

        version(WithPrinterPlugin)
        {
            immutable squelchMessage = "squelch " ~ channelName;
        }

        /++
            Common code to send a query, await the results and unlist the fiber.
         +/
        void queryAwaitAndUnlist(Types)(const string command, const Types types)
        {
            import std.conv : text;

            scope(exit) unawait(service, types);
            await(service, types, yield: false);

            version(WithPrinterPlugin)
            {
                auto threadMessage = ThreadMessage.busMessage("printer", boxed(squelchMessage));
                service.state.messages ~= threadMessage;
            }

            enum properties = (Message.Property.quiet | Message.Property.background);
            immutable message = text(command, ' ', channelName);
            raw(service.state, message, properties);

            do Fiber.yield();  // Awaiting specified types
            while (thisFiber.payload.channel != channelName);

            delay(service, ChanQueryService.timeBetweenQueries, yield: true);
        }

        /++
            Event types that signal the end of a query response.
         +/
        static immutable IRCEvent.Type[2] topicTypes =
        [
            IRCEvent.Type.RPL_TOPIC,
            IRCEvent.Type.RPL_NOTOPIC,
        ];

        queryAwaitAndUnlist("TOPIC", topicTypes[]);
        if (channelName !in service.channelStates) continue chanloop;
        queryAwaitAndUnlist("WHO", IRCEvent.Type.RPL_ENDOFWHO);
        if (channelName !in service.channelStates) continue chanloop;
        queryAwaitAndUnlist("MODE", IRCEvent.Type.RPL_CHANNELMODEIS);
        if (channelName !in service.channelStates) continue chanloop;

        // MODE generic

        foreach (immutable n, immutable modechar; service.state.server.aModes.representation)
        {
            import std.conv : text;

            if (n > 0)
            {
                // Cannot await by event type; there are too many types.
                delay(service, ChanQueryService.timeBetweenQueries, yield: true);
                if (channelName !in service.channelStates) continue chanloop;
            }

            version(WithPrinterPlugin)
            {
                // It's very common to get ERR_CHANOPRIVSNEEDED when querying
                // channels for specific modes.
                // [chanoprivsneeded] [#d] sinisalo.freenode.net: "You're not a channel operator" (#482)
                // Ask the Printer to squelch those messages too.
                auto threadMessage = ThreadMessage.busMessage("printer", boxed(squelchMessage));
                service.state.messages ~= threadMessage;
            }

            enum properties = (Message.Property.quiet | Message.Property.background);
            immutable modeline = text('+', cast(char)modechar);
            mode(
                service.state,
                channelName,
                modeline,
                string.init,
                properties);
        }

        if (channelName !in service.channelStates) continue chanloop;

        // Overwrite state with [ChannelState.queried];
        // [ChannelState.topicKnown] etc are no longer relevant.
        service.channelStates[channelName] = ChannelState.queried;
    }

    // Stop here if we can't or are not interested in going further
    if (!service.transient.serverSupportsWHOIS || !service.state.settings.eagerLookups) return;

    immutable nowInUnix = Clock.currTime.toUnixTime();
    bool[string] uniqueUsers;

    foreach (immutable channelName, const channel; service.state.channels)
    {
        foreach (immutable nickname; channel.users.byKey)
        {
            import kameloso.constants : Timeout;

            if (nickname == service.state.client.nickname) continue;

            const user = nickname in service.state.users;
            if (!user || !user.account.length || ((nowInUnix - user.updated) > Timeout.whoisRetry))
            {
                // No user, or no account and sufficient amount of time passed since last WHOIS
                uniqueUsers[nickname] = true;
            }
        }
    }

    if (!uniqueUsers.length) return;  // Early exit

    uniqueUsers.rehash();

    /++
        Event types that signal the end of a WHOIS response.
     +/
    static immutable whoisTypes =
    [
        IRCEvent.Type.RPL_ENDOFWHOIS,
        IRCEvent.Type.ERR_UNKNOWNCOMMAND,
    ];

    await(service, whoisTypes, yield: false);

    scope(exit)
    {
        unawait(service, whoisTypes[]);

        version(WithPrinterPlugin)
        {
            auto threadMessage = ThreadMessage.busMessage("printer", boxed("unsquelch"));
            service.state.messages ~= threadMessage;

        }
    }

    long lastQueryResults;
    immutable numSecondsBetween = ChanQueryService.timeBetweenQueries.total!"seconds";

    whoisloop:
    foreach (immutable nickname; uniqueUsers.byKey)
    {
        import kameloso.common : logger;
        import kameloso.messaging : whois;
        import core.time : seconds;

        const user = nickname in service.state.users;
        if (!user || (*user).account.length)
        {
            // User disappeared, or something else WHOISed it already.
            continue;
        }

        // Delay between runs after first since aMode probes don't delay at end
        delay(service, ChanQueryService.timeBetweenQueries, yield: true);
        auto elapsed = (Clock.currTime.toUnixTime() - lastQueryResults);
        auto remaining = (numSecondsBetween - elapsed);

        while (remaining > 0)
        {
            delay(service, remaining.seconds, yield: false);
            elapsed = (Clock.currTime.toUnixTime() - lastQueryResults);
            remaining = (numSecondsBetween - elapsed);
        }

        version(WithPrinterPlugin)
        {
            auto threadMessage = ThreadMessage.busMessage("printer", boxed("squelch " ~ nickname));
            service.state.messages ~= threadMessage;

        }

        enum properties = (Message.Property.quiet | Message.Property.background);
        whois(service.state, nickname, properties);
        undelay(service);  // Remove any delays
        Fiber.yield();  // Await whois types registered above

        enum maxConsecutiveUnknownCommands = 3;
        uint consecutiveUnknownCommands;

        while (true)
        {
            with (IRCEvent.Type)
            switch (thisFiber.payload.type)
            {
            case RPL_ENDOFWHOIS:
                consecutiveUnknownCommands = 0;

                if (thisFiber.payload.target.nickname == nickname)
                {
                    // Saw the expected response
                    lastQueryResults = Clock.currTime.toUnixTime();
                    continue whoisloop;
                }
                else
                {
                    // Something else caused a WHOIS; yield until the right one comes along
                    Fiber.yield();
                    continue;
                }

            case ERR_UNKNOWNCOMMAND:
                if (!thisFiber.payload.aux[0].length)
                {
                    // A different flavour of ERR_UNKNOWNCOMMAND doesn't include the command
                    // We can't say for sure it's erroring on "WHOIS" specifically
                    // If consecutive three errors, assume it's not supported

                    if (++consecutiveUnknownCommands >= maxConsecutiveUnknownCommands)
                    {
                        // Cannot WHOIS on this server (assume)
                        enum message1 = "Error: This server does not seem " ~
                            "to support user accounts?";
                        enum message2 = "Consider enabling <l>core</>.<l>preferHostmasks</>.";
                        logger.error(message1);
                        logger.error(message2);
                        service.transient.serverSupportsWHOIS = false;
                        return;
                    }
                }
                else if (thisFiber.payload.aux[0] == "WHOIS")
                {
                    // Cannot WHOIS on this server
                    // Connect will display an error, so don't do it here again
                    service.transient.serverSupportsWHOIS = false;
                    return;
                }
                else
                {
                    // Something else issued an unknown command; yield and try again
                    consecutiveUnknownCommands = 0;
                    Fiber.yield();
                    continue;
                }
                break;

            default:
                import lu.conv : toString;
                immutable message = "Unexpected event type triggered query fiber: " ~
                    "`IRCEvent.Type." ~ thisFiber.payload.type.toString() ~ '`';
                assert(0, message);
            }
        }

        assert(0, "Escaped `while (true)` loop in query fiber delegate");
    }
}


// onSelfjoin
/++
    Adds a channel we join to the internal [ChanQueryService.channels] list of
    channel states.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFJOIN)
    .channelPolicy(omniscientChannelPolicy)
)
void onSelfjoin(ChanQueryService service, const ref IRCEvent event)
{
    service.channelStates[event.channel] = ChannelState.unset;
}


// onSelfpart
/++
    Removes a channel we part from the internal [ChanQueryService.channels]
    list of channel states.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.SELFPART)
    .onEvent(IRCEvent.Type.SELFKICK)
    .channelPolicy(omniscientChannelPolicy)
)
void onSelfpart(ChanQueryService service, const ref IRCEvent event)
{
    service.channelStates.remove(event.channel);
}


// onTopic
/++
    Registers that we have seen the topic of a channel.

    We do this so we know not to query it later. Mostly cosmetic.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_TOPIC)
    .channelPolicy(omniscientChannelPolicy)
)
void onTopic(ChanQueryService service, const ref IRCEvent event)
{
    service.channelStates[event.channel] |= ChannelState.topicKnown;
}


// onEndOfNames
/++
    After listing names (upon joining a channel), initiate a channel query run
    unless one is already running. Additionally don't do it before it has been
    done at least once, after login.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_ENDOFNAMES)
    .channelPolicy(omniscientChannelPolicy)
    .fiber(true)
)
void onEndOfNames(ChanQueryService service)
{
    if (!service.transient.querying && service.transient.queriedAtLeastOnce)
    {
        startChannelQueries(service);
    }
}


// onMyInfo
/++
    After successful connection, start a delayed channel query on all channels.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_MYINFO)
    .fiber(true)
)
void onMyInfo(ChanQueryService service)
{
    import kameloso.plugins.common.scheduling : delay;
    delay(service, service.timeBeforeInitialQueries, yield: true);
    startChannelQueries(service);
}


// onNoSuchChannel
/++
    If we get an error that a channel doesn't exist, remove it from
    [ChanQueryService.channelStates|channelStates]. This stops it from being
    queried in [startChannelQueries].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_NOSUCHCHANNEL)
)
void onNoSuchChannel(ChanQueryService service, const ref IRCEvent event)
{
    service.channelStates.remove(event.channel);
}


version(OmniscientQueries)
{
    enum channelPolicy = ChannelPolicy.any;
}
else
{
    enum channelPolicy = ChannelPolicy.home;
}


mixin UserAwareness!channelPolicy;
mixin ChannelAwareness!channelPolicy;
mixin PluginRegistration!(ChanQueryService, -10.priority);

public:


// ChanQueryService
/++
    The Channel Query service queries channels for information about them (in
    terms of topic and modes) as well as its list of participants.
 +/
final class ChanQueryService : IRCPlugin
{
private:
    import core.time : seconds;

    /++
        Transient state variables, aggregated in a struct.
     +/
    static struct TransientState
    {
        /++
            Whether or not a channel query fiber is running.
         +/
        bool querying;

        /++
            Whether or not at least one channel query has been made.
         +/
        bool queriedAtLeastOnce;

        /++
            Whether or not the server is known to support WHOIS queries. (Defaults to true.)
         +/
        bool serverSupportsWHOIS = true;
    }

    /++
        Transient state of this [ChanQueryService] instance.
     +/
    TransientState transient;

    /++
        Extra delay between channel mode/user queries. Not delaying may
        cause kicks and disconnects if results are returned quickly.
     +/
    static immutable timeBetweenQueries = 4.seconds;

    /++
        Duration after welcome event before the first round of channel-querying will start.
     +/
    static immutable timeBeforeInitialQueries = 60.seconds;

    /++
        Short associative array of the channels the bot is in and which state(s)
        they are in.
     +/
    ubyte[string] channelStates;

    // isEnabled
    /++
        Override
        [kameloso.plugins.common.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.common.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
        and inject a server check, so this service does nothing on Twitch servers.

        Returns:
            `true` if this service should react to events; `false` if not.
     +/
    version(TwitchSupport)
    override public bool isEnabled() const pure nothrow @nogc
    {
        return (state.server.daemon != IRCServer.Daemon.twitch);
    }

    mixin IRCPluginImpl;
}

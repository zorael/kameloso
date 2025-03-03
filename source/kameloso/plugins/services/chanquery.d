/++
    The Channel Query service queries channels for information about them (in
    terms of topic and modes) as well as their lists of participants. It does this
    shortly after having joined a channel, as a service to all other plugins,
    so they don't each have to independently do it themselves.

    It is qualified as a service, so while it is not technically mandatory, it
    is highly recommended if you plan on mixing in
    [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness] into
    your plugins.

    See_Also:
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.services.chanquery;

version(WithChanQueryService):

private:

import kameloso.plugins;
import kameloso.plugins.common.mixins.awareness;
import dialect.defs;
import core.thread.fiber : Fiber;

version(OmniscientQueries)
{
    /++
        The [kameloso.plugins.ChannelPolicy|ChannelPolicy] to mix in
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


// onPing
/++
    Calls [startQueries] to start querying channels and users for information
    about them.

    See_Also:
        [startQueries]
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.PING)
)
void onPing(ChanQueryService service, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);
    startQueries(service);
}


// startQueries
/++
    Starts the routine to query channels and users for information about them.

    Channels are queried first. If the server doesn't support WHOIS, or if
    [kameloso.plugins.common.settings.CoreSettings.eagerLookups|CoreSettings.eagerLookups]
    is `false`, users are not WHOISed.
 +/
void startQueries(ChanQueryService service)
{
    import kameloso.plugins.common.scheduling : delay;
    import kameloso.constants : BufferSize;
    import kameloso.thread : CarryingFiber;
    import core.time : Duration;

    if (service.transient.querying) return;  // Try again next call

    /+
        Do as much as we can here *before* we create the fiber.
     +/
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
    if (!querylist.length && !service.state.coreSettings.eagerLookups) return;

    service.transient.querying = true;  // Effectively "lock"

    scope(exit)
    {
        service.transient.queriedAtLeastOnce = true;
        service.transient.querying = false;  // "Unlock"
    }

    void queryDg()
    {
        /+
            Query channels first; for their topics, their user lists and modes.
         +/
        queryChannels(service, querylist);

        /+
            Users are next, but only if we are doing eager lookups, and the
            server actually supports WHOIS. Otherwise stop here.
         +/
        if (service.state.coreSettings.eagerLookups && service.transient.serverSupportsWHOIS)
        {
            import std.datetime.systime : Clock;

            immutable nowInUnix = Clock.currTime.toUnixTime();
            bool[string] uniqueUsers;

            foreach (immutable channelName, const channel; service.state.channels)
            {
                foreach (immutable nickname; channel.users.byKey)
                {
                    import kameloso.constants : Timeout;

                    if (nickname == service.state.client.nickname) continue;

                    const user = nickname in service.state.users;

                    if (!user ||
                        !user.account.length ||
                        ((nowInUnix - user.updated) > Timeout.Integers.whoisRetrySeconds))
                    {
                        // No user, or no account and sufficient amount of time passed since last WHOIS
                        uniqueUsers[nickname] = true;
                    }
                }
            }

            if (uniqueUsers.length)
            {
                // Go ahead and WHOIS the users
                uniqueUsers.rehash();
                whoisUsers(service, uniqueUsers);
            }
        }
    }

    /+
        This function may be called from within a fiber already, in which case
        we can just call the delegate directly.
     +/
    if (auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis())
    {
        return queryDg();
    }

    auto queryFiber = new CarryingFiber!IRCEvent(&queryDg, BufferSize.fiberStack);
    queryFiber.call();
}


// queryChannels
/++
    Queries channels for information about them.

    This function is called by [startQueries] to query channels for their topics,
    their user lists and modes.

    Parameters:
        service = The [ChanQueryService] instance.
        querylist = An array of channel names to query.
 +/
void queryChannels(ChanQueryService service, const string[] querylist)
in (Fiber.getThis(), "Tried to call `queryChannels` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : await, delay, unawait, undelay;
    import kameloso.thread : CarryingFiber, ThreadMessage, boxed;
    import kameloso.messaging : Message, mode, raw;
    import std.string : representation;

    auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
    assert(thisFiber, "Incorrectly cast fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    outer:
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
        void queryAwaitAndUnlist(const string command, const IRCEvent.Type[] types)
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
            while (thisFiber.payload.channel.name != channelName);

            delay(service, ChanQueryService.timeBetweenQueries, yield: true);
        }

        /++
            Event types that signal the end of a query response.
         +/
        static immutable IRCEvent.Type[2] topicReply =
        [
            IRCEvent.Type.RPL_TOPIC,
            IRCEvent.Type.RPL_NOTOPIC,
        ];

        static immutable IRCEvent.Type[1] whoReply =
        [
            IRCEvent.Type.RPL_ENDOFWHO,
        ];

        static immutable IRCEvent.Type[1] channelModeReply =
        [
            IRCEvent.Type.RPL_CHANNELMODEIS,
        ];

        queryAwaitAndUnlist("TOPIC", topicReply[]);
        if (channelName !in service.channelStates) continue outer;
        queryAwaitAndUnlist("WHO", whoReply[]);
        if (channelName !in service.channelStates) continue outer;
        queryAwaitAndUnlist("MODE", channelModeReply[]);
        if (channelName !in service.channelStates) continue outer;

        // MODE generic
        foreach (immutable n, immutable modechar; service.state.server.aModes.representation)
        {
            import std.conv : text;

            if (n > 0)
            {
                // Cannot await by event type; there are too many types.
                delay(service, ChanQueryService.timeBetweenQueries, yield: true);
                if (channelName !in service.channelStates) continue outer;
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

            mode(service.state,
                channelName,
                modes: modeline,
                content: string.init,
                properties);
        }

        if (channelName !in service.channelStates) continue outer;

        // Overwrite state with [ChannelState.queried];
        // [ChannelState.topicKnown] etc are no longer relevant.
        service.channelStates[channelName] = ChannelState.queried;
    }
}


// whoisUsers
/++
    WHOIS users in channels.

    This function is called by [startQueries] to WHOIS users in channels.

    Parameters:
        service = The [ChanQueryService] instance.
        uniqueUsers = An associative array of unique users to WHOIS.
 +/
void whoisUsers(ChanQueryService service, const bool[string] uniqueUsers)
in (Fiber.getThis(), "Tried to call `whoisUsers` from outside a fiber")
{
    import kameloso.plugins.common.scheduling : await, delay, unawait, undelay;
    import kameloso.thread : CarryingFiber, ThreadMessage, boxed;
    import kameloso.messaging : Message;
    import std.datetime.systime : Clock;

    auto thisFiber = cast(CarryingFiber!IRCEvent)Fiber.getThis();
    assert(thisFiber, "Incorrectly cast fiber: `" ~ typeof(thisFiber).stringof ~ '`');

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

    long timeOfLastQueryResults;
    immutable numSecondsBetween = ChanQueryService.timeBetweenQueries.total!"seconds";

    outer:
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
        auto elapsed = (Clock.currTime.toUnixTime() - timeOfLastQueryResults);
        auto timeRemaining = (numSecondsBetween - elapsed);

        while (timeRemaining > 0)
        {
            delay(service, timeRemaining.seconds, yield: false);
            elapsed = (Clock.currTime.toUnixTime() - timeOfLastQueryResults);
            timeRemaining = (numSecondsBetween - elapsed);
        }

        version(WithPrinterPlugin)
        {
            service.state.messages ~= ThreadMessage.busMessage("printer", boxed("squelch " ~ nickname));
        }

        enum properties = (Message.Property.quiet | Message.Property.background);
        whois(service.state, nickname, properties);
        undelay(service);  // Remove any delays
        Fiber.yield();  // Await whois types registered above

        enum maxConsecutiveUnknownCommands = 3;
        uint consecutiveUnknownCommands;

        inner:
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
                    timeOfLastQueryResults = thisFiber.payload.time; //Clock.currTime.toUnixTime();
                    continue outer;
                }
                else
                {
                    // Something else caused a WHOIS; yield until the right one comes along
                    Fiber.yield();
                    continue inner;
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
                        enum message1 = "This server does not seem to support user accounts?";
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
                    continue inner;
                }
                break;

            default:
                assert(0, "Unreachable");
            }
        }

        assert(0, "Unreachable");
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
void onSelfjoin(ChanQueryService service, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    service.channelStates[event.channel.name] = ChannelState.unset;
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
void onSelfpart(ChanQueryService service, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    service.channelStates.remove(event.channel.name);
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
void onTopic(ChanQueryService service, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    service.channelStates[event.channel.name] |= ChannelState.topicKnown;
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
)
void onEndOfNames(ChanQueryService service, const IRCEvent _)
{
    mixin(memoryCorruptionCheck);

    if (!service.transient.querying && service.transient.queriedAtLeastOnce)
    {
        startQueries(service);
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
void onMyInfo(ChanQueryService service, const IRCEvent _)
{
    import kameloso.plugins.common.scheduling : delay;

    mixin(memoryCorruptionCheck);

    delay(service, service.timeBeforeInitialQueries, yield: true);
    startQueries(service);
}


// onNoSuchChannel
/++
    If we get an error that a channel doesn't exist, remove it from
    [ChanQueryService.channelStates|channelStates]. This stops it from being
    queried in [startQueries].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.ERR_NOSUCHCHANNEL)
)
void onNoSuchChannel(ChanQueryService service, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    service.channelStates.remove(event.channel.name);
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
        [kameloso.plugins.IRCPlugin.isEnabled|IRCPlugin.isEnabled]
        (effectively overriding [kameloso.plugins.IRCPluginImpl.isEnabled|IRCPluginImpl.isEnabled])
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

/++
    The Seen plugin implements "seen"; the ability for someone to
    query when a given nickname was last encountered online.

    We will implement this by keeping an internal `long[string]` associative
    array of timestamps keyed by nickname. Whenever we see a user do something,
    we will update his or her timestamp to the current time. We'll save this
    array to disk when closing the program and read it from file when starting
    it, as well as saving occasionally once every few (compile time-configurable)
    minutes.

    We will rely on the
    [kameloso.plugins.chanqueries.ChanQueriesService|ChanQueriesService] to query
    channels for full lists of users upon joining new ones, including the
    ones we join upon connecting. Elsewise, a completely silent user will never
    be recorded as having been seen, as they would never be triggering any of
    the functions we define to listen to. (There's a setting to ignore non-chatty
    events, as we'll see later.)

    kameloso does primarily not use callbacks, but instead annotates functions
    with `UDA`s of IRC event *types*. When an event is incoming it will trigger
    the function(s) annotated with its type.

    Callback delegates and [core.thread.fiber.Fiber|Fiber]s *are* supported but are not
    the primary way to trigger event handler functions. Such can however
    be registered to process on incoming events, or scheduled with a reasonably
    high degree of precision.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#seen
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.seen;

// We only want to compile this if we're compiling specifically this plugin.
version(WithSeenPlugin):

// We need the definition of an [kameloso.plugins.core.IRCPlugin|IRCPlugin] and other crucial things.
private import kameloso.plugins.common.core;

// Awareness mixins, for plumbing.
private import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;

// Likewise [dialect.defs], for the definitions of an IRC event.
private import dialect.defs;

// [kameloso.irccolours] for some IRC colouring and formatting.
private import kameloso.irccolours : ircBold, ircColourByHash;

// [kameloso.common] for some globals and helpers.
private import kameloso.common : expandTags, logger;

// [std.datetime.systime] for the [std.datetime.systime.Clock|Clock], to update times with.
private import std.datetime.systime : Clock;

// [std.typecons] for [std.typecons.Flag|Flag] and its friends.
private import std.typecons : Flag, No, Yes;

// [core.time] for [core.time.seconds|seconds], with which we can delay some actions.
private import core.time : seconds;


/+
    Most of the module can (and ideally should) be kept private. Our surface
    area here will be restricted to only one [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]
    class, and the usual pattern used is to have the private bits first and that
    public class last. We'll turn that around here to make it easier to visually parse.
 +/

public:


// SeenPlugin
/++
    This is your plugin to the outside world, the only thing publicly visible in the
    entire module. It only serves as a way of proxying calls to our top-level
    private functions, as well as to house plugin-specific and -private variables that we want
    to keep out of top-level scope for the sake of modularity. If the only state
    is in the plugin, several plugins of the same kind can technically be run
    alongside each other, which would allow for several bots to be run in
    parallel. This is not yet supported but there's fundamentally nothing stopping it.

    As such it houses this plugin's *state*, notably its instance of
    [SeenSettings] and its [kameloso.plugins.common.core.IRCPluginState|IRCPluginState].

    The [kameloso.plugins.common.core.IRCPluginState|IRCPluginState] is a struct housing various
    variables that together make up the plugin's state. This is where
    information is kept about the bot, the server, and some metathings allowing
    us to send messages to the server. We don't define it here; we mix it in
    later with the [kameloso.plugins.common.core.IRCPluginImpl|IRCPluginImpl] mixin.

    ---
    struct IRCPluginState
    {
        IRCClient client;
        IRCServer server;
        IRCBot bot;
        CoreSettings settings;
        ConnectionSettings connSettings;
        Tid mainThread;
        IRCUser[string] users;
        IRCChannel[string] channels;
        Replay[][string] pendingReplays;
        bool hasPendingReplays;
        Replay[] readyReplays;
        Fiber[][] awaitingFibers;
        void delegate(IRCEvent)[][] awaitingDelegates;
        ScheduledFiber[] scheduledFibers;
        ScheduledDelegate[] scheduledDelegates;
        long nextScheduledTimestamp;
        void updateScheule();
        Update updates;
        bool* abort;
    }
    ---

    * [kameloso.plugins.common.core.IRCPluginState.client|IRCPluginState.client]
        houses information about the client itself, such as your nickname and
        other things related to an IRC client.

    * [kameloso.plugins.common.core.IRCPluginState.server|IRCPluginState.server]
        houses information about the server you're connected to.

    * [kameloso.plugins.common.core.IRCPluginState.bot|IRCPluginState.bot] houses
        information about things that relate to an IRC bot, like which channels
        to join, which home channels to operate in, the list of administrator accounts, etc.

    * [kameloso.plugins.common.core.IRCPluginState.settings|IRCPluginState.settings]
        is a copy of the "global" [kameloso.kameloso.CoreSettings|CoreSettings],
        which contains information about how the bot should output text, whether
        or not to always save to disk upon program exit, and some other program-wide settings.

    * [kameloso.plugins.common.core.IRCPluginState.connSettings|IRCPluginState.connSettings]
        is like [kameloso.plugins.common.core.IRCPluginState.settings|IRCPluginState.settings],
        except for values relating to the connection to the server; whether to
        use IPv6, paths to any certificates, and the such.

    * [kameloso.plugins.common.core.IRCPluginState.mainThread|IRCPluginState.mainThread]
        is the [std.concurrency.Tid|*thread ID*] of the thread running the main loop.
        We indirectly use it to send strings to the server by way of concurrency
        messages, but it is usually not something you will have to deal with directly.

    * [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
        is an associative array keyed with users' nicknames. The value to that key is an
        [dialect.defs.IRCUser|IRCUser] representing that user in terms of nickname,
        address, ident, services account name, and much more. This is a way to keep track of
        users by more than merely their name. It is however not saved at the end
        of the program; as everything else it is merely state and transient.

    * [kameloso.plugins.common.core.IRCPluginState.channels|IRCPluginState.channels]
        is another associative array, this one with all the known channels keyed
        by their names. This way we can access detailed information about any
        known channel, given only their name.

    * [kameloso.plugins.common.core.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays]
        is also an associative array into which we place [kameloso.plugins.common.core.Replay|Replay]s.
        The main loop will pick up on these and call WHOIS on the nickname in the key.
        A [kameloso.plugins.common.core.Replay|Replay] is otherwise just an
        [dialect.defs.IRCEvent|IRCEvent] to be played back when the WHOIS results
        return, as well as a delegate that invokes the function that was originally
        to be called. Constructing a [kameloso.plugins.common.core.Replay|Replay] is
        all wrapped in a function [kameloso.plugins.common.misc.enqueue|enqueue], with the
        queue management handled behind the scenes.

    * [kameloso.plugins.common.core.IRCPluginState.hasPendingReplays|IRCPluginState.hasPendingReplays]
        is merely a bool of whether or not there currently are any
        [kameloso.plugins.common.core.Replay|Replay]s in
        [kameloso.plugins.common.core.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays],
        cached to avoid associative array length lookups.

    * [kameloso.plugins.common.core.IRCPluginState.readyReplays|IRCPluginState.readyReplays]
        is an array of [kameloso.plugins.common.core.Replay|Replay]s that have
        seen their WHOIS request issued and the result received. Moving one from
        [kameloso.plugins.common.core.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays]
        to [kameloso.plugins.common.core.IRCPluginState.readyReplays|IRCPluginState.readyReplays]
        will make the main loop pick it up, *update* the [dialect.defs.IRCEvent|IRCEvent]
        stored within it with what we now know of the sender and/or target, and
        then replay the event by invoking its delegate.

    * [kameloso.plugins.common.core.IRCPluginState.awaitingFibers|IRCPluginState.awaitingFibers]
        is an array of [core.thread.fiber.Fiber|Fiber]s indexed by [dialect.ircdefs.IRCEvent.Type]s'
        numeric values. Fibers in the array of a particular event type will be
        executed the next time such an event is incoming. Think of it as Fiber callbacks.

    * [kameloso.plugins.common.core.IRCPluginState.awaitingDelegates|IRCPluginState.awaitingDelegates]
        is literally an array of callback delegates, to be triggered when an event
        of a matching type comes along.

    * [kameloso.plugins.common.core.IRCPluginState.scheduledFibers|IRCPluginState.scheduledFibers]
        is also an array of [core.thread.fiber.Fiber|Fiber]s, but not one keyed
        on or indexed by event types. Instead they are tuples of a
        [core.thread.fiber.Fiber|Fiber] and a `long` timestamp of when they should be run.
        Use [kameloso.plugins.common.delayawait.delayFiber|delayFiber] to enqueue.

    * [kameloso.plugins.common.core.IRCPluginState.scheduledDelegates|IRCPluginState.scheduledDelegates]
        is likewise an array of delegates, to be triggered at a later point in time.

    * [kameloso.plugins.common.core.IRCPluginState.nextScheduledTimestamp|IRCPluginState.nextScheduledFibers]
        is also a UNIX timestamp, here of when the next [kameloso.thread.ScheduledFiber|ScheduledFiber]
        in [kameloso.plugins.common.core.IRCPluginState.scheduledFibers|IRCPluginState.scheduledFibers]
        *or* the next [kameloso.thread.ScheduledDelegate|ScheduledDelegate] in
        [kameloso.plugins.common.core.IRCPluginState.scheduledDelegates|IRCPluginState.scheduledDelegates]
        is due to be processed. Caching it here means we won't have to walk through
        the arrays to find out as often.

    * [kameloso.plugins.common.core.IRCPluginState.updateSchedule|IRCPluginState.updateSchedule]
        merely iterates all scheduled fibers and delegates, caching the time at
        which the next one should trigger in
        [kameloso.plugins.common.core.IRCPluginState.nextScheduledTimestamp|IRCPluginState.nextScheduledFibers].

    * [kameloso.plugins.common.core.IRCPluginState.updates|IRCPluginState.updates]
        is a bitfield which represents what aspect of the bot was *changed*
        during processing or postprocessing. If any of the bits are set, represented
        by the enum values of [kameloso.plugins.common.core.IRCPluginState.Updates|IRCPluginState.Updates],
        the main loop will pick up on it and propagate it to other plugins.
        If these flags are not set, changes will never leave the plugin and may
        be overwritten by other plugins. It is mostly for internal use.

    * [kameloso.plugins.common.core.IRCPluginState.abort|IRCPluginState.abort]
        is a pointer to the global abort bool. When this is set, it signals the
        rest of the program that we want to terminate cleanly.
 +/
final class SeenPlugin : IRCPlugin
{
private:  // Module-level private.

    // seenSettings
    /++
        An instance of *settings* for the Seen plugin. We will define this
        later. The members of it will be saved to and loaded from the
        configuration file, for use in our module.
     +/
    SeenSettings seenSettings;


    // seenUsers
    /++
        Our associative array (AA) of seen users; a dictionary keyed with
        users' nicknames and with values that are UNIX timestamps, denoting when
        that user was last *seen* online.

        Example:
        ---
        seenUsers["joe"] = Clock.currTime.toUnixTime;
        // ..later..
        immutable now = Clock.currTime.toUnixTime;
        writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"]));
        ---
     +/
    long[string] seenUsers;


    // seenFile
    /++
        The filename to which to persistently store our list of seen users
        between executions of the program.

        This is only the basename of the file. It will be completed with a path
        to the default (or specified) resource directory, which varies by
        platform. Expect this variable to have values like
        "`/home/user/.local/share/kameloso/servers/irc.libera.chat/seen.json`"
        after the plugin has been instantiated.
     +/
    @Resource string seenFile = "seen.json";


    // timeBetweenSaves
    /++
        The amount of seconds after which seen users should be saved to disk.
     +/
    static immutable timeBetweenSaves = 300.seconds;


    // rehashThresholdMultiplier
    /++
        The multiplier to multiply the length of [seenUsers] with; if the number
        of users added since the last rehash exceeds this value, rehash again.

        ---
        if (plugin.addedSinceLastRehash >
            (plugin.seenUsers.length * plugin.rehashThresholdMultiplier))
        {
            plugin.seenUsers = plugin.seenUsers.rehash();
            plugin.addedSinceLastRehash = 0;
        }
        ---

        See_Also:
            [addedSinceLastRehash]
     +/
    enum rehashThresholdMultiplier = 0.5;


    // addedSinceLastRehash
    /++
        How many users have been added to [seenUsers] since the last rehash.

        If this is below the number of entries in [seenUsers] multiplied by
        [rehashThresholdMultiplier], don't rehash, since there's no need.

        See_Also:
            [rehashThresholdMultiplier]
     +/
    uint addedSinceLastRehash;


    // IRCPluginImpl
    /++
        This mixes in functions that fully implement an
        [kameloso.plugins.common.core.IRCPlugin|IRCPlugin]. They don't do much by themselves
        other than call the module's functions, as well as implement things like
        functions that return the plugin's name, its list of bot command words, etc.
        It does this by introspecting the module and implementing itself as it sees fit.

        This includes the functions that call the top-level event handler functions
        on incoming events.

        Seen from any other module, this module is a big block of private things
        they can't see, plus this visible plugin class. By having this class
        pass on things to the private functions we limit the surface area of
        the plugin to be really small.
     +/
    mixin IRCPluginImpl;


    import kameloso.plugins.common.mixins : MessagingProxy;

    // MessagingProxy
    /++
        This mixin adds shorthand functions to proxy calls to
        [kameloso.messaging] functions, *partially applied* with the main thread ID,
        so they can easily be called with knowledge only of the plugin symbol.

        ---
        plugin.chan("#d", "Hello world!");
        plugin.query("kameloso", "Hello you!");

        with (plugin)
        {
            chan("#d", "This is convenient");
            query("kameloso", "No need to specify plugin.state.mainThread");
        }
        ---
     +/
    mixin MessagingProxy;
}


/+
    The rest will be private.
 +/
private:


// SeenSettings
/++
    We want our plugin to be *configurable* with a section for itself in the
    configuration file. For this purpose we create a "Settings" struct housing
    our configurable bits, which we already made an instance of in [SeenPlugin].

    If it's annotated with [kameloso.plugins.common.core.Settings|Settings], the
    wizardry will pick it up and each member of the struct will be given its own
    line in the configuration file. Note that not all types are supported, such as
    associative arrays or nested structs/classes.

    If the name ends with "Settings", that will be stripped from its section
    header in the file. Hence, this plugin's [SeenSettings] will get the header
    `[Seen]`.
 +/
@Settings struct SeenSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
        The @[kameloso.plugins.common.core.Enabler|Enabler] annotation makes it special and
        lets us easily enable or disable the plugin without having checks everywhere.
     +/
    @Enabler bool enabled = true;

    /++
        Toggles whether or not non-chat events, such as
        [dialect.defs.IRCEvent.Type.JOIN|JOIN]s,
        [dialect.defs.IRCEvent.Type.PART|PART]s and the such, should be considered
        as observations. If set, only chatty events will count as being seen.

        This might make sense to enable on Twitch, but in most other cases it can
        be safely left disabled.
     +/
    bool ignoreNonChatEvents;
}


version(OmniscientSeen)
{
    // omniscientChannelPolicy
    /++
        The [kameloso.plugins.common.core.ChannelPolicy|ChannelPolicy] annotation dictates
        whether or not an annotated function should be called based on the *channel*
        the event took place in, if applicable.

        The three policies are
        [kameloso.plugins.common.core.ChannelPolicy.home|ChannelPolicy.home],
        with which only events in channels in the
        [kameloso.kameloso.IRCBot.homeChannels|IRCBot.homeChannels]
        array will be allowed to trigger it;
        [kameloso.plugins.common.core.ChannelPolicy.guest|ChannelPolicy.guest]
        with which only events outside of such home channels will be allowed to trigger;
        or [kameloso.plugins.common.core.ChannelPolicy.any|ChannelPolicy.any],
        in which case anywhere goes.

        For events that don't correspond to a channel (such as
        [dialect.defs.IRCEvent.Type.QUERY|QUERY]) the setting doesn't apply and is ignored.

        Thus this [omniscientChannelPolicy] enum constant is a compile-time setting
        for all event handlers where whether a channel is a home or not is of
        interest (or even applies). Put in a version block like this it allows
        us to control the plugin's behaviour via `dub` build configurations.
     +/
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    enum omniscientChannelPolicy = ChannelPolicy.home;
}


// onSomeAction
/++
    Whenever a user does something, record this user as having been seen at the
    current time.

    This function will be called whenever an [dialect.defs.IRCEvent|IRCEvent] is
    being processed of the [dialect.defs.IRCEvent.Type|IRCEvent.Type]s that we annotate
    the function with.

    The [kameloso.plugins.common.core.IRCEventHandler.chainable|IRCEventHandler.chainable]
    annotations mean that the plugin will also process other functions in this
    module with the same [dialect.defs.IRCEvent.Type|IRCEvent.Type] annotations,
    even if this one matched. The default is otherwise that it will end early
    after one match and proceed to the next plugin, but this doesn't ring well
    with catch-all functions like these. It's sensible to save
    [kameloso.plugins.common.core.IRCEventHandler.chainable|IRCEventHandler.chainable]
    only for the modules and functions that actually need it.

    The [kameloso.plugins.common.core.IRCEventHandler.requiredPermissions|IRCEventHandler.requiredPermissions]
    annotation dictates who is authorised to trigger the function. It has six
    policies, in increasing order of importance:
    [kameloso.plugins.common.core.Permissions.ignore|Permissions.ignore],
    [kameloso.plugins.common.core.Permissions.anyone|Permissions.anyone],
    [kameloso.plugins.common.core.Permissions.registered|Permissions.registered],
    [kameloso.plugins.common.core.Permissions.whitelist|Permissions.whitelist],
    [kameloso.plugins.common.core.Permissions.operator|Permissions.operator],
    [kameloso.plugins.common.core.Permissions.staff|Permissions.staff] and
    [kameloso.plugins.common.core.Permissions.admin|Permissions.admin].

    * [kameloso.plugins.common.core.Permissions.ignore|Permissions.ignore] will
        let precisely anyone trigger it, without looking them up.

    * [kameloso.plugins.common.core.Permissions.anyone|Permissions.anyone] will
        let anyone trigger it, but only after having looked them up, allowing
        for blacklisting people.

    * [kameloso.plugins.common.core.Permissions.registered|Permissions.registered]
        will let anyone logged into a services account trigger it, provided they
        are not blacklisted.

    * [kameloso.plugins.common.core.Permissions.whitelist|Permissions.whitelist]
        will only allow users in the whitelist section of the `users.json`
        resource file, provided they are also not blacklisted. Consider this to
        correspond to "regulars" in the channel.

    * [kameloso.plugins.common.core.Permissions.operator|Permissions.operator]
        will only allow users in the operator section of the `users.json`
        resource file. Consider this to correspond to "moderators" in the channel.

    * [kameloso.plugins.common.core.Permissions.staff|Permissions.staff] will
        only allow users in the staff section of the `users.json` resource file.
        Consider this to correspond to channel owners.

    * [kameloso.plugins.common.core.Permissions.admin|Permissions.admin] will
        allow only you and your other superuser administrators, as defined in
        the configuration file. This is a program-wide permission and will apply
        to all channels. Consider it to correspond to bot system operators.

    In the case of
    [kameloso.plugins.common.core.Permissions.whitelist|Permissions.whitelist],
    [kameloso.plugins.common.core.Permissions.operator|Permissions.operator],
    [kameloso.plugins.common.core.Permissions.staff|Permissions.staff] and
    [kameloso.plugins.common.core.Permissions.admin|Permissions.admin] it will
    look you up and compare your *services account name* to those known good
    before doing anything. In the case of
    [kameloso.plugins.common.core.Permissions.registered|Permissions.registered],
    merely being logged in is enough. In the case of
    [kameloso.plugins.common.core.Permissions.anyone|Permissions.anyone], the
    WHOIS results won't matter and it will just let it pass, but it will check
    all the same so as to be able to apply the blacklist.
    In the other cases, if you aren't logged into services or if your account
    name isn't included in the lists, the function will not trigger.

    This particular function doesn't care at all, so it is
    [kameloso.plugins.common.core.Permissions.ignore|Permissions.ignore].

    The [kameloso.plugins.common.core.ChannelPolicy|ChannelPolicy] here is the same
    [omniscientChannelPolicy] we defined earlier, versioned to have a different
    value based on the dub build configuration. By default, it's
    [kameloso.plugins.common.core.ChannelPolicy.home|ChannelPolicy.home].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.JOIN)
    .onEvent(IRCEvent.Type.PART)
    .onEvent(IRCEvent.Type.MODE)
    .onEvent(IRCEvent.Type.TWITCH_TIMEOUT)
    .onEvent(IRCEvent.Type.TWITCH_BAN)
    .onEvent(IRCEvent.Type.TWITCH_BULKGIFT)
    .onEvent(IRCEvent.Type.TWITCH_CHARITY)
    .onEvent(IRCEvent.Type.TWITCH_EXTENDSUB)
    .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
    .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
    .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
    .onEvent(IRCEvent.Type.TWITCH_RITUAL)
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
    .onEvent(IRCEvent.Type.TWITCH_SUBUPGRADE)
    .onEvent(IRCEvent.Type.TWITCH_TIMEOUT)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(omniscientChannelPolicy)
    .chainable(true)
)
void onSomeAction(SeenPlugin plugin, const ref IRCEvent event)
{
    /+
        Updates the user's timestamp to the current time, both sender and target.

        This will be automatically called on any and all the kinds of
        [dialect.defs.IRCEvent.Type|IRCEvent.Type]s it is annotated with.
        Furthermore, it will only trigger if it took place in a home channel.

        There's no need to check for whether the sender/target is us, as
        [updateUser] will do it more thoroughly (by stripping any extra modesigns).

        Don't count non-chatty events if the settings say to ignore them.
     +/

    with (IRCEvent.Type)
    switch (event.type)
    {
    case CHAN:
    case QUERY:
    case EMOTE:
        // Chatty event. Drop down
        break;

    version(TwitchSupport)
    {
        case TWITCH_BULKGIFT:
        case TWITCH_CHARITY:
        case TWITCH_EXTENDSUB:
        case TWITCH_GIFTCHAIN:
        case TWITCH_PAYFORWARD:
        case TWITCH_REWARDGIFT:
        case TWITCH_RITUAL:
        case TWITCH_SUB:
        case TWITCH_SUBGIFT:
        case TWITCH_SUBUPGRADE:
            // Consider these as chatty events too
            // targets might be caught in the crossfire in some cases
            goto case CHAN;
    }

    default:
        if (plugin.seenSettings.ignoreNonChatEvents) return;
        // Drop down
        break;
    }

    if (event.sender.nickname)
    {
        plugin.updateUser(event.sender.nickname, event.time);
    }

    if (event.target.nickname)
    {
        plugin.updateUser(event.target.nickname, event.time);
    }
}


// onQuit
/++
    When someone quits, update their entry with the current timestamp iff they
    already have an entry.

    [dialect.defs.IRCEvent.Type.QUIT|QUIT] events don't carry a channel.
    Users bleed into the seen users database from guest channels by quitting
    unless we somehow limit it to only accept quits from those in homes. Users
    in home channels should always have an entry, provided that
    [dialect.defs.IRCEvent.Type.RPL_NAMREPLY|RPL_NAMREPLY] lists were given when
    joining one, which seems to (largely?) be the case.

    Do nothing if an entry was not found.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(SeenPlugin plugin, const ref IRCEvent event)
{
    auto seenTimestamp = event.sender.nickname in plugin.seenUsers;

    if (seenTimestamp)
    {
        *seenTimestamp = event.time;
    }
}


// onNick
/++
    When someone changes nickname, add a new entry with the current timestamp for
    the new nickname, and remove the old one.

    Bookkeeping; this is to avoid getting ghost entries in the seen array.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.NICK)
    .permissionsRequired(Permissions.ignore)
    .chainable(true)
)
void onNick(SeenPlugin plugin, const ref IRCEvent event)
{
    auto seenTimestamp = event.sender.nickname in plugin.seenUsers;

    if (seenTimestamp)
    {
        *seenTimestamp = event.time;
        plugin.seenUsers.remove(event.sender.nickname);
    }
}


// onWHOReply
/++
    Catches each user listed in a WHO reply and updates their entries in the
    seen users list, creating them if they don't exist.

    A WHO request enumerates all members in a channel. It returns several
    replies, one event per each user in the channel. The
    [kameloso.plugins.chanqueries.ChanQueriesService|ChanQueriesService] services
    instigates this shortly after having joined one, as a service to other plugins.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
    .channelPolicy(omniscientChannelPolicy)
)
void onWHOReply(SeenPlugin plugin, const ref IRCEvent event)
{
    // Update the user's entry
    plugin.updateUser(event.target.nickname, event.time);
}


// onNamesReply
/++
    Catch a NAMES reply and record each person as having been seen.

    When requesting NAMES on a channel, or when joining one, the server will send
    a big list of every participant in it, in a big string of nicknames separated by spaces.
    This is done automatically when you join a channel. Nicknames are prefixed
    with mode signs if they are operators, voiced or similar, so we'll need to
    strip that away.

    More concretely, it uses a [std.algorithm.iteration.splitter|splitter] to iterate each
    name and call [updateUser] to update (or create) their entry in the
    [SeenPlugin.seenUsers|seenUsers] associative array.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_NAMREPLY)
    .channelPolicy(omniscientChannelPolicy)
)
void onNamesReply(SeenPlugin plugin, const ref IRCEvent event)
{
    import std.algorithm.iteration : splitter;

    foreach (immutable entry; event.content.splitter(' '))
    {
        import dialect.common : stripModesign;
        import lu.string : nom;
        import std.typecons : Flag, No, Yes;

        string slice = entry;  // mutable
        slice = slice.nom!(Yes.inherit)('!'); // In case SpotChat-like, full nick!ident@address form
        plugin.updateUser(slice, event.time);
    }
}


// onCommandSeen
/++
    Whenever someone says "!seen" in a [dialect.defs.IRCEvent.Type.CHAN|CHAN] or
    a [dialect.defs.IRCEvent.Type.QUERY|QUERY], and if
    [dialect.defs.IRCEvent.Type.CHAN|CHAN] then only if in a *home*, this function triggers.

    The [kameloso.plugins.common.core.IRCEventHandler.Command.word|IRCEventHandler.Command.word]
    annotation defines a piece of text that the incoming message must start with
    for this function to be called.
    [kameloso.plugins.common.core.IRCEventHandler.Command.policy|IRCEventHandler.Command.policy]
    deals with whether the message has to start with the name of the *bot* or not,
    and to what extent.

    Prefix policies can be one of:

    * [kameloso.plugins.common.core.PrefixPolicy.direct|PrefixPolicy.direct],
        where the raw command is expected without any message prefix at all;
        the command is simply that string: "`seen`".

    * [kameloso.plugins.common.core.PrefixPolicy.prefixed|PrefixPolicy.prefixed],
        where the message has to start with the command *prefix* character
        or string (usually `!` or `.`): "`!seen`".

    * [kameloso.plugins.common.core.PrefixPolicy.nickname|PrefixPolicy.nickname],
        where the message has to start with bot's nickname:
        "`kameloso: seen`" -- except if it's in a [dialect.defs.IRCEvent.Type.QUERY|QUERY] message.

    The plugin system will have made certain we only get messages starting with
    "`seen`", since we annotated this function with such a
    [kameloso.plugins.common.core.IRCEventHandler.Command|IRCEventHandler.Command].
    It will since have been sliced off, so we're left only with the "arguments"
    to "`seen`". [dialect.defs.IRCEvent.aux|IRCEvent.aux] contains the triggering
    word, if it's needed.

    If this is a [dialect.defs.IRCEvent.Type.CHAN|CHAN] event, the original lines
    could (for example) have been "`kameloso: seen Joe`", or merely "`!seen Joe`"
    (assuming a "`!`" prefix). If it was a private [dialect.defs.IRCEvent.Type.QUERY|QUERY]
    message, the `kameloso:` prefix will have been removed. In either case, we're
    left with only the parts we're interested in, and the rest sliced off.

    As a result, the [dialect.defs.IRCEvent|IRCEvent] `event` would look something
    like this (given a user `foo` querying "`!seen Joe`" or "`kameloso: seen Joe`"):

    ---
    event.type = IRCEvent.Type.CHAN;
    event.sender.nickname = "foo";
    event.sender.ident = "~bar";
    event.sender.address = "baz.foo.bar.org";
    event.channel = "#bar";
    event.content = "Joe";
    event.aux = "seen";
    ---

    Lastly, the
    [kameloso.plugins.common.core.IRCEventHandler.Command.description|IRCEventHandler.Command.description]
    annotation merely defines how this function will be listed in the "online help"
    list, shown by triggering the [kameloso.plugins.help.HelpPlugin|HelpPlugin]'s'
    "`help`" command.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .permissionsRequired(Permissions.anyone)
    .channelPolicy(omniscientChannelPolicy)
    .addCommand(
        IRCEventHandler.Command()
            .word("seen")
            .policy(PrefixPolicy.prefixed)
            .description("Queries the bot when it last saw a specified nickname online.")
            .syntax("$command [nickname]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("lastseen")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandSeen(SeenPlugin plugin, const ref IRCEvent event)
{
    import kameloso.common : timeSince;
    import dialect.common : isValidNickname;
    import lu.string : contains;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : SysTime;
    import std.format : format;

    /+
        The bot uses concurrency messages to queue strings to be sent to the
        server. This has benefits such as that even a multi-threaded program
        will have synchronous messages sent, and it's overall an easy and
        convenient way for plugin to send messages up the stack.

        There are shorthand versions for sending these messages in
        [kameloso.messaging], and additionally this module has mixed in
        `MessagingProxy` in the [SeenPlugin], creating even shorter shorthand
        versions.

        You can therefore use them as such:

        ---
        with (plugin)  // <-- necessary for the short-shorthand
        {
            chan("#d", "Hello world!");
            query("kameloso", "Hello you!");
            privmsg(event.channel, event.sender.nickname, "Query or chan!");
            join("#flerrp");
            part("#flerrp");
            topic("#flerrp", "This is a new topic");
        }
        ---

        `privmsg` will either send a channel message or a personal query message
        depending on the arguments passed to it. If the first `channel` argument
        is not empty, it will be a `chan` channel message, else a private
        `query` message.
     +/

    immutable requestedUser = event.content;

    with (plugin)
    {
        if (!requestedUser.length)
        {
            immutable message = "Usage: " ~ plugin.state.settings.prefix ~
                event.aux ~ " [nickname]";
            privmsg(event.channel, event.sender.nickname, message);
            return;
        }
        else if (!requestedUser.isValidNickname(plugin.state.server))
        {
            // Nickname contained a space or other invalid character
            immutable message = "Invalid user: <b>" ~ requestedUser ~ "<b>";
            privmsg(event.channel, event.sender.nickname, message);
            return;
        }
        else if (requestedUser == state.client.nickname)
        {
            // The requested nick is the bot's.
            privmsg(event.channel, event.sender.nickname, "T-that's me though...");
            return;
        }
        else if (requestedUser == event.sender.nickname)
        {
            // The person is asking for seen information about him-/herself.
            privmsg(event.channel, event.sender.nickname, "That's you!");
            return;
        }

        foreach (const channel; state.channels)
        {
            if (requestedUser in channel.users)
            {
                immutable pattern = (event.channel.length && (event.channel == channel.name)) ?
                    "<h>%s<h> is here right now!" : "<h>%s<h> is online right now.";
                immutable message = pattern.format(requestedUser);

                privmsg(event.channel, event.sender.nickname, message);
                return;
            }
        }

        // No matches

        if (const userTimestamp = requestedUser in seenUsers)
        {
            enum pattern =  "I last saw <h>%s<h> %s ago.";

            immutable timestamp = SysTime.fromUnixTime(*userTimestamp);
            immutable diff = (Clock.currTime - timestamp);
            immutable elapsed = timeSince!(7, 2)(diff);
            immutable message = pattern.format(requestedUser, elapsed);

            privmsg(event.channel, event.sender.nickname, message);
        }
        else
        {
            // No matches for nickname `event.content` in `plugin.seenUsers`.

            enum pattern = "I have never seen <h>%s<h>.";
            immutable message = pattern.format(requestedUser);

            privmsg(event.channel, event.sender.nickname, message);
        }
    }
}


// updateUser
/++
    Update a given nickname's entry in the seen array with the passed time,
    expressed in UNIX time.

    This is not annotated as an IRC event handler and will merely be invoked from
    elsewhere, like any normal function.

    Example:
    ---
    string potentiallySignedNickname = "@kameloso";
    long now = Clock.currTime.toUnixTime;
    plugin.updateUser(potentiallySignedNickname, now);
    ---

    Params:
        plugin = Current [SeenPlugin].
        signed = Nickname to update, potentially prefixed with one or more modesigns
            (`@`, `+`, `%`, ...).
        time = UNIX timestamp of when the user was seen.
        skipModesignStrp = Whether or not to explicitly not strip modesigns from the nickname.
 +/
void updateUser(SeenPlugin plugin,
    const string signed,
    const long time,
    const Flag!"skipModesignStrip" skipModesignStrip = No.skipModesignStrip)
in (signed.length, "Tried to update a user with an empty (signed) nickname")
{
    import dialect.common : stripModesign;

    // Make sure to strip the modesign, so `@foo` is the same person as `foo`.
    immutable nickname = skipModesignStrip ? signed : signed.stripModesign(plugin.state.server);
    if (nickname == plugin.state.client.nickname) return;

    if (auto nicknameSeen = nickname in plugin.seenUsers)
    {
        // User exists in seenUsers; merely update the time
        *nicknameSeen = time;
    }
    else
    {
        // New user; add an entry and bump the added counter
        plugin.seenUsers[nickname] = time;
        ++plugin.addedSinceLastRehash;
    }
}


// maybeRehash
/++
    Rehash the [SeenPlugin.seenUsers|seenUsers] associative array if we deem
    enough new users have been added to it since the last rehash to warrant it.

    Params:
        plugin = Current [SeenPlugin].
 +/
void maybeRehash(SeenPlugin plugin)
{
    if (plugin.addedSinceLastRehash >
        (plugin.seenUsers.length * plugin.rehashThresholdMultiplier))
    {
        plugin.seenUsers = plugin.seenUsers.rehash();
        plugin.addedSinceLastRehash = 0;
    }
}


// updateAllObservedUsers
/++
    Update all currently observed users.

    This allows us to update users that don't otherwise trigger events that
    would register activity, such as silent participants.

    Params:
        plugin = Current [SeenPlugin].
 +/
void updateAllObservedUsers(SeenPlugin plugin)
{
    bool[string] uniqueUsers;

    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        foreach (const nickname; channel.users.byKey)
        {
            uniqueUsers[nickname] = true;
        }
    }

    immutable now = Clock.currTime.toUnixTime;

    foreach (immutable nickname; uniqueUsers.byKey)
    {
        plugin.updateUser(nickname, now, Yes.skipModesignStrip);
    }
}


// loadSeen
/++
    Given a filename, read the contents and load it into a `long[string]`
    associative array, then returns it. If there was no file there to read,
    return an empty array for a fresh start.

    Params:
        filename = Filename of the file to read from.

    Returns:
        `long[string]` associative array; UNIX timestamp longs keyed by nickname strings.
 +/
long[string] loadSeen(const string filename)
{
    import std.file : exists, isFile, readText;
    import std.json : JSONException, parseJSON;

    long[string] aa;

    if (!filename.exists || !filename.isFile)
    {
        enum pattern = "<l>%s<w> does not exist or is not a file";
        logger.warningf(pattern.expandTags, filename);
        return aa;
    }

    try
    {
        const asJSON = parseJSON(filename.readText).object;

        // Manually insert each entry from the JSON file into the long[string] AA.
        foreach (immutable user, const time; asJSON)
        {
            aa[user] = time.integer;
        }
    }
    catch (JSONException e)
    {
        import kameloso.common : Tint;
        logger.error("Could not load seen JSON from file: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }

    // Rehash the AA, since we potentially added a *lot* of users.
    return aa.rehash();
}


// saveSeen
/++
    Save the passed seen users associative array to disk, in JSON format.

    This is a convenient way to serialise the array.

    Params:
        seenUsers = The associative array of seen users to save.
        filename = Filename of the file to write to.
 +/
void saveSeen(const long[string] seenUsers, const string filename)
in (filename.length, "Tried to save seen users to an empty filename")
{
    import std.json : JSONValue;
    import std.stdio : File, writeln;

    if (!seenUsers.length) return;

    auto file = File(filename, "w");
    file.writeln(JSONValue(seenUsers).toPrettyString);
    //file.flush();
}


// onWelcome
/++
    After we have registered on the server and seen the welcome messages, load
    our seen users from file. Additionally set up a Fiber that periodically
    saves seen users to disk once every [SeenPlugin.timeBetweenSaves|timeBetweenSaves]
    seconds.

    This is to make sure that as little data as possible is lost in the event
    of an unexpected shutdown while still not hammering the disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(SeenPlugin plugin)
{
    import kameloso.plugins.common.delayawait : await, delay;
    import kameloso.constants : BufferSize;
    import core.thread : Fiber;

    plugin.seenUsers = loadSeen(plugin.seenFile);

    void saveDg()
    {
        while (true)
        {
            plugin.updateAllObservedUsers();
            plugin.maybeRehash();
            plugin.seenUsers.saveSeen(plugin.seenFile);
            delay(plugin, plugin.timeBetweenSaves, Yes.yield);
        }
    }

    Fiber saveFiber = new Fiber(&saveDg, BufferSize.fiberStack);
    delay(plugin, saveFiber, plugin.timeBetweenSaves);

    // Use an awaiting delegate to report seen users, to avoid it being repeated
    // on subsequent manual MOTD calls, unlikely as they may be. For correctness' sake.

    static immutable IRCEvent.Type[2] endOfMotdEventTypes =
    [
        IRCEvent.Type.RPL_ENDOFMOTD,
        IRCEvent.Type.ERR_NOMOTD,
    ];

    void endOfMotdDg(IRCEvent)
    {
        import kameloso.plugins.common.delayawait : unawait;
        import lu.string : plurality;

        unawait(plugin, &endOfMotdDg, endOfMotdEventTypes[]);

        // Reports statistics on how many users are registered as having been seen

        enum pattern = "Currently <i>%d<l> %s seen.";
        logger.logf(pattern.expandTags, plugin.seenUsers.length,
            plugin.seenUsers.length.plurality("user", "users"));
    }

    await(plugin, &endOfMotdDg, endOfMotdEventTypes[]);
}


// reload
/++
    Reload seen users from disk.
 +/
void reload(SeenPlugin plugin)
{
    //logger.info("Reloading seen users from disk.");
    plugin.seenUsers = loadSeen(plugin.seenFile);
}


// teardown
/++
    When closing the program or when crashing with grace, save the seen users
    array to disk for later reloading.
 +/
void teardown(SeenPlugin plugin)
{
    plugin.updateAllObservedUsers();
    plugin.seenUsers.saveSeen(plugin.seenFile);
}


// initResources
/++
    Read and write the file of seen people to disk, ensuring that it's there.
 +/
void initResources(SeenPlugin plugin)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(plugin.seenFile);
    }
    catch (JSONException e)
    {
        import kameloso.terminal : TerminalToken, isTTY;
        import std.path : baseName;

        enum bellString = ("" ~ cast(char)(TerminalToken.bell));
        immutable bell = isTTY ? bellString : string.init;

        logger.warning(plugin.seenFile.baseName, " is corrupt. Starting afresh.", bell);
        version(PrintStacktraces) logger.trace(e);
    }

    // Let other Exceptions pass up the stack.

    json.save(plugin.seenFile);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receive a passed [kameloso.thread.BusMessage|BusMessage] with the "`seen`" header,
    and calls functions based on the payload message.

    This is used in the Pipeline plugin, to allow us to trigger seen verbs via
    the command-line pipe, as well as in the Admin plugin for remote control
    over IRC.

    Params:
        plugin = The current [SeenPlugin].
        header = String header describing the passed content payload.
        content = Boxed message content.
 +/
debug
version(Posix)
//version(WithPipelinePlugin)  // Be available to other plugins too, like admin
void onBusMessage(SeenPlugin plugin, const string header, shared Sendable content)
{
    if (!plugin.isEnabled) return;
    if (header != "seen") return;

    import kameloso.thread : BusMessage;
    import lu.string : strippedRight;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    immutable verb = message.payload.strippedRight;

    switch (verb)
    {
    case "reload":
        return .reload(plugin);

    case "save":
        plugin.updateAllObservedUsers();
        plugin.seenUsers.saveSeen(plugin.seenFile);
        logger.info("Seen users saved to disk.");
        break;

    default:
        logger.error("[seen] Unimplemented bus message verb: ", verb);
        break;
    }
}


/++
    [kameloso.plugins.common.awareness.UserAwareness|UserAwareness] is a mixin
    template; it proxies to a few functions defined in [kameloso.plugins.common.awareness]
    to deal with common book-keeping that every plugin *that wants to keep track
    of users* need. If you don't want to track which users you have seen (and are
    visible to you now), you don't need this.

    Additionally it implicitly mixes in
    [kameloso.plugins.common.awareness.MinimalAuthentication|MinimalAuthentication],
    needed as soon as you have any [kameloso.plugins.common.core.PrefixPolicy|PrefixPolicy] checks.
 +/
mixin UserAwareness;


/++
    Complementary to [kameloso.plugins.common.awareness.UserAwareness|UserAwareness] is
    [kameloso.plugins.common.awareness.ChannelAwareness|ChannelAwareness], which
    will add in book-keeping about the channels the bot is in, their topics, modes,
    and list of participants. Channel awareness requires user awareness, but not
    the other way around.

    Depending on the value of [omniscientChannelPolicy] we may want it to limit
    the amount of tracked users to people in our home channels.
 +/
mixin ChannelAwareness!omniscientChannelPolicy;


/++
    This full plugin is <200 source lines of code. (`dscanner --sloc seen.d`)
    Even at those numbers it is fairly feature-rich.
 +/

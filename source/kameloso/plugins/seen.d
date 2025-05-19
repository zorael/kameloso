/++
    The Seen plugin implements "seen"; the ability for someone to
    query when a given nickname was last encountered online.

    We will implement this by keeping an internal `long[string]` associative
    array of timestamps keyed by nickname. Whenever we see a user do something,
    we will update his or her timestamp to the current time. We'll save this
    array to disk when closing the program and read it from file when starting
    it, as well as saving occasionally once every few minutes.

    We will rely on the
    [kameloso.plugins.services.chanquery.ChanQueryService|ChanQueryService] to query
    channels for full lists of users upon joining new ones, including the
    ones we join upon connecting. Elsewise, a completely silent user will never
    be recorded as having been seen, as they would never be triggering any of
    the functions we define to listen to. (There's a setting to ignore non-chatty
    events, as we'll see later.)

    kameloso does primarily not use callbacks, but instead annotates functions
    with `UDA`s of IRC event *types*. When an event is incoming it will trigger
    the function(s) annotated with its type.

    Callback delegates and [core.thread.fiber.Fiber|Fiber]s *are* supported, however.
    Event handlers can be annotated to be called from with in a fiber, and other
    fibers and delegates can be manually registered to process on incoming events,
    alternatively scheduled to a point in time with a reasonably high degree of precision.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#seen,
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.seen;

// We only want to compile this file if we want the plugin built.
version(WithSeenPlugin):

// For when we want to limit some functionality to debug builds.
debug version = Debug;

// We need the definition of an [kameloso.plugins.IRCPlugin|IRCPlugin] and other crucial things.
// We also need the bits to register the plugin to be automatically instantiated.
private import kameloso.plugins;

// Awareness mixins, for plumbing.
private import kameloso.plugins.common.mixins.awareness;

// [kameloso.common] for the global logger instance.
private import kameloso.common : logger;

// Some thread boxing helpers.
private import kameloso.thread : Sendable;

// [dialect.defs], for the definitions of an IRC event.
private import dialect.defs;

// [lu.container] for the rehashing associative array wrapper.
private import lu.container : RehashingAA;


version(OmniscientSeen)
{
    // omniscientChannelPolicy
    /++
        The [kameloso.plugins.ChannelPolicy|ChannelPolicy] annotation dictates
        whether or not an annotated function should be called based on the *channel*
        the event took place in, if applicable.

        The three policies are
        [kameloso.plugins.ChannelPolicy.home|ChannelPolicy.home],
        with which only events in channels in the
        [kameloso.pods.IRCBot.homeChannels|IRCBot.homeChannels]
        array will be allowed to trigger it;
        [kameloso.plugins.ChannelPolicy.guest|ChannelPolicy.guest]
        with which only events outside of such home channels will be allowed to trigger;
        or [kameloso.plugins.ChannelPolicy.any|ChannelPolicy.any],
        in which case anywhere goes.

        For events that don't correspond to a channel (such as a private message
        [dialect.defs.IRCEvent.Type.QUERY|QUERY]) the setting doesn't apply and is ignored.

        Thus this [omniscientChannelPolicy] enum constant is a compile-time setting
        for all event handlers where whether a channel is a home or not is of
        interest (or even applies). Put in a version block like this it allows
        us to control the plugin's behaviour via `dub` build configurations.
     +/
    private enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    /// Ditto
    private enum omniscientChannelPolicy = ChannelPolicy.home;
}


/++
    [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness] is a mixin
    template; it proxies to a few functions defined in [kameloso.plugins.common.mixins.awareness]
    to deal with common book-keeping that every plugin *that wants to keep track
    of users* need. If you don't want to track which users you have seen (and are
    visible to you now), you don't need this.

    Additionally it implicitly mixes in
    [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication],
    needed as soon as you have any [kameloso.plugins.PrefixPolicy|PrefixPolicy] checks.
 +/
mixin UserAwareness;


/++
    Complementary to [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness] is
    [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness], which
    will add in book-keeping about the channels the bot is in, their topics, modes,
    and list of participants. Channel awareness requires user awareness, but not
    the other way around.

    Depending on the value of [omniscientChannelPolicy] we may want it to limit
    the amount of tracked users to people in our home channels.
 +/
mixin ChannelAwareness!omniscientChannelPolicy;


/++
    Mixes in a module constructor that registers this module's plugin to be
    instantiated as part of the program running.
 +/
mixin PluginRegistration!SeenPlugin;


/+
    Most of the module can (and ideally should) be kept private. Our surface
    area here will be restricted to only one [kameloso.plugins.IRCPlugin|IRCPlugin]
    class, and the usual pattern used is to have the private bits first and that
    public class last. We'll turn that around here to make it easier to visually parse.
 +/

public:


// SeenPlugin
/++
    This is your plugin to the outside world, usually the only thing publicly visible in the
    entire module. It only serves as a way of proxying calls to our top-level
    private functions, as well as to house plugin-specific and -private variables that we want
    to keep out of top-level scope for the sake of modularity. If the only state
    is in the plugin, several plugins of the same kind can technically be run
    alongside each other, which would allow for several bots to be run in
    parallel. This is not yet supported but there's fundamentally nothing stopping it.

    As such it houses this plugin's *state*, notably its instance of
    [SeenSettings] and its [kameloso.plugins.IRCPluginState|IRCPluginState].

    The [kameloso.plugins.IRCPluginState|IRCPluginState] is a struct housing various
    variables that together make up the plugin's state. This is additionally where
    information is kept about the bot, the server, and some other meta-things
    about the program.

    We don't declare it here; we will mix it in later with the
    [kameloso.plugins.IRCPluginImpl|IRCPluginImpl] mixin.

    ---
    struct IRCPluginState
    {
        IRCClient client;
        IRCServer server;
        IRCBot bot;
        CoreSettings coreSettings;
        ConnectionSettings connSettings;
        IRCUser[string] users;
        IRCChannel[string] channels;
        Replay[][string] pendingReplays;
        bool hasPendingReplays;
        Replay[] readyReplays;
        Fiber[][] awaitingFibers;
        void delegate(IRCEvent)[][] awaitingDelegates;
        ScheduledFiber[] scheduledFibers;
        ScheduledDelegate[] scheduledDelegates;
        Update updates;
        bool* abort;
        DeferredAction[] deferredActions;
        ThreadMessage[] messages;
        ThreadMessage[] priorityMessages;
        Message[] outgoingMessages;
    }
    ---

    * [kameloso.plugins.IRCPluginState.client|IRCPluginState.client]
    houses information about the client itself, such as your nickname and
    other things related to an IRC client.

    * [kameloso.plugins.IRCPluginState.server|IRCPluginState.server]
    houses information about the server you're connected to.

    * [kameloso.plugins.IRCPluginState.bot|IRCPluginState.bot] houses
    information about things that relate to an IRC bot, like which channels
    to join, which home channels to operate in, the list of administrator accounts, etc.

    * [kameloso.plugins.IRCPluginState.coreSettings|IRCPluginState.coreSettings]
    is a copy of the "global" [kameloso.pods.CoreSettings|CoreSettings],
    which contains information about how the bot should output text, whether
    or not to always save to disk upon program exit, and some other program-wide settings.

    * [kameloso.plugins.IRCPluginState.connSettings|IRCPluginState.connSettings]
    is like [kameloso.plugins.IRCPluginState.coreSettings|IRCPluginState.coreSettings],
    except for values relating to the connection to the server; whether to
    use IPv6, paths to any certificates, and the such.

    * [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    is an associative array keyed with users' nicknames. The value to that key is an
    [dialect.defs.IRCUser|IRCUser] representing that user in terms of nickname,
    address, ident, services account name, and much more. This is a way to keep track of
    users by more than merely their name. It is however not saved at the end
    of the program; as everything else it is merely state and transient.

    * [kameloso.plugins.IRCPluginState.channels|IRCPluginState.channels]
    is another associative array, this one with all the known channels keyed
    by their names. This way we can access detailed information about any
    known channel, given only their name.

    * [kameloso.plugins.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays]
    is also an associative array into which we place [kameloso.plugins.Replay|Replay]s.
    The main loop will pick up on these and call WHOIS on the nickname in the key.
    A [kameloso.plugins.Replay|Replay] is otherwise just an
    [dialect.defs.IRCEvent|IRCEvent] to be played back when the WHOIS results
    return, as well as a delegate that invokes the function that was originally
    to be called. Constructing a [kameloso.plugins.Replay|Replay] is
    all wrapped in a function [kameloso.plugins.enqueue|enqueue], with the
    queue management handled behind the scenes.

    * [kameloso.plugins.IRCPluginState.hasPendingReplays|IRCPluginState.hasPendingReplays]
    is merely a bool of whether or not there currently are any
    [kameloso.plugins.Replay|Replay]s in
    [kameloso.plugins.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays],
    cached to avoid associative array length lookups.

    * [kameloso.plugins.IRCPluginState.readyReplays|IRCPluginState.readyReplays]
    is an array of [kameloso.plugins.Replay|Replay]s that have
    seen their WHOIS request issued and the result received. Moving one from
    [kameloso.plugins.IRCPluginState.pendingReplays|IRCPluginState.pendingReplays]
    to [kameloso.plugins.IRCPluginState.readyReplays|IRCPluginState.readyReplays]
    will make the main loop pick it up, *update* the [dialect.defs.IRCEvent|IRCEvent]
    stored within it with what we now know of the sender and/or target, and
    then replay the event by invoking its delegate.

    * [kameloso.plugins.IRCPluginState.awaitingFibers|IRCPluginState.awaitingFibers]
    is an array of [core.thread.fiber.Fiber|Fiber]s indexed by [dialect.defs.IRCEvent.Type]s'
    numeric values. Fibers in the array of a particular event type will be
    executed the next time such an event is incoming. Think of it as fiber callbacks.

    * [kameloso.plugins.IRCPluginState.awaitingDelegates|IRCPluginState.awaitingDelegates]
    is literally an array of callback delegates, to be triggered when an event
    of a matching type comes along.

    * [kameloso.plugins.IRCPluginState.scheduledFibers|IRCPluginState.scheduledFibers]
    is also an array of [core.thread.fiber.Fiber|Fiber]s, but not one keyed
    on or indexed by event types. Instead they are tuples of a
    [core.thread.fiber.Fiber|Fiber] and a `long` timestamp of when they should be run.
    Use [kameloso.plugins.common.scheduling.delay|delay] to enqueue.

    * [kameloso.plugins.IRCPluginState.scheduledDelegates|IRCPluginState.scheduledDelegates]
    is likewise an array of delegates, to be triggered at a later point in time.

    * [kameloso.plugins.IRCPluginState.updates|IRCPluginState.updates]
    is a bitfield which represents what aspect of the bot was *changed*
    during processing or postprocessing. If any of the bits are set, represented
    by the enum values of [kameloso.plugins.IRCPluginState.Updates|IRCPluginState.Updates],
    the main loop will pick up on it and propagate it to other plugins.
    If these flags are not set, changes will never leave the plugin and may
    be overwritten by other plugins. It is mostly for internal use.

    * [kameloso.plugins.IRCPluginState.abort|IRCPluginState.abort]
    is a pointer to the global abort flag. When this is set, it signals the
    rest of the program that we want to terminate cleanly.

    * [kameloso.plugins.IRCPluginState.deferredActions|IRCPluginState.deferredActions]
    is an array of [kameloso.plugins.DeferredAction|DeferredAction]s;
    a way to defer the execution of a delegate or fiber to the main event loop,
    to be invoked with context only it has, such as knowledge of all plugins.

    * [kameloso.plugins.IRCPluginState.messages|IRCPluginState.messages]
    is an array of [kameloso.thread.ThreadMessage|ThreadMessage]s, used by
    plugins to send messages up the stack to the main event loop. These can
    signal anything from "save configuration to file" to "quit the program".

    * [kameloso.plugins.IRCPluginState.priorityMessages|IRCPluginState.priorityMessages]
    is likewise an array of [kameloso.thread.ThreadMessage|ThreadMessage]s, but
    these will always be processed before those in
    [kameloso.plugins.IRCPluginState.messages|IRCPluginState.messages] are.

    * [kameloso.plugins.IRCPluginState.outgoingMessages|IRCPluginState.outgoingMessages]
    is an array of [kameloso.messaging.Message|Message]s bound to be sent to the server.
 +/
final class SeenPlugin : IRCPlugin
{
private:  // Module-level private.
    import core.time : hours;

    // settings
    /++
        An instance of *settings* for the Seen plugin. We will define these
        below. The members of it will be saved to and loaded from the
        configuration file, for use in our module.
     +/
    SeenSettings settings;


    // seenUsers
    /++
        Our associative array (AA) of seen users; a dictionary keyed with
        users' nicknames and with values that are UNIX timestamps, denoting when
        that user was last *seen* online.

        A [lu.container.RehashingAA|RehashingAA] is used instead of a native
        `long[string]`, merely to be able to ensure a constant level of rehashed-ness.

        Example:
        ---
        seenUsers["joe"] = Clock.currTime.toUnixTime();
        // ..later..
        immutable nowInUnix = Clock.currTime.toUnixTime();
        writeln("Seconds since we last saw joe: ", (nowInUnix - seenUsers["joe"]));
        ---
     +/
    RehashingAA!(long[string]) seenUsers;


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
        The amount of time after which seen users should be saved to disk.
     +/
    static immutable timeBetweenSaves = 1.hours;


    // IRCPluginImpl
    /++
        This mixes in functions that fully implement an
        [kameloso.plugins.IRCPlugin|IRCPlugin]. They don't do much by themselves
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
        [kameloso.messaging] functions, *partially applied* with the plugin's
        [kameloso.plugins.IRCPluginState|IRCPluginState] instance,
        so they can easily be called with knowledge only of the plugin symbol.

        ---
        plugin.chan("#d", "Hello world!");
        plugin.query("kameloso", "Hello you!");

        with (plugin)
        {
            chan("#d", "This is convenient");
            query("kameloso", "No need to specify plugin.state");
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

    If it's annotated with [kameloso.plugins.Settings|Settings], the
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
        The @[kameloso.plugins.Enabler|Enabler] annotation makes it special and
        lets us easily enable or disable the plugin without having checks everywhere.
     +/
    @Enabler bool enabled = true;

    /++
        Toggles whether or not non-chat events, such as
        [dialect.defs.IRCEvent.Type.JOIN|JOIN]s,
        [dialect.defs.IRCEvent.Type.PART|PART]s and the such, should be considered
        as observations. If set, only chatty events will count as being seen.
     +/
    bool ignoreNonChatEvents = false;
}


// onSomeAction
/++
    Whenever a user does something, record this user as having been seen at the
    current time.

    This function will be called whenever an [dialect.defs.IRCEvent|IRCEvent] is
    being processed of the [dialect.defs.IRCEvent.Type|IRCEvent.Type]s that we annotate
    the function with.

    The [kameloso.plugins.IRCEventHandler.chainable|IRCEventHandler.chainable]
    annotations mean that the plugin will also process other functions in this
    module with the same [dialect.defs.IRCEvent.Type|IRCEvent.Type] annotations,
    even if this one matched. The default is otherwise that it will end early
    after one match and proceed to the next plugin, but this doesn't ring well
    with catch-all functions like these. It's sensible to save
    [kameloso.plugins.IRCEventHandler.chainable|IRCEventHandler.chainable]
    only for the modules and functions that actually need it.

    The [kameloso.plugins.IRCEventHandler.requiredPermissions|IRCEventHandler.requiredPermissions]
    annotation dictates who is authorised to trigger the function. It has six
    policies, in increasing order of importance:
    [kameloso.plugins.Permissions.ignore|Permissions.ignore],
    [kameloso.plugins.Permissions.anyone|Permissions.anyone],
    [kameloso.plugins.Permissions.registered|Permissions.registered],
    [kameloso.plugins.Permissions.whitelist|Permissions.whitelist],
    [kameloso.plugins.Permissions.elevated|Permissions.elevated],
    [kameloso.plugins.Permissions.operator|Permissions.operator],
    [kameloso.plugins.Permissions.staff|Permissions.staff] and
    [kameloso.plugins.Permissions.admin|Permissions.admin].

    * [kameloso.plugins.Permissions.ignore|Permissions.ignore] will
        let precisely anyone trigger it, without looking them up. It just doesn't care.

    * [kameloso.plugins.Permissions.anyone|Permissions.anyone] will
        let anyone trigger it, but only after having looked them up, allowing
        for blacklisting people.

    * [kameloso.plugins.Permissions.registered|Permissions.registered]
        will let anyone logged into a services account trigger it, provided they
        are not blacklisted.

    * [kameloso.plugins.Permissions.whitelist|Permissions.whitelist]
        will only allow users in the whitelist section of the `users.json`
        resource file, provided they are also not blacklisted. Consider this to
        correspond to "regulars" in the channel.

    * [kameloso.plugins.Permissions.elevated|Permissions.elevated]
        will also only allow users in the whitelist section of the `users.json`
        resource file, provided they are also not blacklisted. Consider this to
        correspond to VIPs in the channel.

    * [kameloso.plugins.Permissions.operator|Permissions.operator]
        will only allow users in the operator section of the `users.json`
        resource file. Consider this to correspond to "moderators" in the channel.

    * [kameloso.plugins.Permissions.staff|Permissions.staff] will
        only allow users in the staff section of the `users.json` resource file.
        Consider this to correspond to channel owners.

    * [kameloso.plugins.Permissions.admin|Permissions.admin] will
        allow only you and your other superuser administrators, as defined in
        the configuration file. This is a program-wide permission and will apply
        to all channels. Consider it to correspond to bot system operators.

    In the case of
    [kameloso.plugins.Permissions.whitelist|Permissions.whitelist],
    [kameloso.plugins.Permissions.elevated|Permissions.elevated],
    [kameloso.plugins.Permissions.operator|Permissions.operator],
    [kameloso.plugins.Permissions.staff|Permissions.staff] and
    [kameloso.plugins.Permissions.admin|Permissions.admin] it will
    look you up and compare your *services account name* to those known good
    before doing anything. In the case of
    [kameloso.plugins.Permissions.registered|Permissions.registered],
    merely being logged in is enough. In the case of
    [kameloso.plugins.Permissions.anyone|Permissions.anyone], the
    WHOIS results won't matter and it will just let it pass, but it will check
    all the same so as to be able to apply the blacklist.
    In the other cases, if you aren't logged into services or if your account
    name isn't included in the lists, the function will not trigger.

    This particular function doesn't care at all, so it is
    [kameloso.plugins.Permissions.ignore|Permissions.ignore].

    The [kameloso.plugins.ChannelPolicy|ChannelPolicy] here is the same
    [omniscientChannelPolicy] we defined earlier, versioned to have a different
    value based on the dub build configuration. By default, it's
    [kameloso.plugins.ChannelPolicy.home|ChannelPolicy.home].
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .onEvent(IRCEvent.Type.QUERY)
    .onEvent(IRCEvent.Type.EMOTE)
    .onEvent(IRCEvent.Type.JOIN)
    .onEvent(IRCEvent.Type.PART)
    .onEvent(IRCEvent.Type.MODE)
    .onEvent(IRCEvent.Type.TWITCH_SUB)
    .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
    .onEvent(IRCEvent.Type.TWITCH_CHEER)
    .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
    .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
    .onEvent(IRCEvent.Type.TWITCH_BULKGIFT)
    .onEvent(IRCEvent.Type.TWITCH_SUBUPGRADE)
    .onEvent(IRCEvent.Type.TWITCH_CHARITY)
    .onEvent(IRCEvent.Type.TWITCH_BITSBADGETIER)
    .onEvent(IRCEvent.Type.TWITCH_RITUAL)
    .onEvent(IRCEvent.Type.TWITCH_EXTENDSUB)
    .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
    .onEvent(IRCEvent.Type.TWITCH_RAID)
    .onEvent(IRCEvent.Type.TWITCH_CROWDCHANT)
    .onEvent(IRCEvent.Type.TWITCH_ANNOUNCEMENT)
    .onEvent(IRCEvent.Type.TWITCH_DIRECTCHEER)
    .onEvent(IRCEvent.Type.TWITCH_INTRO)
    .onEvent(IRCEvent.Type.TWITCH_MILESTONE)
    .permissionsRequired(Permissions.ignore)
    .channelPolicy(omniscientChannelPolicy)
    .chainable(true)
)
void onSomeAction(SeenPlugin plugin, const IRCEvent event)
{
    /+
        Updates the user's timestamp to the current time, both sender and target.

        This will be automatically called on any and all the kinds of
        [dialect.defs.IRCEvent.Type|IRCEvent.Type]s it is annotated with.

        Whether it will be triggered is determined by the value of
        [omniscientChannelPolicy]; in other words, in home channels unless version
        `OmniscientSeen` was declared.

        There's no need to check for whether the sender/target is us, as
        [updateUser] will do it more thoroughly (by stripping any extra modesigns).

        Don't count non-chatty events if the settings say to ignore them.
     +/

    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    bool skipTarget;

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
        case TWITCH_SUB:
        case TWITCH_CHEER:
        case TWITCH_SUBUPGRADE:
        case TWITCH_CHARITY:
        case TWITCH_BITSBADGETIER:
        case TWITCH_RITUAL:
        case TWITCH_EXTENDSUB:
        case TWITCH_RAID:
        case TWITCH_CROWDCHANT:
        case TWITCH_ANNOUNCEMENT:
        case TWITCH_DIRECTCHEER:
            // Consider these as chatty events too
            break;

        case TWITCH_SUBGIFT:
        case TWITCH_REWARDGIFT:
        case TWITCH_GIFTCHAIN:
        case TWITCH_BULKGIFT:
        case TWITCH_GIFTRECEIVED:
        case TWITCH_PAYFORWARD:
            // These carry targets that should not be counted as having showed activity
            skipTarget = true;
            break;

        case JOIN:
        case PART:
            // Ignore Twitch JOINs and PARTs
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch) return;
            goto default;
    }

    //case MODE:
    default:
        if (plugin.settings.ignoreNonChatEvents) return;
        // Drop down
        break;
    }

    // Only count either the sender or the target, never both at the same time
    // This to stop it from updating seen time when someone is the target of e.g. a sub gift
    if (event.sender.nickname)
    {
        updateUser(plugin, event.sender.nickname, event.time);
    }
    else if (!skipTarget && event.target.nickname)
    {
        updateUser(plugin, event.target.nickname, event.time);
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
void onQuit(SeenPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (auto seenTimestamp = event.sender.nickname in plugin.seenUsers)
    {
        *seenTimestamp = event.time;
    }
}


// onNick
/++
    When someone changes nickname, update their entry in the array.

    For now, don't remove old entries. Revisit this decision later.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.NICK)
    .permissionsRequired(Permissions.ignore)
    .chainable(true)
)
void onNick(SeenPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    if (event.sender.class_ == IRCUser.Class.blacklist) return;

    updateUser(plugin, event.target.nickname, event.time, skipModesignStrip: true);
}


// onWHOReply
/++
    Catches each user listed in a WHO reply and updates their entries in the
    seen users list, creating them if they don't exist.

    A WHO request enumerates all members in a channel. It returns several
    replies, one event per each user in the channel. The
    [kameloso.plugins.services.chanquery.ChanQueryService|ChanQueryService] services
    instigates this shortly after having joined one, as a service to other plugins.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
    .channelPolicy(omniscientChannelPolicy)
)
void onWHOReply(SeenPlugin plugin, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);

    updateUser(plugin, event.target.nickname, event.time);
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
void onNamesReply(SeenPlugin plugin, const IRCEvent event)
{
    import std.algorithm.iteration : splitter;

    mixin(memoryCorruptionCheck);

    version(TwitchSupport)
    {
        // Don't trust NAMES on Twitch.
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch) return;
    }

    foreach (immutable entry; event.content.splitter(' '))
    {
        import dialect.common : stripModesign;
        import lu.string : advancePast;

        string slice = entry;  // mutable
        slice = slice.advancePast('!', inherit: true); // In case SpotChat-like, full nick!ident@address form
        slice = slice.stripModesign(plugin.state.server);
        updateUser(plugin, slice, event.time);
    }
}


// onCommandSeen
/++
    Whenever someone says "!seen" in a [dialect.defs.IRCEvent.Type.CHAN|CHAN] or
    a [dialect.defs.IRCEvent.Type.QUERY|QUERY], and if
    [dialect.defs.IRCEvent.Type.CHAN|CHAN] then only if in a *home*, this function triggers.

    The [kameloso.plugins.IRCEventHandler.Command.word|IRCEventHandler.Command.word]
    annotation defines a piece of text that the incoming message must start with
    for this function to be called.
    [kameloso.plugins.IRCEventHandler.Command.policy|IRCEventHandler.Command.policy]
    deals with whether the message has to start with the name of the *bot* or not,
    and to what extent.

    Prefix policies can be one of:

    * [kameloso.plugins.PrefixPolicy.direct|PrefixPolicy.direct],
        where the raw command is expected without any message prefix at all;
        the command is simply that string: "`seen`".

    * [kameloso.plugins.PrefixPolicy.prefixed|PrefixPolicy.prefixed],
        where the message has to start with the command *prefix* character
        or string (usually `!` or `.`): "`!seen`".

    * [kameloso.plugins.PrefixPolicy.nickname|PrefixPolicy.nickname],
        where the message has to start with bot's nickname:
        "`kameloso: seen`" -- except if it's in a [dialect.defs.IRCEvent.Type.QUERY|QUERY] message.

    The plugin system will have made certain we only get messages starting with
    "`seen`", since we annotated this function with such a
    [kameloso.plugins.IRCEventHandler.Command|IRCEventHandler.Command].
    It will since have been sliced off, so we're left only with the "arguments"
    to "`seen`". [dialect.defs.IRCEvent.aux|IRCEvent.aux[$-1]] contains the triggering
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
    event.channel.name = "#bar";
    event.content = "Joe";
    event.aux[$-1] = "seen";
    ---

    Lastly, the
    [kameloso.plugins.IRCEventHandler.Command.description|IRCEventHandler.Command.description]
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
            .addSyntax("$command [nickname]")
    )
    .addCommand(
        IRCEventHandler.Command()
            .word("lastseen")
            .policy(PrefixPolicy.prefixed)
            .hidden(true)
    )
)
void onCommandSeen(SeenPlugin plugin, const IRCEvent event)
{
    import kameloso.time : timeSince;
    import dialect.common : isValidNickname;
    import std.algorithm.searching : canFind, startsWith;
    import std.datetime.systime : SysTime;
    import std.format : format;

    /+
        The bot uses an array of messages to queue strings to be sent to the
        server.

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
            privmsg(event.channel.name, event.sender.nickname, "Query or chan!");
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

    mixin(memoryCorruptionCheck);

    immutable requestedUser = event.content.startsWith('@') ?
        event.content[1..$] :
        event.content;

    with (plugin)
    {
        if (!requestedUser.length)
        {
            enum pattern = "Usage: <b>%s%s<b> [nickname]";
            immutable message = pattern.format(plugin.state.coreSettings.prefix, event.aux[$-1]);
            return privmsg(event.channel.name, event.sender.nickname, message);
        }
        else if (!requestedUser.isValidNickname(plugin.state.server))
        {
            // Nickname contained a space or other invalid character
            immutable message = "Invalid user: <h>" ~ requestedUser ~ "<h>";
            return privmsg(event.channel.name, event.sender.nickname, message);
        }
        else if (requestedUser == state.client.nickname)
        {
            // The requested nick is the bot's.
            enum message = "T-that's me though...";
            return privmsg(event.channel.name, event.sender.nickname, message);
        }
        else if (requestedUser == event.sender.nickname)
        {
            // The person is asking for seen information about him-/herself.
            enum message = "That's you!";
            return privmsg(event.channel.name, event.sender.nickname, message);
        }

        foreach (const channel; state.channels)
        {
            if (requestedUser in channel.users)
            {
                immutable pattern = (event.channel.name.length && (event.channel.name == channel.name)) ?
                    "<h>%s<h> is here right now!" :
                    "<h>%s<h> is online right now.";
                immutable message = pattern.format(requestedUser);
                return privmsg(event.channel.name, event.sender.nickname, message);
            }
        }

        if (const userTimestamp = requestedUser in seenUsers)
        {
            import std.datetime.systime : Clock;

            enum pattern =  "I last saw <h>%s<h> %s ago.";

            immutable timestamp = SysTime.fromUnixTime(*userTimestamp);
            immutable diff = (Clock.currTime - timestamp);
            immutable elapsed = timeSince!(7, 2)(diff);
            immutable message = pattern.format(requestedUser, elapsed);
            privmsg(event.channel.name, event.sender.nickname, message);
        }
        else
        {
            // No matches for nickname `event.content` in `plugin.seenUsers`.
            enum pattern = "I have never seen <h>%s<h>.";
            immutable message = pattern.format(requestedUser);
            privmsg(event.channel.name, event.sender.nickname, message);
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
    long nowInUnix = Clock.currTime.toUnixTime();
    updateUser(plugin, potentiallySignedNickname, nowInUnix);
    ---

    Params:
        plugin = Current [SeenPlugin].
        signed = Nickname to update, potentially prefixed with one or more modesigns
            (`@`, `+`, `%`, ...).
        time = UNIX timestamp of when the user was seen.
        skipModesignStrip = Whether or not to explicitly not strip modesigns from the nickname.
 +/
void updateUser(
    SeenPlugin plugin,
    const string signed,
    const long time,
    const bool skipModesignStrip = false)
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
    import std.datetime.systime : Clock;

    bool[string] uniqueUsers;

    foreach (immutable channelName, const channel; plugin.state.channels)
    {
        foreach (const nickname; channel.users.byKey)
        {
            uniqueUsers[nickname] = true;
        }
    }

    immutable nowInUnix = Clock.currTime.toUnixTime();

    foreach (immutable nickname; uniqueUsers.byKey)
    {
        updateUser(plugin, nickname, nowInUnix, skipModesignStrip: true);
    }
}


// loadSeen
/++
    Given a filename, read the contents and load it into a `RehashingAA!(long[string])`
    associative array, then returns it. If there was no file there to read,
    return an empty array for a fresh start.

    Params:
        plugin = The current [SeenPlugin].
 +/
void loadSeen(SeenPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import std.file : readText;
    import std.stdio : File, writeln;

    immutable content = plugin.seenFile.readText.strippedRight;

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    plugin.seenUsers = content.deserialize!(long[string]);
    // No need to rehash the AA; RehashingAA will do it on assignment
}


// saveSeen
/++
    Save the passed seen users associative array to disk, in JSON format.

    This is a convenient way to serialise the array.

    Params:
        plugin = The current [SeenPlugin].
 +/
void saveSeen(SeenPlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : File;

    if (!plugin.seenUsers.length) return;

    immutable serialised = JSONValue(plugin.seenUsers.aaOf).toPrettyString;
    File(plugin.seenFile, "w").writeln(serialised);
}


// onWelcome
/++
    After we have registered on the server and seen the welcome messages, load
    our seen users from file. Additionally set up a fiber that periodically
    saves seen users to disk once every [SeenPlugin.timeBetweenSaves|timeBetweenSaves]
    seconds.

    This is to make sure that as little data as possible is lost in the event
    of an unexpected shutdown while still not hammering the disk.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(SeenPlugin plugin, const IRCEvent _)
{
    import kameloso.plugins.common.scheduling : await, delay;
    import kameloso.constants : BufferSize;
    import core.thread.fiber : Fiber;

    mixin(memoryCorruptionCheck);

    loadSeen(plugin);

    void saveDg()
    {
        while (true)
        {
            updateAllObservedUsers(plugin);
            saveSeen(plugin);
            delay(plugin, plugin.timeBetweenSaves, yield: true);
        }
    }

    auto saveFiber = new Fiber(&saveDg, BufferSize.fiberStack);
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
        import kameloso.plugins.common.scheduling : unawait;
        import lu.string : plurality;

        unawait(plugin, &endOfMotdDg, endOfMotdEventTypes[]);

        // Reports statistics on how many users are registered as having been seen
        enum pattern = "Currently <i>%,d</> %s seen.";
        immutable noun = plugin.seenUsers.length.plurality("user", "users");
        logger.logf(pattern, plugin.seenUsers.length, noun);
    }

    await(plugin, &endOfMotdDg, endOfMotdEventTypes[]);
}


// reload
/++
    Reloads seen users from disk.
 +/
void reload(SeenPlugin plugin)
{
    loadSeen(plugin);
}


// teardown
/++
    When closing the program or when crashing with grace, save the seen users
    array to disk for later reloading.
 +/
void teardown(SeenPlugin plugin)
{
    updateAllObservedUsers(plugin);
    saveSeen(plugin);
}


// initResources
/++
    Read and write the file of seen people to disk, ensuring that it's there.
 +/
void initResources(SeenPlugin plugin)
{
    import lu.string : strippedRight;
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = plugin.seenFile.readText.strippedRight;

    if (!content.length)
    {
        File(plugin.seenFile, "w").writeln("{}");
        return;
    }

    version(PrintStacktraces)
    {
        scope(failure)
        {
            import std.json : parseJSON;
            import std.stdio : writeln;

            writeln(content);
            try writeln(content.parseJSON.toPrettyString);
            catch (Exception _) {}
        }
    }

    try
    {
        const deserialised = content.deserialize!(long[string]);
        immutable serialised = JSONValue(deserialised).toPrettyString;
        File(plugin.seenFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Seen file is malformed",
            pluginName: plugin.name,
            malformedFilename: plugin.seenFile);
    }
}


/+
    Only some plugins benefit from this one implementing `onBusMessage`, so omit
    it if they aren't available.
 +/
version(WithPipelinePlugin)
{
    version = ShouldImplementOnBusMessage;
}
else version(WithAdminPlugin)
{
    version = ShouldImplementOnBusMessage;
}


// onBusMessage
/++
    Receive a passed [kameloso.thread.Boxed|Boxed] instance with the "`seen`" header,
    and calls functions based on the payload message.

    This is used in the Pipeline plugin, to allow us to trigger seen verbs via
    the command-line pipe, as well as in the Admin plugin for remote control
    over IRC.

    Params:
        plugin = The current [SeenPlugin].
        header = String header describing the passed content payload.
        content = Boxed message content.
 +/
version(Debug)
version(ShouldImplementOnBusMessage)
void onBusMessage(SeenPlugin plugin, const string header, /*shared*/ Sendable content)
{
    import kameloso.thread : Boxed;

    if (!plugin.isEnabled) return;
    if (header != "seen") return;

    const message = cast(Boxed!string) content;

    if (!message)
    {
        enum pattern = "The <l>%s</> plugin received an invalid bus message: expected type <l>%s";
        logger.errorf(pattern, plugin.name, typeof(message).stringof);
        return;
    }

    immutable verb = message.payload;

    switch (verb)
    {
    case "save":
        updateAllObservedUsers(plugin);
        saveSeen(plugin);
        logger.info("Seen users saved to disk.");
        break;

    default:
        enum pattern = "[seen] Unimplemented bus message verb: <l>%s";
        logger.errorf(pattern, verb);
        break;
    }
}


// selftest
/++
    Performs self-tests against another bot.

    This is just a small test suite to make sure the plugin works as intended.
 +/
version(Selftests)
auto selftest(SeenPlugin _, Selftester s)
{
    s.send("!seen");
    s.expect("Usage: !seen [nickname]");

    s.send("!seen ####");
    s.expect("Invalid user: ####");

    s.send("!seen HarblSnarbl");
    s.expect("I have never seen HarblSnarbl.");

    s.send("!seen ${bot}");
    s.expect("That's you!");

    s.send("!seen ${target}");
    s.expect("T-that's me though...");

    return true;
}


/+
    This full plugin is <250 source lines of code. (`dscanner --sloc seen.d`)
    Even at those numbers it is fairly feature-rich.
 +/

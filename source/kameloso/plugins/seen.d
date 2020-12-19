/++
    The Seen plugin implements "seen" functionality; the ability for someone to
    query when a given nickname was last seen online.

    We will implement this by keeping an internal `long[string]` associative
    array of timestamps keyed by nickname. Whenever we see a user do something,
    we will update his or her timestamp to the current time. We'll save this
    array to disk when closing the program and read it from file when starting
    it, as well as saving occasionally once every few (configurable) hours.

    We will rely on the `kameloso.plugins.chanqueries.ChanQueriesService` to query
    channels for full lists of users upon joining new ones, including the
    ones we join upon connecting. Elsewise, a completely silent user will never
    be recorded as having been seen, as they would never be triggering any of
    the functions we define to listen to.

    kameloso does primarily not use callbacks, but instead annotates functions
    with `UDA`s of IRC event *types*. When an event is incoming it will trigger
    the function(s) annotated with its type.

    Callback delegates and [core.thread.fiber.Fiber]s *are* supported. They can
    be registered to process on incoming events, or scheduled with a reasonably
    high degree of precision.

    See_Also:
        https://github.com/zorael/kameloso/wiki/Current-plugins#seen
 +/
module kameloso.plugins.seen;

// We only want to compile this if we're compiling plugins at all.
version(WithPlugins):

// ...and also if compiling in specifically this plugin.
version(WithSeenPlugin):

// We need the definition of an [kameloso.plugin.core.IRCPlugin] and other crucial things.
private import kameloso.plugins.common.core;

// Awareness mixins, for plumbing.
private import kameloso.plugins.common.awareness : ChannelAwareness, UserAwareness;

// Likewise [dialect.defs], for the definitions of an IRC event.
private import dialect.defs;

// [kameloso.irccolours] for some IRC colouring and formatting.
private import kameloso.irccolours : ircBold, ircColourByHash;

// [kameloso.common] for some globals.
private import kameloso.common : Tint, logger;

// [std.datetime.systime] for the [std.datetime.systime.Clock], to update times with.
private import std.datetime.systime : Clock;

// [std.typecons] for [std.typecons.Flag] and its friends.
private import std.typecons : Flag, No, Yes;


/+
    Most of the module can (and ideally should) be kept private. Our surface
    area here will be restricted to only one [kameloso.plugins.common.core.IRCPlugin]
    class, and the usual pattern used is to have the private bits first and that
    public class last. We'll turn that around here to make it easier to visually parse.
 +/

public:


// SeenPlugin
/++
    This is your plugin to the outside world, the only thing visible in the
    entire module. It only serves as a way of proxying calls to our top-level
    private functions, as well as to house plugin-private variables that we want
    to keep out of top-level scope for the sake of modularity. If the only state
    is in the plugin, several plugins of the same kind can technically be run
    alongside each other, which would allow for several bots to be run in
    parallel. This is not yet supported but there's nothing stopping it.

    As such it houses this plugin's *state*, notably its instance of
    [SeenSettings] and its [kameloso.plugins.common.core.IRCPluginState].

    The [kameloso.plugins.common.core.IRCPluginState] is a struct housing various
    variables that together make up the plugin's state. This is where
    information is kept about the bot, the server, and some metathings allowing
    us to send messages to the server. We don't define it here; we mix it in
    later with the [kameloso.plugins.common.core.IRCPluginImpl] mixin.

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
        Replay[][string] replays;
        bool hasReplays;
        Repeat[] repeats;
        Fiber[][] awaitingFibers;
        void delegate(const IRCEvent)[][] awaitingDelegates;
        ScheduledFiber[] scheduledFibers;  // `ScheduledFiber` is a struct in [kameloso.thread]
        ScheduledDelegate[] scheduledDelegates;  // Ditto
        long nextFiberTimestamp;
        void updateScheule();
        bool botUpdated;
        bool clientUpdated;
        bool serverUpdated;
        bool settingsUpdated;
        bool* abort;
    }
    ---

    * [kameloso.plugins.common.core.IRCPluginState.client] houses information about
        the client itself, such as your nickname and other things related to an
        IRC client.

    * [kameloso.plugins.common.core.IRCPluginState.server] houses information about
        the server you're connected to.

    * [kameloso.plugins.common.core.IRCPluginState.bot] houses information about
        things that relate to an IRC bot, like which channels to join, which
        home channels to operate in, the list of administrator accounts, etc.

    * [kameloso.plugins.common.core.IRCPluginState.settings] is a copy of the
        "global" [kameloso.kameloso.CoreSettings], which contains information
        about how the bot should output text, whether or not to always save to
        disk upon program exit, and some other program-wide settings.

    * [kameloso.plugins.common.core.IRCPluginState.connSettings] is like `settings`,
        except for values relating to the connection to the server; whether
        to use IPv6, paths to any certificates, and the such.

    * [kameloso.plugins.common.core.IRCPluginState.mainThread] is the *thread ID* of
        the thread running the main loop. We indirectly use it to send strings to
        the server by way of concurrency messages, but it is usually not something
        you will have to deal with directly.

    * [kameloso.plugins.common.core.IRCPluginState.users] is an associative array
        keyed with users' nicknames. The value to that key is an
        [dialect.defs.IRCUser] representing that user in terms of nickname,
        address, ident, and services account name. This is a way to keep track of
        users by more than merely their name. It is however not saved at the end
        of the program; it is merely state and transient.

    * [kameloso.plugins.common.core.IRCPluginState.channels] is another associative
        array, this one with all the known channels keyed by their names. This
        way we can access detailed information about any given channel, knowing
        only their name.

    * [kameloso.plugins.common.core.IRCPluginState.replays] is also an
        associative array into which we place [kameloso.plugins.common.core.Replay]s.
        The main loop will pick up on these and call WHOIS on the nickname in the key.
        A [kameloso.plugins.common.core.Replay] is otherwise just an
        [dialect.defs.IRCEvent] to be played back when the WHOIS results
        return, as well as a function pointer to call with that event. This is
        all wrapped in a function [kameloso.plugins.common.base.enqueue], with the
        queue management handled behind the scenes.

    * [kameloso.plugins.common.core.IRCPluginState.hasReplays] is merely a bool
        of whether or not there currently are any [kameloso.plugins.common.core.Replay]s
        in [kameloso.plugins.common.core.IRCPluginState.replays], cached to avoid
        associative array length lookups.

    * [kameloso.plugins.common.core.IRCPluginState.repeats] is an array of
        [kameloso.plugins.common.core.Repeat]s, which is instrumental in repeating
        events from the context of the main event loop. This allows us to update
        information in the event, such as details on its sender, before repeating
        it again. This can only be done outside of plugins.

    * [kameloso.plugins.common.core.IRCPluginState.awaitingFibers] is an associative
        array of [core.thread.fiber.Fiber]s keyed by [kameloso.ircdefs.IRCEvent.Type]s.
        Fibers in the array of a particular event type will be executed the next
        time such an event is incoming. Think of it as Fiber callbacks.

    * [kameloso.plugins.common.core.IRCPluginState.awaitingDelegates] is literally
        an array of callback delegates, to be triggered when an event of a
        matching type comes along.

    * [kameloso.plugins.common.core.IRCPluginState.scheduledFibers] is also an array of
        [core.thread.fiber.Fiber]s, but not an associative one keyed on event types.
        Instead they are tuples of a [core.thread.fiber.Fiber] and a `long`
        timestamp of when they should be run.
        Use [kameloso.plugins.common.delayFiber] to enqueue, or
        [kameloso.plugins.common.delayFiberMsecs] for greater granularity.

    * [kameloso.plugins.common.core.IRCPluginState.scheduledDelegates] is likewise an
        array of delegates, to be triggered at a later point in time.

    * [kameloso.plugins.common.core.IRCPluginState.nextScheduledTimestamp] is also a
        UNIX timestamp, here of when the next [kameloso.thread.ScheduledFiber] in
        [kameloso.plugins.common.core.IRCPluginState.scheduledFibers] *or* the next
        [kameloso.thread.ScheduledDelegate] in
        [kameloso.plugins.common.core.IRCPluginState.scheduledDelegates] is due to be
        processed. Caching it here means we won't have to go through the arrays
        to find out as often.

    * [kameloso.plugins.common.core.IRCPluginState.updateSchedule] merely iterates all
        scheduled fibers and delegates, caching the time at which the next one
        should trigger.

    * [kameloso.plugins.common.core.IRCPluginState.botUpdated] is set when
        [kameloso.plugins.common.core.IRCPluginState.bot] was updated during parsing
        and/or postprocessing. It is merely for internal use.

    * [kameloso.plugins.common.core.IRCPluginState.clientUpdated] is likewise set when
        [kameloso.plugins.common.core.IRCPluginState.client] was updated during parsing
        and/or postprocessing. Ditto.

    * [kameloso.plugins.common.core.IRCPluginState.serverUpdated] is likewise set when
        [kameloso.plugins.common.core.IRCPluginState.server] was updated during parsing
        and/or postprocessing. Ditto.

    * [kameloso.plugins.common.core.IRCPluginState.settingsUpdated] is likewise set when
        [kameloso.plugins.common.core.IRCPluginState.settings] was updated during parsing
        and/or postprocessing. Ditto.

    * [kameloso.plugins.common.core.IRCPluginState.abort] is a pointer to the global
        abort bool. When this is set, it signals the rest of the program that we
        want to terminate cleanly.
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
        Our associative array (AA) of seen users; the dictionary keyed with
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
        "`/home/user/.local/share/kameloso/servers/irc.freenode.net/seen.json`"
        after the plugin has been instantiated.
     +/
    @Resource string seenFile = "seen.json";


    // timeBetweenSaves
    /++
        The amount of seconds after which seen users should be saved to disk.
     +/
    enum timeBetweenSaves = 300;


    // IRCPluginImpl
    /++
        This mixes in functions that fully implement an
        [kameloso.plugins.common.core.IRCPlugin]. They don't do much by themselves
        other than call the module's functions.

        As an exception, it mixes in the bits needed to automatically call
        functions based on their [dialect.defs.IRCEvent.Type] annotations.
        It is mandatory if you want things to work, unless you're making a
        separate implementation yourself.

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

    If it's annotated with [kameloso.plugins.common.core.Settings], the wizardry will
    pick it up and each member of the struct will be given its own line in the
    configuration file. Note that not all types are supported, such as
    associative arrays or nested structs/classes.

    If the name ends with "Settings", that will be stripped from its section
    header in the file. Hence, this plugin's [SeenSettings] will get the header
    `[Seen]`.
 +/
@Settings struct SeenSettings
{
    /++
        Toggles whether or not the plugin should react to events at all.
        The @[kameloso.plugins.common.core.Enabler] annotation makes it special and
        lets us easily enable or disable it without having checks everywhere.
     +/
    @Enabler bool enabled = true;
}


// onSomeAction
/++
    Whenever a user does something, record this user as having been seen at the
    current time.

    This function will be called whenever an [dialect.defs.IRCEvent] is
    being processed of the [dialect.defs.IRCEvent.Type]s that we annotate
    the function with.

    The [kameloso.plugins.common.core.Chainable] annotations mean that the plugin
    will also process other functions in this module with the same
    [dialect.defs.IRCEvent.Type] annotations, even if this one matched. The
    default is otherwise that it will end early after one match, but this
    doesn't ring well with catch-all functions like these. It's sensible to save
    [kameloso.plugins.common.core.Chainable] only for the modules and functions that
    actually need it.

    The [kameloso.plugins.common.core.ChannelPolicy] annotation dictates whether or not this
    function should be called based on the *channel* the event took place in, if
    applicable. The two policies are [kameloso.plugins.common.core.ChannelPolicy.home],
    in which only events in channels in the [kameloso.kameloso.IRCBot.homeChannels]
    array will be allowed to trigger this; or [kameloso.plugins.common.core.ChannelPolicy.any],
    in which case anywhere goes. For events that don't correspond to a channel (such as
    [dialect.defs.IRCEvent.Type.QUERY]) the setting is ignored.

    The [kameloso.plugins.common.core.PermissionsRequired] annotation dictates who is
    authorised to trigger the function. It has six policies, in increasing
    order of importance:
    [kameloso.plugins.common.core.PermissionsRequired.ignore],
    [kameloso.plugins.common.core.PermissionsRequired.anyone],
    [kameloso.plugins.common.core.PermissionsRequired.registered],
    [kameloso.plugins.common.core.PermissionsRequired.whitelist],
    [kameloso.plugins.common.core.PermissionsRequired.operator],
    [kameloso.plugins.common.core.PermissionsRequired.staff] and
    [kameloso.plugins.common.core.PermissionsRequired.admin].

    * [kameloso.plugins.common.core.PermissionsRequired.ignore] will let precisely anyone
        trigger it, without looking them up.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.anyone] will let precisely anyone
        trigger it, but only after having looked them up.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.registered] will let anyone logged
        into a services account trigger it.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.whitelist] will only allow users
        in the whitelist section of the `users.json` resource file. Consider this
        to correspond to "regulars" in the channel.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.operator] will only allow users
        in the operator section of the `users.json` resource file. Consider this
        to correspond to "moderators" in the channel.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.staff] will only allow users
        in the staff section of the `users.json` resource file. Consider this
        to correspond to channel owners.<br>
    * [kameloso.plugins.common.core.PermissionsRequired.admin] will allow only you and
        your other superuser administrators, as defined in the configuration file.

    In the case of [kameloso.plugins.common.core.PermissionsRequired.whitelist],
    [kameloso.plugins.common.core.PermissionsRequired.operator],
    [kameloso.plugins.common.core.PermissionsRequired.staff] and
    [kameloso.plugins.common.core.PermissionsRequired.admin] it will look you up and
    compare your *services account name* to those known good before doing
    anything. In the case of [kameloso.plugins.common.core.PermissionsRequired.registered],
    merely being logged in is enough. In the case of
    [kameloso.plugins.common.core.PermissionsRequired.anyone], the WHOIS results won't
    matter and it will just let it pass, but it will check all the same.
    In the other cases, if you aren't logged into services or if your account
    name isn't included in the lists, the function will not trigger.

    This particular function doesn't care at all, so it is
    [kameloso.plugins.common.core.PermissionsRequired.ignore].
 +/
@Chainable
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.EMOTE)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.PART)
@(IRCEvent.Type.MODE)
@(IRCEvent.Type.TWITCH_TIMEOUT)
@(IRCEvent.Type.TWITCH_BAN)
@(IRCEvent.Type.TWITCH_BULKGIFT)
@(IRCEvent.Type.TWITCH_CHARITY)
@(IRCEvent.Type.TWITCH_EXTENDSUB)
@(IRCEvent.Type.TWITCH_GIFTCHAIN)
@(IRCEvent.Type.TWITCH_GIFTRECEIVED)
@(IRCEvent.Type.TWITCH_PAYFORWARD)
@(IRCEvent.Type.TWITCH_REWARDGIFT)
@(IRCEvent.Type.TWITCH_RITUAL)
@(IRCEvent.Type.TWITCH_SUB)
@(IRCEvent.Type.TWITCH_SUBGIFT)
@(IRCEvent.Type.TWITCH_SUBUPGRADE)
@(IRCEvent.Type.TWITCH_TIMEOUT)
@(PermissionsRequired.ignore)
@(ChannelPolicy.home)
void onSomeAction(SeenPlugin plugin, const ref IRCEvent event)
{
    /+
        Updates the user's timestamp to the current time, both sender and target.

        This will be automatically called on any and all the kinds of
        [dialect.defs.IRCEvent.Type]s it is annotated with. Furthermore, it will
        only trigger if it took place in a home channel.

        There's no need to check for whether the sender/target is us, as
        [updateUser] will do it more thoroughly (by stripping any extra modesigns).
     +/

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

    [dialect.defs.IRCEvent.Type.QUIT] events don't carry a channel.
    Users bleed into the seen users database by quitting unless we somehow limit
    it to only accept quits from those in home channels. Users in home channels
    should always have an entry, provided that
    [dialect.defs.IRCEvent.Type.RPL_NAMREPLY] lists were given when
    joining one, which seems to (largely?) be the case.

    Do nothing if an entry was not found.
 +/
@(IRCEvent.Type.QUIT)
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

    Like [dialect.defs.IRCEvent.Type.QUIT],
    [dialect.defs.IRCEvent.Type.NICK] events don't carry a channel, so we
    can't annotate it [kameloso.plugins.common.core.ChannelPolicy.home]; all we know
    is that the user is in one or more channels we're currently in. We can't
    tell whether it's in a home or not. As such, only update if the user has
    already been observed at least once, which should always be the case (provided
    [dialect.defs.IRCEvent.Type.RPL_NAMREPLY] lists on join).
 +/
@Chainable
@(IRCEvent.Type.NICK)
@(PermissionsRequired.ignore)
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
    [kameloso.plugins.chanqueries.ChanQueriesService] services instigates this
    shortly after having joined one, as a service to other plugins.
 +/
@(IRCEvent.Type.RPL_WHOREPLY)
@(ChannelPolicy.home)
void onWHOReply(SeenPlugin plugin, const ref IRCEvent event)
{
    // Update the user's entry
    plugin.updateUser(event.target.nickname, event.time);
}


// onNamesReply
/++
    Catch a NAMES reply and record each person as having been seen.

    When requesting NAMES on a channel, or when joining one, the server will send a big list of
    every participant in it, in a big string of nicknames separated by spaces.
    This is done automatically when you join a channel. Nicknames are prefixed
    with mode signs if they are operators, voiced or similar, so we'll need to
    strip that away.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
@(ChannelPolicy.home)
void onNamesReply(SeenPlugin plugin, const ref IRCEvent event)
{
    import std.algorithm.iteration : splitter;

    /+
        Use a [std.algorithm.iteration.splitter] to iterate each name and call
        [updateUser] to update (or create) their entry in the
        [SeenPlugin.seenUsers] associative array.
     +/

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


// onEndOfList
/++
    Optimises the lookups in the associative array of seen users.

    At the end of a long listing of users in a channel, when we're reasonably
    sure we've added users to our associative array of seen users, *rehashes* it.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(IRCEvent.Type.RPL_ENDOFWHO)
@(ChannelPolicy.home)
void onEndOfList(SeenPlugin plugin)
{
    plugin.seenUsers = plugin.seenUsers.rehash();
}


// onCommandSeen
/++
    Whenever someone says "seen" in a [dialect.defs.IRCEvent.Type.CHAN] or
    a [dialect.defs.IRCEvent.Type.QUERY], and if
    [dialect.defs.IRCEvent.Type.CHAN] then only if in a *home*, this function triggers.

    The [kameloso.plugins.common.core.BotCommand] annotation defines a piece of text
    that the incoming message must start with for this function to be called.
    [kameloso.plugins.common.core.PrefixPolicy] deals with whether the message has to
    start with the name of the *bot* or not, and to what extent.

    Prefix policies can be one of:
    * `direct`, where the raw command is expected without any bot prefix at all;
        the command is simply that string: "`seen`".
    * `prefixed`, where the message has to start with the command *prefix* character
        or string (usually `!` or `.`): "`!seen`".
    * `nickname`, where the message has to start with bot's nickname:
        "`kameloso: seen`" -- except if it's in a [dialect.defs.IRCEvent.Type.QUERY] message.<br>

    The plugin system will have made certain we only get messages starting with
    "`seen`", since we annotated this function with such a
    [kameloso.plugins.common.core.BotCommand]. It will since have been sliced off,
    so we're left only with the "arguments" to "`seen`". [dialect.defs.IRCEvent.aux]
    contains the triggering word, if it's needed.

    If this is a [dialect.defs.IRCEvent.Type.CHAN] event, the original lines
    could (for example) have been "`kameloso: seen Joe`", or merely "`!seen Joe`"
    (assuming a "`!`" prefix). If it was a private `dialect.defs.IRCEvent.Type.QUERY`
    message, the `kameloso:` prefix will have been removed. In either case, we're
    left with only the parts we're interested in, and the rest sliced off.

    As a result, the `dialect.defs.IRCEvent` `event` would look something like this
    (given a user `foo` querying "`!seen Joe`" or "`kameloso: seen Joe`"):

    ---
    event.type = IRCEvent.Type.CHAN;
    event.sender.nickname = "foo";
    event.sender.ident = "~bar";
    event.sender.address = "baz.foo.bar.org";
    event.channel = "#bar";
    event.content = "Joe";
    event.aux = "seen";
    ---

    Lastly, the [kameloso.plugins.common.core.Description] annotation merely defines
    how this function will be listed in the "online help" list, shown by triggering
    the [kameloso.plugins.help.HelpPlugin]'s' "`help`" command.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.SELFCHAN)
@(PermissionsRequired.anyone)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.prefixed, "seen")
@Description("Queries the bot when it last saw a specified nickname online.", "$command [nickname]")
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
            immutable message = plugin.state.settings.colouredOutgoing ?
                "Invalid user: " ~ requestedUser.ircBold :
                "Invalid user: " ~ requestedUser;

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
                immutable line = (event.channel.length && (event.channel == channel.name)) ?
                    " is here right now!" : " is online right now.";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    requestedUser.ircColourByHash.ircBold ~ line :
                    requestedUser ~ line;

                privmsg(event.channel, event.sender.nickname, message);
                return;
            }
        }

        // No matches

        if (const userTimestamp = requestedUser in seenUsers)
        {
            enum pattern =  "I last saw %s %s ago.";

            immutable timestamp = SysTime.fromUnixTime(*userTimestamp);
            immutable diff = (Clock.currTime - timestamp);
            immutable elapsed = timeSince!(No.abbreviate, 7, 2)(diff);

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(requestedUser.ircColourByHash.ircBold, elapsed) :
                pattern.format(requestedUser, elapsed);

            privmsg(event.channel, event.sender.nickname, message);
        }
        else
        {
            enum pattern = "I have never seen %s.";

            // No matches for nickname `event.content` in `plugin.seenUsers`.
            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(requestedUser.ircColourByHash.ircBold) :
                pattern.format(requestedUser);

            privmsg(event.channel, event.sender.nickname, message);
        }
    }
}


// updateUser
/++
    Updates a given nickname's entry in the seen array with the passed time,
    expressed in UNIX time.

    This is not annotated with an IRC event type and will merely be invoked from
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
 +/
void updateUser(SeenPlugin plugin, const string signed, const long time,
    const Flag!"skipModesignStrip" skipModesignStrip = No.skipModesignStrip)
in (signed.length, "Tried to update a user with an empty (signed) nickname")
{
    import dialect.common : stripModesign;

    // Make sure to strip the modesign, so `@foo` is the same person as `foo`.
    immutable nickname = skipModesignStrip ? signed : signed.stripModesign(plugin.state.server);
    if (nickname == plugin.state.client.nickname) return;
    plugin.seenUsers[nickname] = time;
}


// updateAllObservedUsers
/++
    Updates all currently observed users.

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
    Given a filename, reads the contents and load it into a `long[string]`
    associative array, then returns it. If there was no file there to read,
    returns an empty array for a fresh start.

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
        logger.warningf("%s%s%s does not exist or is not a file",
            Tint.log, filename, Tint.warning);
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
        logger.error("Could not load seen JSON from file: ", Tint.log, e.msg);
        version(PrintStacktraces) logger.trace(e.info);
    }

    // Rehash the AA, since we potentially added a *lot* of users.
    return aa.rehash();
}


// saveSeen
/++
    Saves the passed seen users associative array to disk, but in JSON format.

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

    auto file = File(filename, "w");

    file.writeln(JSONValue(seenUsers).toPrettyString);
}


// onWelcome
/++
    After we have registered on the server and seen the welcome messages, load
    our seen users from file. Additionally sets up a Fiber that periodically
    saves seen users to disk once every [SeenPlugin.timeBetweenSaves] seconds.

    This is to make sure that as little data as possible is lost in the event
    of an unexpected shutdown.
 +/
@(IRCEvent.Type.RPL_WELCOME)
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
            plugin.seenUsers = plugin.seenUsers.rehash();
            plugin.seenUsers.saveSeen(plugin.seenFile);
            delay(plugin, plugin.timeBetweenSaves, No.msecs, Yes.yield);
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

    void endOfMotdDg(const IRCEvent motdEvent)
    {
        import kameloso.plugins.common.delayawait : unawait;
        import lu.string : plurality;

        unawait(plugin, &endOfMotdDg, endOfMotdEventTypes[]);

        // Reports statistics on how many users are registered as having been seen

        logger.logf("Currently %s%d%s %s seen.",
            Tint.info, plugin.seenUsers.length, Tint.log,
            plugin.seenUsers.length.plurality("user", "users"));
    }

    await(plugin, &endOfMotdDg, endOfMotdEventTypes[]);
}


// reload
/++
    Reloads seen users from disk.
 +/
void reload(SeenPlugin plugin)
{
    //logger.info("Reloading seen users from disk.");
    plugin.seenUsers = loadSeen(plugin.seenFile);
}


// teardown
/++
    When closing the program or when crashing with grace, saves the seen users
    array to disk for later reloading.
 +/
void teardown(SeenPlugin plugin)
{
    plugin.updateAllObservedUsers();
    plugin.seenUsers.saveSeen(plugin.seenFile);
}


// initResources
/++
    Reads and writes the file of seen people to disk, ensuring that it's there.
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

    // Let other Exceptions pass.

    json.save(plugin.seenFile);
}


import kameloso.thread : Sendable;

// onBusMessage
/++
    Receives a passed [kameloso.thread.BusMessage] with the "`seen`" header,
    and calls functions based on the payload message.

    This is used in the Pipeline plugin, to allow us to trigger seen verbs via
    the command-line pipe, as well as in the Admin plugin for remote control
    over IRC.

    Params:
        plugin = The current [SeenPlugin].
        header = String header describing the passed content payload.
        content = Message content.
 +/
debug
version(Posix)
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
    [kameloso.plugins.common.awareness.UserAwareness] is a mixin template; a few functions
    defined in [kameloso.plugins.common.awareness] to deal with common bookkeeping that
    every plugin *that wants to keep track of users* need. If you don't want to
    track which users you have seen (and are visible to you now), you don't need this.
 +/
mixin UserAwareness;


/++
    Complementary to [kameloso.plugins.common.awareness.UserAwareness] is
    [kameloso.plugins.common.awareness.ChannelAwareness], which will add in bookkeeping
    about the channels the bot is in, their topics, modes and list of
    participants. Channel awareness requires user awareness, but not the other way around.

    We will want it to limit the amount of tracked users to people in our home channels.
 +/
mixin ChannelAwareness;


/++
    This full plugin is <200 source lines of code. (`dscanner --sloc seen.d`)
    Even at those numbers it is fairly feature-rich.
 +/

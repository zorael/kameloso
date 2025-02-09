/++
    Awareness mixins, for plugins to mix in to extend behaviour and enjoy a
    considerable degree of automation.

    These are used for plugins to mix in book-keeping of users and channels.

    Example:
    ---
    import kameloso.plugins;
    import kameloso.plugins.common.awareness;

    @Settings struct FooSettings { /* ... */ }

    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.CHAN)
        .permissionsRequired(Permissions.anyone)
        .channelPolicy(ChannelPolicy.home)
        .addCommand(
            IRCEventHandler.Command()
                .word("foo")
                .policy(PrefixPolicy.prefixed)
        )
    )
    void onFoo(FooPlugin plugin, const IRCEvent event)
    {
        // ...
    }

    mixin UserAwareness;
    mixin ChannelAwareness;

    final class FooPlugin : IRCPlugin
    {
        FooSettings fooSettings;

        // ...

        mixin IRCPluginImpl;
    }
    ---

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.common.mixins.awareness;

private:

import kameloso.plugins;
import dialect.defs;
import std.typecons : Flag, No, Yes;

public:

@safe:


// MinimalAuthentication
/++
    Implements triggering of queued events in a plugin module, based on user details
    such as account or hostmask.

    Most of the time a plugin doesn't require a full
    [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]; only
    those that need looking up users outside of the current event do. The
    persistency service allows for plugins to just read the information from
    the [dialect.defs.IRCUser|IRCUser] embedded in the event directly, and that's
    often enough.

    General rule: if a plugin doesn't access
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users],
    it's probably going to be enough with only
    [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication].

    Params:
        debug_ = Whether or not to include debugging output.
        module_ = String name of the mixing-in module; generally leave as-is.

    See_Also:
        [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]
        [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness]
 +/
mixin template MinimalAuthentication(
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import dialect.defs : IRCEvent;
    private static import kameloso.plugins.common.mixins.awareness;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "MinimalAuthentication");
    }

    /++
        Flag denoting that
        [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication]
        has been mixed in.
     +/
    package enum hasMinimalAuthentication = true;

    // onMinimalAuthenticationAccountInfoTargetMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationAccountInfoTarget|onMinimalAuthenticationAccountInfoTarget].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationAccountInfoTarget|onMinimalAuthenticationAccountInfoTarget]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_WHOISACCOUNT)
        .onEvent(IRCEvent.Type.RPL_WHOISREGNICK)
        .onEvent(IRCEvent.Type.RPL_ENDOFWHOIS)
        .when(Timing.early)
        .chainable(true)
    )
    void onMinimalAuthenticationAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationAccountInfoTarget(plugin, event);
    }

    // onMinimalAuthenticationUnknownCommandWHOISMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationUnknownCommandWHOIS|onMinimalAuthenticationUnknownCommandWHOIS].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationUnknownCommandWHOIS|onMinimalAuthenticationUnknownCommandWHOIS]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
        .when(Timing.early)
        .chainable(true)
    )
    void onMinimalAuthenticationUnknownCommandWHOISMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onMinimalAuthenticationUnknownCommandWHOIS(plugin, event);
    }
}


// onMinimalAuthenticationAccountInfoTarget
/++
    Replays any queued [kameloso.plugins.Replay|Replay]s awaiting the result
    of a WHOIS query. Before that, records the user's services account by
    saving it to the user's [dialect.defs.IRCClient|IRCClient] in the
    [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users] associative array.

    [dialect.defs.IRCEvent.Type.RPL_ENDOFWHOIS] is also handled, to
    cover the case where a user without an account triggering
    [kameloso.plugins.Permissions.anyone|Permissions.anyone]- or
    [kameloso.plugins.Permissions.ignore|Permissions.ignore]-level commands.

    This function was part of [UserAwareness] but triggering queued replays
    is too common to conflate with it.
 +/
void onMinimalAuthenticationAccountInfoTarget(IRCPlugin plugin, const IRCEvent event) @system
{
    import kameloso.plugins.common : catchUser;

    // Catch the user here, before replaying anything.
    catchUser(plugin, event.target);

    // See if there are any queued replays to trigger
    auto replaysForNickname = event.target.nickname in plugin.state.pendingReplays;
    if (!replaysForNickname) return;

    scope(exit)
    {
        plugin.state.pendingReplays.remove(event.target.nickname);
        plugin.state.hasPendingReplays = (plugin.state.pendingReplays.length > 0);
    }

    if (!replaysForNickname.length) return;

    foreach (immutable i, replay; *replaysForNickname)
    {
        import kameloso.constants : Timeout;

        if ((event.time - replay.timestamp) >= Timeout.whoisDiscard)
        {
            // Stale entry
        }
        else
        {
            plugin.state.readyReplays ~= replay;
        }
    }
}


// onMinimalAuthenticationUnknownCommandWHOIS
/++
    Clears all queued [kameloso.plugins.Replay|Replay]s if the server
    says it doesn't support WHOIS at all.

    This is the case with Twitch servers.
 +/
void onMinimalAuthenticationUnknownCommandWHOIS(IRCPlugin plugin, const IRCEvent event) @system
{
    if (event.aux[0] != "WHOIS") return;

    // We're on a server that doesn't support WHOIS
    // Trigger queued replays of a Permissions.anyone nature, since
    // they're just Permissions.ignore plus a WHOIS lookup just in case
    // Then clear everything

    foreach (replaysForNickname; plugin.state.pendingReplays)
    {
        foreach (replay; replaysForNickname)
        {
            plugin.state.readyReplays ~= replay;
        }
    }

    plugin.state.pendingReplays = null;
    plugin.state.hasPendingReplays = false;
}


// UserAwareness
/++
    Implements *user awareness* in a plugin module.

    This maintains a cache of all currently visible users, adding people to it
    upon discovering them and best-effort culling them when they leave or quit.
    The cache kept is an associative array, in
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users].

    User awareness implicitly requires
    [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|minimal authentication]
    and will silently include it if it was not already mixed in.

    Params:
        channelPolicy = What [kameloso.plugins.ChannelPolicy|ChannelPolicy]
            to apply to enwrapped event handlers.
        debug_ = Whether or not to include debugging output.
        module_ = String name of the mixing-in module; generally leave as-is.

    See_Also:
        [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication]
        [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness]
 +/
mixin template UserAwareness(
    ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import dialect.defs : IRCEvent;
    private static import kameloso.plugins.common.mixins.awareness;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "UserAwareness");
    }

    /++
        Flag denoting that
        [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]
        has been mixed in.
     +/
    package enum hasUserAwareness = true;

    static if (!__traits(compiles, { alias _ = .hasMinimalAuthentication; }))
    {
        mixin kameloso.plugins.common.mixins.awareness.MinimalAuthentication!(debug_, module_);
    }

    // onUserAwarenessQuitMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onUserAwarenessQuit|onUserAwarenessQuit].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessQuit|onUserAwarenessQuit]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.QUIT)
        .when(Timing.cleanup)
        .chainable(true)
    )
    void onUserAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessQuit(plugin, event);
    }

    // onUserAwarenessNickMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onUserAwarenessNick|onUserAwarenessNick].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessNick|onUserAwarenessNick]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.NICK)
        .when(Timing.early)
        .chainable(true)
    )
    void onUserAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessNick(plugin, event);
    }

    // onUserAwarenessCatchTargetMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchTarget|onUserAwarenessCatchTarget].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchTarget|onUserAwarenessCatchTarget]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_WHOISUSER)
        .onEvent(IRCEvent.Type.RPL_WHOREPLY)
        /*.onEvent(IRCEvent.Type.RPL_WHOISACCOUNT)
        .onEvent(IRCEvent.Type.RPL_WHOISREGNICK)*/  // Caught in MinimalAuthentication
        .onEvent(IRCEvent.Type.CHGHOST)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onUserAwarenessCatchTargetMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchTarget(plugin, event);
    }

    // onUserAwarenessCatchSenderMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchSender|onUserAwarenessCatchSender].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchSender|onUserAwarenessCatchSender]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.JOIN)
        .onEvent(IRCEvent.Type.ACCOUNT)
        .onEvent(IRCEvent.Type.AWAY)
        .onEvent(IRCEvent.Type.BACK)
        /*.onEvent(IRCEvent.Type.CHAN)  // Avoid these to be lean; everyone gets indexed by WHO anyway
        .onEvent(IRCEvent.Type.EMOTE)*/ // ...except on Twitch, but TwitchAwareness has these annotations
        .channelPolicy(channelPolicy)
        .when(Timing.setup)
        .chainable(true)
    )
    void onUserAwarenessCatchSenderMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessCatchSender!channelPolicy(plugin, event);
    }

    // onUserAwarenessNamesReplyMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onUserAwarenessNamesReply|onUserAwarenessNamesReply].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessNamesReply|onUserAwarenessNamesReply]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_NAMREPLY)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onUserAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessNamesReply(plugin, event);
    }

    // onUserAwarenessEndOfListMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onUserAwarenessEndOfList|onUserAwarenessEndOfList].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onUserAwarenessEndOfList|onUserAwarenessEndOfList]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_ENDOFNAMES)
        .onEvent(IRCEvent.Type.RPL_ENDOFWHO)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onUserAwarenessEndOfListMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onUserAwarenessEndOfList(plugin, event);
    }
}


// onUserAwarenessQuit
/++
    Removes a user's [dialect.defs.IRCUser|IRCUser] entry from a plugin's user
    list upon them disconnecting.
 +/
void onUserAwarenessQuit(IRCPlugin plugin, const IRCEvent event)
{
    plugin.state.users.remove(event.sender.nickname);
}


// onUserAwarenessNick
/++
    Upon someone changing nickname, update their entry in the
    [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    array to point to the new nickname.

    Removes the old entry after assigning it to the new key.
 +/
void onUserAwarenessNick(IRCPlugin plugin, const IRCEvent event) @system
{
    if (plugin.state.coreSettings.preferHostmasks)
    {
        // Persistence will have set up a complete user with account and everything.
        // There's no point in copying anything over.
    }
    else if (auto oldUser = event.sender.nickname in plugin.state.users)
    {
        plugin.state.users[event.target.nickname] = *oldUser;
    }

    plugin.state.users.remove(event.sender.nickname);
}


// onUserAwarenessCatchTarget
/++
    Catches a user's information and saves it in the plugin's
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    array of [dialect.defs.IRCUser|IRCUser]s.

    [dialect.defs.IRCEvent.Type.RPL_WHOISUSER] events carry values in
    the [dialect.defs.IRCUser.updated|IRCUser.updated] field that we want to store.

    [dialect.defs.IRCEvent.Type.CHGHOST] occurs when a user changes host
    on some servers that allow for custom host addresses.
 +/
void onUserAwarenessCatchTarget(IRCPlugin plugin, const IRCEvent event) @system
{
    import kameloso.plugins.common : catchUser;
    catchUser(plugin, event.target);
}


// onUserAwarenessCatchSender
/++
    Adds a user to the [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users] array,
    potentially including their services account name.

    Servers with the (enabled) capability `extended-join` will include the
    account name of whoever joins in the event string. If it's there, catch
    the user into the user array so we don't have to WHOIS them later.
 +/
void onUserAwarenessCatchSender(ChannelPolicy channelPolicy)
    (IRCPlugin plugin, const IRCEvent event) @system
{
    import kameloso.plugins.common : catchUser;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case ACCOUNT:
    case AWAY:
    case BACK:
        static if (
            (channelPolicy == ChannelPolicy.home) ||
            (channelPolicy == ChannelPolicy.guest))
        {
            // These events don't carry a channel.
            // Catch if there's already an entry. Trust that it's supposed
            // to be there if it's there. (RPL_NAMREPLY probably populated it)

            if (event.sender.nickname in plugin.state.users)
            {
                return catchUser(plugin, event.sender);
            }

            static if (__traits(compiles, { alias _ = .hasChannelAwareness; }))
            {
                // Catch the user if it's visible in some channel we're in.

                foreach (immutable channelName, const channel; plugin.state.channels)
                {
                    import std.algorithm.searching : canFind;

                    static if (channelPolicy == ChannelPolicy.home)
                    {
                        auto channelArray = &plugin.state.bot.homeChannels;
                    }
                    else /*if (channelPolicy == ChannelPolicy.guest)*/
                    {
                        auto channelArray = &plugin.state.bot.guestChannels;
                    }

                    // Skip if the channel is not a home channel or a guest channel, respectively
                    if (!(*channelArray).canFind(channelName)) continue;

                    if (event.sender.nickname in channel.users)
                    {
                        // event is from a user that's in a home channel
                        return catchUser(plugin, event.sender);
                    }
                }
            }
        }
        else /*static if (channelPolicy == ChannelPolicy.any)*/
        {
            // Catch everyone on ChannelPolicy.any
            catchUser(plugin, event.sender);
        }
        break;

    //case JOIN:
    default:
        catchUser(plugin, event.sender);
    }
}


// onUserAwarenessNamesReply
/++
    Catch users in a reply for the request for a NAMES list of all the
    participants in a channel.

    Freenode only sends a list of the nicknames but SpotChat sends the full
    `user!ident@address` information.
 +/
void onUserAwarenessNamesReply(IRCPlugin plugin, const IRCEvent event) @system
{
    import kameloso.plugins.common : catchUser;
    import kameloso.irccolours : stripColours;
    import dialect.common : IRCControlCharacter, stripModesign;
    import lu.string : advancePast;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Do nothing actually. Twitch NAMES is unreliable noise.
            return;
        }
    }

    auto namesRange = event.content.splitter(' ');

    foreach (immutable userstring; namesRange)
    {
        string slice = userstring;  // mutable
        IRCUser user;  // ditto

        if (!slice.canFind('!'))
        {
            // No need to check for slice.contains('@'))
            // Freenode-like, only nicknames with possible modesigns
            immutable nickname = slice.stripModesign(plugin.state.server);
            if (nickname == plugin.state.client.nickname) continue;
            user.nickname = nickname;
        }
        else
        {
            // SpotChat-like, names are in full nick!ident@address form
            immutable signed = slice.advancePast('!');
            immutable nickname = signed.stripModesign(plugin.state.server);
            if (nickname == plugin.state.client.nickname) continue;
            immutable ident = slice.advancePast('@');

            // Do addresses ever contain bold, italics, underlined?
            immutable address = slice.canFind(cast(char)IRCControlCharacter.colour) ?
                stripColours(slice) :
                slice;

            user = IRCUser(nickname, ident, address);
        }

        catchUser(plugin, user);  // this melds with the default conservative strategy
    }
}


// onUserAwarenessEndOfList
/++
    Rehashes, or optimises, the [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    associative array upon the end of a WHO or a NAMES list.

    These replies can list hundreds of users depending on the size of the
    channel. Once an associative array has grown sufficiently, it becomes
    inefficient. Rehashing it makes it take its new size into account and
    makes lookup faster.
 +/
void onUserAwarenessEndOfList(IRCPlugin plugin, const IRCEvent event) @system
{
    if (auto channel = event.channel.name in plugin.state.channels)
    {
        // created in `onChannelAwarenessSelfjoin`
        channel.users.rehash();
    }
}


// ChannelAwareness
/++
    Implements *channel awareness* in a plugin module.

    This maintains a cache of all current channels, their topics and modes, and
    their participants. The cache kept is an associative array, in
    [kameloso.plugins.IRCPluginState.channels|IRCPluginState.channels].

    Channel awareness explicitly requires
    [kameloso.plugins.common.mixins.awareness.UserAwareness|user awareness] and will
    halt compilation if it is not also mixed in.

    Params:
        channelPolicy = What [kameloso.plugins.ChannelPolicy|ChannelPolicy]
            to apply to enwrapped event handlers.
        debug_ = Whether or not to include debugging output.
        module_ = String name of the mixing-in module; generally leave as-is.

    See_Also:
        [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication]
        [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]
 +/
mixin template ChannelAwareness(
    ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import dialect.defs : IRCEvent;
    private static import kameloso.plugins.common.mixins.awareness;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "ChannelAwareness");
    }

    /++
        Flag denoting that [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness]
        has been mixed in.
     +/
    package enum hasChannelAwareness = true;

    static if (!__traits(compiles, { alias _ = .hasUserAwareness; }))
    {
        import std.format : format;

        enum pattern = "`%s` is missing a `UserAwareness` mixin " ~
            "(needed for `ChannelAwareness`)";
        enum message = pattern.format(module_);
        static assert(0, message);
    }

    // onChannelAwarenessSelfjoinMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfjoin|onChannelAwarenessSelfjoin].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfjoin|onChannelAwarenessSelfjoin]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.SELFJOIN)
        .channelPolicy(channelPolicy)
        .when(Timing.setup)
        .chainable(true)
    )
    void onChannelAwarenessSelfjoinMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfjoin(plugin, event);
    }

    // onChannelAwarenessSelfpartMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfpart|onChannelAwarenessSelfpart].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfpart|onChannelAwarenessSelfpart]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.SELFPART)
        .onEvent(IRCEvent.Type.SELFKICK)
        .channelPolicy(channelPolicy)
        .when(Timing.cleanup)
        .chainable(true)
    )
    void onChannelAwarenessSelfpartMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessSelfpart(plugin, event);
    }

    // onChannelAwarenessJoinMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessJoin|onChannelAwarenessJoin].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessJoin|onChannelAwarenessJoin]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.JOIN)
        .channelPolicy(channelPolicy)
        .when(Timing.setup)
        .chainable(true)
    )
    void onChannelAwarenessJoinMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessJoin(plugin, event);
    }

    // onChannelAwarenessPartMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessPart|onChannelAwarenessPart].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessPart|onChannelAwarenessPart]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.PART)
        .channelPolicy(channelPolicy)
        .when(Timing.late)
        .chainable(true)
    )
    void onChannelAwarenessPartMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessPart(plugin, event);
    }

    // onChannelAwarenessNickMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessNick|onChannelAwarenessNick].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessNick|onChannelAwarenessNick]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.NICK)
        .when(Timing.setup)
        .chainable(true)
    )
    void onChannelAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessNick(plugin, event);
    }

    // onChannelAwarenessQuitMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessQuit|onChannelAwarenessQuit].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessQuit|onChannelAwarenessQuit]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.QUIT)
        .when(Timing.late)
        .chainable(true)
    )
    void onChannelAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessQuit(plugin, event);
    }

    // onChannelAwarenessTopicMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessTopic|onChannelAwarenessTopic].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessTopic|onChannelAwarenessTopic]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.TOPIC)
        .onEvent(IRCEvent.Type.RPL_TOPIC)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessTopicMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessTopic(plugin, event);
    }

    // onChannelAwarenessCreationTimeMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessCreationTime|onChannelAwarenessCreationTime].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessCreationTime|onChannelAwarenessCreationTime]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_CREATIONTIME)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessCreationTimeMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessCreationTime(plugin, event);
    }

    // onChannelAwarenessModeMixin
    /++
        Proxies to [kameloso.plugins.common.mixins.awareness.onChannelAwarenessMode|onChannelAwarenessMode].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessMode|onChannelAwarenessMode]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.MODE)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessModeMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessMode(plugin, event);
    }

    // onChannelAwarenessWhoReplyMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessWhoReply|onChannelAwarenessWhoReply].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessWhoReply|onChannelAwarenessWhoReply]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_WHOREPLY)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessWhoReplyMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessWhoReply(plugin, event);
    }

    // onChannelAwarenessNamesReplyMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessNamesReply|onChannelAwarenessNamesReply].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessNamesReply|onChannelAwarenessNamesReply]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_NAMREPLY)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessNamesReply(plugin, event);
    }

    // onChannelAwarenessModeListsMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessModeLists|onChannelAwarenessModeLists].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessModeLists|onChannelAwarenessModeLists]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_BANLIST)
        .onEvent(IRCEvent.Type.RPL_EXCEPTLIST)
        .onEvent(IRCEvent.Type.RPL_INVITELIST)
        .onEvent(IRCEvent.Type.RPL_REOPLIST)
        .onEvent(IRCEvent.Type.RPL_QUIETLIST)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessModeListsMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessModeLists(plugin, event);
    }

    // onChannelAwarenessChannelModeIsMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onChannelAwarenessChannelModeIs|onChannelAwarenessChannelModeIs].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onChannelAwarenessChannelModeIs|onChannelAwarenessChannelModeIs]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.RPL_CHANNELMODEIS)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onChannelAwarenessChannelModeIsMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onChannelAwarenessChannelModeIs(plugin, event);
    }
}


// onChannelAwarenessSelfjoin
/++
    Create a new [dialect.defs.IRCChannel|IRCChannel] in the the
    [kameloso.plugins.IRCPlugin|IRCPlugin]'s
    [kameloso.plugins.IRCPluginState.channels|IRCPluginState.channels]
    associative array when the bot joins a channel.
 +/
void onChannelAwarenessSelfjoin(IRCPlugin plugin, const IRCEvent event)
{
    if (event.channel.name in plugin.state.channels) return;

    plugin.state.channels[event.channel.name] = IRCChannel.init;
    plugin.state.channels[event.channel.name].name = event.channel.name;
}


// onChannelAwarenessSelfpart
/++
    Removes an [dialect.defs.IRCChannel|IRCChannel] from the internal list when the
    bot leaves it.

    Remove users from the [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    array if, by leaving, it left the last channel we can observe it from, so as
    not to leak users. It can be argued that this should be part of user awareness,
    however this would not be possible if it were not for channel-tracking.
    As such keep the behaviour in channel awareness.
 +/
void onChannelAwarenessSelfpart(IRCPlugin plugin, const IRCEvent event)
{
    // On Twitch SELFPART may occur on untracked channels
    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    nickloop:
    foreach (immutable nickname; channel.users.byKey)
    {
        foreach (immutable stateChannelName, const stateChannel; plugin.state.channels)
        {
            if (stateChannelName == event.channel.name) continue;
            if (nickname in stateChannel.users) continue nickloop;
        }

        // nickname is not in any of our other tracked channels; remove
        plugin.state.users.remove(nickname);
    }

    plugin.state.channels.remove(event.channel.name);
}


// onChannelAwarenessJoin
/++
    Adds a user as being part of a channel when they join it.
 +/
void onChannelAwarenessJoin(IRCPlugin plugin, const IRCEvent event)
{
    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    channel.users[event.sender.nickname] = true;
}


// onChannelAwarenessPart
/++
    Removes a user from being part of a channel when they leave it.

    Remove the user from the [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    array if, by leaving, it left the last channel we can observe it from, so as
    not to leak users. It can be argued that this should be part of user awareness,
    however this would not be possible if it were not for channel-tracking.
    As such keep the behaviour in channel awareness.
 +/
void onChannelAwarenessPart(IRCPlugin plugin, const IRCEvent event)
{
    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    if (event.sender.nickname !in channel.users)
    {
        // On Twitch servers with no NAMES on joining a channel, users
        // that you haven't seen may leave despite never having been seen
        return;
    }

    channel.users.remove(event.sender.nickname);

    // Remove entries in the mods AA (ops, halfops, voice, ...)
    foreach (/*immutable prefixChar,*/ ref prefixMods; channel.mods)
    {
        prefixMods.remove(event.sender.nickname);
    }

    foreach (const otherChannel; plugin.state.channels)
    {
        if (event.sender.nickname in otherChannel.users) return;
    }

    // event.sender is not in any of our tracked channels; remove
    plugin.state.users.remove(event.sender.nickname);
}


// onChannelAwarenessNick
/++
    Upon someone changing nickname, update their entry in the
    [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    associative array to point to the new nickname.

    Does *not* add a new entry if one doesn't exits, to counter the fact
    that [dialect.defs.IRCEvent.Type.NICK] events don't belong to a channel,
    and as such can't be regulated with [kameloso.plugins.ChannelPolicy|ChannelPolicy]
    annotations. This way the user will only be moved if it was already added elsewhere.
    Else we'll leak users.

    Removes the old entry after assigning it to the new key.
 +/
void onChannelAwarenessNick(IRCPlugin plugin, const IRCEvent event)
{
    // User awareness bits take care of the IRCPluginState.users AA

    foreach (ref channel; plugin.state.channels)
    {
        if (event.sender.nickname !in channel.users) continue;

        channel.users.remove(event.sender.nickname);
        channel.users[event.target.nickname] = true;
    }
}


// onChannelAwarenessQuit
/++
    Removes a user from all tracked channels if they disconnect.

    Does not touch the internal list of users; the user awareness bits are
    expected to take care of that.
 +/
void onChannelAwarenessQuit(IRCPlugin plugin, const IRCEvent event)
{
    foreach (ref channel; plugin.state.channels)
    {
        channel.users.remove(event.sender.nickname);
    }
}


// onChannelAwarenessTopic
/++
    Update the entry for an [dialect.defs.IRCChannel|IRCChannel] if someone changes
    the topic of it.
 +/
void onChannelAwarenessTopic(IRCPlugin plugin, const IRCEvent event)
{
    if (auto channel = event.channel.name in plugin.state.channels)
    {
        channel.topic = event.content;  // don't strip
    }
}


// onChannelAwarenessCreationTime
/++
    Stores the timestamp of when a channel was created.
 +/
void onChannelAwarenessCreationTime(IRCPlugin plugin, const IRCEvent event)
{
    if (auto channel = event.channel.name in plugin.state.channels)
    {
        channel.created = event.count[0].get();
    }
}


// onChannelAwarenessMode
/++
    Sets a mode for a channel.

    Most modes replace others of the same type, notable exceptions being
    bans and mode exemptions. We let [dialect.common.setMode] take care of that.
 +/
void onChannelAwarenessMode(IRCPlugin plugin, const IRCEvent event)
{
    import dialect.common : setMode;

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            // Twitch modes are unpredictable. Ignore and rely on badges instead.
            return;
        }
    }

    if (auto channel = event.channel.name in plugin.state.channels)
    {
        (*channel).setMode(event.aux[0], event.content, plugin.state.server);
    }
}


// onChannelAwarenessWhoReply
/++
    Adds a user as being part of a channel upon receiving the reply from the
    request for info on all the participants.

    This events includes all normal fields like ident and address, but not
    their channel modes (e.g. `@` for operator).
 +/
void onChannelAwarenessWhoReply(IRCPlugin plugin, const IRCEvent event)
{
    import std.string : representation;

    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    // User awareness bits add the IRCUser
    if (event.aux[0].length)
    {
        // Register operators, half-ops, voiced etc
        // Can be more than one if multi-prefix capability is enabled
        // Server-sent string, can assume ASCII (@,%,+...) and go char by char
        foreach (immutable modesign; event.aux[0].representation)
        {
            if (const modechar = modesign in plugin.state.server.prefixchars)
            {
                import dialect.common : setMode;
                import std.conv : to;

                immutable modestring = (*modechar).to!string;
                (*channel).setMode(modestring, event.target.nickname, plugin.state.server);
            }
            else
            {
                //logger.warning("Invalid modesign in RPL_WHOREPLY: ", modesign);
            }
        }
    }

    if (event.target.nickname == plugin.state.client.nickname) return;

    // In case no mode was applied
    channel.users[event.target.nickname] = true;
}


// onChannelAwarenessNamesReply
/++
    Adds users as being part of a channel upon receiving the reply from the
    request for a list of all the participants.

    On some servers this does not include information about the users, only
    their nickname and their channel mode (e.g. `@` for operator), but other
    servers express the users in the full `user!ident@address` form.
 +/
void onChannelAwarenessNamesReply(IRCPlugin plugin, const IRCEvent event)
{
    import dialect.common : stripModesign;
    import std.algorithm.searching : canFind;
    import std.algorithm.iteration : splitter;
    import std.string : representation;

    if (!event.content.length) return;

    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    auto namesRange = event.content.splitter(' ');

    foreach (immutable userstring; namesRange)
    {
        string slice = userstring;  // mutable
        string nickname;  // ditto

        if (userstring.canFind('!'))// && userstring.canFind('@'))  // No need to check both
        {
            import lu.string : advancePast;
            // SpotChat-like, names are in full nick!ident@address form
            nickname = slice.advancePast('!');
        }
        else
        {
            // Freenode-like, only a nickname with possible @%+ prefix
            nickname = userstring;
        }

        string modesigns;  // mutable
        nickname = nickname.stripModesign(plugin.state.server, modesigns);

        // Register operators, half-ops, voiced etc
        // Can be more than one if multi-prefix capability is enabled
        // Server-sent string, can assume ASCII (@,%,+...) and go char by char
        foreach (immutable modesign; modesigns.representation)
        {
            if (const modechar = modesign in plugin.state.server.prefixchars)
            {
                import dialect.common : setMode;
                import std.conv : to;

                immutable modestring = (*modechar).to!string;
                (*channel).setMode(modestring, nickname, plugin.state.server);
            }
            else
            {
                //logger.warning("Invalid modesign in RPL_NAMREPLY: ", modesign);
            }
        }

        channel.users[nickname] = true;
    }
}


// onChannelAwarenessModeLists
/++
    Adds users of a certain "list" mode to a tracked channel's list of modes
    (banlist, exceptlist, invitelist, etc).
 +/
void onChannelAwarenessModeLists(IRCPlugin plugin, const IRCEvent event)
{
    import dialect.common : setMode;
    import std.conv : to;

    // :kornbluth.freenode.net 367 kameloso #flerrp huerofi!*@* zorael!~NaN@2001:41d0:2:80b4:: 1513899527
    // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
    // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
    // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101

    auto channel = event.channel.name in plugin.state.channels;
    if (!channel) return;

    with (IRCEvent.Type)
    {
        string modestring;  // mutable

        switch (event.type)
        {
        case RPL_BANLIST:
            modestring = "b";
            break;

        case RPL_EXCEPTLIST:
            modestring = (plugin.state.server.exceptsChar == 'e') ?
                "e" :
                plugin.state.server.exceptsChar.to!string;
            break;

        case RPL_INVITELIST:
            modestring = (plugin.state.server.invexChar == 'I') ?
                "I" :
                plugin.state.server.invexChar.to!string;
            break;

        case RPL_REOPLIST:
            modestring = "R";
            break;

        case RPL_QUIETLIST:
            modestring = "q";
            break;

        default:
            enum message = "Unexpected IRC event type annotation on " ~
                "`onChannelAwarenessModeListMixin`";
            assert(0, message);
        }

        (*channel).setMode(modestring, event.content, plugin.state.server);
    }
}


// onChannelAwarenessChannelModeIs
/++
    Adds the modes of a channel to a tracked channel's mode list.
 +/
void onChannelAwarenessChannelModeIs(IRCPlugin plugin, const IRCEvent event)
{
    import dialect.common : setMode;

    if (auto channel = event.channel.name in plugin.state.channels)
    {
        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        (*channel).setMode(event.aux[0], event.content, plugin.state.server);
    }
}


// TwitchAwareness
/++
    Implements scraping of Twitch message events for user details in a module.

    Twitch doesn't always enumerate channel participants upon joining a channel.
    It seems to mostly be done on larger channels, and only rarely when the
    channel is small.

    There is a chance of a user leak, if parting users are not broadcast. As
    such we mark when the user was last seen in the
    [dialect.defs.IRCUser.updated|IRCUser.updated] member, which opens up the possibility
    of pruning the plugin's [kameloso.plugins.IRCPluginState.users|IRCPluginState.users]
    array of old entries.

    Twitch awareness needs channel awareness, or it is meaningless.

    Params:
        channelPolicy = What [kameloso.plugins.ChannelPolicy|ChannelPolicy]
            to apply to enwrapped event handlers.
        debug_ = Whether or not to include debugging output.
        module_ = String name of the mixing-in module; generally leave as-is.

    See_Also:
        [kameloso.plugins.common.mixins.awareness.MinimalAuthentication|MinimalAuthentication]
        [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]
        [kameloso.plugins.common.mixins.awareness.ChannelAwareness|ChannelAwareness]
 +/
version(TwitchSupport)
mixin template TwitchAwareness(
    ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import dialect.defs : IRCEvent;
    private static import kameloso.plugins.common.mixins.awareness;

    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "TwitchAwareness");
    }

    /++
        Flag denoting that [kameloso.plugins.common.mixins.awareness.TwitchAwareness|TwitchAwareness]
        has been mixed in.
     +/
    package enum hasTwitchAwareness = true;

    static if (!__traits(compiles, { alias _ = .hasChannelAwareness; }))
    {
        import std.format : format;

        enum pattern = "`%s` is missing a `ChannelAwareness` mixin " ~
            "(needed for `TwitchAwareness`)";
        enum message = pattern.format(module_);
        static assert(0, message);
    }

    // onTwitchAwarenessSenderCarryingEventMixin
    /++
        Proxies to
        [kameloso.plugins.common.mixins.awareness.onTwitchAwarenessUserCarrierImpl|onTwitchAwarenessUserCarrierImpl].

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onTwitchAwarenessUserCarrierImpl|onTwitchAwarenessUserCarrierImpl]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.CHAN)  // Catch these as we don't index people by WHO on Twitch
        .onEvent(IRCEvent.Type.JOIN)
        .onEvent(IRCEvent.Type.SELFJOIN)
        .onEvent(IRCEvent.Type.PART)
        .onEvent(IRCEvent.Type.EMOTE) // As above
        .onEvent(IRCEvent.Type.TWITCH_SUB)
        .onEvent(IRCEvent.Type.TWITCH_CHEER)
        .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
        .onEvent(IRCEvent.Type.TWITCH_BITSBADGETIER)
        .onEvent(IRCEvent.Type.TWITCH_RAID)
        .onEvent(IRCEvent.Type.TWITCH_UNRAID)
        .onEvent(IRCEvent.Type.TWITCH_RITUAL)
        .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
        .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
        .onEvent(IRCEvent.Type.TWITCH_SUBUPGRADE)
        .onEvent(IRCEvent.Type.TWITCH_CHARITY)
        .onEvent(IRCEvent.Type.TWITCH_BULKGIFT)
        .onEvent(IRCEvent.Type.TWITCH_EXTENDSUB)
        .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
        .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
        .onEvent(IRCEvent.Type.TWITCH_CROWDCHANT)
        .onEvent(IRCEvent.Type.TWITCH_ANNOUNCEMENT)
        .onEvent(IRCEvent.Type.TWITCH_DIRECTCHEER)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onTwitchAwarenessSenderCarryingEventMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onTwitchAwarenessUserCarrierImpl(
            plugin,
            event.channel.name,
            event.sender);
    }

    // onTwitchAwarenessTargetCarryingEventMixin
    /++
        Catch targets from normal Twitch events.

        This has to be done on certain Twitch channels whose participants are
        not enumerated upon joining it, nor joins or parts announced. By
        listening for any message with targets and catching that user that way
        we ensure we do our best to scrape the channels.

        See_Also:
            [kameloso.plugins.common.mixins.awareness.onTwitchAwarenessUserCarrierImpl|onTwitchAwarenessUserCarrierImpl]
     +/
    @(IRCEventHandler()
        .onEvent(IRCEvent.Type.TWITCH_BAN)
        .onEvent(IRCEvent.Type.TWITCH_SUBGIFT)
        .onEvent(IRCEvent.Type.TWITCH_REWARDGIFT)
        .onEvent(IRCEvent.Type.TWITCH_TIMEOUT)
        .onEvent(IRCEvent.Type.TWITCH_GIFTCHAIN)
        .onEvent(IRCEvent.Type.TWITCH_GIFTRECEIVED)
        .onEvent(IRCEvent.Type.TWITCH_PAYFORWARD)
        .onEvent(IRCEvent.Type.CLEARMSG)
        .onEvent(IRCEvent.Type.GLOBALUSERSTATE)
        .channelPolicy(channelPolicy)
        .when(Timing.early)
        .chainable(true)
    )
    void onTwitchAwarenessTargetCarryingEventMixin(IRCPlugin plugin, const IRCEvent event) @system
    {
        kameloso.plugins.common.mixins.awareness.onTwitchAwarenessUserCarrierImpl(
            plugin,
            event.channel.name,
            event.target);
    }
}


// onTwitchAwarenessUserCarrierImpl
/++
    Catch a user from normal Twitch events.

    This has to be done on certain Twitch channels whose participants are
    not enumerated upon joining it, nor joins or parts announced. By
    listening for any message and catching the user that way we ensure we
    do our best to scrape the channels.

    See_Also:
        [kameloso.plugins.common.mixins.awareness.onTwitchAwarenessTargetCarryingEventMixin|onTwitchAwarenessTargetCarryingEventMixin]
 +/
version(TwitchSupport)
void onTwitchAwarenessUserCarrierImpl(
    IRCPlugin plugin,
    const string channelName,
    const IRCUser user) @system
{
    import kameloso.plugins.common : catchUser;

    if (plugin.state.server.daemon != IRCServer.Daemon.twitch) return;

    if (!user.nickname) return;

    // Move the catchUser call here to populate the users array with users in guest channels
    //catchUser(plugin, user);

    auto channel = channelName in plugin.state.channels;
    if (!channel) return;

    if (user.nickname !in channel.users)
    {
        channel.users[user.nickname] = true;
    }

    catchUser(plugin, user);  // <-- this one
}


version(TwitchSupport) {}
else
/++
    No-op mixin of version `!TwitchSupport` [kameloso.plugins.common.mixins.awareness.TwitchAwareness|TwitchAwareness].
 +/
mixin template TwitchAwareness(
    ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    version(unittest)
    {
        import lu.traits : MixinConstraints, MixinScope;
        mixin MixinConstraints!(MixinScope.module_, "TwitchAwareness (stub)");
    }

    /++
        Flag denoting that [kameloso.plugins.common.mixins.awareness.TwitchAwareness|TwitchAwareness]
        has been mixed in.
     +/
    package enum hasTwitchAwareness = true;

    static if (!__traits(compiles, { alias _ = .hasChannelAwareness; }))
    {
        import std.format : format;

        enum pattern = "`%s` is missing a `ChannelAwareness` mixin " ~
            "(needed for `TwitchAwareness`)";
        enum message = pattern.format(module_);
        static assert(0, message);
    }
}

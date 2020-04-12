/++
 +  Awareness mixins, for plugins to mix in to extend behaviour and enjoy a
 +  considerable degree of automation.
 +
 +  Example:
 +  ---
 +  import kameloso.plugins.ircplugin;
 +  import kameloso.plugins.common;
 +  import kameloso.plugins.awareness;
 +
 +  @Settings struct FooSettings { /* ... */ }
 +
 +  @(IRCEvent.Type.CHAN)
 +  @(ChannelPolicy.home)
 +  @(PrefixPolicy.prefixed)
 +  @BotCommand(PrivilegeLevel.anyone, "foo")
 +  void onFoo(FooPlugin plugin, const IRCEvent event)
 +  {
 +      // ...
 +  }
 +
 +  mixin UserAwareness;
 +  mixin ChannelAwareness;
 +
 +  final class FooPlugin : IRCPlugin
 +  {
 +      FooSettings fooSettings;
 +
 +      // ...
 +
 +      mixin IRCPluginImpl;
 +  }
 +  ---
 +/
module kameloso.plugins.awareness;

version(WithPlugins):

private:

import kameloso.plugins.common : ChannelPolicy;

public:

@safe:


// Awareness
/++
 +  Annotation denoting that a function is part of an awareness mixin, and at
 +  what point it should be processed.
 +/
enum Awareness
{
    /++
     +  First stage: setup. The annotated event handlers will process first,
     +  setting the stage for the following `Awareness.early`-annotated handlers.
     +/
    setup,

    /++
     +  Second stage: early. The annotated event handlers will have their chance
     +  to process before the plugin-specific handlers will.
     +/
    early,

    /++
     +  Fourth stage: late. The annotated event handlers will process after
     +  the plugin-specific handlers have all processed.
     +/
    late,

    /++
     +  Fifth and last stage: cleanup. The annotated event handlers will process
     +  after everything else has been called.
     +/
    cleanup,
}


// MinimalAuthentication
/++
 +  Implements triggering of queued events in a plugin module.
 +
 +  Most of the time a plugin doesn't require a full `UserAwareness`; only
 +  those that need looking up users outside of the current event do. The
 +  persistency service allows for plugins to just read the information from
 +  the `dialect.defs.IRCUser` embedded in the event directly, and that's
 +  often enough.
 +
 +  General rule: if a plugin doesn't access `IRCPluginState.users`, it's probably
 +  going to be enough with only `MinimalAuthentication`.
 +
 +  Params:
 +      debug_ = Whether or not to include debugging output.
 +      module_ = String name of the mixing-in module; generally leave as-is.
 +/
mixin template MinimalAuthentication(bool debug_ = false, string module_ = __MODULE__)
{
    private import kameloso.plugins.awareness : Awareness;
    private import lu.traits : MixinConstraints, MixinScope;

    mixin MixinConstraints!(MixinScope.module_, "MinimalAuthentication");

    static if (__traits(compiles, .hasMinimalAuthentication))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("MinimalAuthentication", module_));
    }
    else
    {
        private enum hasMinimalAuthentication = true;
    }


    // onMinimalAuthenticationAccountInfoTargetMixin
    /++
     +  Replays any queued requests awaiting the result of a WHOIS. Before that,
     +  records the user's services account by saving it to the user's
     +  `dialect.defs.IRCClient` in the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array.
     +
     +  `dialect.defs.IRCEvent.Type.RPL_ENDOFWHOIS` is also handled, to
     +  cover the case where a user without an account triggering `PrivilegeLevel.anyone`-
     +  or `PrivilegeLevel.ignored`-level commands.
     +
     +  This function was part of `UserAwareness` but triggering queued requests
     +  is too common to conflate with it.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISACCOUNT)
    @(IRCEvent.Type.RPL_WHOISREGNICK)
    @(IRCEvent.Type.RPL_ENDOFWHOIS)
    void onMinimalAuthenticationAccountInfoTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // Catch the user here, before replaying anything.
        plugin.catchUser(event.target);

        mixin Replayer;

        // See if there are any queued WHOIS requests to trigger
        auto requestsForNickname = event.target.nickname in plugin.state.triggerRequestQueue;

        if (requestsForNickname)
        {
            size_t[] garbageIndexes;

            foreach (immutable i, request; *requestsForNickname)
            {
                import kameloso.constants : Timeout;
                import std.algorithm.searching : canFind;

                scope(exit) garbageIndexes ~= i;

                if ((event.time - request.when) > Timeout.whoisRetry)
                {
                    // Entry is too old, request timed out. Flag it for removal.
                    continue;
                }

                queueToReplay(request);
            }

            foreach_reverse (immutable i; garbageIndexes)
            {
                import std.algorithm.mutation : SwapStrategy, remove;
                *requestsForNickname = (*requestsForNickname).remove!(SwapStrategy.unstable)(i);
            }
        }

        if (requestsForNickname && !requestsForNickname.length)
        {
            plugin.state.triggerRequestQueue.remove(event.target.nickname);
        }
    }


    // onMinimalAuthenticationUnknownCommandWHOIS
    /++
     +  Clears all queued `WHOIS` requests if the server says it doesn't support
     +  `WHOIS` at all.
     +
     +  This is the case with Twitch servers.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.ERR_UNKNOWNCOMMAND)
    void onMinimalAuthenticationUnknownCommandWHOIS(IRCPlugin plugin, const IRCEvent event)
    {
        if (event.aux != "WHOIS") return;

        // We're on a server that doesn't support WHOIS
        // Trigger queued requests of a PrivilegeLevel.anyone nature, since
        // they're just PrivilegeLevel.ignore plus a WHOIS lookup just in case
        // Then clear everything

        mixin Replayer;

        foreach (requests; plugin.state.triggerRequestQueue)
        {
            foreach (request; requests)
            {
                queueToReplay(request);
            }
        }

        plugin.state.triggerRequestQueue.clear();
    }
}


// UserAwareness
/++
 +  Implements *user awareness* in a plugin module.
 +
 +  Plugins that deal with users in any form will need event handlers to handle
 +  people joining and leaving channels, disconnecting from the server, and
 +  other events related to user details (including services account names).
 +
 +  If more elaborate ones are needed, additional functions can be written and,
 +  where applicable, annotated appropriately.
 +
 +  Params:
 +      channelPolicy = What `ChannelPolicy` to apply to enwrapped event handlers.
 +      debug_ = Whether or not to include debugging output.
 +      module_ = String name of the mixing-in module; generally leave as-is.
 +/
mixin template UserAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    private import kameloso.plugins.awareness : Awareness, MinimalAuthentication;
    private import lu.traits : MixinConstraints, MixinScope;

    mixin MixinConstraints!(MixinScope.module_, "UserAwareness");

    static if (__traits(compiles, .hasUserAwareness))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("UserAwareness", module_));
    }
    else
    {
        private enum hasUserAwareness = true;
    }

    static if (!__traits(compiles, .hasMinimalAuthentication))
    {
        mixin MinimalAuthentication!(debug_, module_);
    }


    // onUserAwarenessQuitMixin
    /++
     +  Removes a user's `dialect.defs.IRCUser` entry from a plugin's user
     +  list upon them disconnecting.
     +/
    @(Awareness.cleanup)
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onUserAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.state.users.remove(event.sender.nickname);
    }


    // onUserAwarenessNickMixin
    /++
     +  Upon someone changing nickname, update their entry in the `IRCPlugin`'s
     +  `IRCPluginState.users` array to point to the new nickname.
     +
     +  Removes the old entry after assigning it to the new key.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onUserAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        if (auto oldUser = event.sender.nickname in plugin.state.users)
        {
            plugin.state.users[event.target.nickname] = *oldUser;
            plugin.state.users.remove(event.sender.nickname);
        }
    }


    // onUserAwarenessCatchTargetMixin
    /++
     +  Catches a user's information and saves it in the plugin's
     +  `IRCPluginState.users` array of `dialect.defs.IRCUser`s.
     +
     +  `dialect.defs.IRCEvent.Type.RPL_WHOISUSER` events carry values in
     +  the `dialect.defs.IRCUser.updated` field that we want to store.
     +
     +  `dialect.defs.IRCEvent.Type.CHGHOST` occurs when a user changes host
     +  on some servers that allow for custom host addresses.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOISUSER)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @(IRCEvent.Type.CHGHOST)
    @channelPolicy
    void onUserAwarenessCatchTargetMixin(IRCPlugin plugin, const IRCEvent event)
    {
        plugin.catchUser(event.target);
    }


    // onUserAwarenessCatchSenderMixin
    /++
     +  Adds a user to the `IRCPlugin`'s `IRCPluginState.users` array,
     +  potentially including their services account name.
     +
     +  Servers with the (enabled) capability `extended-join` will include the
     +  account name of whoever joins in the event string. If it's there, catch
     +  the user into the user array so we don't have to `WHOIS` them later.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.ACCOUNT)
    @(IRCEvent.Type.AWAY)
    @(IRCEvent.Type.BACK)
    @channelPolicy
    void onUserAwarenessCatchSenderMixin(IRCPlugin plugin, const IRCEvent event)
    {
        with (IRCEvent.Type)
        switch (event.type)
        {
        case ACCOUNT:
        case AWAY:
        case BACK:
            // These events don't carry a channel, so check our channel user
            // lists to see if we should catch this one or not.

            foreach (const channel; plugin.state.channels)
            {
                if (event.sender.nickname in channel.users)
                {
                    // event is from a user that's in a relevant channel
                    return plugin.catchUser(event.sender);
                }
            }
            break;

        //case JOIN:
        default:
            plugin.catchUser(event.sender);
            break;
        }
    }


    // onUserAwarenessNamesReplyMixin
    /++
     +  Catch users in a reply for the request for a `NAMES` list of all the
     +  participants in a channel, if they are expressed in the full
     +  `user!ident@address` form.
     +
     +  Freenode only sends a list of the nicknames but SpotChat sends the full
     +  information.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @channelPolicy
    void onUserAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import kameloso.irccolours : stripColours;
        import dialect.common : IRCControlCharacter, stripModesign;
        import lu.string : contains, nom;
        import std.algorithm.iteration : splitter;

        auto names = event.content.splitter(" ");

        foreach (immutable userstring; names)
        {
            string slice = userstring;
            IRCUser newUser;

            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) ||
                !slice.contains('!') || !slice.contains('@'))
            {
                // Freenode-like, only nicknames with possible modesigns
                immutable nickname = slice.stripModesign(plugin.state.server);

                version(TwitchSupport)
                {
                    if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
                    {
                        if (nickname == plugin.state.client.nickname) continue;
                    }
                }

                newUser.nickname = nickname;
            }
            else
            {
                // SpotChat-like, names are in full nick!ident@address form
                immutable signed = slice.nom('!');
                immutable nickname = signed.stripModesign(plugin.state.server);
                if (nickname == plugin.state.client.nickname) continue;

                immutable ident = slice.nom('@');

                // Do addresses ever contain bold, italics, underlined?
                immutable address = slice.contains(IRCControlCharacter.colour) ?
                    stripColours(slice) : slice;

                newUser = IRCUser(nickname, ident, address);
            }

            plugin.catchUser(newUser);
        }
    }


    // onUserAwarenessEndOfListMixin
    /++
     +  Rehashes, or optimises, the `IRCPlugin`'s `IRCPluginState.users`
     +  associative array upon the end of a `WHO` or a `NAMES` list.
     +
     +  These replies can list hundreds of users depending on the size of the
     +  channel. Once an associative array has grown sufficiently, it becomes
     +  inefficient. Rehashing it makes it take its new size into account and
     +  makes lookup faster.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_ENDOFNAMES)
    @(IRCEvent.Type.RPL_ENDOFWHO)
    @channelPolicy
    void onUserAwarenessEndOfListMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // Pass a channel name so only that channel is rehashed
        plugin.rehashUsers(event.channel);
    }


    // onUserAwarenessPingMixin
    /++
     +  Rehash the internal `IRCPluginState.users` associative array of
     +  `dialect.defs.IRCUser`s, once every `hoursBetweenRehashes` hours.
     +
     +  We ride the periodicity of `dialect.defs.IRCEvent.Type.PING` to get
     +  a natural cadence without having to resort to queued
     +  `kameloso.thread.ScheduledFiber`s.
     +
     +  The number of hours is so far hardcoded but can be made configurable if
     +  there's a use-case for it.
     +
     +  This re-implements `IRCPlugin.periodically`.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.PING)
    void onUserAwarenessPingMixin(IRCPlugin plugin)
    {
        import std.datetime.systime : Clock;

        enum minutesBeforeInitialRehash = 5;
        enum hoursBetweenRehashes = 12;

        immutable now = Clock.currTime.toUnixTime;

        if (mixin(pingRehashVariableName) == 0L)
        {
            // First PING encountered
            // Delay rehashing to let the client join all channels
            mixin(pingRehashVariableName) = now + (minutesBeforeInitialRehash * 60);
        }
        else if (now >= mixin(pingRehashVariableName))
        {
            // Once every `hoursBetweenRehashes` hours, rehash the `users` array.
            plugin.rehashUsers();
            mixin(pingRehashVariableName) = now + (hoursBetweenRehashes * 3600);
        }
    }


    import std.conv : text;

    /++
     +  UNIX timestamp of when the `IRCPluginState.users` array is next to be
     +  rehashed in `onUserAwarenessPingMixin`.
     +
     +  Randomise the name to avoid any collisions, however far-fetched.
     +/
    private enum pingRehashVariableName = text("_kamelosoNextPingRehashTimestamp", hashOf(module_) % 100);
    mixin("long " ~ pingRehashVariableName ~ ';');
}


// ChannelAwareness
/++
 +  Implements *channel awareness* in a plugin module.
 +
 +  Plugins that need to track channels and the users in them need some event
 +  handlers to handle the bookkeeping. Notably when the bot joins and leaves
 +  channels, when someone else joins, leaves or disconnects, someone changes
 +  their nickname, changes channel modes or topic, as well as some events that
 +  list information about users and what channels they're in.
 +
 +  Channel awareness needs user awareness, or things won't work.
 +
 +  Note: It's possible to get the topic, WHO, NAMES, modes, creation time etc of
 +  channels we're not in, so only update the channel entry if there is one
 +  already (and avoid range errors).
 +
 +  Params:
 +      channelPolicy = What `ChannelPolicy` to apply to enwrapped event handlers.
 +      debug_ = Whether or not to include debugging output.
 +      module_ = String name of the mixing-in module; generally leave as-is.
 +/
version(WithPlugins)
mixin template ChannelAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    private import kameloso.plugins.awareness : Awareness;
    private import lu.traits : MixinConstraints, MixinScope;

    mixin MixinConstraints!(MixinScope.module_, "ChannelAwareness");

    static if (__traits(compiles, .hasChannelAwareness))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("ChannelAwareness", module_));
    }
    else
    {
        private enum hasChannelAwareness = true;
    }

    static if (!__traits(compiles, .hasUserAwareness))
    {
        import std.format : format;
        static assert(0, ("`%s` is missing a `UserAwareness` mixin " ~
            "(needed for `ChannelAwareness`)")
            .format(module_));
    }

    // onChannelAwarenessSelfjoinMixin
    /++
     +  Create a new `dialect.defs.IRCChannel` in the the `IRCPlugin`'s
     +  `IRCPluginState.channels` associative array when the bot joins a channel.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.SELFJOIN)
    @channelPolicy
    void onChannelAwarenessSelfjoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        if (event.channel in plugin.state.channels) return;

        plugin.state.channels[event.channel] = IRCChannel.init;
        plugin.state.channels[event.channel].name = event.channel;
    }


    // onChannelAwarenessSelfpartMixin
    /++
     +  Removes an `dialect.defs.IRCChannel` from the internal list when the
     +  bot leaves it.
     +
     +  Remove users from the `plugin.state.users` array if, by leaving, it left
     +  the last channel we can observe it from, so as not to leak users. It can
     +  be argued that this should be part of user awareness, however this would
     +  not be possible if it were not for channel-tracking. As such keep the
     +  behaviour in channel awareness.
     +/
    @(Awareness.cleanup)
    @(Chainable)
    @(IRCEvent.Type.SELFPART)
    @(IRCEvent.Type.SELFKICK)
    @channelPolicy
    void onChannelAwarenessSelfpartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // On Twitch SELFPART may occur on untracked channels
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        nickloop:
        foreach (immutable nickname; channel.users.byKey)
        {
            foreach (const stateChannel; plugin.state.channels)
            {
                if (nickname in stateChannel.users) continue nickloop;
            }

            // nickname is not in any of our other tracked channels; remove
            plugin.state.users.remove(nickname);
        }

        plugin.state.channels.remove(event.channel);
    }


    // onChannelAwarenessJoinMixin
    /++
     +  Adds a user as being part of a channel when they join one.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.JOIN)
    @channelPolicy
    void onChannelAwarenessJoinMixin(IRCPlugin plugin, const IRCEvent event)
    {
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        channel.users[event.sender.nickname] = true;
    }


    // onChannelAwarenessPartMixin
    /++
     +  Removes a user from being part of a channel when they leave one.
     +
     +  Remove the user from the `plugin.state.users` array if, by leaving, it
     +  left the last channel we can observe it from, so as not to leak users.
     +  It can be argued that this should be part of user awareness, however
     +  this would not be possible if it were not for channel-tracking. As such
     +  keep the behaviour in channel awareness.
     +/
    @(Awareness.late)
    @(Chainable)
    @(IRCEvent.Type.PART)
    @channelPolicy
    void onChannelAwarenessPartMixin(IRCPlugin plugin, const IRCEvent event)
    {
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        if (event.sender.nickname !in channel.users)
        {
            // On Twitch servers with no NAMES on joining a channel, users
            // that you haven't seen may leave despite never having been seen
            return;
        }

        channel.users.remove(event.sender.nickname);

        foreach (const foreachChannel; plugin.state.channels)
        {
            if (event.sender.nickname in foreachChannel.users) return;
        }

        // event.sender is not in any of our tracked channels; remove
        plugin.state.users.remove(event.sender.nickname);
    }


    // onChannelAwarenessNickMixin
    /++
     +  Upon someone changing nickname, update their entry in the
     +  `IRCPluginState.users` associative array point to the new nickname.
     +
     +  Does *not* add a new entry if one doesn't exits, to counter the fact
     +  that `dialect.defs.IRCEvent.Type.NICK` events don't belong to a channel,
     +  and as such can't be regulated with `ChannelPolicy` annotations. This way
     +  the user will only be moved if it was already added elsewhere. Else we'll leak users.
     +
     +  Removes the old entry after assigning it to the new key.
     +/
    @(Awareness.setup)
    @(Chainable)
    @(IRCEvent.Type.NICK)
    void onChannelAwarenessNickMixin(IRCPlugin plugin, const IRCEvent event)
    {
        // User awareness bits take care of the IRCPluginState.users AA

        foreach (ref channel; plugin.state.channels)
        {
            if (event.sender.nickname !in channel.users) continue;

            channel.users.remove(event.sender.nickname);
            channel.users[event.target.nickname] = true;
        }
    }


    // onChannelAwarenessQuitMixin
    /++
     +  Removes a user from all tracked channels if they disconnect.
     +
     +  Does not touch the internal list of users; the user awareness bits are
     +  expected to take care of that.
     +/
    @(Awareness.late)
    @(Chainable)
    @(IRCEvent.Type.QUIT)
    void onChannelAwarenessQuitMixin(IRCPlugin plugin, const IRCEvent event)
    {
        foreach (ref channel; plugin.state.channels)
        {
            channel.users.remove(event.sender.nickname);
        }
    }


    // onChannelAwarenessTopicMixin
    /++
     +  Update the entry for an `dialect.defs.IRCChannel` if someone changes
     +  the topic of it.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.TOPIC)
    @(IRCEvent.Type.RPL_TOPIC)
    @channelPolicy
    void onChannelAwarenessTopicMixin(IRCPlugin plugin, const IRCEvent event)
    {
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        channel.topic = event.content;
    }


    // onChannelAwarenessCreationTimeMixin
    /++
     +  Stores the timestamp of when a channel was created.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_CREATIONTIME)
    @channelPolicy
    void onChannelAwarenessCreationTimeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        channel.created = event.count;
    }


    // onChannelAwarenessModeMixin
    /++
     +  Sets a mode for a channel.
     +
     +  Most modes replace others of the same type, notable exceptions being
     +  bans and mode exemptions. We let `dialect.common.setMode` take care of that.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.MODE)
    @channelPolicy
    void onChannelAwarenessModeMixin(IRCPlugin plugin, const IRCEvent event)
    {
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Twitch modes are unpredictable. Ignore and rely on badges instead.
                return;
            }
        }

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        import dialect.common : setMode;
        (*channel).setMode(event.aux, event.content, plugin.state.server);
    }


    // onChannelAwarenessWhoReplyMixin
    /++
     +  Adds a user as being part of a channel upon receiving the reply from the
     +  request for info on all the participants.
     +
     +  This events includes all normal fields like ident and address, but not
     +  their channel modes (e.g. `@` for operator).
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_WHOREPLY)
    @channelPolicy
    void onChannelAwarenessWhoReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import std.string : representation;

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        // User awareness bits add the IRCUser
        if (event.aux.length)
        {
            // Register operators, half-ops, voiced etc
            // Can be more than one if multi-prefix capability is enabled
            // Server-sent string, can assume ASCII (@,%,+...) and go char by char
            foreach (immutable modesign; event.aux.representation)
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


    // onChannelAwarenessNamesReplyMixin
    /++
     +  Adds users as being part of a channel upon receiving the reply from the
     +  request for a list of all the participants.
     +
     +  On some servers this does not include information about the users, only
     +  their nickname and their channel mode (e.g. `@` for operator), but other
     +  servers express the users in the full `user!ident@address` form.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_NAMREPLY)
    @channelPolicy
    void onChannelAwarenessNamesReplyMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import lu.string : contains;
        import std.algorithm.iteration : splitter;

        if (!event.content.length) return;

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        auto names = event.content.splitter(" ");

        foreach (immutable userstring; names)
        {
            string slice = userstring;
            string nickname;

            if (userstring.contains('!') && userstring.contains('@'))
            {
                import lu.string : nom;
                // SpotChat-like, names are in full nick!ident@address form
                nickname = slice.nom('!');
            }
            else
            {
                // Freenode-like, only a nickname with possible @%+ prefix
                nickname = userstring;
            }

            import dialect.common : stripModesign;

            string modesigns;
            nickname = nickname.stripModesign(plugin.state.server, modesigns);

            // Register operators, half-ops, voiced etc
            // Can be more than one if multi-prefix capability is enabled
            // Server-sent string, can assume ASCII (@,%,+...) and go char by char
            import std.string : representation;
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


    // onChannelAwarenessModeListsMixin
    /++
     +  Adds the list of banned users to a tracked channel's list of modes.
     +
     +  Bans are just normal A-mode channel modes that are paired with a user
     +  and that don't overwrite other bans (can be stacked).
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_BANLIST)
    @(IRCEvent.Type.RPL_EXCEPTLIST)
    @(IRCEvent.Type.RPL_INVITELIST)
    @(IRCEvent.Type.RPL_REOPLIST)
    @(IRCEvent.Type.RPL_QUIETLIST)
    @channelPolicy
    void onChannelAwarenessModeListsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        import dialect.common : setMode;
        import std.conv : to;

        // :kornbluth.freenode.net 367 kameloso #flerrp huerofi!*@* zorael!~NaN@2001:41d0:2:80b4:: 1513899527
        // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
        // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
        // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        with (IRCEvent.Type)
        {
            string modestring;

            switch (event.type)
            {
            case RPL_BANLIST:
                modestring = "b";
                break;

            case RPL_EXCEPTLIST:
                modestring = (plugin.state.server.exceptsChar == 'e') ?
                    "e" : plugin.state.server.invexChar.to!string;
                break;

            case RPL_INVITELIST:
                modestring = (plugin.state.server.invexChar == 'I') ?
                    "I" : plugin.state.server.invexChar.to!string;
                break;

            case RPL_REOPLIST:
                modestring = "R";
                break;

            case RPL_QUIETLIST:
                modestring = "q";
                break;

            default:
                assert(0, "Unexpected IRC event type annotation on " ~
                    "`onChannelAwarenessModeListMixin`");
            }

            (*channel).setMode(modestring, event.content, plugin.state.server);
        }
    }


    // onChannelAwarenessChannelModeIsMixin
    /++
     +  Adds the modes of a channel to a tracked channel's mode list.
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.RPL_CHANNELMODEIS)
    @channelPolicy
    void onChannelAwarenessChannelModeIsMixin(IRCPlugin plugin, const IRCEvent event)
    {
        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        import dialect.common : setMode;
        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        (*channel).setMode(event.aux, event.content, plugin.state.server);
    }
}


// TwitchAwareness
/++
 +  Implements scraping of Twitch message events for user details in a module.
 +
 +  Twitch doesn't always enumerate channel participants upon joining a channel.
 +  It seems to mostly be done on larger channels, and only rarely when the
 +  channel is small.
 +
 +  There is a chance of a user leak, if parting users are not broadcast. As
 +  such we mark when the user was last seen in the
 +  `dialect.defs.IRCUser.updated` member, which opens up the possibility
 +  of pruning the plugin's `IRCPluginState.users` array of old entries.
 +
 +  Twitch awareness needs channel awareness, or it is meaningless.
 +
 +  Params:
 +      channelPolicy = What `ChannelPolicy` to apply to enwrapped event handlers.
 +      debug_ = Whether or not to include debugging output.
 +      module_ = String name of the mixing-in module; generally leave as-is.
 +/
version(WithPlugins)
version(TwitchSupport)
mixin template TwitchAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    private import kameloso.plugins.awareness : Awareness;
    private import lu.traits : MixinConstraints, MixinScope;

    mixin MixinConstraints!(MixinScope.module_, "TwitchAwareness");

    static if (__traits(compiles, .hasTwitchAwareness))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("TwitchAwareness", module_));
    }
    else
    {
        private enum hasTwitchAwareness = true;
    }

    static if (!__traits(compiles, .hasChannelAwareness))
    {
        import std.format : format;
        static assert(0, ("`%s` is missing a `ChannelAwareness` mixin " ~
            "(needed for `TwitchAwareness`)")
            .format(module_));
    }


    // onTwitchAwarenessSenderCarryingEvent
    /++
     +  Catch senders from normal Twitch events.
     +
     +  This has to be done on certain Twitch channels whose participants are
     +  not enumerated upon joining it, nor joins or parts announced. By
     +  listening for any message and catching the user that way we ensure we
     +  do our best to scrape the channels.
     +
     +  See_Also:
     +      `onTwitchAwarenessTargetCarryingEvent`
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.CHAN)
    @(IRCEvent.Type.JOIN)
    @(IRCEvent.Type.PART)
    @(IRCEvent.Type.EMOTE)
    @(IRCEvent.Type.TWITCH_SUB)
    @(IRCEvent.Type.TWITCH_CHEER)
    @(IRCEvent.Type.TWITCH_SUBGIFT)
    @(IRCEvent.Type.TWITCH_HOSTSTART)
    @(IRCEvent.Type.TWITCH_HOSTEND)
    @(IRCEvent.Type.TWITCH_BITSBADGETIER)
    @(IRCEvent.Type.TWITCH_RAID)
    @(IRCEvent.Type.TWITCH_UNRAID)
    @(IRCEvent.Type.TWITCH_RITUAL)
    @(IRCEvent.Type.TWITCH_REWARDGIFT)
    @(IRCEvent.Type.TWITCH_GIFTCHAIN)
    @(IRCEvent.Type.TWITCH_SUBUPGRADE)
    @(IRCEvent.Type.TWITCH_CHARITY)
    @(IRCEvent.Type.TWITCH_BULKGIFT)
    @(IRCEvent.Type.TWITCH_EXTENDSUB)
    @(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    @(IRCEvent.Type.TWITCH_PAYFORWARD)
    @(IRCEvent.Type.TWITCH_SKIPSUBSMODEMESSAGE)
    @(IRCEvent.Type.CLEARMSG)
    @channelPolicy
    void onTwitchAwarenessSenderCarryingEvent(IRCPlugin plugin, const IRCEvent event)
    {
        if (plugin.state.server.daemon != IRCServer.Daemon.twitch) return;

        if (!event.sender.nickname) return;

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        if (event.sender.nickname !in channel.users)
        {
            channel.users[event.sender.nickname] = true;
        }

        plugin.catchUser(event.sender);
    }


    // onTwitchAwarenessTargetCarryingEvent
    /++
     +  Catch targets from normal Twitch events.
     +
     +  This has to be done on certain Twitch channels whose participants are
     +  not enumerated upon joining it, nor joins or parts announced. By
     +  listening for any message with targets and catching that user that way
     +  we ensure we do our best to scrape the channels.
     +
     +  See_Also:
     +      `onTwitchAwarenessSenderCarryingEvent`
     +/
    @(Awareness.early)
    @(Chainable)
    @(IRCEvent.Type.TWITCH_BAN)
    @(IRCEvent.Type.TWITCH_SUBGIFT)
    @(IRCEvent.Type.TWITCH_REWARDGIFT)
    @(IRCEvent.Type.TWITCH_TIMEOUT)
    @(IRCEvent.Type.TWITCH_GIFTCHAIN)
    @(IRCEvent.Type.TWITCH_GIFTRECEIVED)
    @(IRCEvent.Type.TWITCH_PAYFORWARD)
    @channelPolicy
    void onTwitchAwarenessTargetCarryingEvent(IRCPlugin plugin, const IRCEvent event)
    {
        if (plugin.state.server.daemon != IRCServer.Daemon.twitch) return;

        if (!event.target.nickname) return;

        auto channel = event.channel in plugin.state.channels;
        if (!channel) return;

        if (event.target.nickname !in channel.users)
        {
            channel.users[event.target.nickname] = true;
        }

        plugin.catchUser(event.target);
    }
}


version(TwitchSupport) {}
else
/++
 +  No-op mixin of version `!TwitchSupport` `TwitchAwareness`.
 +/
mixin template TwitchAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    bool debug_ = false, string module_ = __MODULE__)
{
    private import lu.traits : MixinConstraints, MixinScope;

    mixin MixinConstraints!(MixinScope.module_, "TwitchAwareness");

    static if (__traits(compiles, .hasTwitchAwareness))
    {
        import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("TwitchAwareness", module_));
    }
    else
    {
        private enum hasTwitchAwareness = true;
    }

    static if (!__traits(compiles, .hasChannelAwareness))
    {
        import std.format : format;
        static assert(0, ("`%s` is missing a `ChannelAwareness` mixin " ~
            "(needed for `TwitchAwareness`)")
            .format(module_));
    }
}

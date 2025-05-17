/++
    The Persistence service keeps track of all encountered users, gathering as much
    information about them as possible, then injects them into
    [dialect.defs.IRCEvent|IRCEvent]s when information about them is incomplete.

    This means that even if a service only refers to a user by nickname, things
    like its ident and address will be available to plugins as well, assuming
    the Persistence service had seen that previously.

    It has no commands.

    See_Also:
        [kameloso.plugins],
        [kameloso.plugins.common]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.services.persistence;

version(WithPersistenceService):

private:

import kameloso.plugins;
import kameloso.common : logger;
import dialect.defs;


// PersistenceSettings
/++
    Settings for the Persistence service.
 +/
@Settings struct PersistenceSettings
{
    private import lu.uda : Unserialisable;

    /++
        To what level the service should monitor and record users in channels.
     +/
    @Unserialisable ChannelPolicy omniscienceLevel = ChannelPolicy.any;
}


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] after parsing and
    fleshes out the [dialect.defs.IRCEvent.sender|IRCEvent.sender] and/or
    [dialect.defs.IRCEvent.target|IRCEvent.target] fields, so that things like
    account names that are only sent sometimes carry over.
 +/
auto postprocess(PersistenceService service, ref IRCEvent event)
{
    import lu.meld : MeldingStrategy, meldInto;
    import std.algorithm.comparison : among;

    /++
        Ensures a user exists in the global cache, conservatively melding it
        into the passed user if it does, inserting the passed user into the
        cache if it doesn't.
     +/
    static auto syncUserWithGlobal(PersistenceService service, ref IRCUser user, ref string errors)
    {
        bool globalUserExisted;

        auto global = establishUserInCache(
            service,
            user,
            string.init,
            createIfNoneExist: true,
            foundExisting: globalUserExisted);

        if (globalUserExisted)
        {
            import lu.meld : MeldingStrategy, meldInto;

            version(none)
            version(TwitchSupport)
            {
                if (global.badges.length && (global.badges != "*"))
                {
                    import std.format : format;

                    enum pattern = "The global '%s' user has badges '%s' when it should be empty";
                    immutable message = pattern.format(global.nickname, global.badges);
                    errors = errors.length ?
                        " | " ~ message :
                        message;

                    global.badges = string.init;
                }
            }

            // Fill in the blanks, conservatively
            (*global).meldInto!(MeldingStrategy.conservative)(user);
        }

        return global;
    }

    /++
        Compares the user account to the array of administrators and sets the
        user class accordingly.

        If the class is `unset`, it is raised to `anyone`.
     +/
    static void discoverAdmin(
        PersistenceService service,
        ref IRCUser user)
    {
        if ((user.class_ == IRCUser.Class.admin) ||
            (user.class_ == IRCUser.Class.blacklist))
        {
            // admin and blacklist are sticky
            return;
        }
        else
        {
            import std.algorithm.searching : canFind;

            if (service.state.bot.admins.canFind(user.account))
            {
                user.class_ = IRCUser.Class.admin;
                return;
            }
        }

        if (user.class_ == IRCUser.Class.unset)
        {
            // Users should never be unset
            user.class_ = IRCUser.Class.anyone;
        }
    }

    /++
        Ensures that the sender and target of an event are in sync with the global
        cache, and that they don't have any channel-specific values set.
     +/
    static void syncEventUsersWithGlobals(
        PersistenceService service,
        ref IRCEvent event)
    {
        IRCUser*[2] users = [ &event.sender, &event.target ];

        foreach (user; users[])
        {
            if (!user.nickname.length) continue;

            // Clear badges before syncing so channel-specific badges don't leak
            // into the global user
            version(TwitchSupport) user.badges = string.init;

            discoverAdmin(service, *user);
            syncUserWithGlobal(service, *user, errors: event.errors);
        }
    }

    /++
        Nested implementation function so we can properly handle the sender and
        target separately.
     +/
    static void postprocessUserImpl(
        PersistenceService service,
        ref IRCEvent event,
        ref IRCUser user,
        const bool isTarget)
    {
        /+
            Ignore server event, events where this is an empty event.target, and
            certain pre-registration events where our nick is unknown.
         +/
        if (!user.nickname.length || (user.nickname == "*")) return;

        version(TwitchSupport)
        {
            if (service.state.server.daemon == IRCServer.Daemon.twitch)
            {
                // Clear badges if it has the empty placeholder asterisk
                // Do this before melding so that it doesn't overwrite the stored value
                if (user.badges == "*") user.badges = string.init;
            }
        }

        bool storedUserExisted;  // out parameter
        string userToRemove;  /// Nickname of user to remove from all caches at the end

        auto stored = establishUserInCache(
            service,
            user,
            event.channel.name,
            createIfNoneExist: true,
            foundExisting: storedUserExisted);

        auto global = event.channel.name.length ?
            syncUserWithGlobal(service, *stored, errors: event.errors) :
            null;

        const old = *stored;

        if (storedUserExisted)
        {
            // Fill in the blanks aggresssively, but restore class and updated
            user.meldInto!(MeldingStrategy.aggressive)(*stored);
            stored.class_ = old.class_;
            stored.updated = old.updated;
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            if (service.state.coreSettings.preferHostmasks &&
                (stored.account != old.account))
            {
                /+
                    Ignore any new account that may have been parsed and melded from user.
                    We only want accounts we resolve in here.
                 +/
                stored.account = old.account;
            }

            /+
                Specialcase some events to resolve account and class, and
                potentially propagate them accordingly.
             +/
            with (IRCEvent.Type)
            switch (event.type)
            {
            case RPL_WHOISACCOUNT:
            case RPL_WHOISREGNICK:
            case RPL_WHOISUSER:
                resolveAccount(service, *stored, event.time);
                goto default;  // to propagate account and resolve class

            case RPL_ENDOFWHOIS:
                /+
                    This event is the last in a WHOIS sequence and doesn't really
                    carry any new and interesting information.
                    If the user wasn't logged into an account, the above cases
                    will never have been hit and the account never had an attempt
                    to be resolved manually. So if the account is known, stop here,
                    otherwise goto the RPL_WHOISACCOUNT case and resolveAccount.
                 +/
                if (user.account.length && (user.account != "*"))
                {
                    // Resolved already
                    break;
                }
                else
                {
                    // No account was resolved, so try to resolve it manually
                    resolveAccount(service, *stored, event.time);
                    goto default;  // to propagate account and resolve class
                }

            case NICK:
            case SELFNICK:
                /+
                    This event has two users; a sender pre-nick change and a
                    target post-nick change. We only want to do this once for
                    the event, so only do it for the target.
                 +/
                if (!isTarget) break;

                if (!storedUserExisted)
                {
                    /+
                        The nick event target is blank. This should always be the case.
                        We could meld but we could also just copy and change the nickname.
                     +/
                    //event.sender.meld!(MeldingStrategy.conservative)(*stored);
                    *stored = event.sender;
                    stored.nickname = old.nickname;
                }
                else if (event.sender.account.length)
                {
                    // Just in case the above is somehow false
                    stored.account = event.sender.account;
                }

                userToRemove = event.sender.nickname;  // Remove old user at the end of the function
                resolveAccount(service, *stored, event.time);
                goto default;  // to propagate account and resolve class

            case QUIT:
                // This removes the user entry from both the cache and the nickname-account map
                userToRemove = stored.nickname;
                break;

            case ACCOUNT:
                if (stored.account == "*")
                {
                    /+
                        An account of "*" means the user logged out of services.
                        It's not strictly true but consider him/her as unknown again.
                     +/
                    service.nicknameAccountMap.remove(stored.nickname);
                    dropAllPrivileges(service, stored.nickname);

                    if (old.account.length)
                    {
                        // Store the previous account in aux[0] if it was known
                        event.aux[0] = old.account;
                    }
                    break;
                }
                goto default;  // to propagate account and resolve class

            //case JOIN:  // JOINs may carry account depending on server capabilities
            default:
                if (stored.account != old.account)
                {
                    /+
                        Event bearing new account.
                        These can be whatever if the "account-tag" capability is set.
                        event.channel.name may be empty here if we jumped from a RPL_WHOIS* case.
                     +/
                    propagateUserAccount(service, *stored);
                    resolveClass(service, *stored, context: event.channel.name, event.time);
                }
                break;
            }
        }

        /+
            Check the user for admin-ness. This also sets the class to anyone
            if it should be unset for some reason.
         +/
        discoverAdmin(service, *stored);

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            // If the user has an account, just assign it registered
            if ((stored.class_ != IRCUser.Class.blacklist) &&
                (stored.class_ < IRCUser.Class.registered) &&
                stored.account.length &&
                (stored.account != "*"))
            {
                stored.class_ = IRCUser.Class.registered;
            }
        }

        // Inject the modified user into the event
        user = *stored;

        /+
            Mutually exclusively either remove a user (by its name) from all caches
            OR update its corresponding global user. If no user is to be removed,
            the stored user will be cloned into the global user.

            If there's no global user, that means the user *is* the global user
            and event.channel.name is empty.
         +/
        if (userToRemove.length)
        {
            foreach (ref channelUsers; service.channelUserCache.aaOf)
            {
                channelUsers.remove(userToRemove);
            }

            /+
                If there's no event.channel.name, the global user is created as
                stored is created. If there is an event.channel.name, the global user
                is created shortly after as a second step.
                So we can logically assume string.init to always be in channelUserCache
                and there's no need to be careful about indexing it.
             +/
            service.channelUserCache[string.init].remove(userToRemove);

            // Also remove the user from the nickname-account map
            service.nicknameAccountMap.remove(userToRemove);
        }
        else if (global)  // alternatively if (event.channel.length)
        {
            // There's no point melding since the stored user should be a superset
            // of the values of the global channel-less one.
            *global = *stored;

            if (global.class_ != IRCUser.Class.admin)
            {
                // No channel context for global users; reset class
                // admin is sticky though
                global.class_ = IRCUser.Class.anyone;
            }

            // Global users should never have channel-specific badges
            version(TwitchSupport) global.badges = string.init;
        }
    }

    if (service.state.server.daemon == IRCServer.Daemon.unset)
    {
        if (event.type == IRCEvent.Type.RPL_WELCOME)
        {
            event.target.class_ = IRCUser.Class.anyone;
        }

        // Too early to do anything meaningful, and it throws off Twitch detection
        return false;
    }

    /+
        Some events may carry invalid users, or are otherwise simply not applicable here.
     +/
    if (event.type.among!
        (IRCEvent.Type.ERR_WASNOSUCHNICK,
        IRCEvent.Type.ERR_NOSUCHNICK,
        IRCEvent.Type.RPL_LOGGEDIN,
        IRCEvent.Type.ERR_NICKNAMEINUSE,
        IRCEvent.Type.ERR_BANONCHAN))
    {
        // Ignore
        return false;
    }

    /+
        If there is a channel, check if it's a channel we should be postprocessing
        fully. If not, do the bare minimum and then return false.
     +/
    if (event.channel.name.length)
    {
        import std.algorithm.searching : canFind;

        with (ChannelPolicy)
        final switch (service.settings.omniscienceLevel)
        {
        case home:
            // omniscienceLevel requires a home channel
            if (!service.state.bot.homeChannels.canFind(event.channel.name))
            {
                syncEventUsersWithGlobals(service, event);
                return false;
            }

            // Drop down
            break;

        case guest:
            // omniscienceLevel requires a guest channel or higher
            if (!service.state.bot.homeChannels.canFind(event.channel.name) &&
                !service.state.bot.guestChannels.canFind(event.channel.name))
            {
                syncEventUsersWithGlobals(service, event);
                return false;
            }

            // Drop down
            break;

        case any:
            // omniscienceLevel is okay with any channel
            // Drop down
            break;
        }
    }

    version(TwitchSupport)
    {
        /++
            Nested implementation function so we can properly handle channel and
            subchannel separately.

            Insert channel IDs into and retrieve channel IDs from entries in the
            service state's `channels` AA.

            This allows us to keep track of channel IDs even if it is not sent
            in the event.
         +/
        static void postprocessChannelImpl(
            PersistenceService service,
            ref IRCEvent.Channel channel)
        {
            if (!channel.name.length) return;

            if (auto stateChannel = channel.name in service.state.channels)
            {
                // Channel exists in service state
                if (!stateChannel.id)
                {
                    // It has no ID
                    if (channel.id)
                    {
                        // ...but the event does; inherit it
                        stateChannel.id = channel.id;
                    }
                }
                else if (channel.id && (channel.id != stateChannel.id))
                {
                    // It has an ID and it's different from the event's; insert it
                    channel.id = stateChannel.id;
                }
            }
            else
            {
                // No channel in the service state so just inherit this one
                service.state.channels[channel.name] = IRCChannel(channel);
            }
        }

        postprocessChannelImpl(service, event.channel);
        postprocessChannelImpl(service, event.subchannel);
    }

    postprocessUserImpl(service, event, event.sender, isTarget: false);
    postprocessUserImpl(service, event, event.target, isTarget: true);

    // Nothing in here should warrant a further message check
    return false;
}


// establishUserInCache
/++
    Fetches a user from the cache, creating it first if it doesn't exist by assigning
    it to the passed user.

    Params:
        service = The current [PersistenceService].
        user = The user to fetch.
        channelName = The channel context from which to fetch a user.
        createIfNoneExist = Whether to create the user if it doesn't exist.
        foundExisting = out-parameter, set to `true` if the user was found
            in the cache; `false` if not.

    Returns:
        A pointer to an [dialect.defs.IRCUser|IRCUser] in the cache.
        If none was found and `createIfNoneExist` is `true`, the user will
        have been created and the return value will be a pointer to it.
        If none was found and `createIfNoneExist` is `false`, the return value
        will be `null`.

    See_Also:
        [PersistenceService.channelUserCache]
 +/
auto establishUserInCache(
    PersistenceService service,
    const IRCUser user,
    const string channelName,
    const bool createIfNoneExist,
    out bool foundExisting)
{
    auto channelUsers = channelName in service.channelUserCache;

    if (!channelUsers)
    {
        // Channel doesn't exist
        if (createIfNoneExist)
        {
            // create everything
            service.channelUserCache.aaOf[channelName][user.nickname] = user;
            return user.nickname in service.channelUserCache[channelName];
        }
        else
        {
            return null;
        }
    }
    else
    {
        if (auto channelUser = user.nickname in *channelUsers)
        {
            // Channel and user combination exists
            foundExisting = true;
            return channelUser;
        }
        else
        {
            // Channel exists but user doesn't
            if (createIfNoneExist)
            {
                (*channelUsers)[user.nickname] = user;
                return user.nickname in *channelUsers;
            }
            else
            {
                return null;
            }
        }
    }
}


// resolveAccount
/++
    Attempts to resolve the account of a user by looking it up in the various
    related caches.

    Adds the user's nickname to the nickname-account map if the nickname does
    not already exist in it.

    The user has its `updated` member set to the passed `time` value.

    Params:
        service = The current [PersistenceService].
        user = The [dialect.defs.IRCUser|IRCUser] whose `account` member to
            resolve, taken by `ref`.
        time = The time to set [dialect.defs.IRCUser.account|user.account] to;
            generally the current UNIX time.

    See_Also:
        [resolveClass]
        [PersistenceService.nicknameAccountMap]
 +/
void resolveAccount(
    PersistenceService service,
    ref IRCUser user,
    const long time)
{
    user.updated = time;

    if (user.account.length || (user.account == "*")) return;

    /+
        Check nickname-account map.
     +/
    if (const cachedAccount = user.nickname in service.nicknameAccountMap)
    {
        // hit
        user.account = *cachedAccount;
    }
    else if (service.state.coreSettings.preferHostmasks)
    {
        /+
            No map match, and we're in hostmask mode.
            Look up the nickname in the definitions (from file).
         +/
        foreach (const definition; service.hostmaskDefinitions)
        {
            import dialect.common : matchesByMask;

            if (!definition.account.length) continue;  // Malformed entry

            if (matchesByMask(user, definition))
            {
                // hit
                service.nicknameAccountMap[user.nickname] = definition.account;
                user.account = definition.account;
                return;
            }
        }
    }
    else
    {
        /+
            No map match and we're not in hostmask mode.
            Add a map entry.
         +/
        service.nicknameAccountMap[user.nickname] = user.account;
    }
}


// resolveClass
/++
    Attempt to resolve a user class, in the context of some channel (or globally
    if passed an empty string).

    The user has its `updated` member set to the passed `time` value.

    Params:
        service = The current [PersistenceService].
        user = The [dialect.defs.IRCUser|IRCUser] whose `class_` member to
            resolve, taken by `ref`.
        context = The channel context in which to resolve the class.
        time = The time to set [dialect.defs.IRCUser.class_|user.class_] to;
            generally the current UNIX time.

    See_Also:
        [resolveAccount]
        [PersistenceService.channelUserClassDefinitions]
 +/
void resolveClass(
    PersistenceService service,
    ref IRCUser user,
    const string context,
    const long time)
{
    import std.algorithm.searching : canFind;

    user.updated = time;

    if ((user.class_ == IRCUser.Class.admin) && (user.account != "*"))
    {
        // Admins are always admins, unless they're logging out
        return;
    }

    if (!user.account.length || (user.account == "*"))
    {
        // No account means it's just a random
        user.class_ = IRCUser.Class.anyone;
    }
    else if (service.state.bot.admins.canFind(user.account))
    {
        // admin discovered
        user.class_ = IRCUser.Class.admin;
    }
    else if (context.length)
    {
        /+
            Look up from class definitions (from file) in this channel context.
         +/
        if (const definedUserClasses = context in service.channelUserClassDefinitions)
        {
            if (const class_ = user.account in *definedUserClasses)
            {
                // Channel and user combination exists
                user.class_ = *class_;
            }
        }
    }
    else
    {
        // account has length but there is no channel context
        // --> can at most be registered (or admin, but we ruled that out)
        user.class_ = IRCUser.Class.registered;
    }
}


// dropAllPrivileges
/++
    Drop all privileges from a user, in all channels.

    Params:
        service = The current [PersistenceService].
        nickname = The nickname of the user to drop privileges from.
        classToo = Whether to also drop the class of the user, resetting it to
            [dialect.defs.IRCUser.Class.anyone|IRCUser.Class.anyone].

    See_Also:
        [PersistenceService.channelUserCache]
 +/
void dropAllPrivileges(
    PersistenceService service,
    const string nickname)
{
    foreach (ref channelUsers; service.channelUserCache.aaOf)
    {
        if (auto channelUser = nickname in channelUsers)
        {
            channelUser.class_ = IRCUser.Class.anyone;
            channelUser.account = string.init;
            channelUser.updated = 1L;  // must not be 0L to meld properly
        }
    }
}


// propagateUserAccount
/++
    Propagate a user's account to all channels and the nickname-account map.

    If the account is "*", the user is considered to have logged out of services
    and will be removed instead.

    Params:
        service = The current [PersistenceService].
        user = The [dialect.defs.IRCUser|IRCUser] whose account to propagate.

    See_Also:
        [dropAllPrivileges]
        [PersistenceService.nicknameAccountMap]
 +/
void propagateUserAccount(
    PersistenceService service,
    const IRCUser user)
{
    if (user.account == "*")
    {
        // An account of "*" means the user logged out of services.
        service.nicknameAccountMap.remove(user.nickname);
        dropAllPrivileges(service, user.nickname);
        return;
    }

    if (user.account.length)
    {
        service.nicknameAccountMap[user.nickname] = user.account;
    }
    else
    {
        service.nicknameAccountMap.remove(user.nickname);
    }

    foreach (ref channelUsers; service.channelUserCache.aaOf)
    {
        if (auto channelUser = user.nickname in channelUsers)
        {
            channelUser.account = user.account;
        }
    }
}


// updateUser
/++
    Update a user in the cache, melding the new user into the existing one if
    it exists, or creating it if it doesn't.

    If a channel context is passed, the function recurses with an empty context
    to update the user in the global cache as well.

    Params:
        service = The current [PersistenceService].
        user = The [dialect.defs.IRCUser|IRCUser] to update.
        context = The context to use as key to the cache section to update;
            may be a channel for a channel-specific update, or an empty string
            for a global update.

    See_Also:
        [PersistenceService.channelUserCache]
 +/
void updateUser(
    PersistenceService service,
    /*const*/ IRCUser user,
    const string context)
{
    version(TwitchSupport)
    static void resetUser(IRCUser* user)
    {
        // Global users should never have channel-specific badges
        user.badges = string.init;

        if (user.class_ != IRCUser.Class.admin)
        {
            // admin is sticky but otherwise reset class
            user.class_ = IRCUser.Class.anyone;
        }
    }

    if (auto cachedUsers = context in service.channelUserCache)
    {
        // Channel exists

        auto cachedUser = user.nickname in *cachedUsers;

        if (cachedUser)
        {
            import lu.meld : MeldingStrategy, meldInto;
            user.meldInto!(MeldingStrategy.aggressive)(*cachedUser);
        }
        else
        {
            // but user doesn't
            (*cachedUsers)[user.nickname] = user;
        }

        version(TwitchSupport)
        {
            if (!context.length)
            {
                // Reset global users so they don't have channel-specific badges
                if (!cachedUser) cachedUser = user.nickname in *cachedUsers;
                resetUser(cachedUser);
            }
        }
    }
    else
    {
        // Neither channel nor user exists
        service.channelUserCache.aaOf[context][user.nickname] = user;

        version(TwitchSupport)
        {
            if (!context.length)
            {
                // As above
                auto cachedUser = user.nickname in service.channelUserCache[context];
                resetUser(cachedUser);
            }
        }
    }

    if (context.length)
    {
        // Recurse to update the user in the global cache
        return updateUser(service, user, context: string.init);
    }
}


// onWelcome
/++
    Reloads classifier definitions from disk.

    This is normally done as part of user awareness, but we're not mixing that
    in so we have to reinvent it.

    Purges old cache entries every 12 hours.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PersistenceService service, const IRCEvent _)
{
    import kameloso.constants : BufferSize;
    import core.thread.fiber : Fiber;
    import core.time : hours;

    mixin(memoryCorruptionCheck);

    reloadAccountClassifiersFromDisk(service);
    if (service.state.coreSettings.preferHostmasks) reloadHostmasksFromDisk(service);

    static immutable cacheEntryAgeCheckPeriodicity = 1.hours;
    enum cacheEntryMaxAgeSeconds = 12 * 3600;  // 12 hours

    void purgeOldCacheEntriesDg()
    {
        while (true)
        {
            import kameloso.plugins.common.scheduling : delay;

            // Delay first so we don't purge immediately after loading
            delay(service, cacheEntryAgeCheckPeriodicity, yield: true);
            purgeOldCacheEntries(service, cacheEntryMaxAgeSeconds);
        }
    }

    auto purgeOldCacheEntriesFiber = new Fiber(&purgeOldCacheEntriesDg, BufferSize.fiberStack);
    purgeOldCacheEntriesFiber.call();
}


// onNamesReply
/++
    Catch users in a reply for the request for a NAMES list of all the
    participants in a channel.

    Freenode only sends a list of the nicknames but SpotChat sends the full
    `user!ident@address` information.

    This was copy/pasted from [kameloso.plugins.common.mixins.awareness.onUserAwarenessNamesReply]
    to spare us the full mixin.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_NAMREPLY)
)
void onNamesReply(PersistenceService service, const IRCEvent event)
{
    import kameloso.irccolours : stripColours;
    import dialect.common : IRCControlCharacter, stripModesign;
    import lu.string : advancePast;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;

    mixin(memoryCorruptionCheck);

    if (service.state.server.daemon == IRCServer.Daemon.twitch)
    {
        // Do nothing actually. Twitch NAMES is unreliable noise.
        return;
    }

    auto names = event.content.splitter(' ');

    if (string.init !in service.channelUserCache)
    {
        service.channelUserCache[string.init] = null;
    }

    foreach (immutable userstring; names)
    {
        if (!userstring.canFind('!'))
        {
            // No need to check for slice.contains('@')
            // Freenode-like, only nicknames with possible modesigns
            // No point only registering nicknames
            return;
        }

        // SpotChat-like, names are rich in full nick!ident@address form
        string slice = userstring;  // mutable
        immutable signed = slice.advancePast('!');
        immutable nickname = signed.stripModesign(service.state.server);

        if (auto existingUser = nickname in service.channelUserCache[string.init])
        {
            if (existingUser.account.length)
            {
                // User already exists in the cache and this event will carry no new information
                continue;
            }
        }

        // Do addresses ever contain bold, italics, underlined?
        immutable ident = slice.advancePast('@');
        immutable address = slice.canFind(cast(char) IRCControlCharacter.colour) ?
            stripColours(slice) :
            slice;

        auto user = IRCUser(nickname, ident, address);
        resolveAccount(service, user, event.time);  // this sets user.updated

        if (user.account && service.state.bot.admins.canFind(user.account))
        {
            // admin discovered
            user.class_ = IRCUser.Class.admin;
            propagateUserAccount(service, user);
        }

        updateUser(service, user, event.channel.name);
    }
}


// onWhoReply
/++
    Catch users in a reply for the request for a WHO list of all the
    participants in a channel.

    Each reply event is only for one user, unlike with NAMES.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WHOREPLY)
)
void onWhoReply(PersistenceService service, const IRCEvent event)
{
    mixin(memoryCorruptionCheck);
    updateUser(service, event.target, event.channel.name);
}


// purgeOldCacheEntries
/++
    Walks the channel-user cache and removes entries older than a certain age.
    Additionally removes channels with no users, and nicknames from the nickname
    account map that are not found in any channel.

    Params:
        service = The current [PersistenceService].
        cacheEntryMaxAgeSeconds = The maximum age of a cache entry in seconds;
            older than which will be removed.
 +/
void purgeOldCacheEntries(
    PersistenceService service,
    const long cacheEntryMaxAgeSeconds)
{
    import lu.array : pruneAA;
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime.toUnixTime();

    foreach (immutable channelName, _; service.channelUserCache.aaOf)
    {
        alias userTooOldPred = (user) => (now - user.updated) > cacheEntryMaxAgeSeconds;
        pruneAA!userTooOldPred(service.channelUserCache.aaOf[channelName]);
    }

    alias emptyChannelPred = (channelUsers) => !channelUsers.length;
    pruneAA!emptyChannelPred(service.channelUserCache.aaOf);

    // Array of keys to remove. A bit too complex for pruneAA
    string[] nicknamesToRemoveFromMap;

    accountMapForeach:
    foreach (immutable nickname, const account; service.nicknameAccountMap.aaOf)
    {
        foreach (channelUsers; service.channelUserCache.aaOf)
        {
            foreach (const user; channelUsers)
            {
                if (user.account == account) continue accountMapForeach;
            }
        }

        // No matches found in any channel, else it would have continued accountMapForeach
        nicknamesToRemoveFromMap ~= nickname;
    }

    // Remove the keys
    foreach (immutable nickname; nicknamesToRemoveFromMap)
    {
        service.nicknameAccountMap.remove(nickname);
    }
}

///
unittest
{
    import std.datetime.systime : Clock;

    immutable nowInUnix = Clock.currTime.toUnixTime();

    IRCPluginState state;
    auto service = new PersistenceService(state);

    IRCUser user1;
    user1.nickname = "foo";
    user1.account = "foo";
    user1.updated = nowInUnix;

    IRCUser user2;
    user2.nickname = "bar";
    user2.account = "bar";
    user2.updated = nowInUnix - 3600;

    IRCUser user3;
    user3.nickname = "baz";
    user3.account = "BAZ";
    user3.updated = nowInUnix - 6*3600;

    service.channelUserCache.aaOf["#channel1"]["foo"] = user1;
    service.channelUserCache.aaOf["#channel1"]["bar"] = user2;
    service.channelUserCache.aaOf["#channel1"]["baz"] = user3;
    service.channelUserCache.aaOf["#channel2"]["foo"] = user1;
    service.channelUserCache.aaOf["#channel2"]["bar"] = user2;
    service.channelUserCache.aaOf["#channel3"]["baz"] = user3;

    service.nicknameAccountMap["foo"] = "foo";
    service.nicknameAccountMap["bar"] = "bar";
    service.nicknameAccountMap["baz"] = "BAZ";

    assert(service.channelUserCache["#channel1"].length == 3);
    assert(service.channelUserCache["#channel2"].length == 2);
    assert(service.channelUserCache["#channel3"].length == 1);
    assert(service.nicknameAccountMap.length == 3);

    service.purgeOldCacheEntries(5*3600);

    assert("foo" in service.channelUserCache["#channel1"]);
    assert("bar" in service.channelUserCache["#channel1"]);
    assert("baz" !in service.channelUserCache["#channel1"]);
    assert("foo" in service.channelUserCache["#channel2"]);
    assert("bar" in service.channelUserCache["#channel2"]);
    assert("#channel3" !in service.channelUserCache);

    assert("foo" in service.nicknameAccountMap);
    assert("bar" in service.nicknameAccountMap);
    assert("baz" !in service.nicknameAccountMap);
}


// reload
/++
    Reloads the service, rehashing the user array and loading
    admin/staff/operator/elevated/whitelist/blacklist classifier definitions from disk.
 +/
void reload(PersistenceService service)
{
    reloadAccountClassifiersFromDisk(service);
    if (service.state.coreSettings.preferHostmasks) reloadHostmasksFromDisk(service);
}


// JSONSchema
/++
    JSON schema for the user classification file.
 +/
struct JSONSchema
{
    string[] staff;  ///
    string[] operator;  ///
    string[] elevated;  ///
    string[] whitelist;  ///
    string[] blacklist;  ///

    /++
        Returns a [std.json.JSONValue|JSONValue] of this [JSONSchema].
     +/
    auto asJSONValue() const
    {
        import std.json : JSONValue;

        JSONValue json;
        json.object = null;
        json["staff"] = this.staff;
        json["operator"] = this.operator;
        json["elevated"] = this.elevated;
        json["whitelist"] = this.whitelist;
        json["blacklist"] = this.blacklist;
        return json;
    }
}


// reloadAccountClassifiersFromDisk
/++
    Reloads admin/staff/operator/elevated/whitelist/blacklist classifier definitions from disk.

    Params:
        service = The current [PersistenceService].
 +/
void reloadAccountClassifiersFromDisk(PersistenceService service)
{
    import asdf.serialization : deserialize;
    import lu.conv : toString;
    import std.file : readText;

    immutable content = service.userFile.readText();

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

    auto json = content.deserialize!(JSONSchema[string]);

    service.channelUserClassDefinitions = null;

    foreach (immutable channelName, const channelSchema; json)
    {
        service.channelUserClassDefinitions.aaOf[channelName] = null;
        auto channelClasses = channelName in service.channelUserClassDefinitions;

        foreach (immutable account; channelSchema.staff)
        {
            (*channelClasses)[account] = IRCUser.Class.staff;
        }

        foreach (immutable account; channelSchema.operator)
        {
            (*channelClasses)[account] = IRCUser.Class.operator;
        }

        foreach (immutable account; channelSchema.elevated)
        {
            (*channelClasses)[account] = IRCUser.Class.elevated;
        }

        foreach (immutable account; channelSchema.whitelist)
        {
            (*channelClasses)[account] = IRCUser.Class.whitelist;
        }

        foreach (immutable account; channelSchema.blacklist)
        {
            (*channelClasses)[account] = IRCUser.Class.blacklist;
        }
    }
}


// reloadHostmasksFromDisk
/++
    Reloads hostmasks definitions from disk.

    Params:
        service = The current [PersistenceService].
 +/
void reloadHostmasksFromDisk(PersistenceService service)
{
    import asdf.serialization : deserialize;
    import std.file : readText;

    immutable content = service.hostmasksFile.readText();

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

    auto accountByHostmask = content.deserialize!(string[string]);

    /+
        The nickname-account map is used elsewhere too, so ideally we wouldn't
        reset it here, but we need to ensure it's in sync with the hostmask definitions.
     +/
    service.nicknameAccountMap = null;
    service.hostmaskDefinitions = null;

    foreach (immutable hostmask, const account; accountByHostmask)
    {
        import kameloso.string : doublyBackslashed;
        import dialect.common : isValidHostmask;
        import std.algorithm.searching : canFind;

        alias examplePlaceholderKey1 = PersistenceService.Placeholder.hostmask1;
        alias examplePlaceholderKey2 = PersistenceService.Placeholder.hostmask2;

        if ((hostmask == examplePlaceholderKey1) ||
            (hostmask == examplePlaceholderKey2))
        {
            continue;
        }

        if (!hostmask.isValidHostmask(service.state.server))
        {
            enum pattern =`Malformed hostmask in <l>%s</>: "<l>%s</>"`;
            logger.warningf(pattern, service.hostmasksFile.doublyBackslashed, hostmask);
            continue;
        }
        else if (!account.length)
        {
            enum pattern =`Incomplete hostmask entry in <l>%s</>: "<l>%s</>" has empty account`;
            logger.warningf(pattern, service.hostmasksFile.doublyBackslashed, hostmask);
            continue;
        }

        try
        {
            auto user = IRCUser(hostmask);
            user.account = account;
            service.hostmaskDefinitions ~= user;

            if (user.nickname.length && !user.nickname.canFind('*'))
            {
                // Nickname has length and is not a glob
                // (adding a glob to hostmaskUsers is okay)
                // Overwrite any existing entry
                service.nicknameAccountMap[user.nickname] = user.account;
            }
        }
        catch (Exception e)
        {
            enum pattern =`Exception parsing hostmask in <l>%s</> ("<l>%s</>"): <l>%s`;
            logger.warningf(pattern, service.hostmasksFile.doublyBackslashed, hostmask, e.msg);
            version(PrintStacktraces) logger.trace(e);
        }
    }
}


// initResources
/++
    Initialises the service's hostmasks and accounts resources.

    Merely calls [initAccountResources] and [initHostmaskResources].
 +/
void initResources(PersistenceService service)
{
    initAccountResources(service);
    initHostmaskResources(service);
}


// initAccountResources
/++
    Reads, completes and saves the user classification JSON file, creating one
    if one doesn't exist. Removes any duplicate entries.

    This ensures there will be "staff", "operator", "elevated", "whitelist"
    and "blacklist" arrays in it.

    Params:
        service = The current [PersistenceService].

    Throws:
        [kameloso.plugins.common.IRCPluginInitialisationException|IRCPluginInitialisationException]
        on failure loading the `user.json` file.
 +/
void initAccountResources(PersistenceService service)
{
    import asdf.serialization : deserialize;
    import mir.serde : SerdeException;
    import std.file : exists, readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = service.userFile.readText();

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
        const deserialised = content.deserialize!(JSONSchema[string]);

        JSONValue json;
        json.object = null;

        foreach (immutable channelName, const channelSchema; deserialised)
        {
            json[channelName] = channelSchema.asJSONValue;
        }

        immutable serialised = json.toPrettyString;
        File(service.userFile, "w").writeln(serialised);
    }
    catch (SerdeException e)
    {
        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Users file is malformed",
            pluginName: service.name,
            malformedFilename: service.userFile);
    }
}


// initHostmaskResources
/++
    Reads, completes and saves the hostmasks JSON file, creating one if it doesn't exist.

    Throws:
        [kameloso.plugins.common.IRCPluginInitialisationException|IRCPluginInitialisationException]
        on failure loading the `hostmasks.json` file.
 +/
void initHostmaskResources(PersistenceService service)
{
    import asdf.serialization : deserialize;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    immutable content = service.hostmasksFile.readText();
    string[string] json;

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
        json = content.deserialize!(typeof(json));
    }
    catch (Exception e)
    {
        import kameloso.common : logger;

        version(PrintStacktraces) logger.trace(e);

        throw new IRCPluginInitialisationException(
            message: "Hostmasks file is malformed",
            pluginName: service.name,
            malformedFilename: service.hostmasksFile);
    }

    alias examplePlaceholderKey1 = PersistenceService.Placeholder.hostmask1;
    alias examplePlaceholderKey2 = PersistenceService.Placeholder.hostmask2;
    alias examplePlaceholderValue1 = PersistenceService.Placeholder.account1;
    alias examplePlaceholderValue2 = PersistenceService.Placeholder.account2;

    if (json.length == 0)
    {
        json[examplePlaceholderKey1] = examplePlaceholderValue1;
        json[examplePlaceholderKey2] = examplePlaceholderValue2;
    }
    else if ((json.length > 2) &&
        ((examplePlaceholderKey1 in json) ||
         (examplePlaceholderKey2 in json)))
    {
        json.remove(examplePlaceholderKey1);
        json.remove(examplePlaceholderKey2);
    }

    immutable serialised = JSONValue(json).toPrettyString;
    File(service.hostmasksFile, "w").writeln(serialised);
}


mixin PluginRegistration!(PersistenceService, -50.priority);

public:


// PersistenceService
/++
    The Persistence service melds new [dialect.defs.IRCUser|IRCUser]s (from
    post-processing new [dialect.defs.IRCEvent|IRCEvent]s) with old records of themselves.

    Sometimes the only bit of information about a sender (or target) embedded in
    an [dialect.defs.IRCEvent|IRCEvent] may be his/her nickname, even though the
    event before detailed everything, even including their account name. With
    this service we aim to complete such [dialect.defs.IRCUser|IRCUser] entries as
    the union of everything we know from previous events.

    It only needs part of [kameloso.plugins.common.mixins.awareness.UserAwareness|UserAwareness]
    for minimal bookkeeping, not the full package, so we only copy/paste the
    relevant bits to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
private:
    import kameloso.constants : KamelosoFilenames;
    import lu.container : RehashingAA;

    /++
        Placeholder values.
     +/
    enum Placeholder
    {
        /++
            Hostmask placeholder 1.
         +/
        hostmask1 = "<nickname1>!<ident>@<address>",

        /++
            Hostmask placeholder 2.
         +/
        hostmask2 = "<nickname2>!<ident>@<address>",

        /++
            Channel placeholder.
         +/
        channel = "<#channel>",

        /++
            Account placeholder 1.
         +/
        account1 = "<account1>",

        /++
            Account placeholder 2.
         +/
        account2 = "<account2>",
    }

    /++
        All Persistence settings gathered.
     +/
    PersistenceSettings settings;

    /++
        File with user definitions.
     +/
    @Resource string userFile = KamelosoFilenames.users;

    /++
        File with user hostmasks.
     +/
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    /++
        Associative array of permanent user classifications, per account and
        channel name, read from file.

        Should be considered read-only outside of the initialising functions.
     +/
    RehashingAA!(IRCUser.Class[string][string]) channelUserClassDefinitions;

    /++
        Hostmask definitions as read from file.

        Should be considered read-only outside of the initialising functions.
     +/
    IRCUser[] hostmaskDefinitions;

    /++
        Map of nicknames to accounts, for easy lookup.
     +/
    RehashingAA!(string[string]) nicknameAccountMap;

    /++
        Cache of users by channel and nickname.
     +/
    RehashingAA!(IRCUser[string][string]) channelUserCache;

    /++
        Inherits a user into the cache.

        Params:
            user = The [dialect.defs.IRCUser|IRCUser] to inherit.
            context = The channel context to inherit the user into.
     +/
    public override void putUser(const IRCUser user, const string context)
    {
        .updateUser(this, user, context);
    }

    mixin IRCPluginImpl;
}

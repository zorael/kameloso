/++
    The Persistence service keeps track of all encountered users, gathering as much
    information about them as possible, then injects them into
    [dialect.defs.IRCEvent|IRCEvent]s when information about them is incomplete.

    This means that even if a service only refers to a user by nickname, things
    like its ident and address will be available to plugins as well, assuming
    the Persistence service had seen that previously.

    It has no commands.

    See_Also:
        [kameloso.plugins.common],
        [kameloso.plugins.common.misc]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.services.persistence;

version(WithPersistenceService):

private:

import kameloso.plugins;
import kameloso.plugins.common;
import kameloso.common : logger;
import dialect.defs;


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
        IRCEvent.Type.ERR_NICKNAMEINUSE))
    {
        // Ignore
        return false;
    }

    /++
        Nested implementation function so we can properly handle the sender and
        target separately.
     +/
    static void postprocessImpl(
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
            event.channel,
            createIfNoneExist: true,
            foundExisting: storedUserExisted);

        IRCUser* global;

        if (event.channel.length)
        {
            // A channel was specified, but also look for a global channel-less entry
            bool globalUserExisted;

            global = establishUserInCache(
                service,
                user,
                string.init,
                createIfNoneExist: true,
                foundExisting: globalUserExisted);

            if (globalUserExisted)
            {
                // Fill in the blanks, conservatively
                (*global).meldInto!(MeldingStrategy.conservative)(*stored);
            }
        }

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
            if (service.state.settings.preferHostmasks &&
                (stored.account != old.account))
            {
                // Ignore any new account that may have been parsed and melded from user
                // We only want accounts we resolve in here
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
            case RPL_ENDOFWHOIS:
            case RPL_WHOISUSER:
                resolveAccount(service, *stored, event.time);
                goto default;  // to propagagte account and resolve class

            case NICK:
            case SELFNICK:
                /+
                    This event has two users; a sender pre-nick chang and a
                    target post-nick change. We only want to do this once for
                    the event, so only do it for the target.
                 +/
                if (!isTarget) break;

                if (!storedUserExisted)
                {
                    // The nick event target is blank. This should always be the case.
                    // We could meld but we could also just copy and change the nickname.
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
                goto default;  // to propagagte account and resolve class

            case QUIT:
                // This removes the user entry from both the cache and the nickname-account map
                userToRemove = stored.nickname;
                break;

            case ACCOUNT:
                if (stored.account == "*")
                {
                    // An account of "*" means the user logged out of services.
                    // It's not strictly true but consider him/her as unknown again.
                    service.nicknameAccountMap.remove(stored.nickname);
                    dropAllPrivileges(service, stored.nickname);

                    if (old.account.length)
                    {
                        // Store the previous account in aux[0] if it was known
                        event.aux[0] = old.account;
                    }
                    break;
                }
                goto default;  // to propagagte account and resolve class

            //case JOIN:  // JOINs may carry account depending on server capabilities
            default:
                if (stored.account != old.account)
                {
                    // Event bearing new account
                    // These can be whatever if the "account-tag" capability is set
                    // event.channel may be empty here if we jumped from a RPL_WHOIS* case
                    propagateUserAccount(service, *stored);
                    resolveClass(service, *stored, context: event.channel, event.time);
                }
                break;
            }

            if ((stored.class_ == IRCUser.Class.anyone) &&
                (stored.account.length && (stored.account != "*")))
            {
                stored.class_ = IRCUser.Class.registered;
            }
        }

        version(TwitchSupport)
        {
            if (service.state.server.daemon == IRCServer.Daemon.twitch)
            {
                if (stored.class_ != IRCUser.Class.admin)
                {
                    import std.algorithm.searching : canFind;

                    // We can't really throttle this, but maybe it pales in
                    // comparison to all the AA lookups we're doing
                    if (service.state.bot.admins.canFind(stored.account))
                    {
                        stored.class_ = IRCUser.Class.admin;
                    }
                }

                if (event.channel.length && (stored.class_ == IRCUser.Class.unset))
                {
                    // Users should never be unset in the context of a channel
                    stored.class_ = IRCUser.Class.anyone;
                }
            }
        }

        // Inject the modified user into the event
        user = *stored;

        /+
            Mutually exclusively either remove a user (by its name) from all caches
            OR update its corresponding global user. If no user is to be removed,
            the stored user will be cloned into the global user.

            If there's no global user, that means the user *is* the global user
            and event.channel is empty.
         +/
        if (userToRemove.length)
        {
            foreach (ref channelUsers; service.channelUserCache.aaOf)
            {
                channelUsers.remove(userToRemove);
            }

            if (auto channellessUsers = string.init in service.channelUserCache)
            {
                // channelUserCache[string.init] should always exist but just in case
                (*channellessUsers).remove(userToRemove);
            }

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
                global.class_ = IRCUser.Class.anyone;
            }

            // Global users should never have channel-specific badges
            version(TwitchSupport) global.badges = string.init;
        }
    }

    postprocessImpl(service, event, event.sender, isTarget: false);
    postprocessImpl(service, event, event.target, isTarget: true);

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
    else if (service.state.settings.preferHostmasks)
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

    if (user.class_ == IRCUser.Class.admin)
    {
        // Admins are always admins, unless they're logging out
        if (user.account != "*") return;
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
            Look up from class definitions (from file).
         +/
        if (const userClasses = context in service.channelUserClassDefinitions)
        {
            if (const class_ = user.account in *userClasses)
            {
                // Channel and user combination exists
                user.class_ = *class_;
            }
        }
    }
    else
    {
        // All else failed, consider it a random registered (since account.length > 0)
        user.class_ = user.account.length ?
            IRCUser.Class.registered :
            IRCUser.Class.anyone;
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
    if (!context.length && (user.class_ != IRCUser.Class.admin))
    {
        // When saving to the global cache, only admins should have a class
        user.class_ = IRCUser.Class.anyone;
    }

    if (auto cachedUsers = context in service.channelUserCache)
    {
        // Channel exists
        if (auto cachedUser = user.nickname in *cachedUsers)
        {
            import lu.meld : MeldingStrategy, meldInto;
            user.meldInto!(MeldingStrategy.aggressive)(*cachedUser);
        }
        else
        {
            // but user doesn't
            (*cachedUsers)[user.nickname] = user;
        }
    }
    else
    {
        // Neither channel nor user exists
        service.channelUserCache.aaOf[context][user.nickname] = user;
    }

    if (context.length)
    {
        // Recurse to update the user in the global cache
        return updateUser(service, user, string.init);
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
    .fiber(true)
)
void onWelcome(PersistenceService service)
{
    import kameloso.plugins.common.scheduling : delay;
    import core.time : hours;

    reloadAccountClassifiersFromDisk(service);
    if (service.state.settings.preferHostmasks) reloadHostmasksFromDisk(service);

    static immutable cacheEntryAgeCheckPeriodicity = 1.hours;
    enum cacheEntryMaxAgeSeconds = 12 * 3600;  // 12 hours

    while (true)
    {
        // Delay first so we don't purge immediately after loading
        delay(service, cacheEntryAgeCheckPeriodicity, yield: true);
        purgeOldCacheEntries(service, cacheEntryMaxAgeSeconds);
    }
}


// onNamesReply
/++
    Catch users in a reply for the request for a NAMES list of all the
    participants in a channel.

    Freenode only sends a list of the nicknames but SpotChat sends the full
    `user!ident@address` information.

    This was copy/pasted from [kameloso.plugins.common.awareness.onUserAwarenessNamesReply]
    to spare us the full mixin.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_NAMREPLY)
)
void onNamesReply(PersistenceService service, const ref IRCEvent event)
{
    import kameloso.irccolours : stripColours;
    import dialect.common : IRCControlCharacter, stripModesign;
    import lu.string : advancePast;
    import std.algorithm.iteration : splitter;
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

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
        if (userstring.indexOf('!') == -1)
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
        immutable address = (slice.indexOf(cast(char)IRCControlCharacter.colour) != -1) ?
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

        updateUser(service, user, event.channel);
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
void onWhoReply(PersistenceService service, const ref IRCEvent event)
{
    updateUser(service, event.target, event.channel);
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
    import std.datetime.systime : Clock;
    debug import std.stdio;

    immutable now = Clock.currTime.toUnixTime();

    foreach (ref channelUsers; service.channelUserCache.aaOf)
    {
        // Array of keys to remove, since we can't mutate the AA while foreaching it
        string[] toRemove;

        foreach (const user; channelUsers)
        {
            immutable secondsSinceUserUpdate = (now - user.updated);
            if (secondsSinceUserUpdate > cacheEntryMaxAgeSeconds) toRemove ~= user.nickname;
        }

        // Remove the keys
        foreach (immutable nickname; toRemove)
        {
            channelUsers.remove(nickname);
        }
    }

    // Array of keys to remove, as above
    string[] channelsToRemoveFromCache;

    foreach (immutable channelName, const channelUsers; service.channelUserCache.aaOf)
    {
        if (!channelUsers.length) channelsToRemoveFromCache ~= channelName;
    }

    foreach (const channelName; channelsToRemoveFromCache)
    {
        service.channelUserCache.remove(channelName);
    }

    // Array of keys to remove, as above
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
    if (service.state.settings.preferHostmasks) reloadHostmasksFromDisk(service);
}


// reloadAccountClassifiersFromDisk
/++
    Reloads admin/staff/operator/elevated/whitelist/blacklist classifier definitions from disk.

    Params:
        service = The current [PersistenceService].
 +/
void reloadAccountClassifiersFromDisk(PersistenceService service)
{
    import lu.conv : toString;
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.load(service.userFile);

    service.channelUserClassDefinitions = null;

    static immutable IRCUser.Class[5] classes =
    [
        IRCUser.Class.staff,
        IRCUser.Class.operator,
        IRCUser.Class.elevated,
        IRCUser.Class.whitelist,
        IRCUser.Class.blacklist,
    ];

    foreach (const class_; classes[])
    {
        immutable list = class_.toString();
        const listFromJSON = list in json;

        if (!listFromJSON)
        {
            // Something's wrong, the file is missing sections and must have been manually modified
            continue;
        }

        try
        {
            foreach (immutable channelName, const channelAccountJSON; listFromJSON.object)
            {
                import std.algorithm.searching : startsWith;

                if (channelName.startsWith('<')) continue;  // example placeholder, skip

                foreach (immutable userJSON; channelAccountJSON.array)
                {
                    if (auto channelUsers = channelName in service.channelUserClassDefinitions.aaOf)
                    {
                        (*channelUsers)[userJSON.str] = class_;
                    }
                    else
                    {
                        service.channelUserClassDefinitions.aaOf[channelName][userJSON.str] = class_;
                    }
                }
            }
        }
        catch (JSONException e)
        {
            enum pattern = "JSON exception caught when populating <l>%s</>: <l>%s";
            logger.warningf(pattern, list, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            enum pattern = "Unhandled exception caught when populating <l>%s</>: <l>%s";
            logger.warningf(pattern, list, e.msg);
            version(PrintStacktraces) logger.trace(e);
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
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage hostmasksJSON;
    hostmasksJSON.load(service.hostmasksFile);

    string[string] accountByHostmask;
    accountByHostmask.populateFromJSON(hostmasksJSON);

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
        import std.string : indexOf;

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

            if (user.nickname.length && (user.nickname.indexOf('*') == -1))
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
        [kameloso.plugins.common.misc.IRCPluginInitialisationException|IRCPluginInitialisationException]
        on failure loading the `user.json` file.
 +/
void initAccountResources(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException, JSONValue;

    JSONStorage json;

    try
    {
        json.load(service.userFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Users file is malformed",
            service.name,
            service.userFile,
            __FILE__,
            __LINE__);
    }

    // Let other Exceptions pass.

    static auto deduplicate(JSONValue before)
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto after = before
            .array
            .sort!((a, b) => a.str < b.str)
            .uniq
            .filter!((a) => a.str.length > 0)
            .array;

        return JSONValue(after);
    }

    /+
    unittest
    {
        auto users = JSONValue([ "foo", "bar", "baz", "bar", "foo" ]);
        assert((users.array.length == 5), users.array.length.to!string);

        users = deduplicated(users);
        assert((users == JSONValue([ "bar", "baz", "foo" ])), users.array.to!string);
    }+/

    static immutable string[5] listTypesInOrder =
    [
        "staff",
        "operator",
        "elevated",
        "whitelist",
        "blacklist",
    ];

    foreach (liststring; listTypesInOrder[])
    {
        alias examplePlaceholderKey = PersistenceService.Placeholder.channel;
        auto listJSON = liststring in json;

        if (!listJSON)
        {
            json[liststring] = null;
            json[liststring].object = null;
            listJSON = liststring in json;

            (*listJSON)[examplePlaceholderKey] = null;
            (*listJSON)[examplePlaceholderKey].array = null;

            auto listPlaceholder = examplePlaceholderKey in *listJSON;
            listPlaceholder.array ~= JSONValue("<nickname1>");
            listPlaceholder.array ~= JSONValue("<nickname2>");
        }
        else /*if (listJSON)*/
        {
            if ((listJSON.object.length > 1) &&
                (examplePlaceholderKey in *listJSON))
            {
                listJSON.object.remove(examplePlaceholderKey);
            }

            try
            {
                foreach (immutable channelName, ref channelAccountsJSON; listJSON.object)
                {
                    if (channelName == examplePlaceholderKey) continue;
                    channelAccountsJSON = deduplicate((*listJSON)[channelName]);
                }
            }
            catch (JSONException e)
            {
                import kameloso.plugins.common.misc : IRCPluginInitialisationException;
                import kameloso.common : logger;

                version(PrintStacktraces) logger.trace(e);
                throw new IRCPluginInitialisationException(
                    "Users file is malformed",
                    service.name,
                    service.userFile,
                    __FILE__,
                    __LINE__);
            }
        }
    }

    // Force staff, operator and whitelist to appear before blacklist in the .json
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, listTypesInOrder);
}


// initHostmaskResources
/++
    Reads, completes and saves the hostmasks JSON file, creating one if it doesn't exist.

    Throws:
        [kameloso.plugins.common.misc.IRCPluginInitialisationException|IRCPluginInitialisationException]
        on failure loading the `hostmasks.json` file.
 +/
void initHostmaskResources(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;

    try
    {
        json.load(service.hostmasksFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
        import kameloso.common : logger;

        version(PrintStacktraces) logger.trace(e);
        throw new IRCPluginInitialisationException(
            "Hostmasks file is malformed",
            service.name,
            service.hostmasksFile,
            __FILE__,
            __LINE__);
    }

    alias examplePlaceholderKey1 = PersistenceService.Placeholder.hostmask1;
    alias examplePlaceholderKey2 = PersistenceService.Placeholder.hostmask2;
    alias examplePlaceholderValue1 = PersistenceService.Placeholder.account1;
    alias examplePlaceholderValue2 = PersistenceService.Placeholder.account2;

    if (json.object.length == 0)
    {
        json[examplePlaceholderKey1] = null;
        json[examplePlaceholderKey1].str = null;
        json[examplePlaceholderKey1].str = examplePlaceholderValue1;
        json[examplePlaceholderKey2] = null;
        json[examplePlaceholderKey2].str = null;
        json[examplePlaceholderKey2].str = examplePlaceholderValue2;
    }
    else if ((json.object.length > 2) &&
        ((examplePlaceholderKey1 in json) ||
         (examplePlaceholderKey2 in json)))
    {
        json.object.remove(examplePlaceholderKey1);
        json.object.remove(examplePlaceholderKey2);
    }

    // Let other Exceptions pass.

    // Adjust saved JSON layout to be more easily edited
    json.save!(JSONStorage.KeyOrderStrategy.passthrough)(service.hostmasksFile);
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

    It only needs part of [kameloso.plugins.common.awareness.UserAwareness|UserAwareness]
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

/++
    The Persistence service keeps track of all encountered users, gathering as much
    information about them as possible, then injects them into
    [dialect.defs.IRCEvent|IRCEvent]s when information about them is incomplete.

    This means that even if a service only refers to a user by nickname, things
    like its ident and address will be available to plugins as well, assuming
    the Persistence service had seen that previously.

    It has no commands.

    See_Also:
        [kameloso.plugins.common.core|plugins.common.core]
        [kameloso.plugins.common.misc|plugins.common.misc]
 +/
module kameloso.plugins.services.persistence;

version(WithPersistenceService):

private:

import kameloso.plugins.common.core;
import kameloso.common : logger;
import dialect.defs;


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] after parsing and
    fleshes out the [dialect.defs.IRCEvent.sender] and/or
    [dialect.defs.IRCEvent.target] fields, so that things like account names
    that are only sent sometimes carry over.

    Merely leverages [postprocessCommon].
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    with (IRCEvent.Type)
    switch (event.type)
    {
    case ERR_WASNOSUCHNICK:
    case ERR_NOSUCHNICK:
    case RPL_LOGGEDIN:
    case ERR_NICKNAMEINUSE:
        // Invalid user or inapplicable, don't complete it
        return;

    case NICK:
    case SELFNICK:
        // Clone the stored sender into a new stored target.
        // Don't delete the old user yet.

        if (const stored = event.sender.nickname in service.state.users)
        {
            service.state.users[event.target.nickname] = *stored;
            ++service.usersAddedSinceLastRehash;
            service.maybeRehash();

            auto newUser = event.target.nickname in service.state.users;
            newUser.nickname = event.target.nickname;

            if (service.state.settings.preferHostmasks)
            {
                // Drop all privileges
                newUser.class_ = IRCUser.Class.anyone;
                newUser.account = string.init;
                newUser.updated = 1L;
            }
        }

        if (!service.state.settings.preferHostmasks)
        {
            if (const channelName = event.sender.nickname in service.userClassChannelCache)
            {
                service.userClassChannelCache[event.target.nickname] = *channelName;
            }
        }

        goto default;

    default:
        return postprocessCommon(service, event);
    }
}


// postprocessCommon
/++
    Postprocessing implementation common for service and hostmasks mode.
 +/
void postprocessCommon(PersistenceService service, ref IRCEvent event)
{
    static void postprocessImpl(PersistenceService service, ref IRCEvent event, ref IRCUser user)
    {
        import std.algorithm.searching : canFind;

        // Ignore server events and certain pre-registration events where our nick is unknown
        if (!user.nickname.length || (user.nickname == "*")) return;

        /++
            Returns the recorded "account" of a user. For use in hostmasks mode.
         +/
        static string getAccount(PersistenceService service, const IRCUser user)
        {
            if (const cachedAccount = user.nickname in service.hostmaskNicknameAccountCache)
            {
                return *cachedAccount;
            }

            foreach (const storedUser; service.hostmaskUsers)
            {
                import dialect.common : matchesByMask;

                if (!storedUser.account.length) continue;

                if (matchesByMask(user, storedUser))
                {
                    service.hostmaskNicknameAccountCache[user.nickname] = storedUser.account;
                    return storedUser.account;
                }
            }

            return string.init;
        }

        /++
            Tries to apply any permanent class for a user in a channel, and if
            none available, tries to set one that seems to apply based on what
            the user looks like.
         +/
        static void applyClassifiers(
            PersistenceService service,
            const ref IRCEvent event,
            ref IRCUser user)
        {
            if ((user.class_ == IRCUser.Class.admin) && (user.account != "*"))
            {
                // Do nothing, admin is permanent and program-wide
                // unless it's someone logging out
                return;
            }

            if (service.state.settings.preferHostmasks && !user.account.length)
            {
                user.account = getAccount(service, user);
                if (user.account.length) user.updated = event.time;
            }

            bool set;

            if (!user.account.length || (user.account == "*"))
            {
                // No account means it's just a random
                user.class_ = IRCUser.Class.anyone;
                set = true;
            }
            else if (service.state.bot.admins.canFind(user.account))
            {
                // admin discovered
                user.class_ = IRCUser.Class.admin;
                return;
            }
            else if (event.channel.length)
            {
                if (const classAccounts = event.channel in service.channelUsers)
                {
                    if (const definedClass = user.account in *classAccounts)
                    {
                        // Permanent class is defined, so apply it
                        user.class_ = *definedClass;
                        set = true;
                    }
                }
            }

            if (!set)
            {
                // All else failed, consider it a random registered or anyone, depending on server
                user.class_ = (service.state.server.daemon == IRCServer.Daemon.twitch) ?
                    IRCUser.Class.anyone : IRCUser.Class.registered;
            }

            // Record this channel as being the one the current class_ applies to.
            // That way we only have to look up a class_ when the channel has changed.
            service.userClassChannelCache[user.nickname] = event.channel;
        }

        // Save cache lookups so we don't do them more than once.
        string* cachedChannel;

        auto stored = user.nickname in service.state.users;
        immutable persistentCacheMiss = stored is null;

        if (service.state.settings.preferHostmasks)
        {
            // Ignore any account that may have been parsed
            user.account = string.init;
        }
        else /*if (!service.state.settings.preferHostmasks)*/
        {
            if (service.state.server.daemon != IRCServer.Daemon.twitch)
            {
                // Apply class here on events that carry new account information.

                with (IRCEvent.Type)
                switch (event.type)
                {
                case JOIN:
                case RPL_WHOISACCOUNT:
                case RPL_WHOISUSER:
                case RPL_WHOISREGNICK:
                    applyClassifiers(service, event, user);
                    break;

                case ACCOUNT:
                    if ((user.account == "*") && stored.account.length)
                    {
                        event.aux = stored.account;
                        goto case RPL_WHOISACCOUNT;
                    }
                    break;

                default:
                    if ((user.account.length && (user.account != "*")) ||
                        (!persistentCacheMiss && !stored.account.length))
                    {
                        // Unexpected event bearing new account
                        // These can be whatever if the "account-tag" capability is set
                        goto case RPL_WHOISACCOUNT;
                    }
                    break;
                }
            }
        }

        if (persistentCacheMiss)
        {
            service.state.users[user.nickname] = user;
            ++service.usersAddedSinceLastRehash;
            service.maybeRehash();
            stored = user.nickname in service.state.users;
        }
        else
        {
            import lu.meld : MeldingStrategy, meldInto;
            // Meld into the stored user, and store the union in the event
            // Skip if the current stored is just a direct copy of user
            // Store initial class and restore after meld. The origin user.class_
            // can ever only be IRCUser.Class.unset UNLESS altered in the switch above.
            // Additionally snapshot the .updated value and restore it after melding

            version(TwitchSupport)
            {
                if (service.state.server.daemon == IRCServer.Daemon.twitch)
                {
                    if (!event.channel.length)
                    {
                        stored.badges = string.init;
                    }
                    else if (stored.badges.length && !user.badges.length)
                    {
                        // The current user doesn't have any badges and the stored one
                        // does, potentially for a different channel. Look it up and
                        // save the AA lookup pointer for later checks, in case we
                        // have to do this again down below.

                        /*const*/ cachedChannel = stored.nickname in service.userClassChannelCache;

                        if (!cachedChannel || (*cachedChannel != event.channel))
                        {
                            // Current event has no badges but the stored one has
                            // and for a different channel. Clear them.
                            stored.badges = string.init;
                        }
                    }
                }
            }

            immutable preMeldClass = stored.class_;
            immutable preMeldUpdated = stored.updated;
            user.meldInto!(MeldingStrategy.aggressive)(*stored);
            stored.updated = preMeldUpdated;

            if (stored.class_ == IRCUser.Class.unset)
            {
                // The class was not changed, restore the previously saved one
                stored.class_ = preMeldClass;
            }
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            if (!service.state.settings.preferHostmasks)
            {
                with (IRCEvent.Type)
                switch (event.type)
                {
                case RPL_WHOISACCOUNT:
                case RPL_WHOISREGNICK:
                case RPL_ENDOFWHOIS:
                    // Record updated timestamp; this is the end of a WHOIS
                    stored.updated = event.time;
                    break;

                case ACCOUNT:
                case JOIN:
                    if (stored.account == "*")
                    {
                        // An account of "*" means the user logged out of services
                        // It's not strictly true but consider him/her as unknown again.
                        stored.account = string.init;
                        stored.class_ = IRCUser.Class.anyone;
                        stored.updated = 1L;  // To facilitate melding
                        service.userClassChannelCache.remove(stored.nickname);
                    }
                    else
                    {
                        // Record updated timestamp; new account known
                        stored.updated = event.time;
                    }
                    break;

                default:
                    break;
                }
            }
            else /*if (service.state.settings.preferHostmasks)*/
            {
                if (event.type == IRCEvent.Type.RPL_ENDOFWHOIS)
                {
                    // As above
                    stored.updated = event.time;
                }
            }
        }

        version(TwitchSupport)
        {
            // Clear badges if it has the empty placeholder asterisk
            if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
                (stored.badges == "*"))
            {
                stored.badges = string.init;
            }
        }

        if ((stored.class_ == IRCUser.Class.admin) && (stored.account != "*"))
        {
            // Do nothing, admin is permanent and program-wide
            // unless it's someone logging out
        }
        else if (!event.channel.length)
        {
            // Not in a channel. Additionally not an admin
            // Default to registered if the user has an account, except on Twitch
            // postprocess in twitch/base.d will assign class as per badges

            if (service.state.server.daemon == IRCServer.Daemon.twitch)
            {
                version(TwitchSupport)
                {
                    // This needs to be versioned becaused IRCUser.badges isn't
                    // available if not version TwitchSupport
                    stored.class_ = IRCUser.Class.anyone;
                    //stored.badges = string.init;  // already done above on cache hit
                }
            }
            else if (stored.account.length && (stored.account != "*"))
            {
                stored.class_ = IRCUser.Class.registered;
            }
            else
            {
                stored.class_ = IRCUser.Class.anyone;
            }
            service.userClassChannelCache.remove(user.nickname);
        }
        else /*if (channel.length)*/
        {
            // Non-admin, channel present. Perform a new cache lookup if none was
            // previously made, otherwise reuse the earlier hit.

            if (!cachedChannel)
            {
                /*const*/ cachedChannel = stored.nickname in service.userClassChannelCache;
            }

            if (!cachedChannel || (*cachedChannel != event.channel))
            {
                // User has no cached channel. Alternatively, user's cached channel
                // is different from this one; class likely differs.
                applyClassifiers(service, event, *stored);
            }
        }

        // Inject the modified user into the event
        user = *stored;
    }

    postprocessImpl(service, event, event.sender);
    postprocessImpl(service, event, event.target);
}


// onQuit
/++
    Removes a user's [dialect.defs.IRCUser|IRCUser] entry from the `users`
    associative array of the current [PersistenceService]'s
    [kameloso.plugins.common.core.IRCPluginState|IRCPluginState] upon them disconnecting.

    Additionally from the nickname-channel cache.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.QUIT)
)
void onQuit(PersistenceService service, const ref IRCEvent event)
{
    if (service.state.settings.preferHostmasks)
    {
        service.hostmaskNicknameAccountCache.remove(event.sender.nickname);
    }

    service.state.users.remove(event.sender.nickname);
    service.userClassChannelCache.remove(event.sender.nickname);
}


// onNick
/++
    Removes old user entries when someone changes nickname. The old nickname
    no longer exists and the storage arrays should reflect that.

    Annotated [kameloso.plugins.common.core.Timing.cleanup|Timing.cleanup] to
    delay execution.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.NICK)
    .onEvent(IRCEvent.Type.SELFNICK)
    .when(Timing.cleanup)
)
void onNick(PersistenceService service, const ref IRCEvent event)
{
    // onQuit already doees everything this function wants to do.
    return onQuit(service, event);
}


// onWelcome
/++
    Reloads classifier definitions from disk. Additionally rehashes the user array,
    allowing for optimised access.

    This is normally done as part of user awareness, but we're not mixing that
    in so we have to reinvent it.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PersistenceService service)
{
    import kameloso.plugins.common.delayawait : delay;
    import kameloso.constants : BufferSize;
    import std.typecons : Flag, No, Yes;
    import core.thread : Fiber;

    service.reloadAccountClassifiersFromDisk();
    if (service.state.settings.preferHostmasks) service.reloadHostmasksFromDisk();
}


// maybeRehash
/++
    Rehashes cache arrays if we deem enough new users have been added to them
    since the last rehash to warrant it.

    Params:
        service = Current [PersistenceService].
 +/
void maybeRehash(PersistenceService service)
{
    enum minimumAddedNeededForRehash = 128;
    enum rehashThresholdMultiplier = 1.0;

    if ((service.usersAddedSinceLastRehash > minimumAddedNeededForRehash) &&
        (service.usersAddedSinceLastRehash > (service.state.users.length * rehashThresholdMultiplier)))
    {
        service.state.users = service.state.users.rehash();
        service.userClassChannelCache = service.userClassChannelCache.rehash();
        service.hostmaskNicknameAccountCache = service.hostmaskNicknameAccountCache.rehash();
        service.channelUsers = service.channelUsers.rehash();

        foreach (ref channelUsers; service.channelUsers)
        {
            channelUsers = channelUsers.rehash();
        }

        service.usersAddedSinceLastRehash = 0;
    }
}


// reload
/++
    Reloads the service, rehashing the user array and loading
    admin/whitelist/blacklist classifier definitions from disk.
 +/
void reload(PersistenceService service)
{
    service.state.users = service.state.users.rehash();
    service.reloadAccountClassifiersFromDisk();
    if (service.state.settings.preferHostmasks) service.reloadHostmasksFromDisk();
}


// reloadAccountClassifiersFromDisk
/++
    Reloads admin/staff/operator/elevated/whitelist/blacklist classifier definitions from disk.

    Params:
        service = The current [PersistenceService].
 +/
void reloadAccountClassifiersFromDisk(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    service.channelUsers.clear();

    import lu.conv : Enum;

    static immutable classes =
    [
        IRCUser.Class.staff,
        IRCUser.Class.operator,
        IRCUser.Class.elevated,
        IRCUser.Class.whitelist,
        IRCUser.Class.blacklist,
    ];

    foreach (class_; classes)
    {
        immutable list = Enum!(IRCUser.Class).toString(class_);
        const listFromJSON = list in json;

        if (!listFromJSON)
        {
            json[list] = null;
            json[list].object = null;
        }

        try
        {
            foreach (immutable channelName, const channelAccountJSON; listFromJSON.object)
            {
                import lu.string : beginsWith;

                if (channelName.beginsWith('<')) continue;

                foreach (immutable userJSON; channelAccountJSON.array)
                {
                    if (channelName !in service.channelUsers)
                    {
                        service.channelUsers[channelName] = (IRCUser.Class[string]).init;
                    }

                    service.channelUsers[channelName][userJSON.str] = class_;
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

    service.hostmaskUsers = null;
    service.hostmaskNicknameAccountCache.clear();

    foreach (immutable hostmask, immutable account; accountByHostmask)
    {
        import dialect.common : isValidHostmask;
        import lu.string : contains;

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
            logger.warningf(pattern, service.hostmasksFile, hostmask);
            continue;
        }
        else if (!account.length)
        {
            enum pattern =`Incomplete hostmask entry in <l>%s</>: "<l>%s</>" has empty account`;
            logger.warningf(pattern, service.hostmasksFile, hostmask);
            continue;
        }

        try
        {
            auto user = IRCUser(hostmask);
            user.account = account;
            service.hostmaskUsers ~= user;

            if (user.nickname.length && !user.nickname.contains('*'))
            {
                // Nickname has length and is not a glob
                // (adding a glob to hostmaskUsers is okay)
                service.hostmaskNicknameAccountCache[user.nickname] = user.account;
            }
        }
        catch (Exception e)
        {
            enum pattern =`Exception parsing hostmask in <l>%s</> ("<l>%s</>"): <l>%s`;
            logger.warningf(pattern, service.hostmasksFile, hostmask, e.msg);
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
    service.initAccountResources();
    service.initHostmaskResources();
}


// initAccountResources
/++
    Reads, completes and saves the user classification JSON file, creating one
    if one doesn't exist. Removes any duplicate entries.

    This ensures there will be "whitelist", "operator", "staff" and "blacklist"
    arrays in it.

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
    json.reset();

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
        assert((users.array.length == 5), users.array.length.text);

        users = deduplicated(users);
        assert((users == JSONValue([ "bar", "baz", "foo" ])), users.array.text);
    }+/

    //import std.range : only;

    static immutable listTypes =
    [
        "staff",
        "operator",
        "elevated",
        "whitelist",
        "blacklist",
    ];

    foreach (liststring; listTypes)
    {
        alias examplePlaceholderKey = PersistenceService.Placeholder.channel;

        if (liststring !in json)
        {
            json[liststring] = null;
            json[liststring].object = null;
            json[liststring][examplePlaceholderKey] = null;
            json[liststring][examplePlaceholderKey].array = null;
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname1>");
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname2>");
        }
        else
        {
            if ((json[liststring].object.length > 1) &&
                (examplePlaceholderKey in json[liststring].object))
            {
                json[liststring].object.remove(examplePlaceholderKey);
            }

            try
            {
                foreach (immutable channelName, ref channelAccountsJSON; json[liststring].object)
                {
                    if (channelName == examplePlaceholderKey) continue;
                    channelAccountsJSON = deduplicate(json[liststring][channelName]);
                }
            }
            catch (JSONException e)
            {
                import kameloso.plugins.common.misc : IRCPluginInitialisationException;
                import kameloso.common : logger;
                import std.path : baseName;

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
    static immutable order = [ "staff", "operator", "elevated", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
}


// initHostmaskResources
/++
    Reads, completes and saves the hostmasks JSON file, creating one if it
    doesn't exist.

    Throws:
        [kameloso.plugins.common.misc.IRCPluginInitialisationException|IRCPluginInitialisationException]
        on failure loading the `hostmasks.json` file.
 +/
void initHostmaskResources(PersistenceService service)
{
    import lu.json : JSONStorage;
    import std.json : JSONException, JSONValue;

    JSONStorage json;
    json.reset();

    try
    {
        json.load(service.hostmasksFile);
    }
    catch (JSONException e)
    {
        import kameloso.plugins.common.misc : IRCPluginInitialisationException;
        import kameloso.common : logger;
        import std.path : baseName;

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

    /// Placeholder values.
    enum Placeholder
    {
        /// Hostmask placeholder 1.
        hostmask1 = "<nickname1>!<ident>@<address>",

        /// Hostmask placeholder 2.
        hostmask2 = "<nickname2>!<ident>@<address>",

        /// Channel placeholder.
        channel = "<#channel>",

        /// Account placeholder 1.
        account1 = "<account1>",

        /// Account placeholder 2.
        account2 = "<account2>",
    }

    /// File with user definitions.
    @Resource string userFile = KamelosoFilenames.users;

    /// File with user hostmasks.
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    /// Associative array of permanent user classifications, per account and channel name.
    IRCUser.Class[string][string] channelUsers;

    /// Hostmask definitions as read from file. Should be considered read-only.
    IRCUser[] hostmaskUsers;

    /// Cached nicknames matched to defined hostmasks.
    string[string] hostmaskNicknameAccountCache;

    /// Associative array of which channel the latest class lookup for an account related to.
    string[string] userClassChannelCache;

    /++
        How many users have been added to the
        [kameloso.plugins.common.core.IRCPluginState.users|IRCPluginState.users]
        associative array since it was last rehashed.
     +/
    uint usersAddedSinceLastRehash;

    mixin IRCPluginImpl;
}

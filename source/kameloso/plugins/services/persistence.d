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
import kameloso.thread : Sendable;
import dialect.defs;


// postprocess
/++
    Hijacks a reference to a [dialect.defs.IRCEvent|IRCEvent] after parsing and
    fleshes out the [dialect.defs.IRCEvent.sender|IRCEvent.sender] and/or
    [dialect.defs.IRCEvent.target|IRCEvent.target] fields, so that things like
    account names that are only sent sometimes carry over.

    Merely leverages [postprocessCommon].
 +/
auto postprocess(PersistenceService service, ref IRCEvent event)
{
    static void postprocessImpl(PersistenceService service, ref IRCEvent event, ref IRCUser user)
    {
        import std.algorithm.searching : canFind;

        // Ignore server events and certain pre-registration events where our nick is unknown
        if (!user.nickname.length || (user.nickname == "*")) return;

        /++
            Attempt to resolve a user class.
         +/
        static void resolveClass(
            PersistenceService service,
            const ref IRCEvent event,
            ref IRCUser user)
        in ((service.state.server.daemon == IRCServer.Daemon.twitch),
            "`persistence.postprocessCommon.resolveClass` should not be called on Twitch")
        {
            user.updated = event.time;

            if (service.state.settings.preferHostmasks && !user.account.length)
            {
                if (const cachedAccount = user.nickname in service.hostmaskNicknameAccountCache)
                {
                    user.account = *cachedAccount;
                }
                else
                {
                    foreach (const storedUser; service.hostmaskUsers)
                    {
                        import dialect.common : matchesByMask;

                        if (!storedUser.account.length) continue;

                        if (matchesByMask(user, storedUser))
                        {
                            service.hostmaskNicknameAccountCache[user.nickname] = storedUser.account;
                            user.account = storedUser.account;
                        }
                    }
                }

                // Drop down
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
            else if (event.channel.length)
            {
                /+
                    Look up from class definitions (from file).
                 +/
                if (const userClassesForChannel = event.channel in service.channelUserClassDefinitions)
                {
                    if (const class_ = user.account in *userClassesForChannel)
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

        /++
            Drop all privileges from a user.
         +/
        static void dropAllPrivileges(ref IRCUser user)
        {
            user.class_ = IRCUser.Class.anyone;
            user.account = string.init;
            user.updated = 1L;  // must not be 0L
        }

        /++
            Fetch a user by an identifier from cache, creating it if one doesn't exist.
         +/
        auto fetchUserFromCache(const string userIdentifier, out bool shouldMeldWithUser)
        {
            auto channelUsers = event.channel in service.channelUserCache;

            if (!channelUsers)
            {
                // Channel doesn't exist, create everything
                service.channelUserCache[event.channel] = null;  // FIXME: RehashingAA quirk
                service.channelUserCache[event.channel][userIdentifier] = user;
                return userIdentifier in service.channelUserCache[event.channel];
            }
            else
            {
                if (auto channelUser = userIdentifier in *channelUsers)
                {
                    // Channel and user combination exists
                    shouldMeldWithUser = true;
                    return channelUser;
                }
                else
                {
                    // Channel exists but user doesn't
                    (*channelUsers)[userIdentifier] = user;
                    return userIdentifier in *channelUsers;
                }
            }
        }

        if (user.class_ == IRCUser.Class.admin)
        {
            if (user.account != "*") return;
            user.class_ = IRCUser.Class.anyone;
        }

        immutable userIdentifier = (user.account == "*") ? user.nickname : user.account;
        immutable serverIsTwitch = (service.state.server.daemon == IRCServer.Daemon.twitch);
        bool shouldMeldWithUser;

        auto stored = fetchUserFromCache(userIdentifier, shouldMeldWithUser);
        const old = *stored;

        if (shouldMeldWithUser)
        {
            import lu.meld : MeldingStrategy, meldInto;

            user.meldInto!(MeldingStrategy.aggressive)(*stored);
            stored.class_ = old.class_;
            stored.updated = old.updated;
        }

        if (service.state.settings.preferHostmasks)
        {
            // Ignore any account that may have been parsed
            stored.account = string.init;
        }

        if (!serverIsTwitch)
        {
            // Apply class here on events that carry new account information.

            with (IRCEvent.Type)
            switch (event.type)
            {
            case RPL_WHOISACCOUNT:
            case RPL_WHOISREGNICK:
            case RPL_ENDOFWHOIS:
            case RPL_WHOISUSER:
                resolveClass(service, event, *stored);
                break;

            case NICK:
            case SELFNICK:
                if (user.class_ != IRCUser.Class.admin)
                {
                    dropAllPrivileges(*stored);
                    resolveClass(service, event, *stored);
                }
                break;

            case ACCOUNT:
                if (user.account == "*")
                {
                    // An account of "*" means the user logged out of services
                    // It's not strictly true but consider him/her as unknown again.
                    dropAllPrivileges(*stored);

                    if (old.account.length)
                    {
                        // Keep the previous account in aux[0] if it was known
                        event.aux[0] = old.account;
                    }
                }

                resolveClass(service, event, *stored);
                break;

            case JOIN:
                resolveClass(service, event, *stored);
                break;

            case ERR_WASNOSUCHNICK:
            case ERR_NOSUCHNICK:
            case RPL_LOGGEDIN:
            case ERR_NICKNAMEINUSE:
                // Invalid user or unapplicable, ignore
                return;

            default:
                if (!old.account.length && user.account.length && (user.account != "*"))
                {
                    // Unexpected event bearing new account
                    // These can be whatever if the "account-tag" capability is set
                    resolveClass(service, event, *stored);
                }
                break;
            }

            stored.class_ = (stored.account.length && (stored.account != "*")) ?
                IRCUser.Class.registered :
                IRCUser.Class.anyone;
        }

        version(TwitchSupport)
        {
            if (serverIsTwitch)
            {
                // Clear badges if it has the empty placeholder asterisk
                if (stored.badges == "*")
                {
                    stored.badges = string.init;
                }

                // Users should never be unset
                if (stored.class_ == IRCUser.Class.unset)
                {
                    stored.class_ = IRCUser.Class.anyone;
                }
            }
        }

        // Inject the modified user into the event
        user = *stored;
    }

    postprocessImpl(service, event, event.sender);
    postprocessImpl(service, event, event.target);

    // Nothing in here should warrant a further message check
    return false;
}


// onQuit
/++
    Removes a user's [dialect.defs.IRCUser|IRCUser] entry from the `users`
    associative array of the current [PersistenceService]'s
    [kameloso.plugins.common.IRCPluginState|IRCPluginState] upon them disconnecting.

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

    foreach (immutable channelName, channelUsers; service.channelUserCache.aaOf)
    {
        channelUsers.remove(event.sender.nickname);
        if (event.sender.account.length) channelUsers.remove(event.sender.account);
    }
}


// onNick
/++
    Removes old user entries when someone changes nickname. The old nickname
    no longer exists and the storage arrays should reflect that.

    Annotated [kameloso.plugins.common.Timing.cleanup|Timing.cleanup] to
    delay execution.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.NICK)
    .onEvent(IRCEvent.Type.SELFNICK)
    .when(Timing.cleanup)
)
void onNick(PersistenceService service, const ref IRCEvent event)
{
    // onQuit already does everything this function wants to do.
    // Do not move the old user to the new one, as this is done in postprocess.
    onQuit(service, event);
}


// onWelcome
/++
    Reloads classifier definitions from disk.

    This is normally done as part of user awareness, but we're not mixing that
    in so we have to reinvent it.
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.RPL_WELCOME)
)
void onWelcome(PersistenceService service)
{
    reloadAccountClassifiersFromDisk(service);
    if (service.state.settings.preferHostmasks) reloadHostmasksFromDisk(service);
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
    import kameloso.plugins.common.misc : catchUser;
    import kameloso.irccolours : stripColours;
    import dialect.common : IRCControlCharacter, stripModesign;
    import lu.string : advancePast;
    import std.algorithm.iteration : splitter;
    import std.string : indexOf;

    if (service.state.server.daemon == IRCServer.Daemon.twitch)
    {
        // Do nothing actually. Twitch NAMES is unreliable noise.
        return;
    }

    auto names = event.content.splitter(' ');

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
        //if (nickname == service.state.client.nickname) continue;
        immutable ident = slice.advancePast('@');

        // Do addresses ever contain bold, italics, underlined?
        immutable address = (slice.indexOf(cast(char)IRCControlCharacter.colour) != -1) ?
            stripColours(slice) :
            slice;

        catchUser(service, IRCUser(nickname, ident, address));  // this melds with the default conservative strategy
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
    import kameloso.plugins.common.misc : catchUser;
    catchUser(service, event.target);
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

                if (channelName.startsWith('<')) continue;

                foreach (immutable userJSON; channelAccountJSON.array)
                {
                    auto theseUsers = channelName in service.channelUserClassDefinitions;

                    if (!theseUsers)
                    {
                        service.channelUserClassDefinitions[channelName] = (IRCUser.Class[string]).init;
                        theseUsers = channelName in service.channelUserClassDefinitions;
                    }

                    (*theseUsers)[userJSON.str] = class_;
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
    //hostmasksJSON.reset();
    hostmasksJSON.load(service.hostmasksFile);

    string[string] accountByHostmask;
    accountByHostmask.populateFromJSON(hostmasksJSON);

    service.hostmaskUsers = null;
    service.hostmaskNicknameAccountCache = null;

    foreach (immutable hostmask, immutable account; accountByHostmask)
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
            service.hostmaskUsers ~= user;

            if (user.nickname.length && (user.nickname.indexOf('*') == -1))
            {
                // Nickname has length and is not a glob
                // (adding a glob to hostmaskUsers is okay)
                service.hostmaskNicknameAccountCache[user.nickname] = user.account;
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

    static immutable string[5] listTypes =
    [
        "staff",
        "operator",
        "elevated",
        "whitelist",
        "blacklist",
    ];

    foreach (liststring; listTypes[])
    {
        alias examplePlaceholderKey = PersistenceService.Placeholder.channel;
        auto listJSON = liststring in json;

        if (!listJSON)
        {
            json[liststring] = null;
            json[liststring].object = null;

            //listJSON = liststring in json;
            //(*listJSON)[examplePlaceholderKey] = null;  // Doesn't work with older compilers
            //(*listJSON)[examplePlaceholderKey].array = null;  // ditto
            //auto listPlaceholder = examplePlaceholderKey in *listJSON;
            //listPlaceholder.array ~= JSONValue("<nickname1>");  // ditto
            //listPlaceholder.array ~= JSONValue("<nickname2>");  // ditto

            json[liststring][examplePlaceholderKey] = null;
            json[liststring][examplePlaceholderKey].array = null;
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname1>");
            json[liststring][examplePlaceholderKey].array ~= JSONValue("<nickname2>");
        }
        else /*if (listJSON)*/
        {
            if ((listJSON.object.length > 1) &&
                (examplePlaceholderKey in *listJSON))
            {
                //listJSON.object.remove(examplePlaceholderKey);  // ditto
                json[liststring].object.remove(examplePlaceholderKey);
            }

            try
            {
                foreach (immutable channelName, ref channelAccountsJSON; listJSON.object)
                {
                    if (channelName == examplePlaceholderKey) continue;
                    //channelAccountsJSON = deduplicate((*listJSON)[channelName]);  // ditto
                    json[liststring][channelName] = deduplicate(json[liststring][channelName]);
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
    static immutable order = [ "staff", "operator", "elevated", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
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
     +/
    RehashingAA!(IRCUser.Class[string])[string] channelUserClassDefinitions;

    /++
        Hostmask definitions as read from file. Should be considered read-only.
     +/
    IRCUser[] hostmaskUsers;

    /++
        Cached nicknames matched to defined hostmasks.
     +/
    RehashingAA!(string[string]) hostmaskNicknameAccountCache;

    /++
        Cache of users by channel and nickname.
     +/
    RehashingAA!(IRCUser[string][string]) channelUserCache;

    /++
        Inherits a user into the cache.
     +/
    public override void putUser(const IRCUser user, const string channel)
    {
        if (channel.length)
        {
            channelUserCache[channel][user.nickname] = user;
        }

        putUserImpl(user);
    }

    mixin IRCPluginImpl;
}

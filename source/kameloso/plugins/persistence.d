/++
 +  The Persistence service keeps track of all seen users, gathering as much
 +  information about them as possible, then injects them into
 +  `kameloso.ircdefs.IRCEvent`s when such information is not present.
 +
 +  This means that even if a service only refers to a user by nickname, things
 +  like his ident and address will be available to plugins as well, assuming
 +  the Persistence service had seen that previously.
 +
 +  It has no commands. It only does postprocessing and doesn't handle
 +  `kameloso.ircdefs.IRCEvent`s in the normal sense at all.
 +
 +  It is technically optional but it's very enriching for plugins, so it stays
 +  recommended.
 +/
module kameloso.plugins.persistence;

import kameloso.plugins.common;
import kameloso.ircdefs;

private:


// postprocess
/++
 +  Hijacks a reference to a `kameloso.ircdefs.IRCEvent` after parsing and
 +  fleshes out the `kameloso.ircdefs.IRCEvent.sender` and/or
 +  `kameloso.ircdefs.IRCEvent.target` fields, so that things like account names
 +  that are only sent sometimes carry over.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    import kameloso.meld : meldInto;
    import std.algorithm.searching : canFind;
    import std.range : only;
    import std.typecons : Flag, No, Yes;

    if (event.type == IRCEvent.Type.QUIT) return;

    foreach (user; only(&event.sender, &event.target))
    {
        if (!user.nickname.length) continue;

        if (auto stored = user.nickname in service.state.users)
        {
            with (user)
            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
                if (account.length) goto case ACCOUNT;
                break;

            case RPL_WHOISACCOUNT:
            case RPL_WHOISUSER:
            case ACCOUNT:
                // Record WHOIS if we have new account information
                import std.datetime.systime : Clock;
                lastWhois = Clock.currTime.toUnixTime;

                if (const classifier = account in service.userClasses)
                {
                    class_ = *classifier;
                }
                else if (service.state.bot.admins.canFind(account))
                {
                    // Admins are (currently) stored in an array IRCBot.admins
                    class_ = Class.admin;
                }
                break;

            default:
                if (account.length && (account != "*") && !stored.account.length)
                {
                    goto case ACCOUNT;
                }
                break;
            }

            // Meld into the stored user, and store the union in the event
            (*user).meldInto!(Yes.overwrite)(*stored);

            // An account of "*" means the user logged out of services
            if (user.account == "*") stored.account = string.init;

            // Inject the modified user into the event
            *user = *stored;
        }
        else
        {
            // New entry
            service.state.users[user.nickname] = *user;
        }
    }
}


// onQuit
/++
 +  Removes a user's `kameloso.ircdefs.IRCUser` entry from the `users`
 +  associative array of the current `PersistenceService`'s
 +  `kameloso.plugins.common.IRCPluginState` upon them disconnecting.
 +/
@(IRCEvent.Type.QUIT)
void onQuit(PersistenceService service, const IRCEvent event)
{
    service.state.users.remove(event.sender.nickname);
}


// onNick
/++
 +  Updates the entry of someone in the `users` associative array of the current
 +  `PersistenceService`'s `kameloso.plugins.common.IRCPluginState` when they
 +  change nickname, to point to the new `kameloso.ircdefs.IRCUser`.
 +
 +  Removes the old entry.
 +/
@(IRCEvent.Type.NICK)
@(IRCEvent.Type.SELFNICK)
void onNick(PersistenceService service, const IRCEvent event)
{
    with (service.state)
    {
        if (auto stored = event.sender.nickname in users)
        {
            users[event.target.nickname] = *stored;
            users[event.target.nickname].nickname = event.target.nickname;
            users.remove(event.sender.nickname);
        }
        else
        {
            users[event.target.nickname] = event.sender;
            users[event.target.nickname].nickname = event.target.nickname;
        }
    }
}


// onEndOfMotd
/++
 +  Reloads classifier definitions from disk.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(PersistenceService service)
{
    service.reloadClassifiersFromDisk();
}


// reload
/++
 +  Reloads the plugin, rehashing the user array and loading
 +  admin/whitelist/blacklist classifier definitions from disk.
 +/
void reload(PersistenceService service)
{
    service.state.users.rehash();
    service.reloadClassifiersFromDisk();
}


// periodically
/++
 +  Periodically rehashes the user array, allowing for optimised access.
 +
 +  This is normally done as part of user-awareness, but we're not mixing that
 +  in so we have to reinvent it.
 +/
void periodically(PersistenceService service)
{
    import std.datetime.systime : Clock;

    immutable now = Clock.currTime.toUnixTime;
    enum hoursBetweenRehashes = 3;

    service.state.users.rehash();
    service.state.nextPeriodical = now + (hoursBetweenRehashes * 3600);
}


// reloadClassifiersFromDisk
/++
 +  Reloads admin/whitelist/blacklist classifier definitions from disk.
 +/
void reloadClassifiersFromDisk(PersistenceService service)
{
    import kameloso.common : logger;
    import kameloso.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    service.userClasses.clear();

    /*if (const adminFromJSON = "admin" in json)
    {
        try
        {
            foreach (const account; adminFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.admin;
            }
        }
        catch (const JSONException e)
        {
            logger.warning("JSON exception caught when populating admins: ", e.msg);
        }
        catch (const Exception e)
        {
            logger.warning("Unhandled exception caught when populating admins: ", e.msg);
        }
    }*/

    if (const whitelistFromJSON = "whitelist" in json)
    {
        try
        {
            foreach (const account; whitelistFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.whitelist;
            }
        }
        catch (const JSONException e)
        {
            logger.warning("JSON exception caught when populating whitelist: ", e.msg);
        }
        catch (const Exception e)
        {
            logger.warning("Unhandled exception caught when populating whitelist: ", e.msg);
        }
    }

    if (const blacklistFromJSON = "blacklist" in json)
    {
        try
        {
            foreach (const account; blacklistFromJSON.array)
            {
                service.userClasses[account.str] = IRCUser.Class.blacklist;
            }
        }
        catch (const JSONException e)
        {
            logger.warning("JSON exception caught when populating blacklist: ", e.msg);
        }
        catch (const Exception e)
        {
            logger.warning("Unhandled exception caught when populating blacklist: ", e.msg);
        }
    }
}


// initResources
/++
 +  Reads, completes and saves the user classification JSON file, creating one
 +  if one doesn't exist.
 +
 +  This ensures there will be a `"whitelist"` and `"blacklist"` array in it.
 +/
void initResources(PersistenceService service)
{
    import kameloso.json : JSONStorage;
    import std.json : JSONValue;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    if ("whitelist" !in json)
    {
        json["whitelist"] = null;
        json["whitelist"].array = null;
    }

    if ("blacklist" !in json)
    {
        json["blacklist"] = null;
        json["blacklist"].array = null;
    }

    json.save(service.userFile);
}


public:


// PersistenceService
/++
 +  The Persistence service melds new `kameloso.ircdefs.IRCUser`s (from
 +  postprocessing new `kameloso.ircdefs.IRCEvent`s) with old records of
 +  themselves.
 +
 +  Sometimes the only bit of information about a sender (or target) embedded in
 +  an `kameloso.ircdefs.IRCEvent` may be his/her nickname, even though the
 +  event before detailed everything, even including their account name. With
 +  this service we aim to complete such `kameloso.ircdefs.IRCUser` entries as
 +  the union of everything we know from previous events.
 +
 +  It only needs part of `kameloso.plugins.common.UserAwareness` for minimal
 +  bookkeeping, not the full package, so we only copy/paste the relevant bits
 +  to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
    /// File with user definitions.
    @ResourceFile string userFile = "users.json";

    /// Associative array of user classifications, per account string name.
    IRCUser.Class[string] userClasses;

    mixin IRCPluginImpl;
}

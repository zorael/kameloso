/++
 +  The Persistence service keeps track of all encountered users, gathering as much
 +  information about them as possible, then injects them into
 +  `dialect.defs.IRCEvent`s when information about them is incomplete.
 +
 +  This means that even if a service only refers to a user by nickname, things
 +  like his ident and address will be available to plugins as well, assuming
 +  the Persistence service had seen that previously.
 +
 +  It has no commands. It only does post-processing and doesn't handle
 +  `dialect.defs.IRCEvent`s in the normal sense at all.
 +
 +  It is mandatory for plugins to pick up user classes.
 +/
module kameloso.plugins.persistence;

version(WithPlugins):
version(WithPersistenceService):

private:

import kameloso.plugins.ircplugin;
import kameloso.plugins.common;
import dialect.defs;


// postprocess
/++
 +  Hijacks a reference to a `dialect.defs.IRCEvent` after parsing and
 +  fleshes out the `dialect.defs.IRCEvent.sender` and/or
 +  `dialect.defs.IRCEvent.target` fields, so that things like account names
 +  that are only sent sometimes carry over.
 +
 +  Merely leverages `postprocessAccounts` and `postprocessHostmasks`.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    return service.state.settings.useHostmasks ?
        postprocessHostmasks(service, event) :
        postprocessAccounts(service, event);
}


// postprocessAccounts
/++
 +  Postprocesses an `dialect.defs.IRCEvent` from an account perspective, e.g.
 +  where a user may be logged onto services.
 +/
void postprocessAccounts(PersistenceService service, ref IRCEvent event)
{
    static void postprocessImpl(PersistenceService service, ref IRCEvent event, ref IRCUser user)
    {
        import std.algorithm.searching : canFind;

        if (!user.nickname.length) return;  // Ignore server events

        if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
            (user.nickname == service.state.client.nickname))
        {
            // On non-Twitch, ignore events originating from us
            return;
        }

        /++
         +  Tries to apply any permanent class for a user in a channel, and if
         +  none available, tries to set one that seems to apply based on what
         +  the user looks like.
         +/
        static void applyClassifiers(PersistenceService service,
            const IRCEvent event, ref IRCUser user)
        {
            bool set;

            if (user.class_ == IRCUser.Class.admin)
            {
                // Do nothing, admin is permanent and program-wide
                return;
            }
            else if (!user.account.length || (user.account == "*"))
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
                // All else failed, consider it a random
                user.class_ = IRCUser.Class.anyone;
            }

            // Record this channel as being the one the current class_ applies to.
            // That way we only have to look up a class_ when the channel has changed.
            service.userClassCurrentChannelCache[user.nickname] = event.channel;
        }

        auto stored = user.nickname in service.state.users;
        immutable foundNoStored = stored is null;

        if (foundNoStored)
        {
            service.state.users[user.nickname] = user;
            stored = user.nickname in service.state.users;
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            // Apply class here on events that carry new account information.

            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
            case ACCOUNT:
            case RPL_WHOISACCOUNT:
            case RPL_WHOISUSER:
            case RPL_WHOISREGNICK:
                applyClassifiers(service, event, user);
                break;

            default:
                if (user.account.length && (user.account != "*") && !stored.account.length)
                {
                    // Unexpected event bearing new account
                    goto case RPL_WHOISACCOUNT;
                }
                break;
            }
        }

        import lu.meld : MeldingStrategy, meldInto;

        // Store initial class and restore after meld. The origin user.class_
        // can ever only be IRCUser.Class.unset UNLESS altered in the switch above.
        immutable preMeldClass = stored.class_;

        // Meld into the stored user, and store the union in the event
        // Skip if the current stored is just a direct copy of user
        if (!foundNoStored) user.meldInto!(MeldingStrategy.aggressive)(*stored);

        if (stored.class_ == IRCUser.Class.unset)
        {
            // The class was not changed, restore the previously saved one
            stored.class_ = preMeldClass;
        }

        if (service.state.server.daemon != IRCServer.Daemon.twitch)
        {
            if (event.type == IRCEvent.Type.RPL_ENDOFWHOIS)
            {
                // Record updated timestamp; this is the end of a WHOIS
                stored.updated = event.time;
            }
            else if (stored.account == "*")
            {
                // An account of "*" means the user logged out of services
                // It's not strictly true but consider him/her as unknown again.

                stored.account = string.init;
                stored.class_ = IRCUser.Class.anyone;
                stored.updated = 1L;  // To facilitate melding
                service.userClassCurrentChannelCache.remove(stored.nickname);
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

        if (stored.class_ == IRCUser.Class.admin)
        {
            // Do nothing, admin is permanent and program-wide
        }
        else if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
            (stored.nickname == service.state.client.nickname))
        {
            stored.class_ = IRCUser.Class.admin;
        }
        else if (!event.channel.length || !service.state.bot.homeChannels.canFind(event.channel))
        {
            // Not a channel or not a home. Additionally not an admin nor us
            stored.class_ = IRCUser.Class.anyone;
            service.userClassCurrentChannelCache.remove(user.nickname);
        }
        else
        {
            const cachedChannel = stored.nickname in service.userClassCurrentChannelCache;

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


// postprocessHostmasks
/++
 +  Postprocesses an `dialect.defs.IRCEvent` from a hostmask perspective, e.g.
 +  where no services are available and users are identified by their hostmasks.
 +/
void postprocessHostmasks(PersistenceService service, ref IRCEvent event)
{
    static void postprocessImpl(PersistenceService service, ref IRCEvent event, ref IRCUser user)
    {
        import std.algorithm.searching : canFind;

        if (!user.nickname.length) return;  // Ignore server events

        if ((service.state.server.daemon != IRCServer.Daemon.twitch) &&
            (user.nickname == service.state.client.nickname))
        {
            // On non-Twitch, ignore events originating from us
            return;
        }

        static bool canFindByValueMask(const string[] array, const IRCUser user,
            const IRCServer.CaseMapping caseMapping)
        {
            import dialect.common : matchesByMask;
            import std.stdio;

            writeln("canFindByValueMask: ", user.hostmask);

            foreach (immutable thisMask; array)
            {
                import lu.string : contains;

                writeln("...vs ", thisMask, "?");

                if (!thisMask.contains('!'))
                {
                    writeln("not a hostmask!");
                    continue;
                }

                if (matchesByMask(user, IRCUser(thisMask), caseMapping))
                {
                    writeln("yes!");
                    return true;
                }
                else
                {
                    writeln("no...");
                }
            }

            writeln("false.");
            return false;
        }

        static IRCUser.Class classByMaskMatch(const IRCUser.Class[IRCUser] aa,
            const IRCUser user, const IRCServer.CaseMapping caseMapping)
        {
            import dialect.common : matchesByMask;
            import std.stdio;

            writeln("classByMaskMatch: ", user.hostmask);

            foreach (immutable thisUser, immutable class_; aa)
            {
                writeln("...vs ", thisUser.hostmask, "?");
                if (matchesByMask(user, thisUser, caseMapping))
                {
                    writeln("yes! ", class_);
                    return class_;
                }
                else
                {
                    writeln("no...");
                }
            }

            writeln("anyone.");
            return IRCUser.Class.anyone;
        }

        /++
         +  Tries to apply any permanent class for a user in a channel, and if
         +  none available, tries to set one that seems to apply based on what
         +  the user looks like.
         +/
        static void applyClassifiers(PersistenceService service,
            const IRCEvent event, ref IRCUser user)
        {
            import std.stdio;
            writeln("applyClassifiers");

            if (user.class_ == IRCUser.Class.admin)
            {
                writeln(user.nickname, " was already admin");
                // Do nothing, admin is permanent and program-wide
                return;
            }
            else if (canFindByValueMask(service.state.bot.admins, user,
                service.state.server.caseMapping))
            {
                writeln("foudn an admin!", user.nickname);
                // admin discovered
                user.class_ = IRCUser.Class.admin;
                return;
            }
            else if (event.channel.length)
            {
                if (const maskclasses = event.channel in service.channelHostmasks)
                {
                    // Permanent class may be defined; apply if so, default to anyone
                    user.class_ = classByMaskMatch(*maskclasses, user,
                        service.state.server.caseMapping);
                }
                else
                {
                    writeln("anyone 1");
                    // No masks defined for this channel, user cannot possibly have a def
                    user.class_ = IRCUser.Class.anyone;
                }
            }
            else
            {
                writeln("anyone 2");
                // All else failed, consider it a random
                user.class_ = IRCUser.Class.anyone;
            }

            // Record this channel as being the one the current class_ applies to.
            // That way we only have to look up a class_ when the channel has changed.
            service.userClassCurrentChannelCache[user.nickname] = event.channel;
        }

        auto stored = user.nickname in service.state.users;
        immutable foundNoStored = stored is null;

        if (foundNoStored)
        {
            service.state.users[user.nickname] = user;
            stored = user.nickname in service.state.users;
        }

        import lu.meld : MeldingStrategy, meldInto;

        // Store initial class and restore after meld.
        immutable preMeldClass = stored.class_;

        // Meld into the stored user, and store the union in the event
        // Skip if the current stored is just a direct copy of user
        if (!foundNoStored) user.meldInto!(MeldingStrategy.aggressive)(*stored);

        if (stored.class_ == IRCUser.Class.unset)
        {
            // The class was not changed, restore the previously saved one
            stored.class_ = preMeldClass;
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

        if (stored.class_ == IRCUser.Class.admin)
        {
            // Do nothing, admin is permanent and program-wide
        }
        else if ((service.state.server.daemon == IRCServer.Daemon.twitch) &&
            (stored.nickname == service.state.client.nickname))
        {
            stored.class_ = IRCUser.Class.admin;
        }
        else if (!event.channel.length || !service.state.bot.homeChannels.canFind(event.channel))
        {
            // Not a channel or not a home. Additionally not an admin nor us
            stored.class_ = IRCUser.Class.anyone;
            service.userClassCurrentChannelCache.remove(user.nickname);
        }
        else
        {
            const cachedChannel = stored.nickname in service.userClassCurrentChannelCache;

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
 +  Removes a user's `dialect.defs.IRCUser` entry from the `users`
 +  associative array of the current `PersistenceService`'s
 +  `kameloso.plugins.common.IRCPluginState` upon them disconnecting.
 +
 +  Additionally from the nickname-chanel cache.
 +/
@(IRCEvent.Type.QUIT)
void onQuit(PersistenceService service, const IRCEvent event)
{
    service.state.users.remove(event.sender.nickname);
    service.userClassCurrentChannelCache.remove(event.sender.nickname);
}


// onNick
/++
 +  Updates the entry of someone in the `users` associative array of the current
 +  `PersistenceService`'s `kameloso.plugins.common.IRCPluginState` when they
 +  change nickname, to point to the new `dialect.defs.IRCUser`.
 +
 +  Removes the old entry.
 +/
@(IRCEvent.Type.NICK)
@(IRCEvent.Type.SELFNICK)
void onNick(PersistenceService service, const IRCEvent event)
{
    with (service.state)
    {
        if (const stored = event.sender.nickname in users)
        {
            users[event.target.nickname] = *stored;
            users[event.target.nickname].nickname = event.target.nickname;
            users.remove(event.sender.nickname);
        }
        /*else
        {
            // Logically this should never happen, as postprocess creates a user
            // if none already exists.
            users[event.target.nickname] = event.sender;
            users[event.target.nickname].nickname = event.target.nickname;
        }*/

        if (const channel = event.sender.nickname in service.userClassCurrentChannelCache)
        {
            service.userClassCurrentChannelCache[event.target.nickname] = *channel;
            service.userClassCurrentChannelCache.remove(event.sender.nickname);
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
    service.reloadAccountClassifiersFromDisk();
    service.reloadHostmaskClassifiersFromDisk();
}


// reload
/++
 +  Reloads the service, rehashing the user array and loading
 +  admin/whitelist/blacklist classifier definitions from disk.
 +/
void reload(PersistenceService service)
{
    service.state.users.rehash();
    service.reloadAccountClassifiersFromDisk();
    service.reloadHostmaskClassifiersFromDisk();
}


// periodically
/++
 +  Periodically rehashes the user array, allowing for optimised access.
 +
 +  This is normally done as part of user-awareness, but we're not mixing that
 +  in so we have to reinvent it.
 +/
void periodically(PersistenceService service, const long now)
{
    import std.datetime.systime : Clock;

    enum hoursBetweenRehashes = 3;

    service.state.users.rehash();
    service.state.nextPeriodical = now + (hoursBetweenRehashes * 3600);
}


// reloadAccountClassifiersFromDisk
/++
 +  Reloads admin/whitelist/blacklist classifier definitions from disk.
 +
 +  Params:
 +      service = The current `PersistenceService`.
 +/
void reloadAccountClassifiersFromDisk(PersistenceService service)
{
    import kameloso.common : logger;
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    service.channelUsers.clear();

    import lu.conv : Enum;
    import std.range : only;

    foreach (class_; only(IRCUser.Class.operator, IRCUser.Class.whitelist, IRCUser.Class.blacklist))
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
            foreach (immutable channel, const channelAccountJSON; listFromJSON.object)
            {
                foreach (immutable accountJSON; channelAccountJSON.array)
                {
                    if (channel !in service.channelUsers)
                    {
                        service.channelUsers[channel] = (IRCUser.Class[string]).init;
                    }

                    service.channelUsers[channel][accountJSON.str] = class_;
                }
            }
        }
        catch (JSONException e)
        {
            logger.warningf("JSON exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            logger.warningf("Unhandled exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
        }
    }
}


// reloadHostmaskClassifiersFromDisk
/++
 +  Reloads admin/whitelist/blacklist classifier definitions from disk.
 +  Hostmask version.
 +
 +  Params:
 +      service = The current `PersistenceService`.
 +/
void reloadHostmaskClassifiersFromDisk(PersistenceService service)
{
    import kameloso.common : logger;
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.hostmasksFile);

    service.channelUsers.clear();

    import lu.conv : Enum;
    import std.range : only;

    foreach (class_; only(IRCUser.Class.operator, IRCUser.Class.whitelist, IRCUser.Class.blacklist))
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
            foreach (immutable channel, const channelAccountJSON; listFromJSON.object)
            {
                foreach (immutable hostmaskJSON; channelAccountJSON.array)
                {
                    if (channel !in service.channelUsers)
                    {
                        service.channelHostmasks[channel] = (IRCUser.Class[IRCUser]).init;
                    }

                    service.channelHostmasks[channel][IRCUser(hostmaskJSON.str)] = class_;
                }
            }
        }
        catch (JSONException e)
        {
            logger.warningf("JSON exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.info);
        }
        catch (Exception e)
        {
            logger.warningf("Unhandled exception caught when populating %s: %s", list, e.msg);
            version(PrintStacktraces) logger.trace(e.toString);
        }
    }
}


// initResources
/++
 +  Reads, completes and saves the user classification JSON file, creating one
 +  if one doesn't exist. Removes any duplicate entries.
 +
 +  This ensures there will be "whitelist", "operator" and "blacklist" arrays in it.
 +
 +  Throws: `kameloso.plugins.common.IRCPluginInitialisationException` on
 +      failure loading the `user.json` file.
 +/
void initResources(PersistenceService service)
{
    initAccountResources(service);
    initHostmaskResources(service);
}


// initAccountResources
/++
 +  FIXME
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
        import kameloso.common : logger;
        import std.path : baseName;

        version(PrintStacktraces) logger.trace(e.toString);
        throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    static auto deduplicate(JSONValue before)
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto after = before
            .array
            .sort!((a,b) => a.str < b.str)
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

    import std.range : only;

    foreach (liststring; only("operator", "whitelist", "blacklist"))
    {
        if (liststring !in json)
        {
            json[liststring] = null;
            json[liststring].object = null;
        }
        else
        {
            try
            {
                foreach (immutable channel, ref channelAccountsJSON; json[liststring].object)
                {
                    channelAccountsJSON = deduplicate(json[liststring][channel]);
                }
            }
            catch (JSONException e)
            {
                import kameloso.common : logger;
                import std.path : baseName;

                version(PrintStacktraces) logger.trace(e.toString);
                throw new IRCPluginInitialisationException(service.userFile.baseName ~ " may be malformed.");
            }
        }
    }

    // Force operator and whitelist to appear before blacklist in the .json
    static immutable order = [ "operator", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
}


// initHostmaskResources
/++
 +  Reads, completes and saves the user classification JSON file, creating one
 +  if one doesn't exist. Removes any duplicate entries.
 +
 +  This ensures there will be "whitelist", "operator" and "blacklist" arrays in it.
 +
 +  Throws: `kameloso.plugins.common.IRCPluginInitialisationException` on
 +      failure loading the `user.json` file.
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
        import kameloso.common : logger;
        import std.path : baseName;

        version(PrintStacktraces) logger.trace(e.toString);
        throw new IRCPluginInitialisationException(service.hostmasksFile.baseName ~ " may be malformed.");
    }

    // Let other Exceptions pass.

    static auto deduplicate(JSONValue before)
    {
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;

        auto after = before
            .array
            .sort!((a,b) => a.str < b.str)
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

    import std.range : only;

    foreach (liststring; only("operator", "whitelist", "blacklist"))
    {
        if (liststring !in json)
        {
            json[liststring] = null;
            json[liststring].object = null;
        }
        else
        {
            try
            {
                foreach (immutable channel, ref channelAccountsJSON; json[liststring].object)
                {
                    channelAccountsJSON = deduplicate(json[liststring][channel]);
                }
            }
            catch (JSONException e)
            {
                import kameloso.common : logger;
                import std.path : baseName;

                version(PrintStacktraces) logger.trace(e.toString);
                throw new IRCPluginInitialisationException(service.hostmasksFile.baseName ~ " may be malformed.");
            }
        }
    }

    // Force operator and whitelist to appear before blacklist in the .json
    static immutable order = [ "operator", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.hostmasksFile, order);
}


public:


// PersistenceService
/++
 +  The Persistence service melds new `dialect.defs.IRCUser`s (from
 +  post-processing new `dialect.defs.IRCEvent`s) with old records of themselves.
 +
 +  Sometimes the only bit of information about a sender (or target) embedded in
 +  an `dialect.defs.IRCEvent` may be his/her nickname, even though the
 +  event before detailed everything, even including their account name. With
 +  this service we aim to complete such `dialect.defs.IRCUser` entries as
 +  the union of everything we know from previous events.
 +
 +  It only needs part of `kameloso.plugins.common.UserAwareness` for minimal
 +  bookkeeping, not the full package, so we only copy/paste the relevant bits
 +  to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
private:
    /// File with user definitions.
    @Resource string userFile = "users.json";

    /// File with hostmasks
    @Resource string hostmasksFile = "hostmasks.json";

    /// Associative array of permanent user classifications, per account and channel name.
    IRCUser.Class[string][string] channelUsers;

    /// FIXME
    IRCUser.Class[IRCUser][string] channelHostmasks;

    /// Associative array of which channel the latest class lookup for an account related to.
    string[string] userClassCurrentChannelCache;

    mixin IRCPluginImpl;
}

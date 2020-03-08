/++
 +  The Persistence service keeps track of all seen users, gathering as much
 +  information about them as possible, then injects them into
 +  `dialect.defs.IRCEvent`s when such information is not present.
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

import kameloso.plugins.common;
import dialect.defs;


// postprocess
/++
 +  Hijacks a reference to a `dialect.defs.IRCEvent` after parsing and
 +  fleshes out the `dialect.defs.IRCEvent.sender` and/or
 +  `dialect.defs.IRCEvent.target` fields, so that things like account names
 +  that are only sent sometimes carry over.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    import std.range : only;

    foreach (user; only(&event.sender, &event.target))
    {
        if (!user.nickname.length) continue;  // Ignore server events

        /++
         +  Tries to apply any permanent class for a user in a channel, and if
         +  none available, tries to set one that seems to apply based on what
         +  the user looks like.
         +/
        void applyClassifiersDg(IRCUser* user, const string channel = event.channel)
        {
            import std.algorithm.searching : canFind;

            if (user.class_ == IRCUser.Class.admin)
            {
                // Do nothing, admin is permanent and program-wide
            }
            else if (!user.account.length)
            {
                // No account means it's just a random
                user.class_ = IRCUser.Class.anyone;
            }
            else if (event.type == IRCEvent.Type.QUERY)
            {
                // Let everyone except admins be considered a random for now
                user.class_ = service.state.bot.admins.canFind(user.account) ?
                    IRCUser.Class.admin : IRCUser.Class.anyone;
            }
            else if (service.state.bot.admins.canFind(user.account))
            {
                // admin discovered
                user.class_ = IRCUser.Class.admin;
            }
            else if (channel.length && (channel in service.channelUsers) &&
                (user.account in service.channelUsers[channel]))
            {
                // Permanent class is defined, so apply it
                user.class_ = service.channelUsers[channel][user.account];
            }
            else
            {
                // All else failed, consider it a random
                user.class_ = IRCUser.Class.anyone;
            }

            // Record this channel as being the one the current class_ applies to.
            // That way we only have to look up a class_ when the channel has changed.
            service.userClassCurrentChannelCache[user.nickname] = channel;
        }

        version(TwitchSupport)
        {
            if (service.state.server.daemon == IRCServer.Daemon.twitch)
            {
                auto stored = user.nickname in service.state.users;

                if (stored)
                {
                    import lu.meld : MeldingStrategy, meldInto;
                    (*user).meldInto!(MeldingStrategy.aggressive)(*stored);
                }
                else
                {
                    service.state.users[user.nickname] = *user;
                    stored = user.nickname in service.state.users;
                }

                // Clear badges if it has the empty placeholder asterisk
                if (user.badges == "*") stored.badges = string.init;

                if (user.class_ == IRCUser.Class.admin)
                {
                    // Do nothing, admin is permanent and program-wide
                }
                else if (event.type == IRCEvent.Type.QUERY)
                {
                    applyClassifiersDg(stored);
                }
                else if (service.userClassCurrentChannelCache.get(user.nickname, string.init) != event.channel)
                {
                    applyClassifiersDg(stored);
                }

                *user = *stored;
                continue;
            }
        }

        if (user.nickname == service.state.client.nickname) continue;

        if (auto stored = user.nickname in service.state.users)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case JOIN:
                if (user.account.length) goto case RPL_WHOISACCOUNT;
                break;

            case ACCOUNT:
                if (user.account == "*")
                {
                    // User logged out, reset updated so the user can be WHOISed again later
                    // A value of 0L won't be melded...
                    user.updated = 1L;
                }
                else
                {
                    goto case RPL_WHOISACCOUNT;
                }
                break;

            case RPL_WHOISACCOUNT:
            case RPL_WHOISUSER:
            case RPL_WHOISREGNICK:
                // Record WHOIS if we have new account information
                import std.datetime.systime : Clock;
                user.updated = Clock.currTime.toUnixTime;
                applyClassifiersDg(user);
                stored.class_ = user.class_;  // Manually set it so it's guaranteed to persist through a meld
                break;

            case RPL_WHOREPLY:
                if (event.aux.length)
                {
                    import std.string : representation;

                    // Register operators, half-ops, voiced etc
                    // Can be more than one if multi-prefix capability is enabled
                    // Server-sent string, can assume ASCII (@,%,+...) and go char by char
                    foreach (immutable modesign; event.aux.representation)
                    {
                        if (modesign in service.state.server.prefixchars)
                        {
                            if ((modesign == '@') && (user.class_ < IRCUser.Class.operator))
                            {
                                // Specialcase operators
                                user.class_ = IRCUser.Class.operator;
                                service.userClassCurrentChannelCache[user.nickname] = event.channel;
                            }
                        }
                    }
                }
                break;

            case RPL_NAMREPLY:
                import lu.string : contains;
                import std.algorithm.iteration : splitter;
                import std.string : representation;

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
                    nickname = service.state.server.stripModesign(nickname, modesigns);

                    // Register operators, half-ops, voiced etc
                    // Can be more than one if multi-prefix capability is enabled
                    // Server-sent string, can assume ASCII (@,%,+...) and go char by char
                    foreach (immutable modesign; modesigns.representation)
                    {
                        if (modesign in service.state.server.prefixchars)
                        {
                            if (nickname == service.state.client.nickname) continue;

                            if ((modesign == '@') && (user.class_ < IRCUser.Class.operator))
                            {
                                // Specialcase operators
                                user.class_ = IRCUser.Class.operator;
                                service.userClassCurrentChannelCache[user.nickname] = event.channel;
                            }
                        }
                    }
                }
                break;

            default:
                if (user.account.length && (user.account != "*") && !stored.account.length)
                {
                    goto case RPL_WHOISACCOUNT;
                }
                break;
            }

            import lu.meld : MeldingStrategy, meldInto;

            // Meld into the stored user, and store the union in the event
            (*user).meldInto!(MeldingStrategy.aggressive)(*stored);

            // An account of "*" means the user logged out of services
            if (user.account == "*") stored.account = string.init;

            if (user.class_ == IRCUser.Class.admin)
            {
                // Do nothing, admin is program-wide
            }
            else if (event.type == IRCEvent.Type.QUERY)
            {
                applyClassifiersDg(stored);
            }
            else if (service.userClassCurrentChannelCache.get(user.nickname, string.init) != event.channel)
            {
                applyClassifiersDg(stored);
            }

            // Inject the modified user into the event
            *user = *stored;
        }
        else if (event.type != IRCEvent.Type.QUIT)
        {
            // New entry
            if (user.account == "*") user.account = string.init;

            if (user.class_ == IRCUser.Class.admin)
            {
                // Do nothing, admin is permanent and program-wide
            }
            else if (event.type == IRCEvent.Type.QUERY)
            {
                applyClassifiersDg(user);
            }
            else if (service.userClassCurrentChannelCache.get(user.nickname, string.init) != event.channel)
            {
                applyClassifiersDg(user);
            }

            service.state.users[user.nickname] = *user;
        }
    }
}


// onQuit
/++
 +  Removes a user's `dialect.defs.IRCUser` entry from the `users`
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
 +  Reloads the service, rehashing the user array and loading
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
 +
 +  Params:
 +      service = The current `PersistenceService`.
 +/
void reloadClassifiersFromDisk(PersistenceService service)
{
    import kameloso.common : logger;
    import lu.json : JSONStorage;
    import std.json : JSONException;

    JSONStorage json;
    json.reset();
    json.load(service.userFile);

    //service.userClasses.clear();
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
            version(PrintStacktraces) logger.trace(e.toString);
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
 +  This ensures there will be a `"whitelist"` and `"blacklist"` array in it.
 +
 +  Throws: `kameloso.plugins.common.IRCPluginInitialisationException` on
 +      failure loading the `user.json` file.
 +/
void initResources(PersistenceService service)
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
        import std.path : baseName;
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
                import kameloso.common : logger, settings;

                string logtint, errortint;

                version(Colours)
                {
                    if (!settings.monochrome)
                    {
                        import kameloso.logger : KamelosoLogger;

                        logtint = (cast(KamelosoLogger)logger).logtint;
                        errortint = (cast(KamelosoLogger)logger).errortint;
                    }
                }

                logger.errorf("An error occured while reading %s%s%s; it may be malformed: %1$s%4s",
                    logtint, service.userFile, errortint, e.msg);
                logger.info("Suggestion: delete it and start afresh.");
            }
        }
    }

    // Force operator and whitelist to appear before blacklist in the .json
    static immutable order = [ "operator", "whitelist", "blacklist" ];
    json.save!(JSONStorage.KeyOrderStrategy.inGivenOrder)(service.userFile, order);
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

    /// Associative array of permanent user classifications, per account and channel name.
    IRCUser.Class[string][string] channelUsers;

    /// Associative array of which channel the latest class lookup for an account related to.
    string[string] userClassCurrentChannelCache;

    mixin IRCPluginImpl;
}

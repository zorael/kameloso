/++
    Implementation of Admin plugin functionality regarding user classifiers.
    For internal use.

    The [dialect.defs.IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.base.AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.admin.classifiers;

version(WithPlugins):
version(WithAdminPlugin):

private:

import kameloso.plugins.admin.base;

import kameloso.plugins.common.base : nameOf;
import kameloso.common : Tint, logger;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.algorithm.comparison : among;
import std.typecons : Flag, No, Yes;

package:


// manageClassLists
/++
    Common code for whitelisting and blacklisting nicknames/accounts.

    Params:
        plugin = The current [kameloso.pluins.admin.baseAdminPlugin].
        event = The triggering [dialect.defs.IRCEvent].
        list = Which list to add/remove from, "whitelist", "operator" or "blacklist".
 +/
void manageClassLists(AdminPlugin plugin, const ref IRCEvent event, const string list)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import lu.string : nom;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        import std.format : format;
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [add|del|list]".format(plugin.state.settings.prefix, list));
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        return plugin.lookupEnlist(slice, list, event.channel, event);

    case "del":
        return plugin.delist(slice, list, event.channel, event);

    case "list":
        immutable channel = slice.length ? slice : event.channel;
        if (!channel.length) return sendUsage();
        return plugin.listList(channel, list, event);

    default:
        return sendUsage();
    }
}


// listList
/++
    Sends a list of the current users in the whitelist, operator list or the
    blacklist to the querying user or channel.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin].
        channel = The channel the list relates to.
        list = Which list to list; "whitelist", "operator", "staff" or "blacklist".
        event = Optional [dialect.defs.IRCEvent] that instigated the listing.
 +/
void listList(AdminPlugin plugin, const string channel, const string list,
    const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import lu.json : JSONStorage;
    import std.format : format;

    immutable asWhat =
        (list == "operator") ? "operators" :
        (list == "staff") ? "staff" :
        (list == "whitelist") ? "whitelisted users" :
        /*(list == "blacklist") ?*/ "blacklisted users";

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

    if ((channel in json[list].object) && json[list][channel].array.length)
    {
        import std.algorithm.iteration : map;

        auto userlist = json[list][channel].array
            .map!(jsonEntry => jsonEntry.str);

        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Current %s in %s: %-(%s, %)"
            .format(asWhat, channel, userlist));
    }
    else
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "There are no %s in %s.".format(asWhat, channel));
    }
}


// lookupEnlist
/++
    Adds an account to either the whitelist, operator list or the blacklist.

    Passes the `list` parameter to [alterAccountClassifier], for list selection.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin].
        rawSpecified = The nickname or account to white-/blacklist.
        list = Which of "whitelist", "operator", "staff" or "blacklist" to add to.
        channel = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent].
 +/
void lookupEnlist(AdminPlugin plugin, const string rawSpecified, const string list,
    const string channel, const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import dialect.common : isValidNickname;
    import lu.string : contains, stripped;
    import std.range : only;

    immutable specified = rawSpecified.stripped;

    immutable asWhat =
        (list == "operator") ? "an operator" :
        (list == "staff") ? "staff" :
        (list == "whitelist") ? "a whitelisted user" :
        /*(list == "blacklist") ?*/ "a blacklisted user";

    /// Report result, either to the local terminal or to the IRC channel/sender
    void report(const AlterationResult result, const string id)
    {
        import std.format : format;

        if (event.sender.nickname.length)
        {
            // IRC report

            with (AlterationResult)
            final switch (result)
            {
            case success:
                enum pattern = "Added %s as %s in %s.";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash.ircBold, asWhat, channel) :
                    pattern.format(id, asWhat, channel);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid delist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "%s was already %s in %s.";

                immutable message = plugin.state.settings.colouredOutgoing ?
                    pattern.format(id.ircColourByHash.ircBold, asWhat, channel) :
                    pattern.format(id, asWhat, channel);

                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;
            }
        }
        else
        {
            // Terminal report

            with (AlterationResult)
            final switch (result)
            {
            case success:
                logger.logf("Added %s%s%s as %s in %s.",
                    Tint.info, specified, Tint.log, asWhat, channel);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid enlist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                logger.logf("%s%s%s is already %s in %s.",
                    Tint.info, specified, Tint.log, asWhat, channel);
                break;
            }
        }
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        foreach (immutable thisList; only("staff", "operator", "whitelist", "blacklist"))
        {
            if (thisList == list) continue;
            plugin.alterAccountClassifier(No.add, thisList, user.account, channel);
        }

        immutable result = plugin.alterAccountClassifier(Yes.add, list, user.account, channel);
        return report(result, nameOf(*user));
    }
    else if (!specified.length)
    {
        if (event.sender.nickname.length)
        {
            // IRC report
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "No nickname supplied.");
        }
        else
        {
            // Terminal report
            logger.warning("No nickname supplied.");
        }
        return;
    }
    else if (!specified.isValidNickname(plugin.state.server))
    {
        if (event.sender.nickname.length)
        {
            // IRC report

            immutable message = plugin.state.settings.colouredOutgoing ?
                "Invalid nickname/account: " ~ specified.ircColour(IRCColour.red).ircBold :
                "Invalid nickname/account: " ~ specified;

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
        else
        {
            // Terminal report
            logger.warning("Invalid nickname/account: ", Tint.log, specified);
        }
        return;
    }

    void onSuccess(const string id)
    {
        version(TwitchSupport)
        {
            if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
            {
                import std.algorithm.iteration : filter;

                if (const userInList = id in plugin.state.users)
                {
                    foreach (immutable thisList; only("staff", "operator", "whitelist", "blacklist"))
                    {
                        if (thisList == list) continue;
                        plugin.alterAccountClassifier(No.add, thisList, id, channel);
                    }

                    immutable result = plugin.alterAccountClassifier(Yes.add, list, id, channel);
                    return report(result, nameOf(*userInList));
                }

                // If we're here, assume a display name was specified and look up the account
                auto usersWithThisDisplayName = plugin.state.users
                    .byValue
                    .filter!(u => u.displayName == id);

                if (!usersWithThisDisplayName.empty)
                {
                    foreach (immutable thisList; only("staff", "operator", "whitelist", "blacklist"))
                    {
                        if (thisList == list) continue;

                        plugin.alterAccountClassifier(No.add, thisList,
                            usersWithThisDisplayName.front.account, channel);
                    }

                    immutable result = plugin.alterAccountClassifier(Yes.add,
                        list, usersWithThisDisplayName.front.account, channel);
                    return report(result, id);
                }

                // Assume a valid account was specified even if we can't see it, and drop down
            }
        }

        foreach (immutable thisList; only("staff", "operator", "whitelist", "blacklist"))
        {
            if (thisList == list) continue;
            plugin.alterAccountClassifier(No.add, thisList, id, channel);
        }

        immutable result = plugin.alterAccountClassifier(Yes.add, list, id, channel);
        report(result, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.log("(Assuming unauthenticated nickname or offline account was specified)");
        return onSuccess(failureUser.nickname);
    }

    version(TwitchSupport)
    {
        if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
        {
            return onSuccess(specified);
        }
    }

    // User not on record or on record but no account; WHOIS and try based on results
    import kameloso.plugins.common.mixins : WHOISFiberDelegate;

    mixin WHOISFiberDelegate!(onSuccess, onFailure);

    enqueueAndWHOIS(specified);
}


// delist
/++
    Removes a nickname from either the whitelist, operator list or the blacklist.

    Passes the `list` parameter to [alterAccountClassifier], for list selection.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin].
        account = The account to delist as whitelisted/blacklisted or as operator.
        list = Which of "whitelist", "operator", "staff" or "blacklist" to remove from.
        channel = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent].
 +/
void delist(AdminPlugin plugin, const string account, const string list,
    const string channel, const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import std.format : format;

    if (!account.length)
    {
        if (event.sender.nickname.length)
        {
            // IRC report
            privmsg(plugin.state, event.channel, event.sender.nickname, "No account specified.");
        }
        else
        {
            // Terminal report
            logger.warning("No account specified.");
        }
        return;
    }

    immutable asWhat =
        (list == "operator") ? "an operator" :
        (list == "staff") ? "staff" :
        (list == "whitelist") ? "a whitelisted user" :
        /*(list == "blacklist") ?*/ "a blacklisted user";

    immutable result = plugin.alterAccountClassifier(No.add, list, account, channel);

    if (event.sender.nickname.length)
    {
        // IRC report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only `AlterationResult` returned to `delist`");

        case noSuchAccount:
        case noSuchChannel:
            enum pattern = "%s isn't %s in %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, asWhat, channel) :
                pattern.format(account, asWhat, channel);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;

        case success:
            enum pattern = "Removed %s as %s in %s.";

            immutable message = plugin.state.settings.colouredOutgoing ?
                pattern.format(account.ircColourByHash.ircBold, asWhat, channel) :
                pattern.format(account, asWhat, channel);

            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;
        }
    }
    else
    {
        // Terminal report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only `AlterationResult` returned to `delist`");

        case noSuchAccount:
            logger.logf("No such account %s%s%s was found as %s in %s.",
                Tint.info, account, Tint.log, asWhat, channel);
            break;

        case noSuchChannel:
            logger.logf("Account %s%s%s isn't %s in %s.",
                Tint.info, account, Tint.log, asWhat, channel);
            break;

        case success:
            logger.logf("Removed %s%s%s as %s in %s",
                Tint.info, account, Tint.log, asWhat, channel);
            break;
        }
    }
}


// AlterationResult
/++
    Enum embodying the results of an account alteration.

    Returned by functions to report success or failure, to let them give terminal
    or IRC feedback appropriately.
 +/
enum AlterationResult
{
    alreadyInList,  /// When enlisting, an account already existed.
    noSuchAccount,  /// When delisting, an account could not be found.
    noSuchChannel,  /// When delisting, a channel count not be found.
    success,        /// Successful enlist/delist.
}


// alterAccountClassifier
/++
    Adds or removes an account from the file of user classifier definitions,
    and reloads all plugins to make them read the updated lists.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin].
        add = Whether to add to or remove from lists.
        list = Which list to add to or remove from; `whitelist`, `operator` or `blacklist`.
        account = Services account name to add or remove.
        channel = Channel the account-class applies to.

    Returns:
        [AlterationResult.alreadyInList] if enlisting (`Yes.add`) and the account
        was already in the specified list.
        [AlterationResult.noSuchAccount] if delisting (`No.add`) and no such
        account could be found in the specified list.
        [AlterationResult.noSuchChannel] if delisting (`No.add`) and no such
        channel could be found in the specified list.
        [AlterationResult.success] if enlisting or delisting succeeded.
 +/
AlterationResult alterAccountClassifier(AdminPlugin plugin, const Flag!"add" add,
    const string list, const string account, const string channelName)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage;
    import std.concurrency : send;
    import std.json : JSONValue;

    JSONStorage json;
    json.reset();
    json.load(plugin.userFile);

    if (add)
    {
        import std.algorithm.searching : canFind;

        immutable accountAsJSON = JSONValue(account);

        if (channelName in json[list].object)
        {
            if (json[list][channelName].array.canFind(accountAsJSON))
            {
                return AlterationResult.alreadyInList;
            }
            else
            {
                json[list][channelName].array ~= accountAsJSON;
            }
        }
        else
        {
            json[list][channelName] = null;
            json[list][channelName].array = null;
            json[list][channelName].array ~= accountAsJSON;
        }

        // Remove placeholder example since there should now be at least one true entry
        json[list].object.remove("<channel>");
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        if (channelName in json[list].object)
        {
            immutable index = json[list][channelName].array.countUntil(JSONValue(account));

            if (index == -1)
            {
                return AlterationResult.noSuchAccount;
            }

            json[list][channelName] = json[list][channelName].array
                .remove!(SwapStrategy.unstable)(index);
        }
        else
        {
            return AlterationResult.noSuchChannel;
        }
    }

    json.save!(JSONStorage.KeyOrderStrategy.adjusted)(plugin.userFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
    return AlterationResult.success;
}


// modifyHostmaskDefinition
/++
    Adds or removes hostmasks used to identify users on servers that don't employ services.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin].
        add = Whether to add or to remove the hostmask.
        account = Account the hostmask will equate to.
        mask = String "nickname!ident@address.tld" hostmask.
        event = Instigating [dialect.defs.IRCEvent].
 +/
void modifyHostmaskDefinition(AdminPlugin plugin, const Flag!"add" add,
    const string account, const string mask, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage, populateFromJSON;
    import lu.string : contains;
    import std.concurrency : send;
    import std.json : JSONValue;

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    bool didSomething;

    if (add)
    {
        import dialect.common : isValidHostmask;

        if (!mask.isValidHostmask(plugin.state.server))
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Invalid hostmask.");
            return;
        }

        aa[mask] = account;
        didSomething = true;

        // Remove placeholder example since there should now be at least one true entry
        aa.remove("<nickname>!<ident>@<address>");

        json.reset();
        json = JSONValue(aa);
    }
    else
    {
        // Allow for removing an invalid mask

        if (mask in aa)
        {
            aa.remove(mask);
            didSomething = true;
        }

        json.reset();
        json = JSONValue(aa);
    }

    json.save!(JSONStorage.KeyOrderStrategy.passthrough)(plugin.hostmasksFile);

    immutable message = didSomething ?
        "Hostmask list updated." :
        "No such hostmask on file.";

    privmsg(plugin.state, event.channel, event.sender.nickname, message);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.Reload());
}

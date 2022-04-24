/++
    Implementation of Admin plugin functionality regarding user classifiers.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.admin.base|admin.base]
 +/
module kameloso.plugins.admin.classifiers;

version(WithAdminPlugin):

private:

import kameloso.plugins.admin.base;

import kameloso.plugins.common.misc : nameOf;
import kameloso.common : Tint, expandTags, logger;
import kameloso.logger : LogLevel;
import kameloso.messaging;
import dialect.defs;
import std.algorithm.comparison : among;
import std.typecons : Flag, No, Yes;

package:


// manageClassLists
/++
    Common code for whitelisting and blacklisting nicknames/accounts.

    Params:
        plugin = The current [kameloso.pluins.admin.base.AdminPlugin|AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        list = Which list to add/remove from; "staff", "whitelist", "operator" or "blacklist".
 +/
void manageClassLists(AdminPlugin plugin,
    const ref IRCEvent event,
    const string list)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import lu.string : beginsWith, nom, strippedRight;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [add|del|list]";
        immutable message = pattern.format(plugin.state.settings.prefix, list);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content;  // mutable
    immutable verb = slice.nom!(Yes.inherit)(' ');
    if (slice.beginsWith('@')) slice = slice[1..$];
    slice = slice.strippedRight;

    switch (verb)
    {
    case "add":
        return plugin.lookupEnlist(slice, list, event.channel, event);

    case "del":
        return plugin.delist(slice, list, event.channel, event);

    case "list":
        immutable channelName = slice.length ? slice : event.channel;
        if (!channelName.length) return sendUsage();
        return plugin.listList(channelName, list, event);

    default:
        return sendUsage();
    }
}


// listList
/++
    Sends a list of the current users in the whitelist, operator list or the
    blacklist to the querying user or channel.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin].
        channel = The channel the list relates to.
        list = Which list to list; "whitelist", "operator", "staff" or "blacklist".
        event = Optional [dialect.defs.IRCEvent|IRCEvent] that instigated the listing.
 +/
void listList(AdminPlugin plugin,
    const string channel,
    const string list,
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

        enum pattern = "Current %s in <b>%s<b>: %-(<h>%s<h>, %)";
        immutable message = pattern.format(asWhat, channel, userlist);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);


    }
    else
    {
        enum pattern = "There are no %s in <b>%s<b>.";
        immutable message = pattern.format(asWhat, channel);
        privmsg(plugin.state, event.channel, event.sender.nickname, message);
    }
}


// lookupEnlist
/++
    Adds an account to either the whitelist, operator list or the blacklist.

    Passes the `list` parameter to [alterAccountClassifier], for list selection.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin].
        specified = The nickname or account to white-/blacklist.
        list = Which of "whitelist", "operator", "staff" or "blacklist" to add to.
        channel = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void lookupEnlist(AdminPlugin plugin,
    const string specified,
    const string list,
    const string channel,
    const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    import dialect.common : isValidNickname;
    import lu.string : beginsWith, contains;

    static immutable listTypes =
    [
        "staff",
        "operator",
        "whitelist",
        "blacklist",
    ];

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
                enum pattern = "Added <h>%s<h> as <b>%s<b> in %s.";
                immutable message = pattern.format(id, asWhat, channel);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid delist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "<h>%s<h> was already <b>%s<b> in %s.";
                immutable message = pattern.format(id, asWhat, channel);
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
                enum pattern = "Added <h>%s</> as %s in %s.";
                logger.logf(pattern.expandTags(LogLevel.all), id, asWhat, channel);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid enlist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "<h>%s</> is already %s in %s.";
                logger.logf(pattern.expandTags(LogLevel.all), id, asWhat, channel);
                break;
            }
        }
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // user.nickname == specified
        foreach (immutable thisList; listTypes)
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
            import std.format : format;

            // IRC report

            enum pattern = "Invalid nickname/account: <4>%s<c>";
            immutable message = pattern.format(specified);
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
                    foreach (immutable thisList; listTypes)
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
                    foreach (immutable thisList; listTypes)
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

        foreach (immutable thisList; listTypes)
        {
            if (thisList == list) continue;
            plugin.alterAccountClassifier(No.add, thisList, id, channel);
        }

        immutable result = plugin.alterAccountClassifier(Yes.add, list, id, channel);
        report(result, id);
    }

    void onFailure(const IRCUser failureUser)
    {
        logger.trace("(Assuming unauthenticated nickname or offline account was specified)");
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
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin].
        account = The account to delist as whitelisted/blacklisted or as operator.
        list = Which of "whitelist", "operator", "staff" or "blacklist" to remove from.
        channel = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void delist(AdminPlugin plugin,
    const string account,
    const string list,
    const string channel,
    const IRCEvent event = IRCEvent.init)
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
            enum pattern = "<h>%s<h> isn't <b>%s<b> in %s.";
            immutable message = pattern.format(account, asWhat, channel);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
            break;

        case success:
            enum pattern = "Removed <h>%s<h> as <b>%s<b> in %s.";
            immutable message = pattern.format(account, asWhat, channel);
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
            enum pattern = "No such account <h>%s</> was found as %s in %s.";
            logger.logf(pattern.expandTags(LogLevel.all), account, asWhat, channel);
            break;

        case noSuchChannel:
            enum pattern = "Account <h>%s</> isn't %s in %s.";
            logger.logf(pattern.expandTags(LogLevel.all), account, asWhat, channel);
            break;

        case success:
            enum pattern = "Removed <h>%s</> as %s in %s.";
            logger.logf(pattern.expandTags(LogLevel.all), account, asWhat, channel);
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
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin].
        add = Whether to add to or remove from lists.
        list = Which list to add to or remove from; `whitelist`, `operator` or `blacklist`.
        account = Services account name to add or remove.
        channelName = Channel the account-class applies to.

    Returns:
        [AlterationResult.alreadyInList] if enlisting (`Yes.add`) and the account
        was already in the specified list.
        [AlterationResult.noSuchAccount] if delisting (`No.add`) and no such
        account could be found in the specified list.
        [AlterationResult.noSuchChannel] if delisting (`No.add`) and no such
        channel could be found in the specified list.
        [AlterationResult.success] if enlisting or delisting succeeded.
 +/
AlterationResult alterAccountClassifier(AdminPlugin plugin,
    const Flag!"add" add,
    const string list,
    const string account,
    const string channelName)
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
        enum examplePlaceholderKey = "<#channel>";
        json[list].object.remove(examplePlaceholderKey);
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

    json.save(plugin.userFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.reload());
    return AlterationResult.success;
}


// modifyHostmaskDefinition
/++
    Adds or removes hostmasks used to identify users on servers that don't employ services.

    Params:
        plugin = The current [kameloso.plugins.admin.base.AdminPlugin|AdminPlugin].
        add = Whether to add or to remove the hostmask.
        account = Account the hostmask will equate to. May be empty if `add` is false.
        mask = String "nickname!ident@address.tld" hostmask.
        event = Instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void modifyHostmaskDefinition(AdminPlugin plugin,
    const Flag!"add" add,
    const string account,
    const string mask,
    const ref IRCEvent event)
in ((!add || account.length), "Tried to add a hostmask with no account to map it to")
in (mask.length, "Tried to add an empty hostmask definition")
{
    import kameloso.thread : ThreadMessage;
    import lu.json : JSONStorage, populateFromJSON;
    import lu.string : contains;
    import std.concurrency : send;
    import std.conv : text;
    import std.format : format;
    import std.json : JSONValue;

    version(Colours)
    {
        import kameloso.terminal.colours : colourByHash;
    }
    else
    {
        // No-colours passthrough noop
        static string colourByHash(const string word, const Flag!"brightTerminal")
        {
            return word;
        }
    }

    // Values from persistence.d etc
    enum examplePlaceholderKey = "<nickname>!<ident>@<address>";
    enum examplePlaceholderValue = "<account>";

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    immutable brightFlag = cast(Flag!"brightTerminal")plugin.state.settings.brightTerminal;

    if (add)
    {
        import dialect.common : isValidHostmask;

        if (!mask.isValidHostmask(plugin.state.server))
        {
            if (event == IRCEvent.init)
            {
                enum pattern = `Invalid hostmask "<l>%s</>"; must be in the form ` ~
                    `"<l>nickname!ident@address</>".`;
                logger.warningf(pattern.expandTags(LogLevel.warning), mask);
            }
            else
            {
                import std.format : format;
                enum pattern = `Invalid hostmask: "<b>%s<b>"; must be in the form "<b>nickname!ident@address.tld<b>".`;
                immutable message = pattern.format(mask);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
            }
            return;
        }

        aa[mask] = account;

        // Remove any placeholder example since there should now be at least one true entry
        aa.remove(examplePlaceholderKey);

        if (event == IRCEvent.init)
        {
            immutable colouredAccount = colourByHash(account, brightFlag);
            enum pattern = `Added hostmask "<l>%s</>", mapped to account <h>%s</>.`;
            logger.infof(pattern.expandTags(LogLevel.info), mask, colouredAccount);
        }
        else
        {
            enum pattern = `Added hostmask "<b>%s<b>", mapped to account <h>%s<h>.`;
            immutable message = pattern.format(mask, account);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
    else
    {
        // Allow for removing an invalid mask

        if (const mappedAccount = mask in aa)
        {
            aa.remove(mask);
            if (!aa.length) aa[examplePlaceholderKey] = examplePlaceholderValue;

            if (event == IRCEvent.init)
            {
                enum pattern = `Removed hostmask "<l>%s</>".`;
                logger.infof(pattern.expandTags(LogLevel.info), mask);
            }
            else
            {
                enum pattern = `Removed hostmask "<b>%s<b>".`;
                immutable message = pattern.format(mask);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
            }
        }
        else
        {
            if (event == IRCEvent.init)
            {
                enum pattern = `No such hostmask "<l>%s</>" on file.`;
                logger.warningf(pattern.expandTags(LogLevel.warning), mask);
            }
            else
            {
                enum pattern = `No such hostmask "<b>%s<b>" on file.`;
                immutable message = format(pattern, mask);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
            }
            return;  // Skip saving and updating below
        }
    }

    json.reset();
    json = JSONValue(aa);
    json.save!(JSONStorage.KeyOrderStrategy.passthrough)(plugin.hostmasksFile);

    // Force persistence to reload the file with the new changes
    plugin.state.mainThread.send(ThreadMessage.reload());
}

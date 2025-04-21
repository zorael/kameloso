/++
    Implementation of Admin plugin functionality regarding user classifiers.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.admin.AdminPlugin|AdminPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.admin]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.admin.classifiers;

version(WithAdminPlugin):

private:

import kameloso.plugins.admin;
import kameloso.plugins.common : nameOf;
import kameloso.common : logger;
import kameloso.messaging;
import dialect.defs;

package:


// manageClassLists
/++
    Common code for enlisting and delisting nicknames/accounts.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        event = The triggering [dialect.defs.IRCEvent|IRCEvent].
        class_ = User class.
 +/
void manageClassLists(
    AdminPlugin plugin,
    const IRCEvent event,
    const IRCUser.Class class_)
{
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : startsWith;

    void sendUsage()
    {
        import lu.conv : toString;
        import std.format : format;

        enum pattern = "Usage: <b>%s%s<b> [add|del|list]";
        immutable message = pattern.format(plugin.state.coreSettings.prefix, class_.toString);
        privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content.stripped;  // mutable
    immutable verb = slice.advancePast(' ', inherit: true);
    if (slice.startsWith('@')) slice = slice[1..$];

    switch (verb)
    {
    case "add":
        return lookupEnlist(plugin, slice, class_, event.channel.name, event);

    case "del":
        return delist(plugin, slice, class_, event.channel.name, event);

    case "list":
        return listList(plugin, event.channel.name, class_, event);

    default:
        return sendUsage();
    }
}


// listList
/++
    Sends a list of the current users in the whitelist, operator list, list of
    elevated users, staff, or the blacklist to the querying user or channel.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        channelName = The channel the list relates to.
        class_ = User class.
        event = Optional [dialect.defs.IRCEvent|IRCEvent] that instigated the listing.
 +/
void listList(
    AdminPlugin plugin,
    const string channelName,
    const IRCUser.Class class_,
    const IRCEvent event = IRCEvent.init)
{
    import asdf.serialization : deserialize;
    import lu.conv : toString;
    import std.file : readText;
    import std.format : format;

    immutable shouldSendToChannel = (event.sender.nickname.length > 0);
    immutable role = getNoun(NounForm.plural, class_);
    immutable list = class_.toString;

    auto json = plugin.userFile
        .readText
        .deserialize!(string[string][string]);

    const channelUsers = channelName in json[list];

    if (channelUsers && channelUsers.length)
    {
        if (shouldSendToChannel)
        {
            enum pattern = "Current %s in <b>%s<b>: %-(<h>%s<h>, %)<h>";
            immutable message = pattern.format(role, channelName, channelUsers);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else
        {
            enum pattern = "Current %s in <l>%s</>: %-(<h>%s</>, %)</>";
            logger.infof(pattern, role, channelName, channelUsers);
        }
    }
    else
    {
        if (shouldSendToChannel)
        {
            enum pattern = "There are no %s in <b>%s<b>.";
            immutable message = pattern.format(role, channelName);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else
        {
            enum pattern = "There are no %s in <l>%s</>.";
            logger.infof(pattern, role, channelName);
        }
    }
}


// lookupEnlist
/++
    Adds an account to either the whitelist, operator list, list of elevated users,
    staff, or the blacklist.

    Passes the `list` parameter to [alterAccountClassifier], for list selection.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        specified = The nickname or account to white-/blacklist.
        class_ = User class.
        channelName = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void lookupEnlist(
    AdminPlugin plugin,
    const string specified,
    const IRCUser.Class class_,
    const string channelName,
    const IRCEvent event = IRCEvent.init)
{
    import kameloso.plugins.common.mixins : WHOISFiberDelegate;
    import dialect.common : isValidNickname;

    static immutable IRCUser.Class[5] validClasses =
    [
        IRCUser.Class.staff,
        IRCUser.Class.operator,
        IRCUser.Class.elevated,
        IRCUser.Class.whitelist,
        IRCUser.Class.blacklist,
    ];

    immutable shouldSendToChannel = (event.sender.nickname.length > 0);
    immutable role = getNoun(NounForm.singular, class_);

    /++
        Report result, either to the local terminal or to the IRC channel/sender
     +/
    void report(const AlterationResult result, const string id)
    {
        import std.format : format;

        if (shouldSendToChannel)
        {
            // IRC report
            with (AlterationResult)
            final switch (result)
            {
            case success:
                enum pattern = "Added <h>%s<h> as <b>%s<b> in %s.";
                immutable message = pattern.format(id, role, channelName);
                privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid delist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "<h>%s<h> was already <b>%s<b> in %s.";
                immutable message = pattern.format(id, role, channelName);
                privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
                break;
            }
        }
        else /*if (!shouldSendToChannel)*/
        {
            // Terminal report
            with (AlterationResult)
            final switch (result)
            {
            case success:
                enum pattern = "Added <h>%s</> as %s in %s.";
                logger.infof(pattern, id, role, channelName);
                break;

            case noSuchAccount:
            case noSuchChannel:
                assert(0, "Invalid enlist-only `AlterationResult` passed to `lookupEnlist.report`");

            case alreadyInList:
                enum pattern = "<h>%s</> is already %s in %s.";
                logger.infof(pattern, id, role, channelName);
                break;
            }
        }
    }

    auto removeAndApply(const string name, /*const*/ string account = string.init)
    {
        if (!account.length) account = name;

        // Remove previous classification from all but the requested class
        foreach (immutable thisClass; validClasses[])
        {
            if (thisClass == class_) continue;

            alterAccountClassifier(
                plugin,
                add: false,
                thisClass,
                account,
                channelName);
        }

        // Make the class change and report
        immutable result = alterAccountClassifier(
            plugin,
            add: true,
            class_,
            account,
            channelName);

        return report(result, name);
    }

    const user = specified in plugin.state.users;

    if (user && user.account.length)
    {
        // Account known, skip ahead
        return removeAndApply(user.account, nameOf(*user));
    }
    else if (!specified.length)
    {
        if (shouldSendToChannel)
        {
            // IRC report
            enum message = "No nickname supplied.";
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
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
        if (shouldSendToChannel)
        {
            import std.format : format;

            // IRC report
            enum pattern = "Invalid nickname/account: <4>%s<c>";
            immutable message = pattern.format(specified);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else
        {
            // Terminal report
            enum pattern = "Invalid nickname/account: <l>%s";
            logger.warningf(pattern, specified);
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
                    return removeAndApply(nameOf(*userInList), id);
                }

                // If we're here, assume a display name was specified and look up the account
                auto usersWithThisDisplayName = plugin.state.users
                    .byValue
                    .filter!(u => u.displayName == id);

                if (!usersWithThisDisplayName.empty)
                {
                    return removeAndApply(id, usersWithThisDisplayName.front.account);
                }

                // Assume a valid account was specified even if we can't see it, and drop down
            }
        }

        return removeAndApply(id);
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
            // Can't WHOIS on Twitch
            return onSuccess(specified);
        }
    }

    // User not on record or on record but no account; WHOIS and try based on results
    mixin WHOISFiberDelegate!(onSuccess, onFailure);
    enqueueAndWHOIS(specified);
}


// NounForm
/++
    Forms in which [getNoun] should produce conjugated nouns.
 +/
enum NounForm
{
    /++
        Indefinite form.
     +/
    indefinite,

    /++
        Singular form (definite).
     +/
    singular,

    /++
        Plural form.
     +/
    plural,
}


// getNoun
/++
    Returns the string of a [dialect.defs.IRCUser.Class|Class] noun conjugated
    to the passed form.

    Params:
        form = Form to conjugate the noun to.
        class_ = [dialect.defs.IRCUser.Class|IRCUser.Class] whose string to conjugate.

    Returns:
        The string name of `class_` conjugated to `form`.
 +/
auto getNoun(const NounForm form, const IRCUser.Class class_)
{
    with (NounForm)
    with (IRCUser.Class)
    final switch (form)
    {
    case indefinite:
        final switch (class_)
        {
        case admin:      return "administrator";
        case staff:      return "staff";
        case operator:   return "operator";
        case elevated:   return "elevated user";
        case whitelist:  return "whitelisted user";
        case registered: return "registered user";
        case anyone:     return "anyone";
        case blacklist:  return "blacklisted user";
        case unset:      return "unset";
        }

    case singular:
        final switch (class_)
        {
        case admin:      return "an administrator";
        case staff:      return "staff";
        case operator:   return "an operator";
        case elevated:   return "an elevated user";
        case whitelist:  return "a whitelisted user";
        case registered: return "a registered user";
        case anyone:     return "anyone";
        case blacklist:  return "a blacklisted user";
        case unset:      return "unset";
        }

    case plural:
        final switch (class_)
        {
        case admin:      return "administrators";
        case staff:      return "staff";
        case operator:   return "operators";
        case elevated:   return "elevated users";
        case registered: return "registered users";
        case whitelist:  return "whitelisted users";
        case anyone:     return "anyone";
        case blacklist:  return "blacklisted users";
        case unset:      return "unset";
        }
    }
}


// getNoun
/++
    Returns the string of a noun conjugated to the passed form.

    Overload that takes a string instead of an [dialect.defs.IRCUser.Class|IRCUser.Class].

    Params:
        form = Form to conjugate the noun to.
        classString = Class string to conjugate.

    Returns:
        The string name of `class_` conjugated to `form`.
 +/
auto getNoun(const NounForm form, const string classString)
{
    import lu.conv : Enum;
    return getNoun(form, Enum!(IRCUser.Class).fromString(classString));
}


// delist
/++
    Removes a nickname from either the whitelist, operator list, list of elevated
    users, staff, or the blacklist.

    Passes the `list` parameter to [alterAccountClassifier], for list selection.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        account = The account to delist.
        class_ = User class.
        channelName = Which channel the enlisting relates to.
        event = Optional instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void delist(
    AdminPlugin plugin,
    const string account,
    const IRCUser.Class class_,
    const string channelName,
    const IRCEvent event = IRCEvent.init)
{
    import std.format : format;

    immutable shouldSendToChannel = (event.sender.nickname.length > 0);

    if (!account.length)
    {
        if (shouldSendToChannel)
        {
            // IRC report
            enum message = "No account specified.";
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else
        {
            // Terminal report
            logger.warning("No account specified.");
        }
        return;
    }

    immutable role = getNoun(NounForm.singular, class_);
    immutable result = alterAccountClassifier(
        plugin,
        add: false,
        class_,
        account,
        channelName);

    if (shouldSendToChannel)
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
            immutable message = pattern.format(account, role, channelName);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            break;

        case success:
            enum pattern = "Removed <h>%s<h> as <b>%s<b> in %s.";
            immutable message = pattern.format(account, role, channelName);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            break;
        }
    }
    else /*if (!shouldSendToChannel)*/
    {
        // Terminal report

        with (AlterationResult)
        final switch (result)
        {
        case alreadyInList:
            assert(0, "Invalid enlist-only `AlterationResult` returned to `delist`");

        case noSuchAccount:
            enum pattern = "No such account <h>%s</> was found as %s in %s.";
            logger.infof(pattern, account, role, channelName);
            break;

        case noSuchChannel:
            enum pattern = "Account <h>%s</> isn't %s in %s.";
            logger.infof(pattern, account, role, channelName);
            break;

        case success:
            enum pattern = "Removed <h>%s</> as %s in %s.";
            logger.infof(pattern, account, role, channelName);
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
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        add = Whether to add to or remove from lists.
        class_ = User class.
        account = Services account name to add or remove.
        channelName = Channel the account-class applies to.

    Returns:
        [AlterationResult.alreadyInList] if enlisting (`add: true`) and the account
        was already in the specified list.
        [AlterationResult.noSuchAccount] if delisting (`add: false`) and no such
        account could be found in the specified list.
        [AlterationResult.noSuchChannel] if delisting (`add: false`) and no such
        channel could be found in the specified list.
        [AlterationResult.success] if enlisting or delisting succeeded.
 +/
auto alterAccountClassifier(
    AdminPlugin plugin,
    const bool add,
    const IRCUser.Class class_,
    const string account,
    const string channelName)
{
    import kameloso.thread : ThreadMessage;
    import asdf.serialization : deserialize;
    import lu.conv : toString;
    import std.file : readText;
    import std.json : JSONValue;
    import std.stdio : File;

    auto json = plugin.userFile
        .readText
        .deserialize!(string[][string][string]);

    immutable list = class_.toString;

    if (add)
    {
        import std.algorithm.searching : canFind;

        if (auto channelAccounts = channelName in json[list])
        {
            if ((*channelAccounts).canFind(account))
            {
                return AlterationResult.alreadyInList;
            }
            else
            {
                *channelAccounts ~= account;
            }
        }
        else
        {
            json[list][channelName] ~= account;
        }

        // Remove placeholder example since there should now be at least one true entry
        enum examplePlaceholderKey = "<#channel>";
        json[list].remove(examplePlaceholderKey);
    }
    else
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import std.algorithm.searching : countUntil;

        if (auto channelAccounts = channelName in json[list])
        {
            immutable index = (*channelAccounts).countUntil(account);

            if (index == -1)
            {
                return AlterationResult.noSuchAccount;
            }

            *channelAccounts = (*channelAccounts)
                .remove!(SwapStrategy.unstable)(index);
        }
        else
        {
            return AlterationResult.noSuchChannel;
        }
    }

    immutable serialised = JSONValue(json).toPrettyString;
    File(plugin.userFile, "w").writeln(serialised);

    version(WithPersistenceService)
    {
        // Force persistence to reload the file with the new changes
        plugin.state.messages ~= ThreadMessage.reload("persistence");
    }

    return AlterationResult.success;
}


// modifyHostmaskDefinition
/++
    Adds or removes hostmasks used to identify users on servers that don't employ services.

    Params:
        plugin = The current [kameloso.plugins.admin.AdminPlugin|AdminPlugin].
        add = Whether to add or to remove the hostmask.
        account = Account the hostmask will equate to. May be empty if `add` is false.
        mask = String "nickname!ident@address.tld" hostmask.
        event = Instigating [dialect.defs.IRCEvent|IRCEvent].
 +/
void modifyHostmaskDefinition(
    AdminPlugin plugin,
    const bool add,
    const string account,
    const string mask,
    const IRCEvent event)
in ((!add || account.length), "Tried to add a hostmask with no account to map it to")
in (mask.length, "Tried to add an empty hostmask definition")
{
    import kameloso.pods : CoreSettings;
    import kameloso.thread : ThreadMessage;
    import asdf.serialization : deserialize;
    import std.conv : text;
    import std.file : readText;
    import std.format : format;
    import std.json : JSONValue;
    import std.stdio : File;

    // Values from persistence.d etc
    enum examplePlaceholderKey = "<nickname>!<ident>@<address>";
    enum examplePlaceholderValue = "<account>";

    immutable shouldSendToChannel = (event.sender.nickname.length > 0);
    auto aa = plugin.hostmasksFile
        .readText
        .deserialize!(string[string]);

    if (add)
    {
        import dialect.common : isValidHostmask;

        if (!mask.isValidHostmask(plugin.state.server))
        {
            if (shouldSendToChannel)
            {
                import std.format : format;
                enum pattern = `Invalid hostmask: "<b>%s<b>"; must be in the form "<b>nickname!ident@address.tld<b>".`;
                immutable message = pattern.format(mask);
                privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            }
            else
            {
                enum pattern = `Invalid hostmask "<l>%s</>"; must be in the form ` ~
                    `"<l>nickname!ident@address</>".`;
                logger.warningf(pattern, mask);
            }
            return;  // Skip saving and updating below
        }

        aa[mask] = account;

        // Remove any placeholder example since there should now be at least one true entry
        aa.remove(examplePlaceholderKey);

        if (shouldSendToChannel)
        {
            enum pattern = `Added hostmask "<b>%s<b>", mapped to account <h>%s<h>.`;
            immutable message = pattern.format(mask, account);
            privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
        }
        else
        {
            enum pattern = `Added hostmask "<l>%s</>", mapped to account <h>%s</>.`;
            logger.infof(pattern, mask, account);
        }
        // Drop down to save
    }
    else
    {
        // Allow for removing an invalid mask

        if (const mappedAccount = mask in aa)
        {
            aa.remove(mask);

            if (!aa.length) aa[examplePlaceholderKey] = examplePlaceholderValue;

            if (event.type == IRCEvent.Type.UNSET)
            {
                enum pattern = `Removed hostmask "<l>%s</>".`;
                logger.infof(pattern, mask);
            }
            else
            {
                enum pattern = `Removed hostmask "<b>%s<b>".`;
                immutable message = pattern.format(mask);
                privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            }
            // Drop down to save
        }
        else
        {
            if (shouldSendToChannel)
            {
                enum pattern = `No such hostmask "<b>%s<b>" on file.`;
                immutable message = format(pattern, mask);
                privmsg(plugin.state, event.channel.name, event.sender.nickname, message);
            }
            else
            {
                enum pattern = `No such hostmask "<l>%s</>" on file.`;
                logger.warningf(pattern, mask);
            }
            return;  // Skip saving and updating below
        }
    }

    immutable serialised = JSONValue(aa).toPrettyString;
    File(plugin.hostmasksFile, "w").writeln(serialised);

    version(WithPersistenceService)
    {
        // Force persistence to reload the file with the new changes
        plugin.state.messages ~= ThreadMessage.reload("persistence");
    }
}

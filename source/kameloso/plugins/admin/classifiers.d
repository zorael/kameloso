
module kameloso.plugins.admin.classifiers;

version(WithPlugins):
version(WithAdminPlugin):

private:

import kameloso.plugins.admin.base;

import kameloso.plugins.common.misc : nameOf;
import kameloso.common : Tint, logger;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.algorithm.comparison : among;
import std.typecons : Flag, No, Yes;

package:




void manageClassLists(AdminPlugin plugin,
    const ref IRCEvent event,
    const string list)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    
}




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
         "blacklisted users";

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




void lookupEnlist(AdminPlugin plugin,
    const string rawSpecified,
    const string list,
    const string channel,
    const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    
}




void delist(AdminPlugin plugin,
    const string account,
    const string list,
    const string channel,
    const IRCEvent event = IRCEvent.init)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    
}




enum AlterationResult
{
    alreadyInList,  
    noSuchAccount,  
    noSuchChannel,  
    success,        
}




AlterationResult alterAccountClassifier(AdminPlugin plugin,
    const Flag!"add" add,
    const string list,
    const string account,
    const string channelName)
in (list.among!("whitelist", "blacklist", "operator", "staff"),
    list ~ " is not whitelist, operator, staff nor blacklist")
{
    
    return AlterationResult.init;
}




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
        import kameloso.terminal : colourByHash;
    }
    else
    {
        
        static string colourByHash(const string word, const Flag!"brightTerminal")
        {
            return word;
        }
    }

    
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
                logger.warningf(`Invalid hostmask: "%s%s%s"; must be in the form ` ~
                    `"%1$snickname!ident@address%3$s".`,
                    Tint.log, mask, Tint.warning);
            }
            else
            {
                import std.format : format;
                privmsg(plugin.state, event.channel, event.sender.nickname,
                    `Invalid hostmask: "%s"; must be in the form "%s".`
                        .format(mask.ircBold, "nickname!ident@address".ircBold));
            }
            return;
        }

        aa[mask] = account;

        
        aa.remove(examplePlaceholderKey);

        immutable colouredAccount = colourByHash(account, brightFlag);

        if (event == IRCEvent.init)
        {
            logger.infof(`Added hostmask "%s%s%s", mapped to account %4$s%3$s.`,
                Tint.log, mask, Tint.info, colouredAccount);
        }
        else
        {
            immutable message = `Added hostmask "%s", mapped to account %s.`
                .format(mask.ircBold, account.ircColourByHash);
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
    else
    {
        

        if (const mappedAccount = mask in aa)
        {
            aa.remove(mask);
            if (!aa.length) aa[examplePlaceholderKey] = examplePlaceholderValue;

            if (event == IRCEvent.init)
            {
                logger.infof(`Removed hostmask "%s%s%s".`, Tint.log, mask, Tint.info);
            }
            else
            {
                immutable message = `Removed hostmask "%s".`.format(mask.ircBold);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
            }
        }
        else
        {
            if (event == IRCEvent.init)
            {
                logger.warningf(`No such hostmask "%s%s%s" on file.`,
                    Tint.log, mask, Tint.warning);
            }
            else
            {
                immutable message = `No such hostmask "%s" on file.`.format(mask.ircBold);
                privmsg(plugin.state, event.channel, event.sender.nickname, message);
            }
            return;  
        }
    }

    json.reset();
    json = JSONValue(aa);
    json.save!(JSONStorage.KeyOrderStrategy.passthrough)(plugin.hostmasksFile);

    
    plugin.state.mainThread.send(ThreadMessage.Reload());
}

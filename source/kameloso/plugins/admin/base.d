
module kameloso.plugins.admin.base;

version(WithPlugins):
version(WithAdminPlugin):

private:

import kameloso.plugins.admin.classifiers;
debug import kameloso.plugins.admin.debugging;

import kameloso.plugins.common.core;
import kameloso.plugins.common.misc : applyCustomSettings;
import kameloso.plugins.common.awareness;
import kameloso.common : Tint, logger;
import kameloso.constants : BufferSize;
import kameloso.irccolours : IRCColour, ircBold, ircColour, ircColourByHash;
import kameloso.messaging;
import dialect.defs;
import std.concurrency : send;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;


version(OmniscientAdmin)
{
    
    enum omniscientChannelPolicy = ChannelPolicy.any;
}
else
{
    
    enum omniscientChannelPolicy = ChannelPolicy.home;
}




@Settings struct AdminSettings
{
private:
    import lu.uda : Unserialisable;

public:
    
    @Enabler bool enabled = true;

    @Unserialisable
    {
        
        bool printRaw;

        
        bool printBytes;
    }
}





void onAnyEvent(AdminPlugin plugin, const ref IRCEvent event)
{
    return onAnyEventImpl(plugin, event);
}





void onCommandShowUser(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandShowUserImpl(plugin, event);
}





void onCommandSave(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;

    privmsg(plugin.state, event.channel, event.sender.nickname, "Saving configuration to disk.");
    plugin.state.mainThread.send(ThreadMessage.Save());
}





void onCommandShowUsers(AdminPlugin plugin)
{
    return onCommandShowUsersImpl(plugin);
}





void onCommandSudo(AdminPlugin plugin, const ref IRCEvent event)
{
    return onCommandSudoImpl(plugin, event);
}






void onCommandQuit(AdminPlugin plugin, const ref IRCEvent event)
{
    quit(plugin.state, event.content);
}





void onCommandHome(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.string : nom, strippedRight;
    import std.format : format;
    import std.typecons : Flag, No, Yes;

    void sendUsage()
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [add|del|list] [channel]"
                .format(plugin.state.settings.prefix, event.aux));
    }

    if (!event.content.length)
    {
        return sendUsage();
    }

    string slice = event.content.strippedRight;  
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    case "add":
        return plugin.addHome(event, slice);

    case "del":
        return plugin.delHome(event, slice);

    case "list":
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Current home channels: %-(%s, %)"
                .format(plugin.state.bot.homeChannels));
        return;

    default:
        return sendUsage();
    }
}




void addHome(AdminPlugin plugin, const ref IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to add a home but the channel string was empty")
{
    
}




void delHome(AdminPlugin plugin, const ref IRCEvent event, const string rawChannel)
in (rawChannel.length, "Tried to delete a home but the channel string was empty")
{
    
}





void onCommandWhitelist(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "whitelist");
}





void onCommandOperator(AdminPlugin plugin, const ref IRCEvent event)
{
    return plugin.manageClassLists(event, "operator");
}





void onCommandPrintBytes(AdminPlugin plugin, const ref IRCEvent event)
{
    
}





void onCommandJoin(AdminPlugin plugin, const ref IRCEvent event)
{
    
}





void onCommandPart(AdminPlugin plugin, const ref IRCEvent event)
{
    
}





void onSetCommand(AdminPlugin plugin, const ref IRCEvent event)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : send;

    void dg(bool success)
    {
        if (success)
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, "Setting changed.");
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Invalid syntax or plugin/setting name.");
        }
    }

    plugin.state.mainThread.send(ThreadMessage.ChangeSetting(), cast(shared)&dg, event.content);
}





void onCommandAuth(AdminPlugin plugin)
{
    
}





void onCommandStatus(AdminPlugin plugin)
{
    
}





void onCommandSummary(AdminPlugin plugin)
{
    
}





void onCommandCycle(AdminPlugin plugin, const ref IRCEvent event)
{
    
}




void listHostmaskDefinitions(AdminPlugin plugin, const ref IRCEvent event)
{
    import lu.json : JSONStorage, populateFromJSON;

    JSONStorage json;
    json.reset();
    json.load(plugin.hostmasksFile);

    string[string] aa;
    aa.populateFromJSON(json);

    
    enum examplePlaceholderKey = "<nickname>!<ident>@<address>";
    aa.remove(examplePlaceholderKey);

    if (aa.length)
    {
        if (event == IRCEvent.init)
        {
            import std.json : JSONValue;
            import std.stdio : writeln;

            logger.log("Current hostmasks:");
            
            writeln(JSONValue(aa).toPrettyString);
        }
        else
        {
            import std.conv : text;
            privmsg(plugin.state, event.channel, event.sender.nickname,
                "Current hostmasks: " ~ aa.text.ircBold);
        }
    }
    else
    {
        enum message = "There are presently no hostmasks defined.";

        if (event == IRCEvent.init)
        {
            logger.info(message);
        }
        else
        {
            privmsg(plugin.state, event.channel, event.sender.nickname, message);
        }
    }
}





void onCommandBus(AdminPlugin plugin, const ref IRCEvent event)
{
    
}


import kameloso.thread : Sendable;



void onBusMessage(AdminPlugin plugin, const string header, shared Sendable content)
{
    if (header != "admin") return;

    

    import kameloso.printing : printObject;
    import kameloso.thread : BusMessage;
    import lu.string : contains, nom, strippedRight;

    auto message = cast(BusMessage!string)content;
    assert(message, "Incorrectly cast message: " ~ typeof(message).stringof);

    string slice = message.payload.strippedRight;
    immutable verb = slice.nom!(Yes.inherit)(' ');

    switch (verb)
    {
    debug
    {
        case "status":
            return plugin.onCommandStatus();

        case "users":
            return plugin.onCommandShowUsers();

        case "user":
            if (const user = slice in plugin.state.users)
            {
                printObject(*user);
            }
            else
            {
                logger.error("No such user: ", slice);
            }
            break;

        case "state":
            printObject(plugin.state);
            break;

        case "printraw":
            plugin.adminSettings.printRaw = !plugin.adminSettings.printRaw;
            return;

        case "printbytes":
            plugin.adminSettings.printBytes = !plugin.adminSettings.printBytes;
            return;
    }

    case "set":
        import kameloso.thread : ThreadMessage;

        void dg(bool success)
        {
            if (success) logger.log("Setting changed.");
        }

        return plugin.state.mainThread.send(ThreadMessage.ChangeSetting(), cast(shared)&dg, slice);

    case "save":
        import kameloso.thread : ThreadMessage;

        logger.log("Saving configuration to disk.");
        return plugin.state.mainThread.send(ThreadMessage.Save());

    case "reload":
        import kameloso.thread : ThreadMessage;

        if (slice.length)
        {
            logger.logf("Reloading plugin \"%s%s%s\".", Tint.info, slice, Tint.log);
        }
        else
        {
            logger.log("Reloading plugins.");
        }

        return plugin.state.mainThread.send(ThreadMessage.Reload(), slice);

    case "whitelist":
    case "operator":
    case "staff":
    case "blacklist":
        import lu.string : SplitResults, splitInto;

        string subverb;
        string channel;

        immutable results = slice.splitInto(subverb, channel);
        if (results == SplitResults.underrun)
        {
            
            logger.warningf("Invalid bus message syntax; expected %s " ~
                "[verb] [channel] [nickname if add/del], got \"%s\"",
                verb, message.payload.strippedRight);
            return;
        }

        switch (subverb)
        {
        case "add":
        case "del":
            immutable user = slice;

            if (!user.length)
            {
                logger.warning("Invalid bus message syntax; no user supplied, " ~
                    "only channel ", channel);
                return;
            }

            if (subverb == "add")
            {
                return plugin.lookupEnlist(user, subverb, channel);
            }
            else 
            {
                return plugin.delist(user, subverb, channel);
            }

        case "list":
            return plugin.listList(channel, verb);

        default:
            logger.warningf("Invalid bus message %s subverb: %s", verb, subverb);
            break;
        }
        break;

    case "hostmask":
        import lu.string : nom;

        immutable subverb = slice.nom!(Yes.inherit)(' ');

        switch (subverb)
        {
        case "add":
            import lu.string : SplitResults, splitInto;

            string account;
            string mask;

            immutable results = slice.splitInto(account, mask);
            if (results != SplitResults.match)
            {
                logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask add [account] [hostmask]");
                return;
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, Yes.add, account, mask, lvalueEvent);

        case "del":
        case "remove":
            if (!slice.length)
            {
                logger.warning("Invalid bus message syntax; " ~
                    "expected hostmask del [hostmask]");
                return;
            }

            IRCEvent lvalueEvent;
            return modifyHostmaskDefinition(plugin, No.add, string.init, slice, lvalueEvent);

        case "list":
            IRCEvent lvalueEvent;
            return listHostmaskDefinitions(plugin, lvalueEvent);

        default:
            logger.warningf("Invalid bus message %s subverb: %s", verb, subverb);
            break;
        }
        break;

    case "summary":
        return plugin.onCommandSummary();

    default:
        logger.error("[admin] Unimplemented bus message verb: ", verb);
        break;
    }
}


public:




final class AdminPlugin : IRCPlugin
{
package:
    import kameloso.constants : KamelosoFilenames;

    
    AdminSettings adminSettings;

    
    @Resource string userFile = KamelosoFilenames.users;

    
    @Resource string hostmasksFile = KamelosoFilenames.hostmasks;

    mixin IRCPluginImpl;
}

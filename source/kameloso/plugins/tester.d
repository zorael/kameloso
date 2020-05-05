/++
 +
 +/
module kameloso.plugins.tester;

version(WithPlugins):
//version(WithTesterPlugin):

private:

import kameloso.plugins.core;
import kameloso.plugins.awareness : MinimalAuthentication;
import kameloso.plugins.common;
import kameloso.common : logger;
import kameloso.messaging;
import kameloso.thread : CarryingFiber;
import dialect.defs;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;


// onCommandTest
/++
 +
 +/
@(IRCEvent.Type.CHAN)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(PrefixPolicy.nickname, "test")
@Description("Runs tests.")
void onCommandTest(TesterPlugin plugin, const IRCEvent event)
{
    import lu.string : SplitResults, splitInto;
    import core.thread : Fiber;

    string slice = event.content;  // mutable
    string pluginName;
    string botNickname;

    immutable results = slice.splitInto(pluginName, botNickname);

    if (results != SplitResults.match)
    {
        import std.format : format;

        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [plugin] [target bot nickname]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    switch (pluginName)
    {
    case "admin":
        void adminDg()
        {
            return testAdminFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&adminDg);
        fiber.call();
        break;

    case "all":
        void allDg()
        {
            return testAdminFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&allDg);
        fiber.call();
        break;

    default:
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Invalid plugin: " ~ event.content);
        break;
    }
}


// testAdminFiber
/++
 +
 +/
void testAdminFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Admin with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    awaitEvents(plugin, IRCEvent.Type.CHAN);
    scope(exit) unlistFiberAwaitingEvents(plugin, IRCEvent.Type.CHAN);

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !home

    send("home del #harpsteff");
    // Ignore reply

    send("home add #harpsteff");
    assert(thisFiber.payload.content == "Home added.");

    send("home add #harpsteff");
    assert(thisFiber.payload.content == "We are already in that home channel.");

    send("home del #harpsteff");
    assert(thisFiber.payload.content == "Home removed.");

    send("home del #harpsteff");
    assert(thisFiber.payload.content == "Channel #harpsteff was not listed as a home.");

    // ------------ lists

    import std.format : format;
    import std.range : only;

    foreach (immutable list; only("operator", "whitelist", "blacklist"))
    {
        immutable asWhat =
            (list == "operator") ? "an operator" :
            (list == "whitelist") ? "a whitelisted user" :
            /*(list == "blacklist") ?*/ "a blacklisted user";

        send(list ~ " del wefpok");
        assert(thisFiber.payload.content == "Account wefpok isn't %s in %s."
            .format(asWhat, origEvent.channel));

        send(list ~ " add wefpok");
        assert(thisFiber.payload.content == "Added wefpok as %s in %s."
            .format(asWhat, origEvent.channel));

        send(list ~ " add wefpok");
        assert(thisFiber.payload.content == "wefpok was already %s in %s."
            .format(asWhat, origEvent.channel));

        send(list ~ " del wefpok");
        assert(thisFiber.payload.content == "Removed wefpok as %s in %s."
            .format(asWhat, origEvent.channel));

        send(list ~ " add");
        assert(thisFiber.payload.content == "No nickname supplied.");

        immutable asWhatList =
            (list == "operator") ? "operators" :
            (list == "whitelist") ? "whitelisted users" :
            /*(list == "blacklist") ?*/ "blacklisted users";

        send(list ~ " list");
        assert(thisFiber.payload.content == "There are no %s in %s."
            .format(asWhatList, origEvent.channel));
    }

    // ------------ misc

    send("cycle #flirrp");
    assert(thisFiber.payload.content == "I am not in that channel.");

    // ------------ hostmasks

    send("hostmask");
    if (thisFiber.payload.content != "This bot is not currently configured " ~
        "to use hostmasks for authentication.")
    {
        send("hostmask add");
        assert(thisFiber.payload.content ==
            "Usage: !hostmask [add|del|list] ([account] [hostmask]/[hostmask])");

        send("hostmask add HIRF#%%!SNIRF$$$@''ä''.''.");
        assert(thisFiber.payload.content == "Invalid hostmask.");

        send("hostmask add kameloso kameloso^!*@*");
        assert(thisFiber.payload.content == "Hostmask list updated.");

        send("hostmask add kameloso kameloso^!*@*");
        assert(thisFiber.payload.content == `Current hostmasks: ["kameloso^!*@*":"kameloso"]`);

        send("hostmask del kameloso^!*@*");
        assert(thisFiber.payload.content == "Hostmask list updated.");

        send("hostmask del kameloso^!*@*");
        assert(thisFiber.payload.content == "No such hostmask on file.");
    }

    logger.info("Admin tests passed!");
}

mixin MinimalAuthentication;


public:

/++
 +
 +/
final class TesterPlugin : IRCPlugin
{
private:
    mixin IRCPluginImpl;
}

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
import lu.string : beginsWith, contains;
import std.algorithm.searching : endsWith;
import std.exception : enforce;
import std.format : format;
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

    immutable results = slice.splitInto(botNickname, pluginName);

    if (results != SplitResults.match)
    {
        import std.format : format;

        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [target bot nickname] [plugin] "
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    switch (pluginName)
    {
    case "admin":
        void adminDg() { return testAdminFiber(plugin, event, botNickname); }
        Fiber fiber = new CarryingFiber!IRCEvent(&adminDg);
        fiber.call();
        break;

    case "automodes":
        void automodesDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testAutomodesFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&automodesDg);
        fiber.call();
        break;

    case "chatbot":
        void chatbotDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testChatbotFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&chatbotDg);
        fiber.call();
        break;

    case "notes":
        void notesDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testNotesFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&notesDg);
        fiber.call();
        break;

    case "oneliners":
        void onelinersDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testOnelinersFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&onelinersDg);
        fiber.call();
        break;

    case "quotes":
        void quotesDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testQuotesFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&quotesDg);
        fiber.call();
        break;

    case "sedreplace":
        void sedReplaceDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testSedReplaceFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&sedReplaceDg);
        fiber.call();
        break;

    case "all":
        void allDg()
        {
            auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
            assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            Fiber.yield();
            while ((thisFiber.payload.channel != event.channel) ||
                (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();

            testAdminFiber(plugin, event, botNickname);
            testAutomodesFiber(plugin, event, botNickname);
            testChatbotFiber(plugin, event, botNickname);
            testNotesFiber(plugin, event, botNickname);
            testOnelinersFiber(plugin, event, botNickname);
            testQuotesFiber(plugin, event, botNickname);
            testSedReplaceFiber(plugin, event, botNickname);
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&allDg);
        fiber.call();
        break;

    default:
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Invalid plugin: " ~ pluginName);
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

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !home

    send("home del #harpsteff");
    enforce(thisFiber.payload.content == "Channel #harpsteff was not listed as a home.");

    send("home add #harpsteff");
    enforce(thisFiber.payload.content == "Home added.");

    send("home add #harpsteff");
    enforce(thisFiber.payload.content == "We are already in that home channel.");

    send("home del #harpsteff");
    enforce(thisFiber.payload.content == "Home removed.");

    send("home del #harpsteff");
    enforce(thisFiber.payload.content == "Channel #harpsteff was not listed as a home.");

    // ------------ lists

    import std.range : only;

    foreach (immutable list; only("operator", "whitelist", "blacklist"))
    {
        immutable asWhat =
            (list == "operator") ? "an operator" :
            (list == "whitelist") ? "a whitelisted user" :
            /*(list == "blacklist") ?*/ "a blacklisted user";

        //"No such account zorael to remove as %s in %s."
        send(list ~ " del zorael");
        enforce((thisFiber.payload.content == "zorael isn't %s in %s."
            .format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add zorael");
        enforce((thisFiber.payload.content == "Added zorael as %s in %s."
            .format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add zorael");
        enforce((thisFiber.payload.content == "zorael was already %s in %s."
            .format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " del zorael");
        enforce((thisFiber.payload.content == "Removed zorael as %s in %s."
            .format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add");
        enforce((thisFiber.payload.content == "No nickname supplied."),
            thisFiber.payload.content);

        immutable asWhatList =
            (list == "operator") ? "operators" :
            (list == "whitelist") ? "whitelisted users" :
            /*(list == "blacklist") ?*/ "blacklisted users";

        send(list ~ " list");
        enforce(thisFiber.payload.content == "There are no %s in %s."
            .format(asWhatList, origEvent.channel));
    }

    // ------------ misc

    send("cycle #flirrp");
    enforce(thisFiber.payload.content == "I am not in that channel.");

    // ------------ hostmasks

    send("hostmask");
    if (thisFiber.payload.content != "This bot is not currently configured " ~
        "to use hostmasks for authentication.")
    {
        send("hostmask add");
        enforce(thisFiber.payload.content ==
            "Usage: !hostmask [add|del|list] ([account] [hostmask]/[hostmask])");

        send("hostmask add kameloso HIRF#%%!SNIR@sdasdasd");
        enforce(thisFiber.payload.content == "Invalid hostmask.");

        send("hostmask add kameloso kameloso^!*@*");
        enforce(thisFiber.payload.content == "Hostmask list updated.");

        send("hostmask list");
        // `Current hostmasks: ["kameloso^!*@*":"kameloso"]`);
        enforce(thisFiber.payload.content.contains(`"kameloso^!*@*":"kameloso"`));

        send("hostmask del kameloso^!*@*");
        enforce(thisFiber.payload.content == "Hostmask list updated.");

        send("hostmask del kameloso^!*@*");
        enforce(thisFiber.payload.content == "No such hostmask on file.");
    }

    logger.info("Admin tests passed!");
}


// testAutomodesFiber
/++
 +
 +/
void testAutomodesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Automodes with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !automode

    /*send("automode list");
    enforce(thisFiber.payload.content == "No automodes defined for channel %s."
        .format(origEvent.channel));*/

    send("automode del");
    enforce(thisFiber.payload.content ==
        "Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    send("automode");
    enforce(thisFiber.payload.content ==
        "Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    send("automode add $¡$¡ +o");
    enforce(thisFiber.payload.content == "Invalid nickname.");

    send("automode add kameloso -v");
    enforce(thisFiber.payload.content == "Can't add a negative automode.");

    send("automode add kameloso +");
    enforce(thisFiber.payload.content == "You must supply a valid mode.");

    send("automode add kameloso +o");
    enforce(thisFiber.payload.content == "Automode modified! kameloso on %s: +o"
        .format(origEvent.channel));

    send("automode add kameloso +v");
    enforce(thisFiber.payload.content == "Automode modified! kameloso on %s: +v"
        .format(origEvent.channel));

    send("automode list");
    enforce(thisFiber.payload.content.contains(`"kameloso":"v"`));

    send("automode del $¡$¡");
    enforce(thisFiber.payload.content == "Invalid nickname.");

    send("automode del kameloso");
    enforce(thisFiber.payload.content == "Automode for kameloso cleared.");

    /*send("automode list");
    enforce(thisFiber.payload.content == "No automodes defined for channel %s."
        .format(origEvent.channel));*/

    send("automode del flerrp");
    enforce(thisFiber.payload.content == "Automode for flerrp cleared.");

    logger.info("Automode tests passed!");
}


// testChatbotFiber
/++
 +
 +/
void testChatbotFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Chatbot with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !say

    send("say zoraelblarbhl");
    enforce(thisFiber.payload.content == "zoraelblarbhl");

    // ------------ !8ball

    import std.algorithm.searching : canFind;

    static immutable string[20] eightballAnswers =
    [
        "It is certain",
        "It is decidedly so",
        "Without a doubt",
        "Yes, definitely",
        "You may rely on it",
        "As I see it, yes",
        "Most likely",
        "Outlook good",
        "Yes",
        "Signs point to yes",
        "Reply hazy try again",
        "Ask again later",
        "Better not tell you now",
        "Cannot predict now",
        "Concentrate and ask again",
        "Don't count on it",
        "My reply is no",
        "My sources say no",
        "Outlook not so good",
        "Very doubtful",
    ];

    send("8ball");
    enforce(eightballAnswers[].canFind(thisFiber.payload.content));

    // ------------ !bash; don't test, it's complicated

    // ------------ DANCE

    await(plugin, IRCEvent.Type.EMOTE);

    send("get on up and DANCE");
    enforce(thisFiber.payload.content == "dances :D-<");
    Fiber.yield();
    enforce(thisFiber.payload.content == "dances :D|-<");
    Fiber.yield();
    enforce(thisFiber.payload.content == "dances :D/-<");

    unawait(plugin, IRCEvent.Type.EMOTE);

    logger.info("Chatbot tests passed!");
}


// testNotesFiber
/++
 +
 +/
void testNotesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Notes with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !note
    send("note %s test".format(botNickname));
    enforce(thisFiber.payload.content ==
        "You cannot leave the bot a message; it would never be replayed.");

    send("note %s test".format(plugin.state.client.nickname));
    enforce(thisFiber.payload.content == "Note added.");

    unawait(plugin, IRCEvent.Type.CHAN);
    part(plugin.state, origEvent.channel);
    await(plugin, IRCEvent.Type.SELFPART);
    Fiber.yield();
    while (thisFiber.payload.channel != origEvent.channel) Fiber.yield();
    unawait(plugin, IRCEvent.Type.SELFPART);

    await(plugin, IRCEvent.Type.SELFJOIN);
    join(plugin.state, origEvent.channel);
    Fiber.yield();
    while (thisFiber.payload.channel != origEvent.channel) Fiber.yield();
    unawait(plugin, IRCEvent.Type.SELFJOIN);
    await(plugin, IRCEvent.Type.CHAN);
    Fiber.yield();
    enforce(thisFiber.payload.content.beginsWith("%s! %1$s left note"
        .format(plugin.state.client.nickname)) &&
        thisFiber.payload.content.endsWith("ago: test"));

    logger.info("Notes tests passed!");
}


// testOnelinersFiber
/++
 +
 +/
void testOnelinersFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Oneliners with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void sendNoPrefix(const string line)
    {
        chan(plugin.state, origEvent.channel, line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !oneliner

    send("commands");
    enforce(thisFiber.payload.content == "There are no commands available right now.");

    send("oneliner");
    enforce(thisFiber.payload.content == "Usage: %soneliner [add|del|list] [trigger] [text]"
        .format(plugin.state.settings.prefix));

    send("oneliner add herp derp dirp darp");
    enforce(thisFiber.payload.content == "Oneliner %sherp added."
        .format(plugin.state.settings.prefix));

    send("oneliner list");
    enforce(thisFiber.payload.content == "Available commands: %sherp"
        .format(plugin.state.settings.prefix));

    sendNoPrefix("%sherp".format(plugin.state.settings.prefix));
    enforce(thisFiber.payload.content == "derp dirp darp");

    send("oneliner del hirrp");
    enforce(thisFiber.payload.content == "No such trigger: %shirrp"
        .format(plugin.state.settings.prefix));

    send("oneliner del herp");
    enforce(thisFiber.payload.content == "Oneliner %sherp removed."
        .format(plugin.state.settings.prefix));

    logger.info("Oneliners tests passed!");
}


// testQuotesFiber
/++
 +
 +/
void testQuotesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Quotes with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    // ------------ !quote

    send("quote");
    enforce(thisFiber.payload.content ==
        "Usage: %squote [nickname] [optional text to add a new quote]"
        .format(plugin.state.settings.prefix));

    send("quote $¡$¡");
    enforce(thisFiber.payload.content == `"$¡$¡" is not a valid account or nickname.`);

    send("quote flerrp");
    //enforce(thisFiber.payload.content == "No quote on record for flerrp.");

    send("quote flerrp flirrp flarrp flurble");
    //enforce(thisFiber.payload.content == "Quote for flerrp saved (1 on record)");

    send("quote flerrp");
    enforce(thisFiber.payload.content == "flerrp | flirrp flarrp flurble");

    logger.info("Quotes tests passed!");
}


// testSedReplaceFiber
/++
 +
 +/
void testSedReplaceFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test SedReplace with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void sendNoPrefix(const string line)
    {
        chan(plugin.state, origEvent.channel, line);
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    chan(plugin.state, origEvent.channel, "I am a fish");
    sendNoPrefix("s/fish/snek/");
    enforce(thisFiber.payload.content == "%s | I am a snek"
        .format(plugin.state.client.nickname));

    chan(plugin.state, origEvent.channel, "I am a fish fish");
    sendNoPrefix("s#fish#snek#");
    enforce(thisFiber.payload.content == "%s | I am a snek fish"
        .format(plugin.state.client.nickname));

    chan(plugin.state, origEvent.channel, "I am a fish fish");
    sendNoPrefix("s_fish_snek_g");
    enforce(thisFiber.payload.content == "%s | I am a snek snek"
        .format(plugin.state.client.nickname));

    logger.info("SedReplace tests passed!");
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

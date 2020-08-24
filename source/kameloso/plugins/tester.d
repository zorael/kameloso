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
import kameloso.plugins.common.delayawait;
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
            "Usage: %s%s [target bot nickname] [plugin]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    switch (pluginName)
    {
    case "admin":
        void adminDg()
        {
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testAdminFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&adminDg);
        fiber.call();
        break;

    case "automodes":
        void automodesDg()
        {
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testSedReplaceFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&sedReplaceDg);
        fiber.call();
        break;

    case "seen":
        void seenDg()
        {
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testSeenFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&seenDg);
        fiber.call();
        break;

    case "counter":
        void counterDg()
        {
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testCounterFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&counterDg);
        fiber.call();
        break;

    case "stopwatch":
        void stopwatchDg()
        {
            chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);
            return testStopwatchFiber(plugin, event, botNickname);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&stopwatchDg);
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
            scope(exit) chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");

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
            testSeenFiber(plugin, event, botNickname);
            testCounterFiber(plugin, event, botNickname);
            testStopwatchFiber(plugin, event, botNickname);

            logger.info("All tests passed!");
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
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !home

    send("home del #harpsteff");
    expect("Channel #harpsteff was not listed as a home.");

    send("home add #harpsteff");
    expect("Home added.");

    send("home add #harpsteff");
    expect("We are already in that home channel.");

    send("home del #harpsteff");
    expect("Home removed.");

    send("home del #harpsteff");
    expect("Channel #harpsteff was not listed as a home.");

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
        expect("zorael isn't %s in %s.".format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add zorael");
        expect("Added zorael as %s in %s.".format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add zorael");
        expect("zorael was already %s in %s.".format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " del zorael");
        expect("Removed zorael as %s in %s.".format(asWhat, origEvent.channel)), thisFiber.payload.content);

        send(list ~ " add");
        expect("No nickname supplied.");

        immutable asWhatList =
            (list == "operator") ? "operators" :
            (list == "whitelist") ? "whitelisted users" :
            /*(list == "blacklist") ?*/ "blacklisted users";

        send(list ~ " list");
        expect("There are no %s in %s.".format(asWhatList, origEvent.channel));
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
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !automode

    /*send("automode list");
    expect("No automodes defined for channel %s.".format(origEvent.channel));*/

    send("automode del");
    expect("Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    send("automode");
    expect("Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    send("automode add $¡$¡ +o");
    expect("Invalid nickname.");

    send("automode add kameloso -v");
    expect("Can't add a negative automode.");

    send("automode add kameloso +");
    expect("You must supply a valid mode.");

    send("automode add kameloso +o");
    expect("Automode modified! kameloso on %s: +o".format(origEvent.channel));

    send("automode add kameloso +v");
    expect("Automode modified! kameloso on %s: +v".format(origEvent.channel));

    send("automode list");
    awaitReply();
    enforce(thisFiber.payload.content.contains(`"kameloso":"v"`));

    send("automode del $¡$¡");
    expect("Invalid nickname.");

    send("automode del kameloso");
    expect("Automode for kameloso cleared.");

    /*send("automode list");
    expect("No automodes defined for channel %s.".format(origEvent.channel));*/

    send("automode del flerrp");
    expect("Automode for flerrp cleared.");

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
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !say

    send("say zoraelblarbhl");
    expect("zoraelblarbhl");

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
    awaitReply();
    enforce(eightballAnswers[].canFind(thisFiber.payload.content));

    // ------------ !bash; don't test, it's complicated

    // ------------ DANCE

    await(plugin, IRCEvent.Type.EMOTE);

    send("get on up and DANCE");
    expect("dances :D-<");
    //Fiber.yield();
    expect("dances :D|-<");
    //Fiber.yield();
    expect("dances :D/-<");

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
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !note

    send("note %s test".format(botNickname));
    expect("You cannot leave the bot a message; it would never be replayed.");

    send("note %s test".format(plugin.state.client.nickname));
    expect("Note added.");

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
    }

    void sendNoPrefix(const string line)
    {
        chan(plugin.state, origEvent.channel, line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !oneliner

    send("commands");
    expect("There are no commands available right now.");

    send("oneliner");
    expect("Usage: %soneliner [add|del|list] [trigger] [text]"
        .format(plugin.state.settings.prefix));

    send("oneliner add herp derp dirp darp");
    expect("Oneliner %sherp added.".format(plugin.state.settings.prefix));

    send("oneliner list");
    expect("Available commands: %sherp".format(plugin.state.settings.prefix));

    sendNoPrefix("%sherp".format(plugin.state.settings.prefix));
    expect("derp dirp darp");

    send("oneliner del hirrp");
    expect("No such trigger: %shirrp".format(plugin.state.settings.prefix));

    send("oneliner del herp");
    expect("Oneliner %sherp removed.".format(plugin.state.settings.prefix));

    logger.info("Oneliners tests passed!");
}


// testQuotesFiber
/++
 +
 +/
void testQuotesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Quotes with empty channel in original event")
{
    import std.algorithm.searching : endsWith;

    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !quote

    send("quote");
    expect("Usage: %squote [nickname] [optional text to add a new quote]"
        .format(plugin.state.settings.prefix));

    send("quote $¡$¡");
    expect(`"$¡$¡" is not a valid account or nickname.`);

    send("quote flerrp");
    awaitReply();
    //expect("No quote on record for flerrp.");

    send("quote flerrp flirrp flarrp flurble");
    awaitReply();
    //expect("Quote for flerrp saved (1 on record)");

    send("quote flerrp");
    awaitReply();
    enforce(thisFiber.payload.content.endsWith("] flerrp | flirrp flarrp flurble"));

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
    }

    void sendNoPrefix(const string line)
    {
        chan(plugin.state, origEvent.channel, line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ s/abc/ABC/

    chan(plugin.state, origEvent.channel, "I am a fish");
    sendNoPrefix("s/fish/snek/");
    expect("%s | I am a snek".format(plugin.state.client.nickname));

    chan(plugin.state, origEvent.channel, "I am a fish fish");
    sendNoPrefix("s#fish#snek#");
    expect("%s | I am a snek fish".format(plugin.state.client.nickname));

    chan(plugin.state, origEvent.channel, "I am a fish fish");
    sendNoPrefix("s_fish_snek_g");
    expect("%s | I am a snek snek".format(plugin.state.client.nickname));

    logger.info("SedReplace tests passed!");
}


// testSeenFiber
/++
 +
 +/
void testSeenFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Seen with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !seen

    send("!seen");
    expect("Usage: !seen [nickname]");

    send("!seen ####");
    expect("Invalid user: ####");

    send("!seen HarblSnarbl");
    expect("I have never seen HarblSnarbl.");

    send("!seen " ~ plugin.state.client.nickname);
    expect("That's you!");

    send("!seen " ~ botNickname);
    expect("T-that's me though...");

    logger.info("Seen tests passed!");
}


// testCounterFiber
/++
 +
 +/
void testCounterFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Counter with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !counter

    send("counter");
    expect("No counters currently active in this channel.");

    send("counter list");
    expect("No counters currently active in this channel.");

    send("counter last");
    expect("Usage: !counter [add|del|list] [counter word]");

    send("counter add");
    expect("Usage: !counter [add|del|list] [counter word]");

    send("counter del blah");
    expect("No such counter enabled.");

    send("counter add blah");
    expect("Counter blah added! Access it with !blah.");

    send("counter add bluh");
    expect("Counter bluh added! Access it with !bluh.");

    send("counter add bluh");
    expect("A counter with that name already exists.");

    send("counter list");
    expect("Current counters: !blah, !bluh");

    // ------------ ![word]

    send("blah");
    expect("blah count so far: 0");

    send("blah+");
    expect("blah +1! Current count: 1");

    send("blah++");
    expect("blah +1! Current count: 2");

    send("blah+2");
    expect("blah +2! Current count: 4");

    send("blah+abc");
    expect("Not a number: abc");

    send("blah-");
    expect("blah -1! Current count: 3");

    send("blah--");
    expect("blah -1! Current count: 1");

    send("blah-2");
    expect("blah -2! Current count: -1");

    send("blah=10");
    expect("blah count assigned to 10!");

    send("blah");
    expect("blah count so far: 10");

    send("blah?");
    expect("blah count so far: 0");

    // ------------ !counter cleanup

    send("counter del blah");
    expect("Counter blah removed.");

    send("counter del blah");
    expect("No such counter enabled.");

    send("counter list");
    expect("Current counters: !bluh");

    send("counter del blah");
    expect("Counter bluh removed.");

    send("counter list");
    expect("No counters currently active in this channel.");

    logger.info("Counter tests passed!");
}


// testStopwatchFiber
/++
 +
 +/
void testStopwatchFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Stopwatch with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string line)
    {
        awaitReply();
        enforce(thisFiber.payload.content == line);
    }

    // ------------ !stopwatch

    send("stopwatch");
    expect("Usage: !stopwatch [start|stop|status]");

    send("stopwatch");
    expect("You do not have a stopwatch running.");

    send("stopwatch status");
    expect("You do not have a stopwatch running.");

    send("stopwatch status harbl");
    expect("There is no such stopwatch running. (harbl)");

    send("stopwatch start");
    expect("Stopwatch started!");

    send("stopwatch");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Elapsed time: "));

    send("stopwatch status");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Elapsed time: "));

    send("stopwatch start");
    expect("Stopwatch restarted!");

    send("stopwatch stop");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Stopwatch stopped after "));

    send("stopwatch start");
    expect("Stopwatch started!");

    send("stopwatch clear");
    expect("Clearing all stopwatches in channel " ~ origEvent.channel ~ '.');

    send("stopwatch");
    expect("You do not have a stopwatch running.");

    logger.info("Stopwatch tests passed!");
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

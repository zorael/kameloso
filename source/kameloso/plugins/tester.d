/++
 +
 +/
module kameloso.plugins.tester;

version(WithPlugins):
//version(WithTesterPlugin):

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
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


pragma(msg, "Compiling tester plugin");


version(DigitalMars)
{
    debug
    {
        // Everything seems okay
    }
    else
    {
        pragma(msg, "WARNING: The test suite may segfault on dmd with -release.");
        pragma(msg, "Use ldc for better results.");
    }
}


// onCommandTest
/++
 +
 +/
@(IRCEvent.Type.CHAN)
@(PermissionsRequired.admin)
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

    void awaitReply()
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

        Fiber.yield();
        while ((thisFiber.payload.channel != event.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
        assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    void disableColours()
    {
        chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=false");
    }

    void enableColours()
    {
        chan(plugin.state, event.channel, botNickname ~ ": set core.colouredOutgoing=true");
    }

    void runTestAndReport(alias fun)()
    {
        immutable success = fun(plugin, event, botNickname);

        if (success)
        {
            logger.info(__traits(identifier, fun), " tests PASSED");
        }
        else
        {
            logger.warning(__traits(identifier, fun), " tests FAILED");
        }

        immutable results = success ? "passed" : "FAILED";
        chan(plugin.state, event.channel, __traits(identifier, fun) ~ " tests: " ~ results);
    }

    void wrapTest(alias fun)()
    {
        await(plugin, IRCEvent.Type.CHAN);
        scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

        disableColours();
        scope(exit) enableColours();
        expect("Setting changed.");

        runTestAndReport!fun();
    }

    switch (pluginName)
    {
    case "admin":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testAdminFiber, 32_768);
        fiber.call();
        break;

    case "automodes":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testAutomodesFiber, 32_768);
        fiber.call();
        break;

    case "chatbot":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testChatbotFiber, 32_768);
        fiber.call();
        break;

    case "notes":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testNotesFiber, 32_768);
        fiber.call();
        break;

    case "oneliners":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testOnelinersFiber, 32_768);
        fiber.call();
        break;

    case "quotes":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testQuotesFiber, 32_768);
        fiber.call();
        break;

    case "sedreplace":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testSedReplaceFiber, 32_768);
        fiber.call();
        break;

    case "seen":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testSeenFiber, 32_768);
        fiber.call();
        break;

    case "counter":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testCounterFiber, 32_768);
        fiber.call();
        break;

    case "stopwatch":
        Fiber fiber = new CarryingFiber!IRCEvent(&wrapTest!testStopwatchFiber, 32_768);
        fiber.call();
        break;

    case "all":
        void allDg()
        {
            await(plugin, IRCEvent.Type.CHAN);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

            disableColours();
            scope(exit) enableColours();
            expect("Setting changed.");

            runTestAndReport!testAdminFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testAutomodesFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testChatbotFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testNotesFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testOnelinersFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testQuotesFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testSedReplaceFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testSeenFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testCounterFiber();
            delay(plugin, 3, No.msecs, Yes.yield);
            runTestAndReport!testStopwatchFiber();

            logger.info("All tests finished!");
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&allDg, 32_768*3);
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
bool testAdminFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Admin with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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
        expect("zorael isn't %s in %s.".format(asWhat, origEvent.channel));

        send(list ~ " add zorael");
        expect("Added zorael as %s in %s.".format(asWhat, origEvent.channel));

        send(list ~ " add zorael");
        expect("zorael was already %s in %s.".format(asWhat, origEvent.channel));

        send(list ~ " del zorael");
        expect("Removed zorael as %s in %s.".format(asWhat, origEvent.channel));

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
    expect("I am not in that channel.");

    // ------------ hostmasks

    send("hostmask");
    awaitReply();
    if (thisFiber.payload.content != "This bot is not currently configured " ~
        "to use hostmasks for authentication.")
    {
        send("hostmask add");
        expect("Usage: !hostmask [add|del|list] ([account] [hostmask]/[hostmask])");

        send("hostmask add kameloso HIRF#%%!SNIR@sdasdasd");
        expect("Invalid hostmask.");

        send("hostmask add kameloso kameloso^!*@*");
        expect("Hostmask list updated.");

        send("hostmask list");
        // `Current hostmasks: ["kameloso^!*@*":"kameloso"]`);
        awaitReply();
        enforce(thisFiber.payload.content.contains(`"kameloso^!*@*":"kameloso"`),
            thisFiber.payload.content, __FILE__, __LINE__);

        send("hostmask del kameloso^!*@*");
        expect("Hostmask list updated.");

        send("hostmask del kameloso^!*@*");
        expect("No such hostmask on file.");
    }

    return true;
}


// testAutomodesFiber
/++
 +
 +/
bool testAutomodesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Automodes with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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
    enforce(thisFiber.payload.content.contains(`"kameloso":"v"`),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("automode del $¡$¡");
    expect("Invalid nickname.");

    send("automode del kameloso");
    expect("Automode for kameloso cleared.");

    /*send("automode list");
    expect("No automodes defined for channel %s.".format(origEvent.channel));*/

    send("automode del flerrp");
    expect("Automode for flerrp cleared.");

    return true;
}


// testChatbotFiber
/++
 +
 +/
bool testChatbotFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Chatbot with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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
    enforce(eightballAnswers[].canFind(thisFiber.payload.content),
        thisFiber.payload.content, __FILE__, __LINE__);

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

    return true;
}


// testNotesFiber
/++
 +
 +/
bool testNotesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Notes with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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
        thisFiber.payload.content.endsWith("ago: test"),
        thisFiber.payload.content, __FILE__, __LINE__);

    return true;
}


// testOnelinersFiber
/++
 +
 +/
bool testOnelinersFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Oneliners with empty channel in original event")
{
    scope(failure) return false;

    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void sendPrefixed(const string line)
    {
        chan(plugin.state, origEvent.channel, plugin.state.settings.prefix ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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

    sendPrefixed("herp");
    expect("derp dirp darp");

    send("oneliner del hirrp");
    expect("No such trigger: %shirrp".format(plugin.state.settings.prefix));

    send("oneliner del herp");
    expect("Oneliner %sherp removed.".format(plugin.state.settings.prefix));

    return true;
}


// testQuotesFiber
/++
 +
 +/
bool testQuotesFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Quotes with empty channel in original event")
{
    import std.algorithm.searching : endsWith;

    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !quote

    send("quote");
    expect("Usage: %squote [nickname] [text to add a new quote]"
        .format(plugin.state.settings.prefix));

    send("quote $¡$¡");
    expect(`"$¡$¡" is not a valid account or nickname.`);

    send("quote flerrp");
    expect("No quote on record for flerrp.");

    send("quote flerrp flirrp flarrp flurble");
    expect("Quote flerrp #0 saved.");

    send("quote flerrp");
    awaitReply();
    enforce(thisFiber.payload.content.endsWith("] flerrp | flirrp flarrp flurble"),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("modquote flerrp 0 KAAS FLAAS");
    expect("Quote flerrp #0 modified.");

    send("modquote flerrp 0");
    awaitReply();
    enforce(thisFiber.payload.content.endsWith("] flerrp | KAAS FLAAS"),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("mergequotes flerrp flirrp");
    expect("1 quote merged from flerrp into flirrp.");

    send("quote flirrp");
    awaitReply();
    enforce(thisFiber.payload.content.endsWith("] flirrp | KAAS FLAAS"),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("delquote flirrp 0");
    expect("Quote flirrp #0 removed.");

    send("delquote flirrp 0");
    expect("No quotes on record for user flirrp.");

    return true;
}


// testSedReplaceFiber
/++
 +
 +/
bool testSedReplaceFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test SedReplace with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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

    return true;
}


// testSeenFiber
/++
 +
 +/
bool testSeenFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Seen with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
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

    return true;
}


// testCounterFiber
/++
 +
 +/
bool testCounterFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Counter with empty channel in original event")
{
    scope(failure) return false;

    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void sendPrefixed(const string line)
    {
        chan(plugin.state, origEvent.channel, plugin.state.settings.prefix ~ line);
    }

    void awaitReply()
    {
        Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname)) Fiber.yield();
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !counter

    send("counter");
    awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.beginsWith("Current counters: ")), thisFiber.payload.content);

    send("counter list");
    awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.beginsWith("Current counters: ")), thisFiber.payload.content);

    send("counter last");
    expect("Usage: !counter [add|del|list] [counter word]");

    send("counter add");
    expect("Usage: !counter [add|del|list] [counter word]");

    send("counter del blah");
    awaitReply();
    enforce(((thisFiber.payload.content == "No such counter available.") ||
        (thisFiber.payload.content == "Counter blah removed.")), thisFiber.payload.content);

    send("counter del bluh");
    awaitReply();
    enforce(((thisFiber.payload.content == "No such counter available.") ||
        (thisFiber.payload.content == "Counter bluh removed.")), thisFiber.payload.content);

    send("counter add blah");
    expect("Counter blah added! Access it with !blah.");

    send("counter add bluh");
    expect("Counter bluh added! Access it with !bluh.");

    send("counter add bluh");
    expect("A counter with that name already exists.");

    send("counter list");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Current counters: ") &&
        (thisFiber.payload.content.contains("!blah") &&
        thisFiber.payload.content.contains("!bluh")), thisFiber.payload.content);

    // ------------ ![word]

    send("set counter.wordAloneIncrements=false");
    expect("Setting changed.");

    sendPrefixed("blah");
    expect("blah count so far: 0");

    sendPrefixed("blah+");
    expect("blah +1! Current count: 1");

    sendPrefixed("blah++");
    expect("blah +1! Current count: 2");

    sendPrefixed("blah+2");
    expect("blah +2! Current count: 4");

    sendPrefixed("blah+abc");
    expect("Not a number: abc");

    sendPrefixed("blah-");
    expect("blah -1! Current count: 3");

    sendPrefixed("blah--");
    expect("blah -1! Current count: 2");

    sendPrefixed("blah-2");
    expect("blah -2! Current count: 0");

    sendPrefixed("blah=10");
    expect("blah count assigned to 10!");

    sendPrefixed("blah");
    expect("blah count so far: 10");

    sendPrefixed("blah?");
    expect("blah count so far: 10");

    // ------------ !counter cleanup

    send("counter del blah");
    expect("Counter blah removed.");

    send("counter del blah");
    expect("No such counter available."); //available.");

    send("counter list");
    expect("Current counters: !bluh");

    send("counter del bluh");
    expect("Counter bluh removed.");

    send("counter list");
    awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.beginsWith("Current counters: ")), thisFiber.payload.content);

    return true;
}


// testStopwatchFiber
/++
 +
 +/
bool testStopwatchFiber(TesterPlugin plugin, const IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Stopwatch with empty channel in original event")
{
    scope(failure) return false;

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

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !stopwatch

    send("stopwatch harbl");
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
    enforce(thisFiber.payload.content.beginsWith("Elapsed time: "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch status");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Elapsed time: "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch start");
    expect("Stopwatch restarted!");

    send("stopwatch stop");
    awaitReply();
    enforce(thisFiber.payload.content.beginsWith("Stopwatch stopped after "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch start");
    expect("Stopwatch started!");

    send("stopwatch clear");
    expect("Clearing all stopwatches in channel " ~ origEvent.channel ~ '.');

    send("stopwatch");
    expect("You do not have a stopwatch running.");

    return true;
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

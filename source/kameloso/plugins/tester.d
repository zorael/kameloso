/++
 +
 +/
module kameloso.plugins.tester;

private:

import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.plugins.common.delayawait;
import kameloso.common : logger;
import kameloso.irccolours : stripEffects;
import kameloso.messaging;
import kameloso.thread : CarryingFiber;
import dialect.defs;
import lu.string : beginsWith, contains;
import std.algorithm.searching : endsWith;
import std.exception : enforce;
import std.format : format;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;
import core.time;

pragma(msg, "Compiling tester plugin");

mixin MinimalAuthentication;
mixin ModuleRegistration;


version(DigitalMars)
{
    debug
    {
        // Everything seems okay
    }
    else
    {
        pragma(msg, "Note: The test suite may/will segfault on dmd with -release " ~
            "if we're using `const ref` parameters with Fibers. Investigate if it happens.");
    }
}


// onCommandTest
/++
 +
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.admin)
    .addCommand(
        IRCEventHandler.Command()
            .word("test")
            .policy(PrefixPolicy.nickname)
            .description("Runs tests.")
            .addSyntax("$command [target bot nickname] [plugin, or \"all\"]")
    )
)
void onCommandTest(TesterPlugin plugin, const /*ref*/ IRCEvent event)
{
    import kameloso.constants : BufferSize;
    import lu.string : SplitResults, splitInto;
    import std.meta : AliasSeq;
    import core.thread : Fiber;

    logger.info("tester invoked.");

    string slice = event.content;  // mutable
    string pluginName;
    string botNickname;

    immutable results = slice.splitInto(botNickname, pluginName);

    if (results != SplitResults.match)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [target bot nickname] [plugin]"
            .format(plugin.state.settings.prefix, event.aux));
        return;
    }

    void send(const string line)
    {
        chan(plugin.state, event.channel, botNickname ~ ": " ~ line);
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
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    void sync()
    {
        import std.conv : text;
        import std.random : uniform;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);

        immutable id = uniform(0, 1000);

        send(text("say ", id));
        do awaitReply(); while (thisFiber.payload.content != id.text);
    }

    bool runTestAndReport(alias fun)()
    {
        bool success;

        try
        {
            sync();
            fun(plugin, event, botNickname);
            logger.info(__traits(identifier, fun), " tests PASSED");
            success = true;
        }
        catch (Exception e)
        {
            import std.stdio;
            logger.warning(__traits(identifier, fun), " tests FAILED");
            writeln(e);
            //success = false;
        }

        immutable results = success ? "passed" : "FAILED";
        chan(plugin.state, event.channel, "--------------------------------[ " ~
            __traits(identifier, fun) ~ " tests: " ~ results);
        return success;
    }

    alias tests = AliasSeq!(
        testAdminFiber,
        testAutomodeFiber,
        testChatbotFiber,
        testNotesFiber,
        testOnelinersFiber,
        testQuotesFiber,
        testSedReplaceFiber,
        testSeenFiber,
        testCounterFiber,
        testStopwatchFiber,
        testTimerFiber,
        testTimeFiber,
        testBashFiber,
        testPollFiber,
    );

    top:
    switch (pluginName)
    {
    foreach (test; tests)
    {
        import std.uni : toLower;
        enum caseName = __traits(identifier, test)[4..$-5].toLower;

        case caseName:
            void caseDg()
            {
                await(plugin, IRCEvent.Type.CHAN, No.yield);
                scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

                runTestAndReport!test();
            }

            Fiber fiber = new CarryingFiber!IRCEvent(&caseDg, BufferSize.fiberStack);
            fiber.call();
            break top;
    }

    case "all":
        void allDg()
        {
            await(plugin, IRCEvent.Type.CHAN, No.yield);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

            //awaitReply();  // advance past current message ("test [nickname] [plugin]")

            static immutable timeInBetween = 10.seconds;
            uint successes;

            foreach (immutable i, test; tests)
            {
                immutable success = runTestAndReport!test();
                if (success) ++successes;

                if (i+1 != tests.length)
                {
                    delay(plugin, timeInBetween, Yes.yield);

                    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
                    while (thisFiber.payload.content.length)
                    {
                        delay(plugin, 1.seconds, Yes.yield);
                    }
                }
            }

            enum pattern = "%d/%d tests finished successfully.";
            immutable message = pattern.format(successes, tests.length);
            logger.info(message);
            send(message);
        }

        Fiber fiber = new CarryingFiber!IRCEvent(&allDg, BufferSize.fiberStack);
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
void testAdminFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
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

    foreach (immutable list; only("staff"))//, "operator", "whitelist", "blacklist"))
    {
        immutable definiteFormSingular =
            (list == "staff") ? "staff" :
            (list == "operator") ? "an operator" :
            (list == "whitelist") ? "a whitelisted user" :
            /*(list == "blacklist") ?*/ "a blacklisted user";

        immutable plural =
            (list == "staff") ? "staff" :
            (list == "operator") ? "operators" :
            (list == "whitelist") ? "whitelisted users" :
            /*(list == "blacklist") ?*/ "blacklisted users";

        //"No such account xorael to remove as %s in %s."
        send(list ~ " del xorael");
        expect("xorael isn't %s in %s.".format(definiteFormSingular, origEvent.channel));

        send(list ~ " add xorael");
        expect("Added xorael as %s in %s.".format(definiteFormSingular, origEvent.channel));

        send(list ~ " add xorael");
        expect("xorael was already %s in %s.".format(definiteFormSingular, origEvent.channel));

        send(list ~ " list");
        expect("Current %s in %s: xorael".format(plural, origEvent.channel));

        send(list ~ " del xorael");
        expect("Removed xorael as %s in %s.".format(definiteFormSingular, origEvent.channel));

        send(list ~ " list");
        expect("There are no %s in %s.".format(plural, origEvent.channel));

        send(list ~ " add");
        expect("No nickname supplied.");
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

    send("reload");
    expect("Reloading plugins.");

    send("reload admin");
    expect("Reloading plugin \"admin\".");

    send("join #skabalooba");
    send("part #skabalooba");

    send("get admin.enabled");
    expect("admin.enabled=true");

    send("get core.prefix");
    expect("core.prefix=\"%s\"".format(plugin.state.settings.prefix));
}


// testAutomodeFiber
/++
 +
 +/
void testAutomodeFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Automode with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
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
    expect("Automodes cannot be negative.");

    send("automode add kameloso +");
    expect("You must supply a valid mode.");

    send("automode add kameloso +o");
    expect("Automode modified! kameloso in %s: +o".format(origEvent.channel));

    send("automode add kameloso +v");
    expect("Automode modified! kameloso in %s: +v".format(origEvent.channel));

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
}


// testChatbotFiber
/++
 +
 +/
void testChatbotFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Chatbot with empty channel in original event")
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !say

    send("say xoraelblarbhl");
    expect("xoraelblarbhl");

    // ------------ !8ball

    /*import std.algorithm.searching : canFind;

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
        thisFiber.payload.content, __FILE__, __LINE__);*/

    // ------------ DANCE

    await(plugin, IRCEvent.Type.EMOTE, No.yield);

    sendNoPrefix("get on up and DANCE");
    expect("dances :D-<");
    expect("dances :D|-<");
    expect("dances :D/-<");

    unawait(plugin, IRCEvent.Type.EMOTE);
}


// testNotesFiber
/++
 +
 +/
void testNotesFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        immutable stripped = thisFiber.payload.content.stripEffects();
        enforce((stripped == msg), "'%s' != '%s'".format(stripped, msg), file, line);
    }

    void cycle()
    {
        unawait(plugin, IRCEvent.Type.CHAN);
        part(plugin.state, origEvent.channel);
        await(plugin, IRCEvent.Type.SELFPART, Yes.yield);
        while (thisFiber.payload.channel != origEvent.channel) Fiber.yield();
        unawait(plugin, IRCEvent.Type.SELFPART);

        join(plugin.state, origEvent.channel);
        await(plugin, IRCEvent.Type.SELFJOIN, Yes.yield);
        while (thisFiber.payload.channel != origEvent.channel) Fiber.yield();
        unawait(plugin, IRCEvent.Type.SELFJOIN);
        await(plugin, IRCEvent.Type.CHAN, No.yield);
    }

    // ------------ !note

    send("note %s test".format(botNickname));
    expect("You cannot leave me a message; it would never be replayed.");

    send("note %s test".format(plugin.state.client.nickname));
    expect("Note saved.");

    cycle();

    awaitReply();
    immutable stripped = thisFiber.payload.content.stripEffects();
    enforce(stripped.beginsWith("%s! %1$s left note"
        .format(plugin.state.client.nickname)) &&
        stripped.endsWith("ago: test"),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("set notes.playBackOnAnyActivity=false");
    expect("Setting changed.");

    send("note %s abc def ghi".format(plugin.state.client.nickname));
    expect("Note saved.");

    send("note %s 123 456 789".format(plugin.state.client.nickname));
    expect("Note saved.");

    cycle();
    expect("%s! You have 2 notes.".format(plugin.state.client.nickname));

    awaitReply();
    immutable stripped2 = thisFiber.payload.content.stripEffects();
    enforce(stripped2.endsWith("ago: abc def ghi"),
        thisFiber.payload.content, __FILE__, __LINE__);

    awaitReply();
    immutable stripped3 = thisFiber.payload.content.stripEffects();
    enforce(stripped3.endsWith("ago: 123 456 789"),
        thisFiber.payload.content, __FILE__, __LINE__);
}


// testOnelinersFiber
/++
 +
 +/
void testOnelinersFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Oneliners with empty channel in original event")
{
    immutable prefix = plugin.state.settings.prefix;

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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !oneliner

    send("commands");
    expect("There are no commands available right now.");

    send("oneliner");
    expect("Usage: %soneliner [new|insert|add|edit|del|list] ...".format(prefix));

    send("oneliner add herp derp dirp darp");
    expect("No such oneliner: %sherp".format(prefix));

    send("oneliner new");
    expect("Usage: %soneliner new [trigger] [type] [optional cooldown]".format(prefix));

    send("oneliner new herp ordered");
    expect("Oneliner %sherp created! Use %1$soneliner add to add lines.".format(prefix));

    sendPrefixed("herp");
    expect("(Empty oneliner; use %soneliner add herp to add lines.)".format(prefix));

    send("oneliner add herp 123");
    expect("Oneliner line added.");

    send("oneliner add herp 456");
    expect("Oneliner line added.");

    sendPrefixed("herp");
    expect("123");

    sendPrefixed("herp");
    expect("456");

    sendPrefixed("herp");
    expect("123");

    send("oneliner insert herp 0 000");
    expect("Oneliner line inserted.");

    sendPrefixed("herp");
    expect("000");

    sendPrefixed("herp");
    expect("123");

    send("oneliner list");
    expect("Available commands: %sherp".format(prefix));

    send("oneliner del hurp");
    expect("No such oneliner: %shurp".format(prefix));

    send("oneliner del herp");
    expect("Oneliner %sherp removed.".format(prefix));

    send("oneliner list");
    expect("There are no commands available right now.");

    send("oneliner new herp random 10");
    expect("Oneliner %sherp created! Use %1$soneliner add to add lines.".format(prefix));

    sendPrefixed("herp");
    expect("(Empty oneliner; use %soneliner add herp to add lines.)".format(prefix));

    send("oneliner add herp abc");
    expect("Oneliner line added.");

    sendPrefixed("herp");
    expect("abc");

    sendPrefixed("herp");

    logger.info("wait 10 seconds...");
    delay(plugin, 10.seconds, Yes.yield);
    enforce(!thisFiber.payload.content.length);

    sendPrefixed("herp");
    expect("abc");

    send("oneliner del herp");
    expect("Oneliner %sherp removed.".format(prefix));

    send("commands");
    expect("There are no commands available right now.");
}


// testQuotesFiber
/++
 +
 +/
void testQuotesFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Quotes with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !quote

    send("quote");
    expect("Usage: %squote [nickname] [optional search terms or #index]"
        .format(plugin.state.settings.prefix));

    send("quote $¡$¡");
    expect("Invalid nickname: $¡$¡");

    send("quote flerrp");
    expect("No quotes on record for flerrp!");

    send("addquote");
    expect("Usage: %saddquote [nickname] [new quote]"
        .format(plugin.state.settings.prefix));

    send("addquote flerrp flirrp flarrp flurble");
    expect("Quote added at index #0.");

    send("addquote flerrp flirrp flarrp FLARBLE");
    expect("Quote added at index #1.");

    send("quote flerrp");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("flirrp flarrp"),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("quote flerrp #1");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("flirrp flarrp FLARBLE ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("quote flerrp #99");
    expect("Index #99 out of range; valid is [0..1] (inclusive).");

    send("quote flerrp #honk");
    expect("Index must be a positive number.");

    send("quote flerrp flarble");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("flirrp flarrp FLARBLE ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("quote flerrp honkedonk");
    expect("No quotes found for search terms \"honkedonk\"");

    send("modquote");
    expect("Usage: %smodquote [nickname] [index] [new quote text]"
        .format(plugin.state.settings.prefix));

    send("modquote flerrp #0 KAAS FLAAS");
    expect("Quote modified.");

    send("quote flerrp #0");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("KAAS FLAAS ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("mergequotes flerrp flirrp");
    expect("2 quotes merged.");

    send("quote flirrp #0");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("KAAS FLAAS ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("quote flerrp");
    expect("No quotes on record for flerrp!");

    send("delquote flirrp #0");
    expect("Quote removed, indexes updated.");

    send("delquote flirrp #0");
    expect("Quote removed, indexes updated.");

    send("delquote flirrp #0");
    expect("No quotes on record for flirrp!");
}


// testSedReplaceFiber
/++
 +
 +/
void testSedReplaceFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ s/abc/ABC/

    sendNoPrefix("I am a fish");
    sendNoPrefix("s/fish/snek/");
    expect("%s | I am a snek".format(plugin.state.client.nickname));

    sendNoPrefix("I am a fish fish");
    sendNoPrefix("s#fish#snek#");
    expect("%s | I am a snek fish".format(plugin.state.client.nickname));

    sendNoPrefix("I am a fish fish");
    sendNoPrefix("s_fish_snek_g");
    expect("%s | I am a snek snek".format(plugin.state.client.nickname));

    sendNoPrefix("s/harbusnarbu");
    sendNoPrefix("s#snarbu#snofl/#");
    // Should be no response
    delay(plugin, 3.seconds, Yes.yield);
    enforce(!thisFiber.payload.content.length);
}


// testSeenFiber
/++
 +
 +/
void testSeenFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
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
}


// testCounterFiber
/++
 +
 +/
void testCounterFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Counter with empty channel in original event")
{
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !counter

    send("counter");
    expect("Usage: !counter [add|del|format|list] [counter word]");

    send("counter list");
    awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.beginsWith("Current counters: ")), thisFiber.payload.content);

    send("counter last");
    expect("Usage: !counter [add|del|format|list] [counter word]");

    send("counter add");
    expect("Usage: !counter [add|del|format|list] [counter word]");

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
    immutable stripped = thisFiber.payload.content.stripEffects();
    enforce(stripped.beginsWith("Current counters: ") &&
        (stripped.contains("!blah") &&
        stripped.contains("!bluh")), thisFiber.payload.content);

    // ------------ ![word]

    sendPrefixed("blah");
    expect("blah count so far: 0");

    sendPrefixed("blah+");
    expect("blah +1! Current count: 1");

    sendPrefixed("blah++");
    expect("blah +1! Current count: 2");

    sendPrefixed("blah+2");
    expect("blah +2! Current count: 4");

    sendPrefixed("blah+abc");
    expect("abc is not a number.");

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

    send("counter format blah ? ABC $count DEF");
    expect("Format pattern updated.");

    send("counter format blah + count +$step = $count");
    expect("Format pattern updated.");

    send("counter format blah - count -$step = $count");
    expect("Format pattern updated.");

    send("counter format blah = count := $count");
    expect("Format pattern updated.");

    sendPrefixed("blah");
    expect("ABC 10 DEF");

    sendPrefixed("blah+");
    expect("count +1 = 11");

    sendPrefixed("blah-2");
    expect("count -2 = 9");

    sendPrefixed("blah=42");
    expect("count := 42");

    send("counter format blah ? -");
    expect("Format pattern cleared.");

    sendPrefixed("blah");
    expect("blah count so far: 42");

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
}


// testStopwatchFiber
/++
 +
 +/
void testStopwatchFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
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
    enforce(thisFiber.payload.content.stripEffects().beginsWith("Elapsed time: "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch status");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("Elapsed time: "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch start");
    expect("Stopwatch restarted!");

    send("stopwatch stop");
    awaitReply();
    enforce(thisFiber.payload.content.stripEffects().beginsWith("Stopwatch stopped after "),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("stopwatch start");
    expect("Stopwatch started!");

    send("stopwatch clear");
    expect("Clearing all stopwatches in channel " ~ origEvent.channel ~ '.');

    send("stopwatch");
    expect("You do not have a stopwatch running.");
}


// testTimerFiber
/++
 +
 +/
void testTimerFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Timer with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !timer

    send("timer");
    expect("Usage: %stimer [new|add|del|suspend|resume|list] ..."
        .format(plugin.state.settings.prefix));

    send("timer new");
    expect(("Usage: %stimer new [name] [type] [condition] [message count threshold] " ~
        "[time threshold] [stagger message count] [stagger time]")
            .format(plugin.state.settings.prefix));

    send("timer new hirrsteff ordered both 0 10s 0 10s");
    expect("New timer added! Use !timer add to add lines.");

    send("timer suspend hirrsteff");
    expect("Timer suspended. Use %stimer resume hirrsteff to resume it."
        .format(plugin.state.settings.prefix));

    send("timer add splorf hello");
    expect("No such timer is defined. Add a new one with !timer new.");

    send("timer add hirrsteff HERLO");
    expect("Line added to timer hirrsteff.");

    send("timer insert hirrsteff 0 fgsfds");
    expect("Line added to timer hirrsteff.");

    send("timer edit hirrsteff 1 HARLO");
    expect("Line #1 of timer hirrsteff edited.");

    send("timer list");
    expect("Current timers for channel %s:".format(origEvent.channel));
    expect(`["hirrsteff"] lines:2 | type:ordered | condition:both | ` ~
        "message count threshold:0 | time threshold:10 | stagger message count:0 | stagger time:10 | suspended:true");

    logger.info("Wait ~1 cycle, nothing should happen...");
    delay(plugin, 15.seconds, Yes.yield);
    enforce(!thisFiber.payload.content.length,
        "'%s' != '%s'".format(thisFiber.payload.content, string.init), __FILE__, __LINE__           );

    send("timer resume hirrsteff");
    expect("Timer resumed!");

    logger.info("Wait 3 cycles + 10 seconds...");

    expect("fgsfds");
    logger.info("ok");

    expect("HARLO");
    logger.info("ok");

    expect("fgsfds");
    logger.info("all ok");

    send("timer del hirrsteff 0");
    expect("Line removed from timer hirrsteff. Lines remaining: 1");

    expect("HARLO");
    logger.info("all ok again");

    send("timer del hirrsteff");
    expect("Timer removed.");

    send("timer del hirrsteff");
    expect("There is no timer by that name.");
}


// testTimeFiber
/++
 +
 +/
void testTimeFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Time with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }



    // ------------ !time

    string response;  // mutable

    send("time");
    awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.beginsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" locally."),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("time CET");
    awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.beginsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in CET."),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("time Europe/Stockholm");
    awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.beginsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in Europe/Stockholm."),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("time Dubai");
    awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.beginsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in Dubai."),
        thisFiber.payload.content, __FILE__, __LINE__);

    send("time honk");
    expect("Invalid timezone: honk");
}


// testPollFiber
/++
 +
 +/
void testPollFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Poll with empty channel in original event")
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
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !poll

    send("poll");
    expect("Usage: %spoll [duration] [choice1] [choice2] ...".format(plugin.state.settings.prefix));

    send("poll arf");
    expect("Need one duration and at least two choices.");

    send("poll arf urf hirf");
    expect("Malformed duration.");

    send("poll 5s snik snek");
    expect("Voting commenced! Please place your vote for one of: snek, snik (5 seconds)");
    expect("Voting complete, no one voted.");

    send("poll 7 snik snek");
    expect("Voting commenced! Please place your vote for one of: snek, snik (7 seconds)");
    sendNoPrefix("snek");
    expect("Voting complete! Here are the results:");
    expect("snik : 0 votes");
    expect("snek : 1 vote (100.0%)");

    send("poll 1h2m3s snik snek");
    expect("Voting commenced! Please place your vote for one of: snek, snik (1 hour, 2 minutes and 3 seconds)");

    send("poll end");
    expect("Voting complete, no one voted.");

    send("poll 1d23h59m59s snik snek");
    expect("Voting commenced! Please place your vote for one of: snek, snik (1 day, 23 hours, 59 minutes and 59 seconds)");

    send("poll abort");
    expect("Poll aborted.");

    send("poll abort");
    expect("There is no ongoing poll.");

    send("poll end");
    expect("There is no ongoing poll.");
}


// testBashFiber
/++
 +
 +/
void testBashFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Bash with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    void send(const string line)
    {
        chan(plugin.state, origEvent.channel, botNickname ~ ": " ~ line);
    }

    void awaitReply()
    {
        do Fiber.yield();
        while ((thisFiber.payload.channel != origEvent.channel) ||
            (thisFiber.payload.sender.nickname != botNickname));
    }

    void expect(const string msg, const string file = __FILE__, const size_t line = __LINE__)
    {
        awaitReply();
        enforce((thisFiber.payload.content.stripEffects() == msg),
            "'%s' != '%s'".format(thisFiber.payload.content, msg), file, line);
    }

    // ------------ !bash

    send("bash 5273");
    awaitReply();
    immutable banner = thisFiber.payload.content.stripEffects();

    if (banner == "[bash.org] #5273")
    {
        // Ok
        expect("erno> hm. I've lost a machine.. literally _lost_. it responds to ping, " ~
            "it works completely, I just can't figure out where in my apartment it is.");
    }
    else if (banner == "No reponse received from bash.org; is it down?")
    {
        // Also ok, it's down
        // Just return without attempting honk fetch
        return;
    }
    else
    {
        throw new Exception(banner);
    }

    send("bash honk");
    awaitReply();
    immutable honk = thisFiber.payload.content.stripEffects();

    if (honk == "No such bash.org quote found.")
    {
        // Ok
    }
    else if (honk == "No reponse received from bash.org; is it down?")
    {
        // Also ok, it's down
    }
    else
    {
        throw new Exception(honk);
    }
}


public:


/++
 +
 +/
final class TesterPlugin : IRCPlugin
{
private:
    mixin IRCPluginImpl;
}

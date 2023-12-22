/++
 +
 +/
module kameloso.plugins.tester;

private:

import kameloso.plugins;
import kameloso.plugins.common.core;
import kameloso.plugins.common.awareness : MinimalAuthentication;
import kameloso.plugins.common.delayawait;
import kameloso.common : logger;
import kameloso.irccolours : stripEffects;
import kameloso.messaging;
import kameloso.thread : CarryingFiber;
import dialect.defs;
import std.algorithm.searching : endsWith, startsWith;
import std.exception : enforce;
import std.format : format;
import std.string : indexOf;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;
import core.time;

pragma(msg, "Compiling tester plugin");

mixin MinimalAuthentication;
mixin PluginRegistration!TesterPlugin;


version(DigitalMars)
{
    debug
    {
        // Everything seems okay
    }
    else
    {
        pragma(msg, "Note: The test suite may/will segfault on dmd with -release " ~
            "because of memory corruption. Not much we can do. Use ldc for better results.");
    }
}


struct Sender
{
    IRCPlugin plugin;

    string botNickname;

    string channelName;

    CarryingFiber!IRCEvent fiber;

    static immutable delayBetween = 3.seconds;

    this(
        IRCPlugin plugin,
        CarryingFiber!IRCEvent fiber,
        const string channelName,
        const string botNickname)
    {
        this.plugin = plugin;
        this.fiber = fiber;
        this.channelName = channelName;
        this.botNickname = botNickname;
    }

    void send(const string line)
    in (plugin)
    {
        delay(plugin, delayBetween, Yes.yield);
        chan(plugin.state, channelName, botNickname ~ ": " ~ line);
    }

    void sendPrefixed(const string line)
    in (plugin)
    {
        delay(plugin, delayBetween, Yes.yield);
        chan(plugin.state, channelName, plugin.state.settings.prefix ~ line);
    }

    void sendNoPrefix(const string line)
    in (plugin)
    {
        delay(plugin, delayBetween, Yes.yield);
        chan(plugin.state, channelName, line);
    }

    void awaitReply()
    in (plugin)
    {
        do Fiber.yield();
        while ((fiber.payload.channel != channelName) ||
            (fiber.payload.sender.nickname != botNickname));
    }

    void expect(
        const string expected,
        const string file = __FILE__,
        const size_t line = __LINE__)
    in (plugin)
    {
        awaitReply();

        immutable actual = fiber.payload.content.stripEffects();
        if (actual != expected)
        {
            enum pattern = "'%s' != '%s' (%s:%d)";
            immutable message = pattern.format(actual, expected, file, line);
            throw new Exception(message);
        }
    }
}


// onCommandTest
/++
 +
 +/
@(IRCEventHandler()
    .onEvent(IRCEvent.Type.CHAN)
    .permissionsRequired(Permissions.admin)
    .fiber(true)
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

    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');

    string slice = event.content;  // mutable
    string pluginName;
    string botNickname;

    immutable results = slice.splitInto(botNickname, pluginName);

    if (results != SplitResults.match)
    {
        privmsg(plugin.state, event.channel, event.sender.nickname,
            "Usage: %s%s [target bot nickname] [plugin]"
            .format(plugin.state.settings.prefix, event.aux[$-1]));
        return;
    }

    auto s = Sender(plugin, thisFiber, event.channel, botNickname);

    void sync()
    {
        import std.conv : text;
        import std.random : uniform;

        auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);

        immutable id = uniform(0, 1000);

        s.send(text("say ", id));
        do s.awaitReply(); while (thisFiber.payload.content != id.text);
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
        //testBashFiber,
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

            /*Fiber fiber = new CarryingFiber!IRCEvent(&caseDg, BufferSize.fiberStack);
            fiber.call();*/
            caseDg();
            break top;
    }

    case "all":
        void allDg()
        {
            await(plugin, IRCEvent.Type.CHAN, No.yield);
            scope(exit) unawait(plugin, IRCEvent.Type.CHAN);

            //awaitReply();  // advance past current message ("test [nickname] [plugin]")

            static immutable timeInBetween = 10.seconds;
            string[] failedTestNames;
            uint successes;

            foreach (immutable i, test; tests)
            {
                immutable success = runTestAndReport!test();
                if (success) ++successes;
                else
                {
                    failedTestNames ~= __traits(identifier, tests[i]);
                }

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


            enum pattern = "%d/%d tests finished successfully. failed: %-(%s, %)";
            immutable message = pattern.format(successes, tests.length, failedTestNames);
            logger.info(message);
            s.send(message);
        }

        /*Fiber fiber = new CarryingFiber!IRCEvent(&allDg, BufferSize.fiberStack);
        fiber.call();*/
        allDg();
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !home

    s.send("home del #harpsteff");
    s.expect("Channel #harpsteff was not listed as a home channel.");

    s.send("home add #harpsteff");
    s.expect("Home channel added.");

    s.send("home add #harpsteff");
    s.expect("We are already in that home channel.");

    s.send("home del #harpsteff");
    s.expect("Home channel removed.");

    s.send("home del #harpsteff");
    s.expect("Channel #harpsteff was not listed as a home channel.");

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
        s.send(list ~ " del xorael");
        s.expect("xorael isn't %s in %s.".format(definiteFormSingular, origEvent.channel));

        s.send(list ~ " add xorael");
        s.expect("Added xorael as %s in %s.".format(definiteFormSingular, origEvent.channel));

        s.send(list ~ " add xorael");
        s.expect("xorael was already %s in %s.".format(definiteFormSingular, origEvent.channel));

        s.send(list ~ " list");
        s.expect("Current %s in %s: xorael".format(plural, origEvent.channel));

        s.send(list ~ " del xorael");
        s.expect("Removed xorael as %s in %s.".format(definiteFormSingular, origEvent.channel));

        s.send(list ~ " list");
        s.expect("There are no %s in %s.".format(plural, origEvent.channel));

        s.send(list ~ " add");
        s.expect("No nickname supplied.");
    }

    // ------------ misc

    s.send("cycle #flirrp");
    s.expect("I am not in that channel.");

    // ------------ hostmasks

    s.send("hostmask");
    s.awaitReply();
    if (thisFiber.payload.content != "This bot is not currently configured " ~
        "to use hostmasks for authentication.")
    {
        s.send("hostmask add");
        s.expect("Usage: !hostmask [add|del|list] ([account] [hostmask]/[hostmask])");

        s.send("hostmask add kameloso HIRF#%%!SNIR@sdasdasd");
        s.expect("Invalid hostmask.");

        s.send("hostmask add kameloso kameloso^!*@*");
        s.expect("Hostmask list updated.");

        s.send("hostmask list");
        // `Current hostmasks: ["kameloso^!*@*":"kameloso"]`);
        s.awaitReply();
        enforce((thisFiber.payload.content.indexOf(`"kameloso^!*@*":"kameloso"`) != -1),
            thisFiber.payload.content, __FILE__, __LINE__);

        s.send("hostmask del kameloso^!*@*");
        s.expect("Hostmask list updated.");

        s.send("hostmask del kameloso^!*@*");
        s.expect("No such hostmask on file.");
    }

    s.send("reload");
    s.expect("Reloading plugins.");

    s.send("reload admin");
    s.expect("Reloading plugin \"admin\".");

    s.send("join #skabalooba");
    s.send("part #skabalooba");

    s.send("get admin.enabled");
    s.expect("admin.enabled=true");

    s.send("get core.prefix");
    s.expect("core.prefix=\"%s\"".format(plugin.state.settings.prefix));
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !automode

    /*send("automode list");
    s.expect("No automodes defined for channel %s.".format(origEvent.channel));*/

    s.send("automode del");
    s.expect("Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    s.send("automode");
    s.expect("Usage: %sautomode [add|clear|list] [nickname/account] [mode]"
        .format(plugin.state.settings.prefix));

    s.send("automode add $¡$¡ +o");
    s.expect("Invalid nickname.");

    s.send("automode add kameloso -v");
    s.expect("Automodes cannot be negative.");

    s.send("automode add kameloso +");
    s.expect("You must supply a valid mode.");

    s.send("automode add kameloso +o");
    s.expect("Automode modified! kameloso in %s: +o".format(origEvent.channel));

    s.send("automode add kameloso +v");
    s.expect("Automode modified! kameloso in %s: +v".format(origEvent.channel));

    s.send("automode list");
    s.awaitReply();
    enforce((thisFiber.payload.content.indexOf(`"kameloso":"v"`) != -1),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("automode del $¡$¡");
    s.expect("Automode for $¡$¡ cleared.");

    s.send("automode del kameloso");
    s.expect("Automode for kameloso cleared.");

    /*send("automode list");
    s.expect("No automodes defined for channel %s.".format(origEvent.channel));*/

    s.send("automode del flerrp");
    s.expect("Automode for flerrp cleared.");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !say

    s.send("say xoraelblarbhl");
    s.expect("xoraelblarbhl");

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

    s.send("8ball");
    s.awaitReply();
    enforce(eightballAnswers[].canFind(thisFiber.payload.content),
        thisFiber.payload.content, __FILE__, __LINE__);*/

    // ------------ DANCE

    await(plugin, IRCEvent.Type.EMOTE, No.yield);

    s.sendNoPrefix("get on up and DANCE");
    s.expect("dances :D-<");
    s.expect("dances :D|-<");
    s.expect("dances :D/-<");

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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

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

    s.send("note %s test".format(botNickname));
    s.expect("You cannot leave me a message; it would never be replayed.");

    s.send("note %s test".format(plugin.state.client.nickname));
    s.expect("Note saved.");

    cycle();

    s.awaitReply();
    immutable stripped = thisFiber.payload.content.stripEffects();
    enforce(stripped.startsWith("%s! %1$s left note"
        .format(plugin.state.client.nickname)) &&
        stripped.endsWith("ago: test"),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("set note.playBackOnAnyActivity=false");
    s.expect("Setting changed.");

    s.send("note %s abc def ghi".format(plugin.state.client.nickname));
    s.expect("Note saved.");

    s.send("note %s 123 456 789".format(plugin.state.client.nickname));
    s.expect("Note saved.");

    cycle();
    s.expect("%s! You have 2 notes.".format(plugin.state.client.nickname));

    s.awaitReply();
    immutable stripped2 = thisFiber.payload.content.stripEffects();
    enforce(stripped2.endsWith("ago: abc def ghi"),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.awaitReply();
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
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    immutable prefix = plugin.state.settings.prefix;

    // ------------ !oneliner

    s.send("commands");
    s.expect("There are no commands available right now.");

    s.send("oneliner");
    s.expect("Usage: %soneliner [new|insert|add|edit|del|list] ...".format(prefix));

    s.send("oneliner add herp derp dirp darp");
    s.expect("No such oneliner: %sherp".format(prefix));

    s.send("oneliner new");
    s.expect("Usage: %soneliner new [trigger] [type] [optional cooldown]".format(prefix));

    s.send("oneliner new herp ordered");
    s.expect("Oneliner %sherp created! Use %1$soneliner add to add lines.".format(prefix));

    s.sendPrefixed("herp");
    s.expect("(Empty oneliner; use %soneliner add herp to add lines.)".format(prefix));

    s.send("oneliner add herp 123");
    s.expect("Oneliner line added.");

    s.send("oneliner add herp 456");
    s.expect("Oneliner line added.");

    s.sendPrefixed("herp");
    s.expect("123");

    s.sendPrefixed("herp");
    s.expect("456");

    s.sendPrefixed("herp");
    s.expect("123");

    s.send("oneliner insert herp 0 000");
    s.expect("Oneliner line inserted.");

    s.sendPrefixed("herp");
    s.expect("000");

    s.sendPrefixed("herp");
    s.expect("123");

    s.send("oneliner list");
    s.expect("Available commands: %sherp".format(prefix));

    s.send("oneliner del hurp");
    s.expect("No such oneliner: %shurp".format(prefix));

    s.send("oneliner del herp");
    s.expect("Oneliner %sherp removed.".format(prefix));

    s.send("oneliner list");
    s.expect("There are no commands available right now.");

    s.send("oneliner new herp random 10");
    s.expect("Oneliner %sherp created! Use %1$soneliner add to add lines.".format(prefix));

    s.sendPrefixed("herp");
    s.expect("(Empty oneliner; use %soneliner add herp to add lines.)".format(prefix));

    s.send("oneliner add herp abc");
    s.expect("Oneliner line added.");

    s.sendPrefixed("herp");
    s.expect("abc");

    s.sendPrefixed("herp");

    logger.info("wait 10 seconds...");
    delay(plugin, 10.seconds, Yes.yield);
    enforce(!thisFiber.payload.content.length);

    s.sendPrefixed("herp");
    s.expect("abc");

    s.send("oneliner del herp");
    s.expect("Oneliner %sherp removed.".format(prefix));

    s.send("commands");
    s.expect("There are no commands available right now.");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !quote

    s.send("quote");
    s.expect("Usage: %squote [nickname] [optional search terms or #index]"
        .format(plugin.state.settings.prefix));

    s.send("quote $¡$¡");
    s.expect("Invalid nickname: $¡$¡");

    s.send("quote flerrp");
    s.expect("No quotes on record for flerrp!");

    s.send("addquote");
    s.expect("Usage: %saddquote [nickname] [new quote]"
        .format(plugin.state.settings.prefix));

    s.send("addquote flerrp flirrp flarrp flurble");
    s.expect("Quote added at index #0.");

    s.send("addquote flerrp flirrp flarrp FLARBLE");
    s.expect("Quote added at index #1.");

    s.send("quote flerrp");
    s.awaitReply();
    enforce(thisFiber.payload.content.stripEffects().startsWith("flirrp flarrp"),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("quote flerrp #1");
    s.awaitReply();
    enforce(thisFiber.payload.content.stripEffects().startsWith("flirrp flarrp FLARBLE ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("quote flerrp #99");
    s.expect("Index #99 out of range; valid is [0..1] (inclusive).");

    s.send("quote flerrp #honk");
    s.expect("Index must be a positive number.");

    s.send("quote flerrp flarble");
    s.awaitReply();
    enforce(thisFiber.payload.content.stripEffects().startsWith("flirrp flarrp FLARBLE ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("quote flerrp honkedonk");
    s.expect("No quotes found for search terms \"honkedonk\"");

    s.send("modquote");
    s.expect("Usage: %smodquote [nickname] [index] [new quote text]"
        .format(plugin.state.settings.prefix));

    s.send("modquote flerrp #0 KAAS FLAAS");
    s.expect("Quote modified.");

    s.send("quote flerrp #0");
    s.awaitReply();
    enforce(thisFiber.payload.content.stripEffects().startsWith("KAAS FLAAS ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("mergequotes flerrp flirrp");
    s.expect("2 quotes merged.");

    s.send("quote flirrp #0");
    s.awaitReply();
    enforce(thisFiber.payload.content.stripEffects().startsWith("KAAS FLAAS ("),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("quote flerrp");
    s.expect("No quotes on record for flerrp!");

    s.send("delquote flirrp #0");
    s.expect("Quote removed, indexes updated.");

    s.send("delquote flirrp #0");
    s.expect("Quote removed, indexes updated.");

    s.send("delquote flirrp #0");
    s.expect("No quotes on record for flirrp!");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ s/abc/ABC/

    s.sendNoPrefix("I am a fish");
    s.sendNoPrefix("s/fish/snek/");
    s.expect("%s | I am a snek".format(plugin.state.client.nickname));

    s.sendNoPrefix("I am a fish fish");
    s.sendNoPrefix("s#fish#snek#");
    s.expect("%s | I am a snek fish".format(plugin.state.client.nickname));

    s.sendNoPrefix("I am a fish fish");
    s.sendNoPrefix("s_fish_snek_g");
    s.expect("%s | I am a snek snek".format(plugin.state.client.nickname));

    s.sendNoPrefix("s/harbusnarbu");
    s.sendNoPrefix("s#snarbu#snofl/#");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !seen

    s.send("!seen");
    s.expect("Usage: !seen [nickname]");

    s.send("!seen ####");
    s.expect("Invalid user: ####");

    s.send("!seen HarblSnarbl");
    s.expect("I have never seen HarblSnarbl.");

    s.send("!seen " ~ plugin.state.client.nickname);
    s.expect("That's you!");

    s.send("!seen " ~ botNickname);
    s.expect("T-that's me though...");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !counter

    s.send("counter");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter list");
    s.awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.startsWith("Current counters: ")), thisFiber.payload.content);

    s.send("counter last");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter add");
    s.expect("Usage: !counter [add|del|format|list] [counter word]");

    s.send("counter del blah");
    s.awaitReply();
    enforce(((thisFiber.payload.content == "No such counter available.") ||
        (thisFiber.payload.content == "Counter blah removed.")), thisFiber.payload.content);

    s.send("counter del bluh");
    s.awaitReply();
    enforce(((thisFiber.payload.content == "No such counter available.") ||
        (thisFiber.payload.content == "Counter bluh removed.")), thisFiber.payload.content);

    s.send("counter add blah");
    s.expect("Counter blah added! Access it with !blah.");

    s.send("counter add bluh");
    s.expect("Counter bluh added! Access it with !bluh.");

    s.send("counter add bluh");
    s.expect("A counter with that name already exists.");

    s.send("counter list");
    s.awaitReply();
    immutable stripped = thisFiber.payload.content.stripEffects();
    enforce(stripped.startsWith("Current counters: ") &&
        ((stripped.indexOf("!blah") != -1) &&
        (stripped.indexOf("!bluh") != -1)), thisFiber.payload.content);

    // ------------ ![word]

    s.sendPrefixed("blah");
    s.expect("blah count so far: 0");

    s.sendPrefixed("blah+");
    s.expect("blah +1! Current count: 1");

    s.sendPrefixed("blah++");
    s.expect("blah +1! Current count: 2");

    s.sendPrefixed("blah+2");
    s.expect("blah +2! Current count: 4");

    s.sendPrefixed("blah+abc");
    s.expect("abc is not a number.");

    s.sendPrefixed("blah-");
    s.expect("blah -1! Current count: 3");

    s.sendPrefixed("blah--");
    s.expect("blah -1! Current count: 2");

    s.sendPrefixed("blah-2");
    s.expect("blah -2! Current count: 0");

    s.sendPrefixed("blah=10");
    s.expect("blah count assigned to 10!");

    s.sendPrefixed("blah");
    s.expect("blah count so far: 10");

    s.sendPrefixed("blah?");
    s.expect("blah count so far: 10");

    s.send("counter format blah ? ABC $count DEF");
    s.expect("Format pattern updated.");

    s.send("counter format blah + count +$step = $count");
    s.expect("Format pattern updated.");

    s.send("counter format blah - count -$step = $count");
    s.expect("Format pattern updated.");

    s.send("counter format blah = count := $count");
    s.expect("Format pattern updated.");

    s.sendPrefixed("blah");
    s.expect("ABC 10 DEF");

    s.sendPrefixed("blah+");
    s.expect("count +1 = 11");

    s.sendPrefixed("blah-2");
    s.expect("count -2 = 9");

    s.sendPrefixed("blah=42");
    s.expect("count := 42");

    s.send("counter format blah ? -");
    s.expect("Format pattern cleared.");

    s.sendPrefixed("blah");
    s.expect("blah count so far: 42");

    // ------------ !counter cleanup

    s.send("counter del blah");
    s.expect("Counter blah removed.");

    s.send("counter del blah");
    s.expect("No such counter available."); //available.");

    s.send("counter list");
    s.expect("Current counters: !bluh");

    s.send("counter del bluh");
    s.expect("Counter bluh removed.");

    s.send("counter list");
    s.awaitReply();
    enforce(((thisFiber.payload.content == "No counters currently active in this channel.") ||
        thisFiber.payload.content.startsWith("Current counters: ")), thisFiber.payload.content);
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !stopwatch

    s.send("stopwatch harbl");
    s.expect("Usage: !stopwatch [start|stop|status]");

    s.send("stopwatch");
    s.expect("You do not have a stopwatch running.");

    s.send("stopwatch status");
    s.expect("You do not have a stopwatch running.");

    s.send("stopwatch status harbl");
    s.expect("There is no such stopwatch running. (harbl)");

    s.send("stopwatch start");
    s.expect("Stopwatch started!");

    s.send("stopwatch");
    s.awaitReply();

    {
        immutable actual = thisFiber.payload.content.stripEffects();
        if (!actual.startsWith("Elapsed time: "))
        {
            throw new Exception(actual);
        }
    }

    s.send("stopwatch status");
    s.awaitReply();

    {
        immutable actual = thisFiber.payload.content.stripEffects();
        if (!actual.startsWith("Elapsed time: "))
        {
            throw new Exception(actual);
        }
    }

    s.send("stopwatch start");
    s.expect("Stopwatch restarted!");

    s.send("stopwatch stop");
    s.awaitReply();

    {
        immutable actual = thisFiber.payload.content.stripEffects();
        if (!actual.startsWith("Stopwatch stopped after "))
        {
            throw new Exception(actual);
        }
    }

    s.send("stopwatch start");
    s.expect("Stopwatch started!");

    s.send("stopwatch clear");
    s.expect("Clearing all stopwatches in channel " ~ origEvent.channel ~ '.');

    s.send("stopwatch");
    s.expect("You do not have a stopwatch running.");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !timer

    s.send("timer");
    s.expect("Usage: %stimer [new|add|del|suspend|resume|list] ..."
        .format(plugin.state.settings.prefix));

    s.send("timer new");
    s.expect(("Usage: %stimer new [name] [type] [condition] [message count threshold] " ~
        "[time threshold] [stagger message count] [stagger time]")
            .format(plugin.state.settings.prefix));

    s.send("timer new hirrsteff ordered both 0 10s 0 10s");
    s.expect("New timer added! Use !timer add to add lines.");

    s.send("timer suspend hirrsteff");
    s.expect("Timer suspended. Use %stimer resume hirrsteff to resume it."
        .format(plugin.state.settings.prefix));

    s.send("timer add splorf hello");
    s.expect("No such timer is defined. Add a new one with !timer new.");

    s.send("timer add hirrsteff HERLO");
    s.expect("Line added to timer hirrsteff.");

    s.send("timer insert hirrsteff 0 fgsfds");
    s.expect("Line added to timer hirrsteff.");

    s.send("timer edit hirrsteff 1 HARLO");
    s.expect("Line #1 of timer hirrsteff edited.");

    s.send("timer list");
    s.expect("Current timers for channel %s:".format(origEvent.channel));
    s.expect(`["hirrsteff"] lines:2 | type:ordered | condition:both | ` ~
        "message count threshold:0 | time threshold:10 | stagger message count:0 | stagger time:10 | suspended:true");

    logger.info("Wait ~1 cycle, nothing should happen...");
    delay(plugin, 15.seconds, Yes.yield);
    enforce(!thisFiber.payload.content.length,
        "'%s' != '%s'".format(thisFiber.payload.content, string.init), __FILE__, __LINE__           );

    s.send("timer resume hirrsteff");
    s.expect("Timer resumed!");

    logger.info("Wait 3 cycles + 10 seconds...");

    s.expect("fgsfds");
    logger.info("ok");

    s.expect("HARLO");
    logger.info("ok");

    s.expect("fgsfds");
    logger.info("all ok");

    s.send("timer del hirrsteff 0");
    s.expect("Line removed from timer hirrsteff. Lines remaining: 1");

    s.expect("HARLO");
    logger.info("all ok again");

    s.send("timer del hirrsteff");
    s.expect("Timer removed.");

    s.send("timer del hirrsteff");
    s.expect("There is no timer by that name.");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !time

    string response;  // mutable

    s.send("time");
    s.awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.startsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" locally."),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("time CET");
    s.awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.startsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in CET."),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("time Europe/Stockholm");
    s.awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.startsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in Europe/Stockholm."),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("time Dubai");
    s.awaitReply();
    response = thisFiber.payload.content.stripEffects();
    enforce(response.startsWith("The time is currently "),
        thisFiber.payload.content, __FILE__, __LINE__);
    enforce(response.endsWith(" in Dubai."),
        thisFiber.payload.content, __FILE__, __LINE__);

    s.send("time honk");
    s.expect("Invalid timezone: honk");
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
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !poll

    s.send("poll");
    s.expect("Usage: %spoll [duration] [choice1] [choice2] ...".format(plugin.state.settings.prefix));

    s.send("poll arf");
    s.expect("Need one duration and at least two choices.");

    s.send("poll arf urf hirf");
    s.expect("Malformed duration.");

    s.send("poll 5s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (5 seconds)");
    s.expect("Voting complete, no one voted.");

    s.send("poll 7 snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (7 seconds)");
    s.sendNoPrefix("snek");
    s.expect("Voting complete! Here are the results:");
    s.expect("snik : 0 votes");
    s.expect("snek : 1 vote (100.0%)");

    s.send("poll 1h2m3s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (1 hour, 2 minutes and 3 seconds)");

    s.send("poll end");
    s.expect("Voting complete, no one voted.");

    s.send("poll 1d23h59m59s snik snek");
    s.expect("Voting commenced! Please place your vote for one of: snek, snik (1 day, 23 hours, 59 minutes and 59 seconds)");

    s.send("poll abort");
    s.expect("Poll aborted.");

    s.send("poll abort");
    s.expect("There is no ongoing poll.");

    s.send("poll end");
    s.expect("There is no ongoing poll.");
}


// testBashFiber
/++
 +
 +/
version(none)
void testBashFiber(TesterPlugin plugin, const /*ref*/ IRCEvent origEvent, const string botNickname)
in (origEvent.channel.length, "Tried to test Bash with empty channel in original event")
{
    auto thisFiber = cast(CarryingFiber!IRCEvent)(Fiber.getThis);
    assert(thisFiber, "Incorrectly cast Fiber: `" ~ typeof(thisFiber).stringof ~ '`');
    auto s = Sender(plugin, thisFiber, origEvent.channel, botNickname);

    // ------------ !bash

    s.send("bash 5273");
    s.awaitReply();
    immutable banner = thisFiber.payload.content.stripEffects();

    if (banner == "[bash.org] #5273")
    {
        // Ok
        s.expect("erno> hm. I've lost a machine.. literally _lost_. it responds to ping, " ~
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

    s.send("bash honk");
    s.awaitReply();
    immutable honk = thisFiber.payload.content.stripEffects();

    if (honk == "Could not fetch bash.org quote: No such quote found.")
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

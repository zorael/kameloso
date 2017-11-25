module kameloso.plugins.admin;

import kameloso.plugins.common;
import kameloso.ircstructs;
import kameloso.common : ThreadMessage, logger;

import std.concurrency : send;
import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Toggles whether onAnyEvent prints the raw strings of all incoming events
bool printAll;

/// Toggles whether onAnyEvent prints the raw bytes of the *contents* of events
bool printBytes;

/// Toggles whether onAnyEvent prints assert statements for incoming events
bool printAsserts;


// tabs
/++
 +  Returns spaces equal to that of num tabs (\t).
 +/
string tabs(uint num) pure
{
    enum tab = "    ";

    string total;

    foreach (i; 0..num)
    {
        total ~= tab;
    }

    return total;
}


// formatAssertStatementLines
/++
 +  Constructs assert statement lines for each changed field of a type.
 +/
void formatAssertStatementLines(Sink, Thing)(auto ref Sink sink, Thing thing,
    const string prefix = string.init, uint depth = 0)
{
    foreach (immutable i, value; thing.tupleof)
    {
        alias T = typeof(value);
        enum memberstring = __traits(identifier, thing.tupleof[i]);

        static if ((memberstring == "raw") || (memberstring == "time"))
        {
            continue;
        }
        else static if (is(T == struct))
        {
            sink.formatAssertStatementLines(thing.tupleof[i], memberstring, depth);
        }
        else
        {
            if (value != Thing.init.tupleof[i])
            {
                import std.format : formattedWrite;
                import std.traits : isSomeString;

                static if (isSomeString!T)
                {
                    enum pattern = "%sassert((%s%s == \"%s\"), %s%s);\n";
                }
                else
                {
                    enum pattern = "%sassert((%s%s == %s), %s%s.to!string);\n";
                }

                sink.formattedWrite(pattern,
                    depth.tabs,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring, value,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring);
            }
        }
    }
}

unittest
{
    import std.array : Appender;
    Appender!string sink;
    sink.reserve(512);

    IRCBot bot;
    auto parser = IRCParser(bot);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    sink.formatAssertStatementLines(event, string.init, 2);

    assert(sink.data ==
`        assert((type == CHAN), type.to!string);
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
`, '\n' ~ sink.data);
}


// formatAssertStatementLines
/++
 +  Constructs statement lines for each changed field of an IRCBot, including
 +  instantiating a fresh one.
 +/
void formatBot(Sink)(auto ref Sink sink, const IRCBot bot)
{

    sink.put("IRCBot bot;\n");
    sink.put("with (bot)\n");
    sink.put("{\n");

    foreach (immutable i, value; bot.tupleof)
    {
        import std.format : formattedWrite;
        import std.traits : isSomeString;
        alias T = typeof(value);
        enum memberstring = __traits(identifier, bot.tupleof[i]);

        static if (is(T == struct) || is(T == class))
        {
            // Can't recurse for now, future improvement
            continue;
        }
        else
        {
            if (value != IRCBot.init.tupleof[i])
            {
                static if (isSomeString!T)
                {
                    enum pattern = "%s%s = \"%s\";\n";
                }
                else
                {
                    enum pattern = "%s%s = %s;\n";
                }

                sink.formattedWrite(pattern, 1.tabs, memberstring, value);
            }
        }

    }

    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

unittest
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCBot bot;
    with (bot)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
    }

    sink.formatBot(bot);

    assert(sink.data ==
`IRCBot bot;
with (bot)
{
    nickname = "NICKNAME";
    user = "UUUUUSER";
}`, '\n' ~ sink.data);
}


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an IRCEvent.
 +/
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
{
    import std.array : Appender;
    import std.format : formattedWrite;

    sink.put("{\n");
    sink.formattedWrite("%simmutable event = \"%s\"\n",
        1.tabs, event.raw);
    sink.formattedWrite("%s                  .toIRCEvent(bot);\n", 1.tabs);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatAssertStatementLines(event, string.init, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

version(none)  // FIXME
unittest
{
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(512);

    IRCBot bot;
    auto parser = IRCParser(bot);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");

    // copy/paste the above
    sink.put("{\n");
    sink.formattedWrite("%simmutable event = \"%s\"\n",
        1.tabs, event.raw);
    sink.formattedWrite("%s                  .toIRCEvent(bot);\n", 1.tabs);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatAssertStatementLines(event, string.init, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    assert(sink.data ==
`{
    immutable event = ":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball"
    with (event)
    {
        assert((type == CHAN), type.to!string);
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
    }
}`, '\n' ~ sink.data);
}



// onCommandShowUsers
/++
 +  Prints out the current state.users array in the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "users")
void onCommandShowUsers()
{
    logger.trace("Printing Admin's users");

    printObject(state.bot);

    foreach (entry; state.users.byKeyValue)
    {
        writefln("%-12s [%s]", entry.key, entry.value);
    }
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "sudo")
void onCommandSudo(const IRCEvent event)
{
    state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


// onCommandFake
/++
 +  Fake that a string was sent by the server.
 +
 +  Chance of infinite loop?
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "fake")
void onCommandFake(const IRCEvent event)
{
    state.mainThread.send(event.content);
}


// onCommandQuit
/++
 +  Sends a QUIT event to the server.
 +
 +  If any extra text is following the 'quit' prefix, it uses that as the quit
 +  reason, otherwise it falls back to the default as specified in the
 +  configuration file.
 +
 +  Params:
 +      event = tshe triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "quit")
void onCommandQuit(const IRCEvent event)
{
    state.mainThread.send(ThreadMessage.Quit(), event.content);
}


// onCommandAddChan
/++
 +  Add a channel to the list of currently active channels.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "addhome")
void onCommandAddHome(const IRCEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel(state.bot.server))
    {
        logger.warning("Invalid channel");
        return;
    }

    with (state)
    {
        if (!bot.homes.canFind(channel))
        {
            mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ channel);
        }

        logger.info("Adding channel: ", channel);
        bot.homes ~= channel;
        bot.updated = true;
    }
}


// onCommandDelHome
/++
 +  Removes a channel from the list of currently active home channels.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "delhome")
void onCommandDelHome(const IRCEvent event)
{
    import std.algorithm : countUntil, remove;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel(state.bot.server))
    {
        logger.warning("Invalid channel");
        return;
    }

    with (state)
    {
        immutable chanIndex = bot.homes.countUntil(channel);

        if (chanIndex == -1)
        {
            logger.warningf("Channel %s was not in bot.homes", channel);
            return;
        }

        bot.homes = bot.homes.remove(chanIndex);
        bot.updated = true;
        mainThread.send(ThreadMessage.Sendline(), "PART :" ~ channel);
    }
}


// onCommandAddFriend
/++
 +  Add a nickname to the list of users who may trigger the bot.
 +
 +  This is at a 'friends' level, as opposed to 'anyone' and 'master'.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "addfriend")
void onCommandAddFriend(const IRCEvent event)
{
    import std.string : indexOf, strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        logger.warning("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        logger.warning("Nickname must not contain spaces");
        return;
    }

    with (state)
    {
        bot.friends ~= nickname;
        bot.updated = true;
        logger.infof("%s added to friends", nickname);
    }
}


// onCommandDelFriend
/++
 +  Remove a nickname from the list of users who may trigger the bot.
 +
 +  Params:
 +      event = The triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "delfriend")
void onCommandDelFriend(const IRCEvent event)
{
    import std.algorithm : countUntil, remove;
    import std.string : indexOf, strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        logger.warning("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        logger.warning("Only one nick at a time. Nickname must not contain spaces");
        return;
    }

    immutable friendIndex = state.bot.friends.countUntil(nickname);

    if (friendIndex == -1)
    {
        logger.warning("No such friend");
        return;
    }

    with (state)
    {
        bot.friends = bot.friends.remove(friendIndex);
        bot.updated = true;
        logger.infof("%s removed from friends", nickname);
    }
}


// onCommandResetTerminal
/++
 +  Outputs the ASCII control character 15 to the terminal.
 +
 +  This helps with restoring it if the bot has accidentally printed a different
 +  control character putting it would-be binary mode, like what happens when
 +  you try to cat a binary file.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "resetterm")
void onCommandResetTerminal()
{
    write(TerminalToken.reset);
}


// onCommandPrintAll
/++
 +  Toggles a flag to print all incoming events raw.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printall")
void onCommandPrintAll()
{
    printAll = !printAll;
    logger.info("Printing all: ", printAll);
}


// onCommandPrintBytes
/++
 +  Toggles a flag to print all incoming events as bytes.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printbytes")
void onCommandPrintBytes()
{
    printBytes = !printBytes;
    logger.info("Printing bytes: ", printBytes);
}


// onCommandAsserts
/++
 +  Toggles a flag to print assert statements for incoming events.
 +
 +  This is for debugging purposes.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "asserts")
void onCommandAsserts()
{
    printAsserts = !printAsserts;
    logger.info("Printing asserts: ", printAsserts);
    formatBot(stdout.lockingTextWriter, state.bot);
}


// onAnyEvent
/++
 +  Prints all incoming events raw if the flag to do so has been set with
 +  onCommandPrintAll, by way of the 'printall' verb. Also prints the content
 +  of any incomings events, cast to bytes.
 +
 +  Params:
 +      event = the event whose raw IRC string to print.
 +/
@(IRCEvent.Type.ANY)
void onAnyEvent(const IRCEvent event)
{
    if (printAll) logger.trace(event.raw, '$');

    if (printBytes)
    {
        import std.string : representation;

        foreach (i, c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }
    }

    if (printAsserts)
    {
        import std.algorithm.searching : canFind;

        if ((cast(ubyte[])event.raw).canFind(1))
        {
            logger.warning("event.raw contains CTCP 1 which might not get printed");
        }

        formatEventAssertBlock(stdout.lockingTextWriter, event);
    }
}


// onCommandJoin
/++
 +  Joins a supplied channel.
 +
 +  Simply defers to joinPartImpl with the prefix JOIN.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "join")
void onCommandJoin(const IRCEvent event)
{
    joinPartImpl("JOIN", event);
}


// onCommandPart
/++
 +  Parts from a supplied channel.
 +
 +  Simply defers to joinPartImpl with the prefix PART.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "part")
void onCommandPart(const IRCEvent event)
{
    joinPartImpl("PART", event);
}


// joinPartImpl
/++
 +  Joins or parts a supplied channel.
 +
 +  Technically sends the action passed in the prefix variable with the list of
 +  channels as its list of arguments.
 +
 +  Params:
 +      prefix = the action string to send (JOIN or PART).
 +      event = the triggering IRCEvent.
 +/
void joinPartImpl(const string prefix, const IRCEvent event)
{
    import std.algorithm.iteration : joiner, splitter;
    import std.format : format;

    // The prefix could be in lowercase. Do we care?
    assert(((prefix == "JOIN") || (prefix == "PART")),
           "Invalid prefix passed to joinPartlImpl: " ~ prefix);

    if (!event.content.length)
    {
        logger.warning("No channels supplied...");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(prefix, event.content.splitter(' ').joiner(",")));
}


public:

mixin BasicEventHandlers;
mixin OnEventImpl;


// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use and debugging.
 +
 +  It was historically part of Chatbot.
 +/
final class AdminPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

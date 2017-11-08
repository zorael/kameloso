module kameloso.plugins.admin;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;
import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Toggles whether onAnyEvent prints the raw strings of all incoming events
bool printAll;

/// Toggles whether onAnyEvent prints the raw bytes of the *contents* of events
bool printBytes;


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
@Prefix(NickPrefixPolicy.required, "sudo")
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
@Prefix(NickPrefixPolicy.required, "fake")
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
@Prefix(NickPrefixPolicy.required, "quit")
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
@Prefix(NickPrefixPolicy.required, "addhome")
void onCommandAddHome(const IRCEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        logger.warning("Invalid channel");
        return;
    }

    if (!state.bot.homes.canFind(channel))
    {
        state.mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ channel);
    }

    logger.info("Adding channel: ", channel);
    state.bot.homes ~= channel;
    updateBot();
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
@Prefix(NickPrefixPolicy.required, "delhome")
void onCommandDelHome(const IRCEvent event)
{
    import std.algorithm : countUntil, remove;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        logger.warning("Invalid channel");
        return;
    }

    immutable chanIndex = state.bot.homes.countUntil(channel);

    if (chanIndex == -1)
    {
        logger.warningf("Channel %s was not in bot.homes", channel);
        return;
    }

    state.bot.homes = state.bot.homes.remove(chanIndex);
    state.mainThread.send(ThreadMessage.Sendline(), "PART :" ~ channel);
    updateBot();
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
@Prefix(NickPrefixPolicy.required, "addfriend")
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

    state.bot.friends ~= nickname;
    logger.infof("%s added to friends", nickname);
    updateBot();
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
@Prefix(NickPrefixPolicy.required, "delfriend")
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

    state.bot.friends = state.bot.friends.remove(friendIndex);
    logger.infof("%s removed from friends", nickname);
    updateBot();
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
@Prefix(NickPrefixPolicy.required, "resetterm")
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
@Prefix(NickPrefixPolicy.required, "printall")
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
@Prefix(NickPrefixPolicy.required, "printbytes")
void onCommandPrintBytes()
{
    printBytes = !printBytes;
    logger.info("Printing bytes: ", printBytes);
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
@Prefix(NickPrefixPolicy.required, "join")
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
@Prefix(NickPrefixPolicy.required, "part")
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


// onCommandWriteConfig
/++
 +  Sends a concurrency message to write the current configuration to disk.
 +
 +  This includes current channels.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "writeconfig")
void onCommandWriteConfig()
{
    state.mainThread.send(ThreadMessage.WriteConfig());
}


public:

mixin BasicEventHandlers!__MODULE__;
mixin OnEventImpl!__MODULE__;


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

module kameloso.plugins.admin;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

/// Toggles whether onAnyEvent prints the raw strings of all incoming IRC events
bool printAll;

bool printBytes;


// updateBot TODO: deduplicate
/++
 +  Takes a copy of the current bot state and concurrency-sends it to the main thread,
 +  propagating any changes up the stack and then down to all other plugins.
 +/
void updateBot()
{
    const botCopy = state.bot;
    state.mainThread.send(cast(shared)botCopy);
}


// onCommandSudo
/++
 +  Sends supplied text to the server, verbatim.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("sudo")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "sudo")
void onCommandSudo(const IrcEvent event)
{
    if (state.users[event.sender].login != state.bot.master)
    {
        writefln(Foreground.lightred, "Failsafe triggered: user is not master (%s)", event.sender);
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


// onCommandQuit
/++
 +  Sends a QUIT event to the server.
 +
 +  If any extra text is following the 'quit' prefix, it uses that as the quit reason,
 +  otherwise it falls back to the default as specified in the configuration file.
 +
 +  Params:
 +      event = tshe triggering IrcEvent.
 +/
@Label("quit")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "quit")
void onCommandQuit(const IrcEvent event)
{
    state.mainThread.send(ThreadMessage.Quit(), event.content);
}


// onCommandAddChan
/++
 +  Add a channel to the list of currently active channels.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("addchan")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "addhome")
void onCommandAddHome(const IrcEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        writeln(Foreground.lightred, "invalid channel: ", channel);
        return;
    }

    if (!state.bot.homes.canFind(channel))
    {
        state.mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ channel);
    }

    writeln(Foreground.lightcyan, "Adding channel: ", channel);
    state.bot.homes ~= channel;
    updateBot();
}


// onCommandDelChan
/++
 +  Removes a channel from the list of currently active home channels.
 +
 +  Params:
 +      event = the triggering IrcEvent.
 +/
@Label("delchan")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "delchan")
@Prefix(NickPrefixPolicy.required, "delhome")
void onCommandDelChan(const IrcEvent event)
{
    import std.algorithm : countUntil, remove;
    import std.string : strip;

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        writeln(Foreground.lightred, "invalid channel: ", channel);
        return;
    }

    immutable chanIndex = state.bot.homes.countUntil(channel);

    if (chanIndex == -1)
    {
        writefln(Foreground.lightred, "Channel %s was not in bot.homes", channel);
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
 +      event = the triggering IrcEvent.
 +/
@Label("addfriend")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "addfriend")
void onCommandAddFriend(const IrcEvent event)
{
    import std.string : indexOf, strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln(Foreground.lightred, "No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln(Foreground.lightred, "Nickname must not contain spaces");
        return;
    }

    state.bot.friends ~= nickname;
    writefln(Foreground.lightcyan, "%s added to friends", nickname);
    updateBot();
}


// onCommandDelFriend
/++
 +  Remove a nickname from the list of users who may trigger the bot.
 +
 +  Params:
 +      event = The triggering IrcEvent.
 +/
@Label("delfriend")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "delfriend")
void onCommandDelFriend(const IrcEvent event)
{
    import std.algorithm : countUntil, remove;
    import std.string : indexOf, strip;

    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln(Foreground.lightred, "No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln(Foreground.lightred, "Only one nick at a time. Nickname must not contain spaces");
        return;
    }

    immutable friendIndex = state.bot.friends.countUntil(nickname);

    if (friendIndex == -1)
    {
        writefln(Foreground.lightred, "No such friend");
        return;
    }

    state.bot.friends = state.bot.friends.remove(friendIndex);
    writefln(Foreground.lightcyan, "%s removed from friends", nickname);
    updateBot();
}


// onCommandResetTerminal
/++
 +  Outputs the ASCII control character 15 to the terminal.
 +
 +  This helps with restoring it if the bot has accidentally printed a different control
 +  character putting it would-be binary mode, like what happens when you try to cat a
 +  binary file.
 +/
@Label("resetterm")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "resetterm")
void onCommandResetTerminal()
{
    import std.stdio : write;
    write(TerminalResetToken);
}


// onCommandPrintAll
/++
 +  Toggles a flag to print all incoming IRC events raw.
 +
 +  This is for debugging purposes.
 +/
@Label("toggleprintall")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "printall")
void onCommandPrintAll()
{
    printAll = !printAll;
    writeln(Foreground.green, "Printing all: ", printAll);
}


@Label("toggleprintbytes")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "printbytes")
void onCommandPrintBytes()
{
    printBytes = !printBytes;
    writeln(Foreground.green, "Printing bytes: ", printBytes);
}

// onAnyEvent
/++
 +  Prints all incoming IRC events raw if the flag to do so has been set with onCommandPrintAll,
 +  by way of the 'printall' verb.
 +
 +  It is annotated with Chainable.yes to allow other functions to not halt the triggering
 +  process, allowing other functions to trigger on the same IrcEvent.
 +
 +  Params:
 +      event = the event whose raw IRC string to print.
 +/
@Label("print")
@(IrcEvent.Type.ANY)
@(Chainable.yes)
void onAnyEvent(const IrcEvent event)
{
    if (printAll) writeln(Foreground.cyan, event.raw, "$");

    if (printBytes)
    {
        import std.string : representation;

        foreach (i, c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }
    }
}


// onCommandStatus
/++
 +  Propagates a request via the main thread to have all plugins print their IrcPluginState
 +  struct to the terminal.
 +
 +  It doesn't print its own at this point; it merely sets the ball running so it will,
 +  in the end, receive the message to do so itself.
 +/
@Label("status")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "status")
void onCommandStatus()
{
    state.mainThread.send(ThreadMessage.Status());
}


// onCommandJoinPart
/++
 +  Joins or parts a supplied channel.
 +
 +  Params:
 +      prefix = a prefix string of either "join" or "part".
 +      event = the triggering IrcEvent.
 +/
@Label("join/part")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "join")
@Prefix(NickPrefixPolicy.required, "part")
void onCommandJoinPart(const string prefix, const IrcEvent event)
{
    import std.algorithm.iteration : splitter, joiner;
    import std.format : format;

    if (!event.content.length)
    {
        writeln(Foreground.lightred, "No channels supplied...");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(prefix, event.content.splitter(' ').joiner(",")));
}


@Label("writeconfig")
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPrefixPolicy.required, "writeconfig")
void onWriteConfig(const IrcEvent event)
{
    state.mainThread.send(ThreadMessage.WriteConfig());
}


mixin BasicEventHandlers!__MODULE__;
mixin OnEventImpl!__MODULE__;

public:


// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use.
 +
 +  It was historically part of Chatbot.
 +/
final class AdminPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}

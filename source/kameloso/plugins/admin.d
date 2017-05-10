module kameloso.plugins.admin;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.stringutils;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.concurrency;
import std.traits;
import std.string;
import std.algorithm;

private:

IrcPluginState state;
bool printAll;


void updateBot()
{
    with (state)
    {
        shared botCopy = cast(shared)bot;
        mainThread.send(botCopy);
    }
}


@(Label("sudo"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "sudo"))
void onCommandSudo(const IrcEvent event)
{
    if (state.users[event.sender].login != state.bot.master)
    {
        writefln("Failsafe triggered: bot is not master (%s)", event.sender);
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


@(Label("quit"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "quit"))
void onCommandQuit(const IrcEvent event)
{
    if (state.users[event.sender].login != state.bot.master)
    {
        writefln("Failsafe triggered: bot is not master (%s)", event.sender);
        return;
    }

    // By sending a concurrency message it should quit nicely
    state.mainThread.send(ThreadMessage.Quit(), event.content);
}


@(Label("addchan"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "addchan"))
@(Prefix(NickPrefixPolicy.required, "addhome"))
void onCommandAddChan(const IrcEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : strip;

    immutable channel = event.content.strip();

    // Add an "active" channel, in which the bot should react
    if (!channel.isValidChannel)
    {
        writeln("invalid channel: ", channel);
        return;
    }

    if (!state.bot.channels.canFind(channel))
    {
        state.mainThread.send(ThreadMessage.Sendline(), "JOIN :" ~ channel);
    }

    writeln("Adding channel: ", channel);
    state.bot.channels ~= channel;
    updateBot();
}


@(Label("delchan"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "delchan"))
@(Prefix(NickPrefixPolicy.required, "delhome"))
void onCommandDelChan(const IrcEvent event)
{
    // Remove a channel from the active list

    immutable channel = event.content.strip();

    if (!channel.isValidChannel)
    {
        writeln("invalid channel: ", channel);
        return;
    }

    const chanIndex = state.bot.channels.countUntil(channel);

    if (chanIndex == -1)
    {
        writefln("Channel %s was not in bot.channels", channel);
        return;
    }

    state.bot.channels = state.bot.channels.remove(chanIndex);
    state.mainThread.send(ThreadMessage.Sendline(), "PART :" ~ channel);
    updateBot();
}


@(Label("addfriend"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "addfriend"))
void onCommandAddFriend(const IrcEvent event)
{
    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln("Nickname must not contain spaces");
        return;
    }

    state.bot.friends ~= nickname;
    writefln("%s added to friends", nickname);
    updateBot();
}


@(Label("delfriend"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "delfriend"))
void onCommandDelFriend(const IrcEvent event)
{
    immutable nickname = event.content.strip();

    if (!nickname.length)
    {
        writeln("No nickname supplied...");
        return;
    }
    else if (nickname.indexOf(" ") != -1)
    {
        writeln("Nickname must not contain spaces");
        return;
    }

    auto friendIndex = state.bot.friends.countUntil(nickname);

    if (friendIndex == -1)
    {
        writefln("No such friend");
        return;
    }

    state.bot.friends = state.bot.friends.remove(friendIndex);
    writefln("%s removed from friends", nickname);
    updateBot();
}


@(Label("resetterm"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "resetterm"))
void onCommandResetTerminal(const IrcEvent event)
{
    import std.stdio : write;
    write(ControlCharacter.termReset);
}


@(Label("toggleprintall"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "printall"))
void onCommandPrintAll(const IrcEvent event)
{
    printAll = !printAll;
    writeln("Printing all: ", printAll);
}


@Label("print")
@(IrcEvent.Type.ANY)
@(Chainable.yes)
void onAnyEvent(const IrcEvent event)
{
    if (printAll) writeln(event.raw);
}


@(Label("status"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "status"))
void onCommandStatus(const IrcEvent event)
{
    state.mainThread.send(ThreadMessage.Status());
}


@(Label("join/part"))
@(IrcEvent.Type.CHAN)
@(IrcEvent.Type.QUERY)
@(PrivilegeLevel.master)
@(Prefix(NickPrefixPolicy.required, "join"))
@(Prefix(NickPrefixPolicy.required, "part"))
void onCommandJoinPart(const string prefix, const IrcEvent event)
{
    import std.algorithm.iteration : splitter, joiner;
    import std.format : format;

    if (!event.content.length)
    {
        writeln("No channels supplied...");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(prefix, event.content.splitter(' ').joiner(",")));
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;


public:

// AdminPlugin
/++
 +  A plugin aimed for adḿinistrative use. It was historically part of Chatbot but now lives
 +  by itself, sadly with much code between them duplicated. FIXME.
 +/
final class AdminPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}

module kameloso.messaging;

private:

import kameloso.plugins.common.core : IRCPluginState;
import dialect.defs;
import std.concurrency : Tid, send;
import std.typecons : Flag, No, Yes;

version(unittest)
{
    import lu.conv : Enum;
    import std.concurrency : receive, receiveOnly, thisTid;
    import std.conv : to;
}

public:

struct Message
{
    enum Property
    {
        fast        = 1 << 0,
        quiet       = 1 << 1,
        background  = 1 << 2,
        forced      = 1 << 3,
        priority    = 1 << 4,
        immediate   = 1 << 5,
    }

    IRCEvent event;
    Property properties;
    string caller;
}

void chan(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string channelName,
    const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channelName.length, "Tried to send a channel message but no channel was given")
{}

void query(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string nickname,
    const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (nickname.length, "Tried to send a private query but no nickname was given")
{}

void privmsg(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string channel,
    const string nickname,
    const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in ((channel.length || nickname.length), "Tried to send a PRIVMSG but no channel nor nickname was given")
{}

void emote(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string emoteTarget,
    const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (emoteTarget.length, "Tried to send an emote but no target was given")
{}

void mode(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string channel,
    const const(char)[] modes,
    const string content = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to set a mode but no channel was given")
{}

void part(Flag!"priority" priority = No.priority)
    (IRCPluginState state,
    const string channel,
    const string reason = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to part a channel but no channel was given")
{}

void quit(Flag!"priority" priority = Yes.priority)
    (IRCPluginState state,
    const string reason = string.init,
    const Flag!"quiet" quiet = No.quiet)
{
    static if (priority) import std.concurrency : send = prioritySend;
    import kameloso.thread : ThreadMessage;

    state.mainThread.send(ThreadMessage.Quit(),
        reason.length ? reason : state.bot.quitReason, cast()quiet);
}

void immediate(IRCPluginState state,
    const string line,
    const Flag!"quiet" quiet = No.quiet,
    const string caller = __FUNCTION__)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.UNSET;
    m.event.content = line;
    m.caller = caller;
    m.properties |= Message.Property.immediate;

    if (quiet) m.properties |= Message.Property.quiet;

    state.mainThread.prioritySend(m);
}

alias immediateline = immediate;

void askToOutputImpl(string logLevel)(IRCPluginState state, const string line)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;
    mixin("state.mainThread.prioritySend(ThreadMessage.TerminalOutput." ~ logLevel ~ ", line);");
}

alias askToWriteln = askToOutputImpl!"writeln";

/++
 +  Functions used to send messages to the server.
 +
 +  It does this by crafting `kameloso.ircdefs.IRCEvent`s from the passed
 +  arguments, then sends it to the concurrency message-reading parts of the
 +  main loop, which formats them into strings and sends them to the server.
 +/
module kameloso.messaging;

import kameloso.ircdefs;
import kameloso.plugins.common : IRCPluginState;
import kameloso.string : beginsWithOneOf;

import std.typecons : Flag, No, Yes;
import std.concurrency : Tid, send;


// chan
/++
 +  Sends a channel message.
 +/
void chan(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel, const string content)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "chan was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.target.special = quiet;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}


// query
/++
 +  Sends a private query message to a user.
 +/
void query(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string nickname, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    event.target.special = quiet;
    event.target.nickname = nickname;
    event.content = content;

    state.mainThread.send(event);
}


// privmsg
/++
 +  Sends either a channel message or a private query message depending on
 +  the arguments passed to it.
 +
 +  This reflects how channel messages and private messages are both the
 +  underlying same type; `PRIVMSG`.
 +/
void privmsg(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel,
    const string nickname, const string content)
{
    if (channel.length)
    {
        assert(channel.beginsWithOneOf(state.bot.server.chantypes),
            "privmsg was passed invalid channel: " ~ channel);
        return chan!quiet(state, channel, content);
    }
    else if (nickname.length)
    {
        assert(channel.beginsWithOneOf(state.bot.server.chantypes),
            "privmsg was passed a channel for nick: " ~ channel);
        return query!quiet(state, nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }
}

deprecated("throttleline is deprecated, use privmsg instead.")
alias throttleline = privmsg;


// emote
/++
 +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
 +/
void emote(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string emoteTarget, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    event.target.special = quiet;
    event.content = content;

    if (emoteTarget.beginsWithOneOf(state.bot.server.chantypes))
    {
        event.channel = emoteTarget;
    }
    else
    {
        event.target.nickname = emoteTarget;
    }

    state.mainThread.send(event);
}


// mode
/++
 +  Sets a channel mode.
 +
 +  This includes modes that pertain to a user in the context of a channel,
 +  like bans.
 +/
void mode(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel,
    const string modes, const string content = string.init)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "mode was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.MODE;
    event.target.special = quiet;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    state.mainThread.send(event);
}


// topic
/++
 +  Sets the topic of a channel.
 +/
void topic(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel, const string content)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "topic was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    event.target.special = quiet;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}


// invite
/++
 +  Invites a user to a channel.
 +/
void invite(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel, const string nickname)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "invite was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    event.target.special = quiet;
    event.channel = channel;
    event.target.nickname = nickname;

    state.mainThread.send(event);
}


// join
/++
 +  Joins a channel.
 +/
void join(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "join was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    event.target.special = quiet;
    event.channel = channel;

    state.mainThread.send(event);
}


// kick
/++
 +  Kicks a user from a channel.
 +/
void kick(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel,
    const string nickname, const string reason = string.init)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes),
        "kick was passed invalid channel: " ~ channel);
    assert(nicikname.beginsWithOneOf(state.bot.server.chantypes),
        "kick was passed channel as nickname: " ~ nickname);

    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    event.target.special = quiet;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    state.mainThread.send(event);
}


// part
/++
 +  Leaves a channel.
 +/
void part(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "part was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    event.target.special = quiet;
    event.channel = channel;

    state.mainThread.send(event);
}


// quit
/++
 +  Disconnects from the server, optionally with a quit reason.
 +/
void quit(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    event.target.special = quiet;
    event.content = reason;

    state.mainThread.send(event);
}


// raw
/++
 +  Sends text to the server, verbatim.
 +
 +  This is used to send messages of types for which there exist no helper
 +  functions.
 +/
void raw(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string line)
{
    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    event.target.special = quiet;
    event.content = line;

    state.mainThread.send(event);
}

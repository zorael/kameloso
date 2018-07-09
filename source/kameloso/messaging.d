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

version(unittest)
{
    import std.concurrency : receiveOnly, thisTid;
    import std.conv : to;
}


// chan
/++
 +  Sends a channel message.
 +/
void chan(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string channel, const string content)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "chan was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.chan("#channel", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.CHAN), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
    }
}


// query
/++
 +  Sends a private query message to a user.
 +/
void query(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string nickname, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.target.nickname = nickname;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.query("kameloso", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.QUERY), type.to!string);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "content"), content);
    }
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
        assert(!nickname.beginsWithOneOf(state.bot.server.chantypes),
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

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.privmsg("#channel", string.init, "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.CHAN), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    state.privmsg(string.init, "kameloso", "content");

    immutable event2 = receiveOnly!IRCEvent;
    with (event2)
    {
        assert((type == IRCEvent.Type.QUERY), type.to!string);
        assert(!channel.length, channel);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "content"), content);
    }
}


// emote
/++
 +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
 +/
void emote(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string emoteTarget, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    if (quiet) event.target.class_ = IRCUser.Class.special;
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

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.emote("#channel", "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.EMOTE), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    state.emote("kameloso", "content");

    immutable event2 = receiveOnly!IRCEvent;
    with (event2)
    {
        assert((type == IRCEvent.Type.EMOTE), type.to!string);
        assert(!channel.length, channel);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "content"), content);
    }
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
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.mode("#channel", "+o", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.MODE), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((aux == "+o"), aux);
    }
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
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.topic("#channel", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.TOPIC), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
    }
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
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.target.nickname = nickname;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.invite("#channel", "kameloso");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.INVITE), type.to!string);
        assert((channel == "#channel"), channel);
        assert((target.nickname == "kameloso"), target.nickname);
    }
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
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.join("#channel");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.JOIN), type.to!string);
        assert((channel == "#channel"), channel);
    }
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
    assert(!nickname.beginsWithOneOf(state.bot.server.chantypes),
        "kick was passed channel as nickname: " ~ nickname);

    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.kick("#channel", "kameloso", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.KICK), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((target.nickname == "kameloso"), target.nickname);
    }
}


// part
/++
 +  Leaves a channel.
 +/
void part(Flag!"quiet" quiet = No.quiet)(IRCPluginState state,
    const string channel, const string reason = string.init)
{
    assert(channel.beginsWithOneOf(state.bot.server.chantypes), "part was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = reason;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.part("#channel", "reason");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.PART), type.to!string);
        assert((channel == "#channel"), channel);
        assert((content == "reason"), content);
    }
}


// quit
/++
 +  Disconnects from the server, optionally with a quit reason.
 +/
void quit(Flag!"quiet" quiet = No.quiet)(IRCPluginState state, const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.content = reason;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.quit("reason");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.QUIT), type.to!string);
        assert((content == "reason"), content);
    }
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
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.content = line;

    state.mainThread.send(event);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    state.raw("commands");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.UNSET), type.to!string);
        assert((content == "commands"), content);
    }
}

/++
 +  Functions used to send messages to the server.
 +/
module kameloso.messaging;

import kameloso.ircdefs;

import std.typecons : Flag, No, Yes;
import std.concurrency : Tid, send;


// chan
/++
 +  Sends a channel message.
 +/
void chan(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string content)
{
    assert((channel[0] == '#'), "chan was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.target.special = quiet;
    event.channel = channel;
    event.content = content;

    tid.send(event);
}


// query
/++
 +  Sends a private query message to a user.
 +/
void query(Flag!"quiet" quiet = No.quiet)(Tid tid, const string nickname,
    const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    event.target.special = quiet;
    event.target.nickname = nickname;
    event.content = content;

    tid.send(event);
}


// privmsg
/++
 +  Sends either a channel message or a private query message depending on
 +  the arguments passed to it.
 +
 +  This reflects how channel messages and private messages are both the
 +  underlying same type; `PRIVMSG`.
 +/
void privmsg(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname, const string content)
{
    if (channel.length)
    {
        assert((channel[0] == '#'), "privmsg was passed invalid channel: " ~ channel);
        return chan!quiet(tid, channel, content);
    }
    else if (nickname.length)
    {
        assert((nickname[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
        return query!quiet(tid, nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }
}


// throttleline
/++
 +  Sends either a channel message or a private query message depending on
 +  the arguments passed to it.
 +
 +  It sends it in a throttled fashion, usable for long output when the bot
 +  may otherwise get kicked for spamming.
 +/
void throttleline(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname, const string content)
{
    import kameloso.common : ThreadMessage;
    import std.format : format;

    string line;

    if (channel.length)
    {
        assert((channel[0] == '#'), "privmsg was passed invalid channel: " ~ channel);
        line = "PRIVMSG %s :%s".format(channel, content);
    }
    else if (nickname.length)
    {
        assert((nickname[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
        line = "PRIVMSG %s :%s".format(nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }

    tid.send(ThreadMessage.Throttleline(), line);
}


// emote
/++
 +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
 +/
void emote(Flag!"quiet" quiet = No.quiet)(Tid tid, const string emoteTarget,
    const string content)
{
    import kameloso.string : beginsWith;

    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    event.target.special = quiet;
    event.content = content;

    if (emoteTarget.beginsWith('#'))
    {
        event.channel = emoteTarget;
    }
    else
    {
        event.target.nickname = emoteTarget;
    }

    tid.send(event);
}


// mode
/++
 +  Sets a channel mode.
 +
 +  This includes modes that pertain to a user in the context of a channel,
 +  like bans.
 +/
void mode(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string modes, const string content = string.init)
{
    assert((channel[0] == '#'), "mode was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.MODE;
    event.target.special = quiet;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    tid.send(event);
}


// topic
/++
 +  Sets the topic of a channel.
 +/
void topic(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string content)
{
    assert((channel[0] == '#'), "topic was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    event.target.special = quiet;
    event.channel = channel;
    event.content = content;

    tid.send(event);
}


// invite
/++
 +  Invites a user to a channel.
 +/
void invite(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname)
{
    assert((channel[0] == '#'), "invite was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    event.target.special = quiet;
    event.channel = channel;
    event.target.nickname = nickname;

    tid.send(event);
}


// join
/++
 +  Joins a channel.
 +/
void join(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel)
{
    assert((channel[0] == '#'), "join was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    event.target.special = quiet;
    event.channel = channel;

    tid.send(event);
}


// kick
/++
 +  Kicks a user from a channel.
 +/
void kick(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname, const string reason = string.init)
{
    assert((channel[0] == '#'), "kick was passed invalid channel: " ~ channel);
    assert((nickname[0] != '#'), "kick was passed channel as nickname: " ~ nickname);
    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    event.target.special = quiet;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    tid.send(event);
}


// part
/++
 +  Leaves a channel.
 +/
void part(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel)
{
    assert((channel[0] == '#'), "part was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    event.target.special = quiet;
    event.channel = channel;

    tid.send(event);
}


// quit
/++
 +  Disconnects from the server, optionally with a quit reason.
 +/
void quit(Flag!"quiet" quiet = No.quiet)(Tid tid, const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    event.target.special = quiet;
    event.content = reason;

    tid.send(event);
}


// raw
/++
 +  Sends text to the server, verbatim.
 +
 +  This is used to send messages of types for which there exist no helper
 +  functions.
 +/
void raw(Flag!"quiet" quiet = No.quiet)(Tid tid, const string line)
{
    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    event.target.special = quiet;
    event.content = line;

    tid.send(event);
}

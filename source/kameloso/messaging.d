module kameloso.messaging;

import kameloso.ircdefs;

import std.typecons : Flag, No, Yes;
import std.concurrency : Tid, send;

// chan
/++
+  FIXME
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
+  FIXME
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
+  FIXME
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
        assert((channel[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
        return query!quiet(tid, nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }
}

// throttleline
/++
+  FIXME
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
        assert((channel[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
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
+  FIXME
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

// chanmode
/++
+  FIXME
+/
void chanmode(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string modes, const string content = string.init)
{
    assert((channel[0] == '#'), "chanmode was passed invalid channel: " ~ channel);

    IRCEvent event;
    event.type = IRCEvent.Type.CHANMODE;
    event.target.special = quiet;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    tid.send(event);
}

// usermode
/++
+  FIXME
+/
void usermode(Flag!"quiet" quiet = No.quiet)(Tid tid, const string nickname,
    const string modes)
{
    assert((nickname[0] != '#'), "usermode was passed channel as nickname: " ~ nickname);

    IRCEvent event;
    event.type = IRCEvent.Type.USERMODE;
    event.target.special = quiet;
    event.target.nickname = nickname;
    event.aux = modes;

    tid.send(event);
}

// topic
/++
+  FIXME
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
+  FIXME
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
+  FIXME
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
+  FIXME
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
+  FIXME
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
+  FIXME
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
+  FIXME
+/
void raw(Flag!"quiet" quiet = No.quiet)(Tid tid, const string line)
{
    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    event.target.special = quiet;
    event.content = line;

    tid.send(event);
}

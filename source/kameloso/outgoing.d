module kameloso.outgoing;

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency : Tid, send;
import std.typecons : Flag, No, Yes;


// chan
/++
 +  FIXME
 +/
version(none)
void chan(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string content)
{
    assert((channel[0] == '#'), "chan was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.channel = channel;
    event.content = content;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// query
/++
 +  FIXME
 +/
version(none)
void query(Flag!"quiet" quiet = No.quiet)(Tid tid, const string nickname,
    const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    event.target.nickname = nickname;
    event.content = content;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// privmsg
/++
 +  FIXME
 +/
version(none)
void privmsg(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname, const string content)
{
    if (channel.length)
    {
        assert((channel[0] == '#'), "privmsg was passed invalid channel: " ~ channel);
        static if (quiet) tid.chan(channel, content, true);
        else tid.chan(channel, content);
    }
    else if (nickname.length)
    {
        assert((channel[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
        static if (quiet) tid.query(nickname, content, true);
        else tid.query(nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }
}


// privmsg
/++
 +  FIXME
 +/
version(none)
void throttleline(Tid tid, const string channel, const string nickname,
    const string content, bool quiet = false)
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
version(none)
void emote(Flag!"quiet" quiet = No.quiet)(Tid tid, const string emoteTarget,
    const string content)
{
    import kameloso.string : beginsWith;

    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    event.content = content;

    if (emoteTarget.beginsWith('#'))
    {
        event.channel = emoteTarget;
    }
    else
    {
        event.target.nickname = emoteTarget;
    }

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// chanmode
/++
 +  FIXME
 +/
version(none)
void chanmode(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string modes, const string content = string.init)
{
    assert((channel[0] == '#'), "chanmode was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHANMODE;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// usermode
/++
 +  FIXME
 +/
version(none)
void usermode(Flag!"quiet" quiet = No.quiet)(Tid tid, const string nickname,
    const string modes)
{
    assert((nickname[0] != '#'), "usermode was passed channel as nickname: " ~ nickname);
    IRCEvent event;
    event.type = IRCEvent.Type.USERMODE;
    event.target.nickname = nickname;
    event.aux = modes;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// topic
/++
 +  FIXME
 +/
version(none)
void topic(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string content)
{
    assert((channel[0] == '#'), "topic was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    event.channel = channel;
    event.content = content;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// invite
/++
 +  FIXME
 +/
version(none)
void invite(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname)
{
    assert((channel[0] == '#'), "invite was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    event.channel = channel;
    event.target.nickname = nickname;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// join
/++
 +  FIXME
 +/
version(none)
void join(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel)
{
    assert((channel[0] == '#'), "join was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    event.channel = channel;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// kick
/++
 +  FIXME
 +/
version(none)
void kick(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string nickname, const string reason = string.init)
{
    assert((channel[0] == '#'), "kick was passed invalid channel: " ~ channel);
    assert((nickname[0] != '#'), "kick was passed channel as nickname: " ~ nickname);
    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// part
/++
 +  FIXME
 +/
version(none)
void part(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel)
{
    assert((channel[0] == '#'), "part was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    event.channel = channel;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// quit
/++
 +  FIXME
 +/
version(none)
void quit(Flag!"quiet" quiet = No.quiet)(Tid tid, const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    event.content = reason;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}


// raw
/++
 +  FIXME
 +/
version(none)
void raw(Flag!"quiet" quiet = No.quiet)(Tid tid, const string line)
{
    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    event.content = line;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}

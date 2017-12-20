module kameloso.outgoing;

import kameloso.plugins.common;
import kameloso.ircdefs;

import std.concurrency : Tid, send;
import std.typecons : Flag, No, Yes;


// chan
/++
 +  FIXME
 +/
void chan(Tid tid, const string channel, const string content, bool quiet = false)
{
    assert((channel[0] == '#'), "chan was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.channel = channel;
    event.content = content;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// query
/++
 +  FIXME
 +/
void query(Tid tid, const string nickname, const string content, bool quiet = false)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    event.target.nickname = nickname;
    event.content = content;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// privmsg
/++
 +  FIXME
 +/
void privmsg(Tid tid, const string channel, const string nickname,
    const string content, bool quiet = false)
{
    if (channel.length)
    {
        assert((channel[0] == '#'), "privmsg was passed invalid channel: " ~ channel);
        tid.chan(channel, content, quiet);
    }
    else if (nickname.length)
    {
        assert((channel[0] != '#'), "privmsg was passed a channel for nick: " ~ channel);
        tid.query(nickname, content, quiet);
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
void emote(Tid tid, const string emoteTarget, const string content,
    bool quiet = false)
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

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// chanmode
/++
 +  FIXME
 +/
void chanmode(Tid tid, const string channel, const string modes,
    const string content = string.init, bool quiet = false)
{
    assert((channel[0] == '#'), "chanmode was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHANMODE;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// usermode
/++
 +  FIXME
 +/
void usermode(Tid tid, const string nickname, const string modes, bool quiet = false)
{
    assert((nickname[0] != '#'), "usermode was passed channel as nickname: " ~ nickname);
    IRCEvent event;
    event.type = IRCEvent.Type.USERMODE;
    event.target.nickname = nickname;
    event.aux = modes;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// topic
/++
 +  FIXME
 +/
void topic(Tid tid, const string channel, const string content, bool quiet = false)
{
    assert((channel[0] == '#'), "topic was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    event.channel = channel;
    event.content = content;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// invite
/++
 +  FIXME
 +/
void invite(Tid tid, const string channel, const string nickname, bool quiet = false)
{
    assert((channel[0] == '#'), "invite was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    event.channel = channel;
    event.target.nickname = nickname;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// join
/++
 +  FIXME
 +/
void join(Tid tid, const string channel, bool quiet = false)
{
    assert((channel[0] == '#'), "join was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    event.channel = channel;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// kick
/++
 +  FIXME
 +/
void kick(Tid tid, const string channel, const string nickname,
    const string reason = string.init, bool quiet = false)
{
    assert((channel[0] == '#'), "kick was passed invalid channel: " ~ channel);
    assert((nickname[0] != '#'), "kick was passed channel as nickname: " ~ nickname);
    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// part
/++
 +  FIXME
 +/
void part(Tid tid, const string channel, bool quiet = false)
{
    assert((channel[0] == '#'), "part was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    event.channel = channel;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// quit
/++
 +  FIXME
 +/
void quit(Tid tid, const string reason = string.init, bool quiet = false)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    event.content = reason;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}


// raw
/++
 +  FIXME
 +/
void raw(Tid tid, const string line, bool quiet = false)
{
    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    event.content = line;

    if (quiet) tid.send(event, true);
    else tid.send(event);
}

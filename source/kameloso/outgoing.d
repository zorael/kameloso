module kameloso.outgoing;

import kameloso.plugins.common;
import kameloso.ircdefs;


// chan
/++
 +  FIXME
 +/
void chan(IRCPlugin plugin, const string channel, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.channel = channel;
    event.content = content;

    plugin.state.mainThread.send(event);
}


// query
/++
 +  FIXME
 +/
void query(IRCPlugin plugin, const string nickname, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    event.target.nickname = nickname;
    event.content = content;

    plugin.state.mainThread.send(event);
}


// emote
/++
 +  FIXME
 +/
void emote(IRCPlugin plugin, const string emoteTarget, const string content)
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

    plugin.state.mainThread.send(event);
}


// chanmode
/++
 +  FIXME
 +/
void chanmode(IRCPlugin plugin, const string channel, const string modes,
    const string content = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.CHANMODE;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    plugin.state.mainThread.send(event);
}


// usermode
/++
 +  FIXME
 +/
void usermode(IRCPlugin plugin, const string nickname, const string modes)
{
    IRCEvent event;
    event.type = IRCEvent.Type.USERMODE;
    event.target.nickname = nickname;
    event.aux = modes;

    plugin.state.mainThread.send(event);
}


// topic
/++
 +  FIXME
 +/
void topic(IRCPlugin plugin, const string channel, const string content)
{
    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    event.channel = channel;
    event.content = content;

    plugin.state.mainThread.send(event);
}


// invite
/++
 +  FIXME
 +/
void invite(IRCPlugin plugin, const string channel, const string nickname)
{
    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    event.channel = channel;
    event.target.nickname = nickname;

    plugin.state.mainThread.send(event);
}


// join
/++
 +  FIXME
 +/
void join(IRCPlugin plugin, const string channel)
{
    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    event.channel = channel;

    plugin.state.mainThread.send(event);
}


// kick
/++
 +  FIXME
 +/
void kick(IRCPlugin plugin, const string channel, const string nickname,
    const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    plugin.state.mainThread.send(event);
}


// part
/++
 +  FIXME
 +/
void part(IRCPlugin plugin, const string channel)
{
    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    event.channel = channel;

    plugin.state.mainThread.send(event);
}


// quit
/++
 +  FIXME
 +/
void quit(IRCPlugin plugin, const string reason = string.init)
{
    IRCEvent event;
    event.type = IRCEvent.Type.QUIT;
    event.content = reason;

    plugin.state.mainThread.send(event);
}

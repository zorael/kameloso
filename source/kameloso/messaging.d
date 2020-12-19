/++
    Functions used to send messages to the server.

    To send a server message some information is needed; like
    message type, message target, perhaps channel, content and such.
    [dialect.defs.IRCEvent] has all of this, so it lends itself to repurposing
    it to aggregate and carry them, through concurrency messages. These are caught by the
    concurrency message-reading parts of the main loop, which reversely parses
    them into strings and sends them on to the server.

    Example:
    ---
    //IRCPluginState state;

    chan(state, "#channel", "Hello world!");
    query(state, "nickname", "foo bar");
    mode(state, "#channel", "nickname", "+o");
    topic(state, "#channel", "I thought what I'd do was, I'd pretend I was one of those deaf-mutes.");
    ---

    Having to supply the [kameloso.plugins.common.core.IRCPluginState] on every call
    can be avoided for plugins, by mixing in [kameloso.plugins.common.mixins.MessagingProxy]
    and placing the messaging function calls inside a `with (plugin)` block.

    Example:
    ---
    IRCPluginState state;
    auto plugin = new MyPlugin(state);  // has mixin MessagingProxy;

    with (plugin)
    {
        chan("#channel", "Foo bar baz");
        query("nickname", "hello");
        mode("#channel", string.init, "+b", "dudebro!*@*");
        mode(string.init, "nickname", "+i");
    }
    ---
 +/
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


// Message
/++
    An [dialect.defs.IRCEvent] with some metadata, to be used when crafting an
    outgoing message to the server.
 +/
struct Message
{
    /++
        Properties of a [Message]. Describes how it should be sent.
     +/
    enum Property
    {
        fast        = 1 << 0,  /// Message should be sent faster than normal. (Twitch)
        quiet       = 1 << 1,  /// Message should be sent without echoing it to the terminal.
        background  = 1 << 2,  /// Message should be lazily sent in the background.
        forced      = 1 << 3,  /// Message should bypass some checks.
        priority    = 1 << 4,  /// Message should be given higher priority.
        immediate   = 1 << 5,  /// Message should be sent immediately.
    }

    /++
        The [dialect.defs.IRCEvent] that contains the information we want to send to the server.
     +/
    IRCEvent event;

    /++
        The properties of this message. More than one may be used, with bitwise-or.
     +/
    Property properties;

    /++
        String name of the function that is sending this message, or something
        else that gives context.
     +/
    string caller;
}


// chan
/++
    Sends a channel message.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channelName = Channel in which to send the message.
        content = Message body content to send.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void chan(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channelName, const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channelName.length, "Tried to send a channel message but no channel was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.CHAN;
    m.event.channel = channelName;
    m.event.content = content;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    version(TwitchSupport)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            import std.algorithm.searching : canFind;

            if (state.bot.homeChannels.canFind(channelName))
            {
                // We're in a home channel
                m.properties |= Message.Property.fast;
            }
            /*else if (auto channel = channelName in state.channels)
            {
                if ((*channel).ops.canFind(state.client.nickname))
                {
                    m.properties |= Message.Property.fast;
                }
            }*/
        }
    }

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    chan(state, "#channel", "content", Yes.quiet, Yes.background);

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert(m.properties & Message.Property.fast);
            }
        }
    );
}


// query
/++
    Sends a private query message to a user.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        nickname = Nickname of user to which to send the private message.
        content = Message body content to send.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void query(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string nickname, const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (nickname.length, "Tried to send a private query but no nickname was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.QUERY;
    m.event.target.nickname = nickname;
    m.event.content = content;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    query(state, "kameloso", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
                assert((target.nickname == "kameloso"), target.nickname);
                assert((content == "content"), content);
                assert((m.properties == Message.Property.init));
            }
        }
    );
}


// privmsg
/++
    Sends either a channel message or a private query message depending on
    the arguments passed to it.

    This reflects how channel messages and private messages are both the
    underlying same type; [dialect.defs.IRCEvent.Type.PRIVMSG].

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel in which to send the message, if applicable.
        nickname = Nickname of user to which to send the message, if applicable.
        content = Message body content to send.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void privmsg(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname, const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in ((channel.length || nickname.length), "Tried to send a PRIVMSG but no channel nor nickname was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    if (channel.length)
    {
        return chan!priority(state, channel, content, quiet, background, caller);
    }
    else if (nickname.length)
    {
        return query!priority(state, nickname, content, quiet, background, caller);
    }
    else
    {
        assert(0);//, "Tried to send empty `privmsg` with no channel nor target nickname");
    }
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    privmsg(state, "#channel", string.init, "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert(!target.nickname.length, target.nickname);
                assert(m.properties == Message.Property.init);
            }
        }
    );

    privmsg(state, string.init, "kameloso", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
                assert(!channel.length, channel);
                assert((target.nickname == "kameloso"), target.nickname);
                assert((content == "content"), content);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// emote
/++
    Sends an `ACTION` "emote" to the supplied target (nickname or channel).

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        emoteTarget = Target of the emote, either a nickname to be sent as a
            private message, or a channel.
        content = Message body content to send.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void emote(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string emoteTarget, const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (emoteTarget.length, "Tried to send an emote but no target was given")
{
    static if (priority) import std.concurrency : send = prioritySend;
    import lu.string : contains;

    Message m;

    m.event.type = IRCEvent.Type.EMOTE;
    m.event.content = content;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    if (state.server.chantypes.contains(emoteTarget[0]))
    {
        m.event.channel = emoteTarget;
    }
    else
    {
        m.event.target.nickname = emoteTarget;
    }

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    emote(state, "#channel", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert(!target.nickname.length, target.nickname);
                assert(m.properties == Message.Property.init);
            }
        }
    );

    emote(state, "kameloso", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
                assert(!channel.length, channel);
                assert((target.nickname == "kameloso"), target.nickname);
                assert((content == "content"), content);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// mode
/++
    Sets a channel mode.

    This includes modes that pertain to a user in the context of a channel, like bans.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel to change the modes of.
        modes = Mode characters to apply to the channel.
        content = Target of mode change, if applicable.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void mode(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const const(char)[] modes, const string content = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to set a mode but no channel was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.MODE;
    m.event.channel = channel;
    m.event.aux = modes.idup;
    m.event.content = content;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    mode(state, "#channel", "+o", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.MODE), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert((aux == "+o"), aux);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// topic
/++
    Sets the topic of a channel.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel whose topic to change.
        content = Topic body text.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void topic(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string content,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to set a topic but no channel was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.TOPIC;
    m.event.channel = channel;
    m.event.content = content;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    topic(state, "#channel", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.TOPIC), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// invite
/++
    Invites a user to a channel.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel to which to invite the user.
        nickname = Nickname of user to invite.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void invite(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to send an invite but no channel was given")
in (nickname.length, "Tried to send an invite but no nickname was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.INVITE;
    m.event.channel = channel;
    m.event.target.nickname = nickname;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    invite(state, "#channel", "kameloso");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.INVITE), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((target.nickname == "kameloso"), target.nickname);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// join
/++
    Joins a channel.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel to join.
        key = Channel key to join the channel with, if it's locked.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void join(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string key = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to join a channel but no channel was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.JOIN;
    m.event.channel = channel;
    m.event.aux = key;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    join(state, "#channel");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.JOIN), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// kick
/++
    Kicks a user from a channel.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel from which to kick the user.
        nickname = Nickname of user to kick.
        reason = Optionally the reason behind the kick.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void kick(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname, const string reason = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to kick someone but no channel was given")
in (nickname.length, "Tried to kick someone but no nickname was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.KICK;
    m.event.channel = channel;
    m.event.target.nickname = nickname;
    m.event.content = reason;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    kick(state, "#channel", "kameloso", "content");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.KICK), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "content"), content);
                assert((target.nickname == "kameloso"), target.nickname);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// part
/++
    Leaves a channel.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        channel = Channel to leave.
        reason = Optionally, reason behind leaving.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void part(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string reason = string.init,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to part a channel but no channel was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.PART;
    m.event.channel = channel;
    m.event.content = reason.length ? reason : state.bot.partReason;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    part(state, "#channel", "reason");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.PART), Enum!(IRCEvent.Type).toString(type));
                assert((channel == "#channel"), channel);
                assert((content == "reason"), content);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// quit
/++
    Disconnects from the server, optionally with a quit reason.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
            Default to `Yes.priority`, since we're quitting.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        reason = Optionally, the reason for quitting.
        quiet = Whether or not to echo what was sent to the local terminal.
 +/
void quit(Flag!"priority" priority = Yes.priority)(IRCPluginState state,
    const string reason = string.init, const Flag!"quiet" quiet = No.quiet)
{
    static if (priority) import std.concurrency : send = prioritySend;
    import kameloso.thread : ThreadMessage;

    state.mainThread.send(ThreadMessage.Quit(),
        reason.length ? reason : state.bot.quitReason, cast()quiet);
}

///
unittest
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : MessageMismatch;
    import std.typecons : Tuple;

    IRCPluginState state;
    state.mainThread = thisTid;

    quit(state, "reason");

    try
    {
        receiveOnly!(Tuple!(ThreadMessage.Quit, string, Flag!"quiet"))();
    }
    catch (MessageMismatch e)
    {
        assert(0, "Message mismatch when unit testing `messaging.quit`");
    }
}


// whois
/++
    Queries the server for WHOIS information about a user.

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        nickname = String nickname to query for.
        force = Whether or not to force the WHOIS, skipping any hysteresis queues.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void whois(Flag!"priority" priority = No.priority)(IRCPluginState state, const string nickname,
    const Flag!"force" force = No.force,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
in (nickname.length, caller ~ " tried to WHOIS but no nickname was given")
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.RPL_WHOISACCOUNT;
    m.event.target.nickname = nickname;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (force) m.properties |= Message.Property.forced;
    if (priority) m.properties |= Message.Property.priority;

    version(TraceWhois)
    {
        import std.stdio : writefln;
        writefln("[TraceWhois] messaging.whois caught request to WHOIS \"%s\" " ~
            "from %s (priority:%s force:%s, quiet:%s, background:%s)",
            nickname, caller, cast(bool)priority, force, quiet, background);
    }

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    whois(state, "kameloso", Yes.force);

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), Enum!(IRCEvent.Type).toString(type));
                assert((target.nickname == "kameloso"), target.nickname);
                assert(m.properties & Message.Property.forced);
            }
        }
    );
}


// raw
/++
    Sends text to the server, verbatim.

    This is used to send messages of types for which there exist no helper functions.

    See_Also:
        [immediate]

    Params:
        priority = Whether or not to send the message as a priority message,
            received before other messages are, if there are several.
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        line = Raw IRC string to send to the server.
        quiet = Whether or not to echo what was sent to the local terminal.
        background = Whether or not to send it as a low-priority background message.
        caller = String name of the calling function, or something else that gives context.
 +/
void raw(Flag!"priority" priority = No.priority)(IRCPluginState state, const string line,
    const Flag!"quiet" quiet = No.quiet,
    const Flag!"background" background = No.background,
    const string caller = __FUNCTION__)
{
    static if (priority) import std.concurrency : send = prioritySend;

    Message m;

    m.event.type = IRCEvent.Type.UNSET;
    m.event.content = line;
    m.caller = caller;

    if (quiet) m.properties |= Message.Property.quiet;
    if (background) m.properties |= Message.Property.background;
    if (priority) m.properties |= Message.Property.priority;

    state.mainThread.send(m);
}

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    raw(state, "commands");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.UNSET), Enum!(IRCEvent.Type).toString(type));
                assert((content == "commands"), content);
                assert(m.properties == Message.Property.init);
            }
        }
    );
}


// immediate
/++
    Immediately sends text to the server, verbatim. Skips all queues.

    This is used to send messages of types for which there exist no helper
    functions, and where they must be sent at once.

    See_Also:
        [raw]

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState], via
            which to send messages to the server.
        line = Raw IRC string to send to the server.
        quiet = Whether or not to echo what was sent to the local terminal.
        caller = String name of the calling function, or something else that gives context.
 +/
void immediate(IRCPluginState state, const string line,
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

///
unittest
{
    IRCPluginState state;
    state.mainThread = thisTid;

    immediate(state, "commands");

    receive(
        (Message m)
        {
            with (m.event)
            {
                assert((type == IRCEvent.Type.UNSET), Enum!(IRCEvent.Type).toString(type));
                assert((content == "commands"), content);
                assert(m.properties & Message.Property.immediate);
            }
        }
    );
}

/// Merely an alias to [immediate], because we use both terms at different places.
alias immediateline = immediate;


// askToOutputImpl
/++
    Sends a concurrency message asking to print the supplied text to the local
    terminal, instead of doing it directly.

    Params:
        logLevel = The [std.experimental.logging.LogLevel] at which to log the message.
        state = Current [kameloso.plugins.common.core.IRCPluginState], used to send
            the concurrency message to the main thread.
        line = The text body to ask the main thread to display.
 +/
void askToOutputImpl(string logLevel)(IRCPluginState state, const string line)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;
    mixin("state.mainThread.prioritySend(ThreadMessage.TerminalOutput." ~ logLevel ~ ", line);");
}

/// Sends a concurrency message to the main thread asking to print text to the local terminal.
alias askToWriteln = askToOutputImpl!"writeln";
/// Sends a concurrency message to the main thread to `logger.trace` text to the local terminal.
alias askToTrace = askToOutputImpl!"trace";
/// Sends a concurrency message to the main thread to `logger.log` text to the local terminal.
alias askToLog = askToOutputImpl!"log";
/// Sends a concurrency message to the main thread to `logger.info` text to the local terminal.
alias askToInfo = askToOutputImpl!"info";
/// Sends a concurrency message to the main thread to `logger.warning` text to the local terminal.
alias askToWarn = askToOutputImpl!"warning";
/// Simple alias to [askToWarn], because both spellings are right.
alias askToWarning = askToWarn;
/// Sends a concurrency message to the main thread to `logger.error` text to the local terminal.
alias askToError = askToOutputImpl!"error";

unittest
{
    import kameloso.thread : ThreadMessage;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.askToWriteln("writeln");
    state.askToTrace("trace");
    state.askToLog("log");
    state.askToInfo("info");
    state.askToWarn("warning");
    state.askToError("error");

    alias T = ThreadMessage.TerminalOutput;

    static immutable T[6] expectedLevels =
    [
        T.writeln,
        T.trace,
        T.log,
        T.info,
        T.warning,
        T.error,
    ];

    static immutable string[6] expectedMessages =
    [
        "writeln",
        "trace",
        "log",
        "info",
        "warning",
        "error",
    ];

    static assert(expectedLevels.length == expectedMessages.length);

    foreach (immutable i; 0..expectedMessages.length)
    {
        import std.concurrency : receiveTimeout;
        import std.conv : text;
        import std.variant : Variant;
        import core.time : seconds;

        receiveTimeout((-1).seconds,
            (ThreadMessage.TerminalOutput logLevel, string message)
            {
                assert((logLevel == expectedLevels[i]), logLevel.text);
                assert((message == expectedMessages[i]), message.text);
            },
            (Variant v)
            {
                assert(0, "Receive loop test in `messaging.d` failed.");
            }
        );
    }
}

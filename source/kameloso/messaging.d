/++
 +  Functions used to send messages to the server.
 +
 +  It does this by crafting `kameloso.irc.defs.IRCEvent`s from the passed
 +  arguments, then sends it to the concurrency message-reading parts of the
 +  main loop, which formats them into strings and sends them to the server.
 +/
module kameloso.messaging;

import kameloso.irc.defs;
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
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel in which to send the message.
 +      content = Message body content to send.
 +/
void chan(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string content)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.chan("#channel", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
    }
}


// query
/++
 +  Sends a private query message to a user.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      nickname = Nickname of user to which to send the private message.
 +      content = Message body content to send.
 +/
void query(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string nickname, const string content)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.QUERY;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.target.nickname = nickname;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.query("kameloso", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
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
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel in which to send the message, if applicable.
 +      nickname = Nickname of user to which to send the message, if applicable.
 +      content = Message body content to send.
 +/
void privmsg(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string nickname, const string content)
{
    static if (priority) import std.concurrency : send = prioritySend;

    if (channel.length)
    {
        return chan!quiet(state, channel, content);
    }
    else if (nickname.length)
    {
        return query!quiet(state, nickname, content);
    }
    else
    {
        assert(0, "Empty privmsg");
    }
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.privmsg("#channel", string.init, "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    state.privmsg(string.init, "kameloso", "content");

    immutable event2 = receiveOnly!IRCEvent;
    with (event2)
    {
        assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
        assert(!channel.length, channel);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "content"), content);
    }
}


// emote
/++
 +  Sends an `ACTION` "emote" to the supplied target (nickname or channel).
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      emoteTarget = Target of the emote, either a nickname to be sent as a
 +          private message, or a channel.
 +      content = Message body content to send.
 +/
void emote(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string emoteTarget, const string content)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.content = content;

    if (emoteTarget.beginsWithOneOf(state.client.server.chantypes))
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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.emote("#channel", "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    state.emote("kameloso", "content");

    immutable event2 = receiveOnly!IRCEvent;
    with (event2)
    {
        assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
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
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to change the modes of.
 +      modes = Mode characters to apply to the channel.
 +      content = Target of mode change, if applicable.
 +/
void mode(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string modes, const string content = string.init)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.MODE;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.aux = modes;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.mode("#channel", "+o", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.MODE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((aux == "+o"), aux);
    }
}


// topic
/++
 +  Sets the topic of a channel.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel whose topic to change.
 +      content = Topic body text.
 +/
void topic(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string content)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.TOPIC;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = content;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.topic("#channel", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.TOPIC), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
    }
}


// invite
/++
 +  Invites a user to a channel.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to which to invite the user.
 +      nickname = Nickname of user to invite.
 +/
void invite(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string nickname)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.INVITE;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.target.nickname = nickname;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.invite("#channel", "kameloso");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.INVITE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((target.nickname == "kameloso"), target.nickname);
    }
}


// join
/++
 +  Joins a channel.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to join.
 +/
void join(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.join("#channel");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.JOIN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
    }
}


// kick
/++
 +  Kicks a user from a channel.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel from which to kick the user.
 +      nickname = Nickname of user to kick.
 +      reason = Optionally the reason behind the kick.
 +/
void kick(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string nickname, const string reason = string.init)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.KICK;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.target.nickname = nickname;
    event.content = reason;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.kick("#channel", "kameloso", "content");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.KICK), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((target.nickname == "kameloso"), target.nickname);
    }
}


// part
/++
 +  Leaves a channel.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to leave.
 +      reason = Optionally, reason behind leaving.
 +/
void part(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string channel, const string reason = string.init)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.PART;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.content = reason;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.part("#channel", "reason");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.PART), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "reason"), content);
    }
}


// quit
/++
 +  Disconnects from the server, optionally with a quit reason.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server. Default to `Yes.priority`, since we're quitting.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      reason = Optionally, the reason for quitting.
 +/
void quit(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = Yes.priority)
    (IRCPluginState state, const string reason = string.init)
{
    static if (priority) import std.concurrency : send = prioritySend;

    import kameloso.thread : ThreadMessage;
    state.mainThread.send(ThreadMessage.Quit(), reason);
}

///
unittest
{
    import kameloso.conv : Enum;
    IRCPluginState state;
    state.mainThread = thisTid;

    state.quit("reason");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.QUIT), Enum!(IRCEvent.Type).toString(type));
        assert((content == "reason"), content);
    }
}


// raw
/++
 +  Sends text to the server, verbatim.
 +
 +  This is used to send messages of types for which there exist no helper
 +  functions.
 +
 +  Params:
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      line = Raw IRC string to send to the server.
 +/
void raw(Flag!"quiet" quiet = No.quiet, Flag!"priority" priority = No.priority)
    (IRCPluginState state, const string line)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    static if (quiet) event.target.class_ = IRCUser.Class.special;
    event.content = line;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    state.raw("commands");

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.UNSET), Enum!(IRCEvent.Type).toString(type));
        assert((content == "commands"), content);
    }
}


// askToLogImpl
/++
 +  Sends a concurrency message asking to print the supplied text to the local
 +  terminal, instead of doing it directly.
 +
 +  Params:
 +      state = Current `kameloso.plugins.common.IRCPluginState`, used to send
 +          the concurrency message to the main thread.
 +      line = The text body to ask the main thread to display.
 +/
void askToLogImpl(string logLevel)(IRCPluginState state, const string line)
{
    import kameloso.thread : ThreadMessage;
    import std.concurrency : prioritySend;
    mixin("state.mainThread.prioritySend(ThreadMessage.TerminalOutput." ~ logLevel ~ ", line);");
}

/// Sends a concurrency message to the main thread asking to print text to the local terminal.
alias askToWriteln = askToLogImpl!"writeln";
/// Sends a concurrency message to the main thread to `logger.trace` text to the local terminal.
alias askToTrace = askToLogImpl!"trace";
/// Sends a concurrency message to the main thread to `logger.log` text to the local terminal.
alias askToLog = askToLogImpl!"log";
/// Sends a concurrency message to the main thread to `logger.info` text to the local terminal.
alias askToInfo = askToLogImpl!"info";
/// Sends a concurrency message to the main thread to `logger.warning` text to the local terminal.
alias askToWarn = askToLogImpl!"warning";
/// Simple alias to `askToWarn`, because both spellings are right.
alias askToWarning = askToWarn;
/// Sends a concurrency message to the main thread to `logger.error` text to the local terminal.
alias askToError = askToLogImpl!"error";

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
        import core.time : seconds;
        import std.concurrency : receiveTimeout;
        import std.conv : text;
        import std.variant : Variant;

        receiveTimeout(0.seconds,
            (ThreadMessage.TerminalOutput logLevel, string message)
            {
                assert((logLevel == expectedLevels[i]), logLevel.text);
                assert((message == expectedMessages[i]), message.text);
            },
            (Variant v)
            {
                assert(0, "Receive loop test in messaging.d failed.");
            }
        );
    }
}

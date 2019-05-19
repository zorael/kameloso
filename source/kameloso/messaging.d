/++
 +  Functions used to send messages to the server.
 +
 +  It does this by crafting `kameloso.irc.defs.IRCEvent`s from the passed
 +  arguments, then sends it to the concurrency message-reading parts of the
 +  main loop, which formats them into strings and sends them to the server.
 +/
module kameloso.messaging;

import kameloso.irc.defs;
import kameloso.common : settings;
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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel in which to send the message.
 +      content = Message body content to send.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void chan(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string content, bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    chan(state, "#channel", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      nickname = Nickname of user to which to send the private message.
 +      content = Message body content to send.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void query(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string nickname, const string content, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    query(state, "kameloso", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel in which to send the message, if applicable.
 +      nickname = Nickname of user to which to send the message, if applicable.
 +      content = Message body content to send.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void privmsg(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname, const string content, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    if (channel.length)
    {
        return chan!priority(state, channel, content, quiet);
    }
    else if (nickname.length)
    {
        return query!priority(state, nickname, content, quiet);
    }
    else
    {
        assert(0, "Tried to send empty privmsg with no channel nor target nickname");
    }
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    privmsg(state, "#channel", string.init, "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    privmsg(state, string.init, "kameloso", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      emoteTarget = Target of the emote, either a nickname to be sent as a
 +          private message, or a channel.
 +      content = Message body content to send.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void emote(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string emoteTarget, const string content, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.EMOTE;
    if (quiet) event.target.class_ = IRCUser.Class.special;
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

    emote(state, "#channel", "content");

    immutable event1 = receiveOnly!IRCEvent;
    with (event1)
    {
        assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(!target.nickname.length, target.nickname);
    }

    emote(state, "kameloso", "content");

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
 +  This includes modes that pertain to a user in the context of a channel, like bans.
 +
 +  Params:
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to change the modes of.
 +      modes = Mode characters to apply to the channel.
 +      content = Target of mode change, if applicable.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void mode(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string modes, const string content = string.init,
    const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    mode(state, "#channel", "+o", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel whose topic to change.
 +      content = Topic body text.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void topic(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string content, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    topic(state, "#channel", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to which to invite the user.
 +      nickname = Nickname of user to invite.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void invite(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    invite(state, "#channel", "kameloso");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to join.
 +      key = Channel key to join the channel with, if it's locked.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void join(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string key = string.init,
    const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.JOIN;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.channel = channel;
    event.aux = key;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    join(state, "#channel");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel from which to kick the user.
 +      nickname = Nickname of user to kick.
 +      reason = Optionally the reason behind the kick.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void kick(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string nickname, const string reason = string.init,
    const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    kick(state, "#channel", "kameloso", "content");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      channel = Channel to leave.
 +      reason = Optionally, reason behind leaving.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void part(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string channel, const string reason = string.init, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

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
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    part(state, "#channel", "reason");

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
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server. Default to `Yes.priority`, since we're quitting.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      reason = Optionally, the reason for quitting.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void quit(Flag!"priority" priority = Yes.priority)(IRCPluginState state,
    const string reason = string.init, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    import kameloso.thread : ThreadMessage;
    state.mainThread.send(ThreadMessage.Quit(), reason, cast()quiet);
}

///
unittest
{
    import kameloso.conv : Enum;
    import kameloso.thread : ThreadMessage;
    import std.concurrency : MessageMismatch;
    import std.typecons : Tuple;

    IRCPluginState state;
    state.mainThread = thisTid;

    quit(state, "reason");

    try
    {
        receiveOnly!(Tuple!(ThreadMessage.Quit, string, bool))();
    }
    catch (MessageMismatch e)
    {
        assert(0, "Message mismatch when unit testing messaging.quit");
    }
}


// whois
/++
 +  Queries the server for WHOIS information about a user.
 +
 +  Params:
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      nickname = String nickname to query for.
 +      force = Whether or not to force the WHOIS, skipping any hysteresis queues.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void whois(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string nickname, const bool force = false, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.RPL_WHOISACCOUNT;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.target.nickname = nickname;
    if (force) event.num = 1;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    whois(state, "kameloso", true);

    immutable event = receiveOnly!IRCEvent;
    with (event)
    {
        assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "kameloso"), target.nickname);
        assert(num > 0);
    }
}


// raw
/++
 +  Sends text to the server, verbatim.
 +
 +  This is used to send messages of types for which there exist no helper functions.
 +
 +  Params:
 +      priority = Whether or not to send the message as a priority message,
 +          skipping messages in the threshold queue and immediately sending it
 +          to the server.
 +      state = Current plugin's `kameloso.plugins.common.IRCPluginState`, via
 +          which to send messages to the server.
 +      line = Raw IRC string to send to the server.
 +      quiet = Whether or not to echo what was sent to the local terminal.
 +/
void raw(Flag!"priority" priority = No.priority)(IRCPluginState state,
    const string line, const bool quiet = settings.hideOutgoing)
{
    static if (priority) import std.concurrency : send = prioritySend;

    IRCEvent event;
    event.type = IRCEvent.Type.UNSET;
    if (quiet) event.target.class_ = IRCUser.Class.special;
    event.content = line;

    state.mainThread.send(event);
}

///
unittest
{
    import kameloso.conv : Enum;

    IRCPluginState state;
    state.mainThread = thisTid;

    raw(state, "commands");

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
 +      logLevel = The `std.experimental.logging.LogLevel` at which to log the message.
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

/++
    Functions used to send messages to the server.

    To send a server message some information is needed; like
    message type, message target, perhaps channel, content and such.
    [dialect.defs.IRCEvent|IRCEvent] has all of this, so it lends itself to
    repurposing it to aggregate and carry them, through message structs in an array "queue".
    These are caught by the main loop, which reversely parses them into strings
    and sends them on to the server.

    Example:
    ---
    //IRCPluginState state;

    chan(state, "#channel", "Hello world!");
    query(state, "nickname", "foo bar");
    mode(state, "#channel", "nickname", "+o");
    topic(state, "#channel", "I thought what I'd do was, I'd pretend I was one of those deaf-mutes.");
    ---

    Having to supply the [kameloso.plugins.common.core.IRCPluginState|IRCPluginState]
    on every call can be avoided for plugins, by mixing in
    [kameloso.plugins.common.mixins.MessagingProxy|MessagingProxy]
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

    See_Also:
        [kameloso.thread]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.messaging;

private:

import kameloso.plugins.common.core : IRCPluginState;
import kameloso.irccolours : expandIRCTags, stripIRCTags;
import dialect.defs;
import std.typecons : Flag, No, Yes;
static import kameloso.common;

version(unittest) import lu.conv : Enum;

public:


// Message
/++
    An [dialect.defs.IRCEvent|IRCEvent] with some metadata, to be used when
    crafting an outgoing message to the server.
 +/
struct Message
{
    /++
        Properties of a [Message]. Describes how it should be sent.
     +/
    enum Property
    {
        none        = 1 << 0,  /// Unset value.
        fast        = 1 << 1,  /// Message should be sent faster than normal. (Twitch)
        quiet       = 1 << 2,  /// Message should be sent without echoing it to the terminal.
        background  = 1 << 3,  /// Message should be lazily sent in the background.
        forced      = 1 << 4,  /// Message should bypass some checks.
        priority    = 1 << 5,  /// Message should be given higher priority.
        immediate   = 1 << 6,  /// Message should be sent immediately.
    }

    /++
        The [dialect.defs.IRCEvent|IRCEvent] that contains the information we
        want to send to the server.
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

    /++
        Whether this message has been sent to the server yet.
     +/
    bool exhausted;
}


// chan
/++
    Sends a channel message.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channelName = Channel in which to send the message.
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void chan(
    ref IRCPluginState state,
    const string channelName,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channelName.length, "Tried to send a channel message but no channel was given")
{
    Message m;

    m.event.type = IRCEvent.Type.CHAN;
    m.event.channel = channelName;
    m.properties = properties;
    m.caller = caller;

    bool strippedTags;

    version(TwitchSupport)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            m.event.content = content.stripIRCTags;
            strippedTags = true;

            if (auto channel = channelName in state.channels)
            {
                if (auto ops = 'o' in channel.mods)
                {
                    if (state.client.nickname in *ops)
                    {
                        // We are a moderator and can as such send things fast
                        m.properties |= Message.Property.fast;
                    }
                }
            }
        }
    }

    if (!strippedTags) m.event.content = content.expandIRCTags;
    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    enum properties = (Message.Property.quiet | Message.Property.background);
    chan(state, "#channel", "content", properties);

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        //assert(m.properties & Message.Property.fast);
    }
}


// reply
/++
    Replies to a message in a Twitch channel. Requires version `TwitchSupport`,
    without which it will just pass on to [chan].

    If an [dialect.defs.IRCEvent|IRCEvent] of type [dialect.defs.IRCEvent.Type.QUERY|QUERY]
    is passed *and* we're connected to a Twitch server *and* the
    [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin] is compiled in,
    it will send a bus message to have the reply be sent as a whisper instead.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        event = Original event, to which we're replying.
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void reply(
    ref IRCPluginState state,
    const ref IRCEvent event,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (event.channel.length, "Tried to reply to a channel message but no channel was given")
{
    /++
        Just pass it onto [privmsg].
     +/
    void sendNormally()
    {
        privmsg(
            state,
            event.channel,
            event.sender.nickname,
            content,
            properties,
            caller);
    }

    version(TwitchSupport)
    {
        import kameloso.common : logger;
        import lu.conv : Enum;

        if (state.server.daemon != IRCServer.Daemon.twitch) return sendNormally();

        version(WithTwitchPlugin)
        {
            if (event.type == IRCEvent.Type.QUERY)
            {
                import kameloso.thread : ThreadMessage, boxed;

                // Whisper
                Message m;

                m.event.type = IRCEvent.Type.QUERY;
                m.event.content = content.stripIRCTags;
                m.event.target = event.sender;
                m.caller = caller;

                auto messageBox = (properties & Message.Property.priority) ?
                    &state.priorityMessages :
                    &state.messages;

                *messageBox ~= ThreadMessage.busMessage("twitch", boxed(m));
                return;
            }
        }

        if (event.type == IRCEvent.Type.CHAN)
        {
            // Channel reply
            Message m;

            m.event.type = IRCEvent.Type.CHAN;
            m.event.channel = event.channel;
            m.event.content = content.stripIRCTags;
            m.event.tags = "reply-parent-msg-id=" ~ event.id;
            m.properties = properties;
            m.caller = caller;

            if (auto channel = m.event.channel in state.channels)
            {
                if (auto ops = 'o' in channel.mods)
                {
                    if (state.client.nickname in *ops)
                    {
                        // We are a moderator and can as such send things fast
                        m.properties |= Message.Property.fast;
                    }
                }
            }

            state.outgoingMessages ~= m;
        }
        else if (event.type == IRCEvent.Type.QUERY)
        {
            // non-version WithTwitchPlugin
            enum message = "Tried to <l>reply</> in a query but the <l>twitch</> plugin is not compiled in";
            logger.error(message);
        }
        else
        {
            enum pattern = "Tried to <l>reply</> to an event of an unsupported type: <l>%s";
            logger.errorf(pattern, Enum!(IRCEvent.Type).toString(event.type));
        }
    }
    else
    {
        sendNormally();
    }
}

///
version(TwitchSupport)
unittest
{
    IRCPluginState state;
    state.server.daemon = IRCServer.Daemon.twitch;

    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.sender.nickname = "kameloso";
    event.channel = "#channel";
    event.content = "content";
    event.id = "some-reply-id";

    reply(state, event, "reply content");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((content == "reply content"), content);
        assert((tags == "reply-parent-msg-id=some-reply-id"), tags);
        assert((m.properties == Message.Property.init));
    }
}


// query
/++
    Sends a private query message to a user.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        nickname = Nickname of user to which to send the private message.
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void query(
    ref IRCPluginState state,
    const string nickname,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (nickname.length, "Tried to send a private query but no nickname was given")
{
    Message m;

    m.event.type = IRCEvent.Type.QUERY;
    m.event.target.nickname = nickname;
    m.properties = properties;
    m.caller = caller;

    bool strippedTags;

    version(TwitchSupport)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            m.event.content = content.stripIRCTags;
            strippedTags = true;
        }
    }

    if (!strippedTags) m.event.content = content.expandIRCTags;
    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    query(state, "kameloso", "content");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "content"), content);
        assert((m.properties == Message.Property.init));
    }
}


// privmsg
/++
    Sends either a channel message or a private query message depending on
    the arguments passed to it.

    This reflects how channel messages and private messages are both the
    underlying same type; [dialect.defs.IRCEvent.Type.PRIVMSG|PRIVMSG].

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel in which to send the message, if applicable.
        nickname = Nickname of user to which to send the message, if applicable.
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void privmsg(
    ref IRCPluginState state,
    const string channel,
    const string nickname,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in ((channel.length || nickname.length), "Tried to send a PRIVMSG but no channel nor nickname was given")
{
    immutable expandedContent = content.expandIRCTags;

    if (channel.length)
    {
        return chan(state, channel, expandedContent, properties, caller);
    }
    else if (nickname.length)
    {
        return query(state, nickname, expandedContent, properties, caller);
    }
    else
    {
        // In case contracts are disabled?
        assert(0, "Tried to send a PRIVMSG but no channel nor nickname was given");
    }
}

///
unittest
{
    IRCPluginState state;

    {
        privmsg(state, "#channel", string.init, "content");

        immutable m = state.outgoingMessages.data[0];
        with (m.event)
        {
            assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
            assert((channel == "#channel"), channel);
            assert((content == "content"), content);
            assert(!target.nickname.length, target.nickname);
            assert(m.properties == Message.Property.init);
        }

        state.outgoingMessages.clear();
    }
    {
        privmsg(state, string.init, "kameloso", "content");

        immutable m = state.outgoingMessages.data[0];
        with (m.event)
        {
            assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type));
            assert(!channel.length, channel);
            assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "content"), content);
            assert(m.properties == Message.Property.init);
        }
    }
}


// emote
/++
    Sends an `ACTION` "emote" to the supplied target (nickname or channel).

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        emoteTarget = Target of the emote, either a nickname to be sent as a
            private message, or a channel.
        content = Message body content to send.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void emote(
    ref IRCPluginState state,
    const string emoteTarget,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (emoteTarget.length, "Tried to send an emote but no target was given")
{
    import std.string : indexOf;

    Message m;

    m.event.type = IRCEvent.Type.EMOTE;
    m.properties = properties;
    m.caller = caller;

    if (state.server.chantypes.indexOf(emoteTarget[0]) != -1)
    {
        m.event.channel = emoteTarget;
    }
    else
    {
        m.event.target.nickname = emoteTarget;
    }

    bool strippedTags;

    version(TwitchSupport)
    {
        if (state.server.daemon == IRCServer.Daemon.twitch)
        {
            m.event.content = content.stripIRCTags;
            strippedTags = true;
        }
    }

    if (!strippedTags) m.event.content = content.expandIRCTags;
    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    {
        emote(state, "#channel", "content");

        immutable m = state.outgoingMessages.data[0];
        with (m.event)
        {
            assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
            assert((channel == "#channel"), channel);
            assert((content == "content"), content);
            assert(!target.nickname.length, target.nickname);
            assert(m.properties == Message.Property.init);
        }

        state.outgoingMessages.clear();
    }
    {
        emote(state, "kameloso", "content");

        immutable m = state.outgoingMessages.data[0];
        with (m.event)
        {
            assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
            assert(!channel.length, channel);
            assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "content"), content);
            assert(m.properties == Message.Property.init);
        }
    }
}


// mode
/++
    Sets a channel mode.

    This includes modes that pertain to a user in the context of a channel, like bans.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel to change the modes of.
        modes = Mode characters to apply to the channel.
        content = Target of mode change, if applicable.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void mode(
    ref IRCPluginState state,
    const string channel,
    const const(char)[] modes,
    const string content = string.init,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to set a mode but no channel was given")
{
    Message m;

    m.event.type = IRCEvent.Type.MODE;
    m.event.channel = channel;
    m.event.aux[0] = modes.idup;
    m.event.content = content.expandIRCTags;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    mode(state, "#channel", "+o", "content");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.MODE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((aux[0] == "+o"), aux[0]);
        assert(m.properties == Message.Property.init);
    }
}


// topic
/++
    Sets the topic of a channel.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel whose topic to change.
        content = Topic body text.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void topic(
    ref IRCPluginState state,
    const string channel,
    const string content,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to set a topic but no channel was given")
{
    Message m;

    m.event.type = IRCEvent.Type.TOPIC;
    m.event.channel = channel;
    m.event.content = content.expandIRCTags;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    topic(state, "#channel", "content");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.TOPIC), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert(m.properties == Message.Property.init);
    }
}


// invite
/++
    Invites a user to a channel.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel to which to invite the user.
        nickname = Nickname of user to invite.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void invite(
    ref IRCPluginState state,
    const string channel,
    const string nickname,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to send an invite but no channel was given")
in (nickname.length, "Tried to send an invite but no nickname was given")
{
    Message m;

    m.event.type = IRCEvent.Type.INVITE;
    m.event.channel = channel;
    m.event.target.nickname = nickname;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    invite(state, "#channel", "kameloso");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.INVITE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((target.nickname == "kameloso"), target.nickname);
        assert(m.properties == Message.Property.init);
    }
}


// join
/++
    Joins a channel.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel to join.
        key = Channel key to join the channel with, if it's locked.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void join(
    ref IRCPluginState state,
    const string channel,
    const string key = string.init,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to join a channel but no channel was given")
{
    Message m;

    m.event.type = IRCEvent.Type.JOIN;
    m.event.channel = channel;
    m.event.aux[0] = key;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    join(state, "#channel");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.JOIN), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert(m.properties == Message.Property.init);
    }
}


// kick
/++
    Kicks a user from a channel.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel from which to kick the user.
        nickname = Nickname of user to kick.
        reason = Optionally the reason behind the kick.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void kick(
    ref IRCPluginState state,
    const string channel,
    const string nickname,
    const string reason = string.init,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to kick someone but no channel was given")
in (nickname.length, "Tried to kick someone but no nickname was given")
{
    Message m;

    m.event.type = IRCEvent.Type.KICK;
    m.event.channel = channel;
    m.event.target.nickname = nickname;
    m.event.content = reason.expandIRCTags;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    kick(state, "#channel", "kameloso", "content");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.KICK), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "content"), content);
        assert((target.nickname == "kameloso"), target.nickname);
        assert(m.properties == Message.Property.init);
    }
}


// part
/++
    Leaves a channel.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        channel = Channel to leave.
        reason = Optionally, reason behind leaving.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void part(
    ref IRCPluginState state,
    const string channel,
    const string reason = string.init,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (channel.length, "Tried to part a channel but no channel was given")
{
    Message m;

    m.event.type = IRCEvent.Type.PART;
    m.event.channel = channel;
    m.event.content = reason.length ? reason.expandIRCTags : state.bot.partReason;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    part(state, "#channel", "reason");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.PART), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#channel"), channel);
        assert((content == "reason"), content);
        assert(m.properties == Message.Property.init);
    }
}


// quit
/++
    Disconnects from the server, optionally with a quit reason.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        reason = Optionally, the reason for quitting.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/

void quit(
    ref IRCPluginState state,
    const string reason = string.init,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
{
    Message m;

    m.event.type = IRCEvent.Type.QUIT;
    m.event.content = reason.length ? reason : state.bot.quitReason;
    m.caller = caller;
    m.properties = (properties | Message.Property.priority);

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    enum properties = Message.Property.quiet;
    quit(state, "reason", properties);

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.QUIT), Enum!(IRCEvent.Type).toString(type));
        assert((content == "reason"), content);
        assert(m.caller.length);
        assert(m.properties & (Message.Property.forced | Message.Property.priority | Message.Property.quiet));
    }
}


// whois
/++
    Queries the server for WHOIS information about a user.

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        nickname = String nickname to query for.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void whois(
    ref IRCPluginState state,
    const string nickname,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
in (nickname.length, caller ~ " tried to WHOIS but no nickname was given")
{
    Message m;

    m.event.type = IRCEvent.Type.RPL_WHOISACCOUNT;
    m.event.target.nickname = nickname;
    m.properties = properties;
    m.caller = caller;

    version(unittest) {}
    else version(TraceWhois)
    {
        import std.stdio : stdout, writefln;
        enum pattern = "[TraceWhois] messaging.whois caught request to WHOIS \"%s\" " ~
            "from %s (priority:%s force:%s, quiet:%s, background:%s)";
        writefln(
            pattern,
            nickname,
            caller,
            cast(bool)(properties & Message.Property.priority),
            cast(bool)(properties & Message.Property.forced),
            cast(bool)(properties & Message.Property.quiet),
            cast(bool)(properties & Message.Property.background));
        if (state.settings.flush) stdout.flush();
    }

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    enum properties = Message.Property.forced;
    whois(state, "kameloso", properties);

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "kameloso"), target.nickname);
        assert(m.properties & Message.Property.forced);
    }
}


// raw
/++
    Sends text to the server, verbatim.

    This is used to send messages of types for which there exist no helper functions.

    See_Also:
        [immediate]

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        line = Raw IRC string to send to the server.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void raw(
    ref IRCPluginState state,
    const string line,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
{
    Message m;

    m.event.type = IRCEvent.Type.UNSET;
    m.event.content = line.expandIRCTags;
    m.properties = properties;
    m.caller = caller;

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    raw(state, "commands");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.UNSET), Enum!(IRCEvent.Type).toString(type));
        assert((content == "commands"), content);
        assert(m.properties == Message.Property.init);
    }
}


// immediate
/++
    Immediately sends text to the server, verbatim. Skips all queues.

    This is used to send messages of types for which there exist no helper
    functions, and where they must be sent at once.

    See_Also:
        [raw]

    Params:
        state = The current plugin's [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            via which to send messages to the server.
        line = Raw IRC string to send to the server.
        properties = Custom message properties, such as [Message.Property.quiet]
            and [Message.Property.forced].
        caller = String name of the calling function, or something else that gives context.
 +/
void immediate(
    ref IRCPluginState state,
    const string line,
    const Message.Property properties = Message.Property.none,
    const string caller = __FUNCTION__)
{
    Message m;

    m.event.type = IRCEvent.Type.UNSET;
    m.event.content = line.expandIRCTags;
    m.caller = caller;
    m.properties = (properties | Message.Property.immediate);

    state.outgoingMessages ~= m;
}

///
unittest
{
    IRCPluginState state;

    immediate(state, "commands");

    immutable m = state.outgoingMessages.data[0];
    with (m.event)
    {
        assert((type == IRCEvent.Type.UNSET), Enum!(IRCEvent.Type).toString(type));
        assert((content == "commands"), content);
        assert(m.properties & Message.Property.immediate);
    }
}

/++
    Merely an alias to [immediate], because we use both terms at different places.
 +/
alias immediateline = immediate;


// askToOutputImpl
/++
    Sends a message asking to print the supplied text to the local
    terminal, instead of doing it directly.

    Params:
        askVerb = An `askToX` string verb where `X` corresponds to the
            [kameloso.logger.LogLevel|LogLevel] at which to log the message.
        state = Current [kameloso.plugins.common.core.IRCPluginState|IRCPluginState],
            used for its [kameloso.plugins.common.core.IRCPluginState.messages|messages] array.
        line = The text body to ask the main thread to display.
 +/
void askToOutputImpl(string askVerb)(IRCPluginState state, const string line)
{
    import kameloso.thread : ThreadMessage;
    mixin("state.messages ~= ThreadMessage(ThreadMessage.MessageType." ~ askVerb ~ ", line);");
}


/+
    Generate `askToLevel` family of functions at compile-time, provided the compiler
    is recent enough to support it. Too old compilers fail at resolving the "static"
    [askToWarn] alias.

    For older compilers, just provide the handwritten aliases.
 +/
static if (__VERSION__ >= 2099L)
{
    private import kameloso.thread : ThreadMessage;
    private import std.meta : AliasSeq;

    private alias askLevels = AliasSeq!(
        "askToTrace",
        "askToLog",
        "askToInfo",
        "askToWarn",
        "askToError",
        "askToCritical",
        "askToFatal",
        "askToWriteln",
    );

    static foreach (immutable askVerb; askLevels)
    {
        mixin(`
        /++
            Sends a message to the main thread to print text using
            the [KamelosoLogger] to the local terminal.
         +/
        alias ` ~ askVerb ~ ` = askToOutputImpl!"` ~ askVerb ~ `";
`);
    }

    /++
        Simple alias to [askToWarn], because both spellings are right.
     +/
    alias askToWarning = askToWarn;
}
else
{
    /++
        Sends a message to the main thread to [KamelosoLogger.trace] text to the local terminal.
     +/
    alias askToTrace = askToOutputImpl!"askToTrace";
    /++
        Sends a message to the main thread to [KamelosoLogger.log] text to the local terminal.
     +/
    alias askToLog = askToOutputImpl!"askToLog";
    /++
        Sends a message to the main thread to [KamelosoLogger.info] text to the local terminal.
     +/
    alias askToInfo = askToOutputImpl!"askToInfo";
    /++
        Sends a message to the main thread to [KamelosoLogger.warning] text to the local terminal.
     +/
    alias askToWarn = askToOutputImpl!"askToWarn";
    /++
        Simple alias to [askToWarn], because both spellings are right.
     +/
    alias askToWarning = askToWarn;
    /++
        Sends a message to the main thread to [KamelosoLogger.error] text to the local terminal.
     +/
    alias askToError = askToOutputImpl!"askToError";
    /++
        Sends a message to the main thread to [KamelosoLogger.critical] text to the local terminal.
     +/
    alias askToCritical = askToOutputImpl!"askToCritical";
    /++
        Sends a message to the main thread to [KamelosoLogger.fatal] text to the local terminal.
     +/
    alias askToFatal = askToOutputImpl!"askToFatal";
    /++
        Sends a message to the main thread asking to print text to the local terminal.
     +/
    alias askToWriteln = askToOutputImpl!"askToWriteln";
}

unittest
{
    import kameloso.thread : ThreadMessage;

    IRCPluginState state;

    state.askToTrace("trace");
    state.askToLog("log");
    state.askToInfo("info");
    state.askToWarn("warning");
    state.askToError("error");
    state.askToCritical("critical");
    state.askToWriteln("writeln");

    alias T = ThreadMessage.MessageType;

    static immutable T[7] expectedLevels =
    [
        T.askToTrace,
        T.askToLog,
        T.askToInfo,
        T.askToWarn,
        T.askToError,
        T.askToCritical,
        //T.askToFatal,
        T.askToWriteln,
    ];

    static immutable string[7] expectedMessages =
    [
        "trace",
        "log",
        "info",
        "warning",
        "error",
        "critical",
        //"fatal",
        "writeln",
    ];

    static assert(expectedLevels.length == expectedMessages.length);

    foreach (immutable i; 0..expectedMessages.length)
    {
        foreach (message; state.messages)
        {
            assert((message.type == expectedLevels[i]),
                Enum!(ThreadMessage.MessageType).toString(message.type));
            assert((message.content == expectedMessages[i]), message.content);
        }
    }
}

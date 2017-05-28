module kameloso.plugins.ctcp;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;


@Label("ctcpversion")
@(IrcEvent.Type.CTCP_VERSION)
void onCtcpVersion(const IrcEvent event)
{
    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "VERSION kameloso:%s:linux" ~ ctcp)
        .format(event.sender, kamelosoVersion));
}


@Label("ctcpfinger")
@(IrcEvent.Type.CTCP_FINGER)
void onCtcpFinger(const IrcEvent event)
{
    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "FINGER kameloso %s" ~ ctcp)
        .format(event.sender, kamelosoVersion));
}


@Label("ctcpsource")
@(IrcEvent.Type.CTCP_SOURCE)
void onCtcpSource(const IrcEvent event)
{
    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "SOURCE %s" ~ ctcp)
        .format(event.sender, kamelosoSource));
}


@Label("ctcpping")
@(IrcEvent.Type.CTCP_PING)
void onCtcpPing(const IrcEvent event)
{
    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "PING %s" ~ ctcp)
        .format(event.sender, event.content));
}


@Label("ctcptime")
@(IrcEvent.Type.CTCP_TIME)
void onCtcpTime(const IrcEvent event)
{
    import std.datetime : Clock;

    // "New implementations SHOULD default to UTC time for privacy reasons."

    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "TIME %s" ~ ctcp)
        .format(event.sender, Clock.currTime.toUTC));
}


@Label("ctcpuserinfo")
@(IrcEvent.Type.CTCP_USERINFO)
void onCtcpUserinfo(const IrcEvent event)
{
    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "USERINFO %s (%s)" ~ ctcp)
        .format(event.sender, state.bot.nickname, state.bot.user));
}


@Label("ctcpclientinfo")
@(IrcEvent.Type.CTCP_CLIENTINFO)
void onCtcpClientinfo(const IrcEvent event)
{
    enum string allCtcpTypes = ()
    {
        import std.conv   : to;
        import std.traits : getSymbolsByUDA, getUDAs, isSomeFunction;
        import std.string : stripRight;

        string allTypes;

        foreach (fun; getSymbolsByUDA!(mixin(__MODULE__), IrcEvent.Type))
        {
            static if (isSomeFunction!(fun))
            {
                immutable type = getUDAs!(fun, IrcEvent.Type)[0];

                allTypes = allTypes ~ type.to!string[5..$] ~ " ";
            }
        }

        return allTypes.stripRight();
    }();

    // Don't forget to add ACTION, it's handed elsewhere

    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "CLIENTINFO ACTION %s" ~ ctcp)
        .format(event.sender, allCtcpTypes));
}


public:


mixin OnEventImpl!__MODULE__;


// CTCP
/++
 *  The CTCP plugin (client-to-client protocol) answers to special queries
 *  sometime made over the IRC protocol. These are generally of metadata about
 *  the client itself and its capbilities.
 *
 *  Information about these were gathered from the following sites:
 *      https://modern.ircdocs.horse/ctcp.html
 *      http://www.irchelp.org/protocol/ctcpspec.html
 +/
final class CtcpPlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}
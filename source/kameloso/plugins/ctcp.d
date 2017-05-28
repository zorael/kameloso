module kameloso.plugins.ctcp;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.concurrency : send;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

@Label("ctcps")
@(IrcEvent.Type.CTCP_VERSION)
@(IrcEvent.Type.CTCP_FINGER)
@(IrcEvent.Type.CTCP_SOURCE)
@(IrcEvent.Type.CTCP_PING)
@(IrcEvent.Type.CTCP_TIME)
@(IrcEvent.Type.CTCP_USERINFO)
void onCtcps(const IrcEvent event)
{
    import std.format : format;

    string line;

    with (IrcEvent.Type)
    switch (event.type)
    {
    case CTCP_VERSION:
        line = "VERSION kameloso:%s:linux".format(kamelosoVersion);
        break;

    case CTCP_FINGER:
        line = "FINGER kameloso " ~ kamelosoVersion;
        break;

    case CTCP_SOURCE:
        line = "SOURCE " ~ kamelosoSource;
        break;

    case CTCP_PING:
        line = "PING " ~ event.content;
        break;

    case CTCP_TIME:
        import std.datetime : Clock;

        line = "TIME " ~ Clock.currTime.toUTC().toString();
        break;

    case CTCP_USERINFO:
        line = "USERINFO %s (%s)".format(state.bot.nickname, state.bot.user);
        break;

    default:
        assert(0);
    }

    with (IrcControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ line ~ ctcp).format(event.sender));
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
                foreach (type; getUDAs!(fun, IrcEvent.Type))
                {
                    allTypes = allTypes ~ type.to!string[5..$] ~ " ";
                }
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
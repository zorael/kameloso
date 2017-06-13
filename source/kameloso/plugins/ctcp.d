module kameloso.plugins.ctcp;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

// onCTCPs
/++
 +  Handle CTCP requests.
 +
 +  This is a catch-all function handling 5/6 CTCP requests we support, instead
 +  of having five different functions each dealing with one. Either design
 +  works; both end up with a switch.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("ctcps")
@(IRCEvent.Type.CTCP_VERSION)
@(IRCEvent.Type.CTCP_FINGER)
@(IRCEvent.Type.CTCP_SOURCE)
@(IRCEvent.Type.CTCP_PING)
@(IRCEvent.Type.CTCP_TIME)
@(IRCEvent.Type.CTCP_USERINFO)
void onCTCPs(const IRCEvent event)
{
    import std.concurrency : send;
    import std.format : format;

    string line;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case CTCP_VERSION:
        line = "VERSION kameloso:%s:linux".format(kamelosoInfo.version_);
        break;

    case CTCP_FINGER:
        line = "FINGER kameloso " ~ kamelosoInfo.version_;
        break;

    case CTCP_SOURCE:
        line = "SOURCE " ~ kamelosoInfo.source;
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

    with (IRCControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ line ~ ctcp).format(event.sender));
}


// onCTCPClientinfo
/++
 +  Sends a list of which CTCP events we understand.
 +
 +  This builds a string of the names of all IRCEvent.Types that begin
 +  with CTCP_, at compile-time. As such, as long as we name any new
 +  such types CTCP_SOMETHING, this list will always be correct.
 +
 +  Params:
 +      event = the triggering IRCEvent.
 +/
@Label("ctcpclientinfo")
@(IRCEvent.Type.CTCP_CLIENTINFO)
void onCTCPClientinfo(const IRCEvent event)
{
    import std.concurrency : send;

    enum string allCTCPTypes = ()
    {
        import std.conv   : to;
        import std.string : stripRight;
        import std.traits : getSymbolsByUDA, getUDAs, isSomeFunction;

        string allTypes;

        foreach (fun; getSymbolsByUDA!(mixin(__MODULE__), IRCEvent.Type))
        {
            static if (isSomeFunction!(fun))
            {
                foreach (type; getUDAs!(fun, IRCEvent.Type))
                {
                    allTypes = allTypes ~ type.to!string[5..$] ~ " ";
                }
            }
        }

        return allTypes.stripRight();
    }();

    // Don't forget to add ACTION, it's handed elsewhere

    with (IRCControlCharacter)
    state.mainThread.send(ThreadMessage.Sendline(),
        ("NOTICE %s :" ~ ctcp ~ "CLIENTINFO ACTION %s" ~ ctcp)
        .format(event.sender, allCTCPTypes));
}


public:


mixin OnEventImpl!__MODULE__;


// CTCP
/++
 +  The CTCP plugin (client-to-client protocol) answers to special queries
 +  sometime made over the IRC protocol. These are generally of metadata about
 +  the client itself and its capbilities.
 +
 +  Information about these were gathered from the following sites:
 +      https://modern.ircdocs.horse/ctcp.html
 +      http://www.irchelp.org/protocol/ctcpspec.html
 +/
final class CTCPPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

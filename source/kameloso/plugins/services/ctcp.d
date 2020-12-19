/++
    The CTCP service handles responding to CTCP (client-to-client protocol)
    requests behind the scenes.

    It has no commands and is not aware in the normal sense; it only blindly
    responds to requests.
 +/
module kameloso.plugins.services.ctcp;

version(WithPlugins):
version(WithCTCPService):

private:

import kameloso.plugins.common.core;
import kameloso.messaging;
import dialect.defs;
import std.typecons : Flag, No, Yes;


// onCTCPs
/++
    Handles `CTCP` requests.

    This is a catch-all function handling most `CTCP` requests we support,
    instead of having five different functions each dealing with one.
    Either design works; both end up with a switch.
 +/
//@(IRCEvent.Type.CTCP_SLOTS)  // We don't really need to handle those
@(IRCEvent.Type.CTCP_VERSION)
@(IRCEvent.Type.CTCP_FINGER)
@(IRCEvent.Type.CTCP_SOURCE)
@(IRCEvent.Type.CTCP_PING)
@(IRCEvent.Type.CTCP_TIME)
@(IRCEvent.Type.CTCP_USERINFO)
@(IRCEvent.Type.CTCP_DCC)
@(IRCEvent.Type.CTCP_AVATAR)
@(IRCEvent.Type.CTCP_LAG)
void onCTCPs(CTCPService service, const ref IRCEvent event)
{
    import kameloso.constants : KamelosoInfo;
    import std.format : format;

    // https://modern.ircdocs.horse/ctcp.html

    string line;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case CTCP_VERSION:
        import std.system : os;
        /*  This metadata query is used to return the name and version of the
            client software in use. There is no specified format for the version
            string.

            VERSION is universally implemented. Clients MUST implement this CTCP message.

            Example:
            Query:     VERSION
            Response:  VERSION WeeChat 1.5-rc2 (git: v1.5-rc2-1-gc1441b1) (Apr 25 2016)
         */

        line = "VERSION kameloso %s, built %s, running on %s"
            .format(cast(string)KamelosoInfo.version_, cast(string)KamelosoInfo.built, os);
        break;

    case CTCP_FINGER:
        /*  This metadata query returns miscellaneous info about the user,
            typically the same information that’s held in their realname field.
            However, some implementations return the client name and version instead.

            FINGER is widely implemented, but largely obsolete. Clients MAY
            implement this CTCP message.

            Example:
            Query:     FINGER
            Response:  FINGER WeeChat 1.5
         */
        line = "FINGER kameloso " ~ cast(string)KamelosoInfo.version_;
        break;

    case CTCP_SOURCE:
        /*  This metadata query is used to return the location of the source
            code for the client.

            SOURCE is rarely implemented. Clients MAY implement this CTCP message.

            Example:
            Query:     SOURCE
            Response:  SOURCE https://weechat.org/download
         */
        line = "SOURCE " ~ cast(string)KamelosoInfo.source;
        break;

    case CTCP_PING:
        /*  This extended query is used to confirm reachability with other
            clients and to check latency. When receiving a CTCP PING, the reply
            must contain exactly the same parameters as the original query.

            PING is universally implemented. Clients MUST implement this CTCP message.

            Example:
            Query:     PING 1473523721 662865
            Response:  PING 1473523721 662865

            Query:     PING foo bar baz
            Response:  PING foo bar baz
         */
        line = "PING " ~ event.content;
        break;

    case CTCP_TIME:
        import std.datetime.systime : Clock;
        /*  This extended query is used to return the client’s local time in an
            unspecified human-readable format. We recommend ISO 8601 format, but
            raw ctime() output appears to be the most common in practice.

            New implementations SHOULD default to UTC time for privacy reasons.

            TIME is almost universally implemented. Clients SHOULD implement
            this CTCP message.

            Example:
            Query:     TIME
            Response:  TIME 2016-09-26T00:45:36Z
         */
        line = "TIME " ~ Clock.currTime.toUTC().toString();
        break;

    /* case CTCP_CLIENTINFO:
        // more complex; handled in own function
        break; */

    case CTCP_USERINFO:
        /*  This metadata query returns miscellaneous info about the user,
            typically the same information that’s held in their realname field.

            However, some implementations return <nickname> (<realname>) instead.

            USERINFO is widely implemented, but largely obsolete. Clients MAY
            implement this CTCP message.

            Example:
            Query:     USERINFO
            Response:  USERINFO fred (Fred Foobar)
         */
        line = "USERINFO %s (%s)".format(service.state.client.nickname, service.state.client.realName);
        break;

    case CTCP_DCC:
        /*  DCC (Direct Client-to-Client) is used to setup and control
            connections that go directly between clients, bypassing the IRC
            server. This is typically used for features that require a large
            amount of traffic between clients or simply wish to bypass the
            server itself such as file transfer, direct chat, and voice messages.

            Properly implementing the various DCC types requires a document all
            of its own, and are not described here.

            DCC is widely implemented. Clients MAY implement this CTCP message.
         */
        break;

    case CTCP_AVATAR:
        /*  http://www.kvirc.net/doc/doc_ctcp_avatar.html

            Every IRC user has a client-side property called AVATAR.

            Let's say that there are two users: A and B.
            When user A wants to see the B's avatar he simply sends a CTCP
            AVATAR request to B (the request is sent through a PRIVMSG IRC
            command). User B replies with a CTCP AVATAR notification (sent
            through a NOTICE IRC command) with the name or URL of his avatar.

            The actual syntax for the notification is:

            AVATAR <avatar_file> [<filesize>]

            The <avatar_file> may be either the name of a B's local image file
            or a URL pointing to an image on some web server.
         */
        // FIXME: return something hardcoded?
        break;

    case CTCP_LAG:
        // g-line fishing? do nothing?
        break;

    default:
        import lu.conv : Enum;
        assert(0, "Missing `CTCP_` case entry for `IRCEvent.Type." ~
            Enum!(IRCEvent.Type).toString(event.type) ~ '`');
    }

    version(unittest)
    {
        return;
    }
    else
    {
        import dialect.common : I = IRCControlCharacter;
        immutable target = event.sender.isServer ?
            event.sender.address: event.sender.nickname;
        raw(service.state, "NOTICE %s :%c%s%2$c".format(target, cast(char)I.ctcp, line), Yes.quiet);
    }
}

unittest
{
    // Ensure onCTCPs implement cases for all its annotated
    // [dialect.defs.IRCEvent.Type]s.
    import std.traits : getUDAs;

    IRCPluginState state;
    auto service = new CTCPService(state);

    foreach (immutable type; getUDAs!(onCTCPs, IRCEvent.Type))
    {
        IRCEvent event;
        event.type = type;
        onCTCPs(service, event);
    }
}


// onCTCPClientinfo
/++
    Sends a list of which `CTCP` events we understand.

    This builds a string of the names of all `dialect.defs.IRCEvent.Type`s
    that begin with `CTCP_`, at compile-time. As such, as long as we name any
    new such types `CTCP_SOMETHING`, this list will always be correct.
 +/
@(IRCEvent.Type.CTCP_CLIENTINFO)
void onCTCPClientinfo(CTCPService service, const ref IRCEvent event)
{
    import dialect.common : IRCControlCharacter;
    import std.format : format;

    /*  This metadata query returns a list of the CTCP messages that this
        client supports and implements. CLIENTINFO is widely implemented.

        Clients SHOULD implement this CTCP message.

        Example:
        Query:     CLIENTINFO
        Response:  CLIENTINFO ACTION DCC CLIENTINFO FINGER PING SOURCE TIME USERINFO VERSION
     */

    enum allCTCPTypes = ()
    {
        import lu.string : beginsWith, strippedRight;
        import lu.traits : getSymbolsByUDA;
        import std.traits : getUDAs, isSomeFunction;

        mixin("import thisModule = ", __MODULE__, ";");

        string allTypes;

        foreach (fun; getSymbolsByUDA!(thisModule, IRCEvent.Type))
        {
            static if (isSomeFunction!(fun))
            {
                foreach (immutable type; getUDAs!(fun, IRCEvent.Type))
                {
                    import lu.conv : Enum;
                    enum typestring = Enum!(IRCEvent.Type).toString(type);

                    static if (typestring.beginsWith("CTCP_"))
                    {
                        allTypes ~= typestring[5..$] ~ " ";
                    }
                }
            }
        }

        return allTypes.strippedRight;
    }().idup;

    // Don't forget to add ACTION, it's handed elsewhere

    with (IRCControlCharacter)
    {
        import std.conv : text;
        raw(service.state, text("NOTICE %s :", cast(char)ctcp, "CLIENTINFO ACTION %s", cast(char)ctcp)
            .format(event.sender.nickname, allCTCPTypes));
    }
}


public:


// CTCPService
/++
    The `CTCP` service (client-to-client protocol) answers to special queries
    sometime made over the IRC protocol. These are generally of metadata about
    the client itself and its capabilities.

    Information about these were gathered from the following sites:
        - https://modern.ircdocs.horse/ctcp.html
        - http://www.irchelp.org/protocol/ctcpspec.html
 +/
final class CTCPService : IRCPlugin
{
private:
    // isEnabled
    /++
        Override [kameloso.plugins.common.core.IRCPluginImpl.isEnabled] and inject
        a server check, so this service does nothing on Twitch servers.

        Returns:
            `true` if this service should react to events; `false` if not.
     +/
    version(TwitchSupport)
    override public bool isEnabled() const @property pure nothrow @nogc
    {
        return (state.server.daemon != IRCServer.Daemon.twitch);
    }

    mixin IRCPluginImpl;
}

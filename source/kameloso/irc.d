module kameloso.irc;

public import kameloso.ircstructs;

import kameloso.common;
import kameloso.constants;
import kameloso.stringutils : nom;

import std.format : format, formattedRead;
import std.string : indexOf;
import std.stdio;

@safe:

private:


void onPRIVMSG(const ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : beginsWith;

    // FIXME, change so that it assigns to the proper field

    immutable targetOrChannel = slice.nom(" :");
    event.content = slice;

    if (targetOrChannel.isValidChannel(parser.bot.server))
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content
        event.type = IRCEvent.Type.CHAN;
        event.channel = targetOrChannel;
    }
    else
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content
        event.type = IRCEvent.Type.QUERY;
        event.target.nickname = targetOrChannel;
    }

    if (slice.length < 3) return;

    if ((slice[0] == IRCControlCharacter.ctcp) &&
        (slice[$-1] == IRCControlCharacter.ctcp))
    {
        slice = slice[1..$-1];
        immutable ctcpEvent = (slice.indexOf(' ') != -1) ? slice.nom(' ') : slice;
        event.content = slice;

        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :ACTION test test content
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :ACTION test test content
        // :py-ctcp!ctcp@ctcp-scanner.rizon.net PRIVMSG kameloso^^ :VERSION
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :TIME
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :PING 1495974267 590878
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :CLIENTINFO
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :DCC
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :SOURCE
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :USERINFO
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :FINGER

        import std.traits : EnumMembers;

        /++
            +  This iterates through all IRCEvent.Types that begin with
            +  "CTCP_" and generates switch cases for the string of each.
            +  Inside it will assign event.type to the corresponding
            +  IRCEvent.Type.
            +
            +  Like so, except automatically generated through compile-time
            +  introspection:
            +
            +      case "CTCP_PING":
            +          event.type = CTCP_PING;
            +          event.aux = "PING";
            +          break;
            +/

        with (IRCEvent.Type)
        top:
        switch (ctcpEvent)
        {
        case "ACTION":
            // We already sliced away the control characters and nommed the
            // "ACTION" ctcpEvent string, so just set the type and break.
            event.type = IRCEvent.Type.EMOTE;
            break;

        foreach (immutable type; EnumMembers!(IRCEvent.Type))
        {
            import std.conv : to;

            enum typestring = type.to!string;

            static if (typestring.beginsWith("CTCP_"))
            {
                case typestring[5..$]:
                    event.type = type;
                    event.aux = typestring[5..$];
                    break top;
            }
        }

        default:
            logger.warning("-------------------- UNKNOWN CTCP EVENT");
            //printObject(event);
            break;
        }
    }
}

IRCEvent toIRCEvent(ref IRCParser parser, const string raw)
{
    import std.datetime : Clock;

    return IRCEvent.init;
}


public:


/// This simply looks at an event and decides whether it is from a nickname
/// registration service.
version(none)
bool isFromAuthService(const ref IRCParser parser, const IRCEvent event)
{
    return true;
}


/// Checks whether a string *looks* like a channel.
bool isValidChannel(const string line, const IRCServer server)
{
    return true;
}

/// Checks if a string *looks* like a nickname.
bool isValidNickname(const string nickname, const IRCServer server)
{
    return true;
}

// stripModeSign
/++
 +  Takes a nickname and strips it of any prepended mode signs, like the @ in @nickname.
 +
 +  The list of signs should be added to when more are discovered.
 +
 +  Params:
 +      nickname = The signed nickname.
 +
 +  Returns:
 +      The nickname with the sign sliced off.
 +/
string stripModeSign(const string nickname)
{
    return string.init;
}

// networkOf
/++
 +  Tries to guess the network of an IRC server based on its address.
 +
 +  This is done early on before connecting. After registering, we can (usually)
 +  get the correct answer from the RPL_ISUPPORT event (NETWORK tag).
 +
 +  Params:
 +      address = the IRC server address to evaluate.
 +
 +  Returns:
 +      a member of the IRCServer.Network enum type signifying which network
 +      the server was guessed to be part of.
 +/
IRCServer.Network networkOf(const string address)
{
    with (IRCServer.Network)
    {
        import std.algorithm.searching : endsWith;

        immutable IRCServer.Network[string] networkMap =
        [
            ".freenode.net"   : freenode,
            ".rizon.net"      : rizon,
            ".quakenet.org"   : quakenet,
            ".undernet.org"   : undernet,
            ".gamesurge.net"  : gamesurge,
            ".twitch.tv"      : twitch,
            ".unrealircd.org" : unreal,
            ".efnet.org"      : efnet,
            ".ircnet.org"     : ircnet,
            ".swiftirc.net"   : swiftirc,
            ".SwiftIRC.net"   : swiftirc,
            ".irchighway.net" : irchighway,
            ".dal.net"        : dalnet,
        ];

        foreach (addressTail, net; networkMap)
        {
            if (address.endsWith(addressTail))
            {
                return networkMap[addressTail];
            }
        }

        return unknown;
    }
}

unittest
{
    import std.conv : to;

    with (IRCServer.Network)
    {
        immutable n1 = networkOf("irc.freenode.net");
        assert(n1 == freenode, n1.to!string);

        immutable n2 = networkOf("harbl.hhorlb.rizon.net");
        assert(n2 == rizon, n2.to!string);

        immutable n3 = networkOf("under.net.undernet.org");
        assert(n3 == undernet, n3.to!string);

        immutable n4 = networkOf("irc.irc.irc.gamesurge.net");
        assert(n4 == gamesurge, n4.to!string);

        immutable n5 = networkOf("irc.chat.twitch.tv");
        assert(n5 == twitch, n5.to!string);

        immutable n6 = networkOf("irc.unrealircd.org");
        assert(n6 == unreal, n6.to!string);
    }
}


string nickServiceOf(const IRCServer.Network network)
{
    with (IRCServer.Network)
    {
        static immutable string[14] netmap =
        [
            unknown    : "NickServ",
            unfamiliar : "NickServ",
            freenode   : "NickServ",
            rizon      : "NickServ",
            quakenet   : "Q@CServe.quakenet.org",
            undernet   : string.init,
            gamesurge  : "AuthServ@Services.GameSurge.net",
            twitch     : string.init,
            unreal     : "NickServ",
            efnet      : string.init,
            ircnet     : string.init,
            swiftirc   : "NickServ",
            irchighway : "NickServ",
            dalnet     : "NickServ@services.dal.net",
        ];

        return netmap[network];
    }
}

unittest
{
    import std.conv : to;

    IRCParser parser;

    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    immutable e1 = parser.toIRCEvent(":tepper.freenode.net NOTICE * :*** Checking Ident");
    with (e1)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert((content == "*** Checking Ident"), content);
    }

    /+
    [ERR_NICKNAMEINUSE] tepper.freenode.net (kameloso): "Nickname is already in use." (#433)
    :tepper.freenode.net 433 * kameloso :Nickname is already in use.
     +/
    immutable e2 = parser.toIRCEvent(":tepper.freenode.net 433 * kameloso :Nickname is already in use.");
    with (e2)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_NICKNAMEINUSE), type.to!string);
        assert((content == "Nickname is already in use."), content);
        assert((num == 433), num.to!string);
    }

    /+
    [RPL_WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = parser.toIRCEvent(":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
    with (e3)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WELCOME), type.to!string);
        assert((target.nickname == "kameloso^"), target.nickname);
        assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"),
               content);
        assert((num == 1), num.to!string);
    }

    /+
    [RPL_ENDOFMOTD] tepper.freenode.net (kameloso^): "End of /MOTD command." (#376)
    :tepper.freenode.net 376 kameloso^ :End of /MOTD command.
     +/
    immutable e4 = parser.toIRCEvent(":tepper.freenode.net 376 kameloso^ :End of /MOTD command.");
    with (e4)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_ENDOFMOTD), type.to!string);
        assert((content == "End of /MOTD command."), content);
        assert((num == 376), num.to!string);
    }

    /+
    [SELFMODE] kameloso^ (kameloso^) <+i>
    :kameloso^ MODE kameloso^ :+i
     +/
    immutable e5 = parser.toIRCEvent(":kameloso^ MODE kameloso^ :+i");
    with (e5)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((type == IRCEvent.Type.SELFMODE), type.to!string);
        assert((aux == "+i"), aux);
    }

    /+
    [QUERY] zorael (kameloso^): "sudo privmsg zorael :derp"
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp
     +/
    immutable e6 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp");
    with (e6)
    {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.QUERY), type.to!string); // Will this work?
        assert((target.nickname == "kameloso^"), target.nickname);
        assert((content == "sudo privmsg zorael :derp"), content);
    }

    /+
    [RPL_WHOISUSER] tepper.freenode.net (zorael): "~NaN ns3363704.ip-94-23-253.eu" <jr> (#311)
    :tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr
     +/
    immutable e7 = parser.toIRCEvent(":tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr");
    with (e7)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WHOISUSER), type.to!string);
        assert((target.nickname == "zorael"), target.nickname);
        assert((target.ident == "~NaN"), target.ident);
        assert((target.address == "ns3363704.ip-94-23-253.eu"), target.address);
        assert((content == "jr"), content);
        assert((num == 311), num.to!string);
    }

    /+
    [WHOISLOGIN] tepper.freenode.net (zurael): "is logged in as" <zorael> (#330)
    :tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as
     +/
    immutable e8 = parser.toIRCEvent(":tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as");
    with (e8)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), type.to!string);
        assert((target.nickname == "zurael"), target.nickname);
        assert((content == "zorael"), content);
        assert((target.login == "zorael"), target.login);
        assert((num == 330), num.to!string);
    }

    /+
    [PONG] tepper.freenode.net
    :tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net
     +/
    immutable e9 = parser.toIRCEvent(":tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net");
    with (e9)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.PONG), type.to!string);
        assert(!target.nickname.length, target.nickname); // More than the server and type is never parsed
    }

    /+
    [QUIT] wonderworld: "Remote host closed the connection"
    :wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection
     +/
    immutable e10 = parser.toIRCEvent(":wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de " ~
        "QUIT :Remote host closed the connection");
    with (e10)
    {
        assert((sender.nickname == "wonderworld"), sender.nickname);
        assert((type == IRCEvent.Type.QUIT), type.to!string);
        assert(!target.nickname.length, target.nickname);
        assert((content == "Remote host closed the connection"), content);
    }

    /+
    [CHANMODE] zorael (kameloso^) [#flerrp] <+v>
    :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
     +/
     immutable e11 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^");
     with (e11)
     {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.CHANMODE), type.to!string);
        assert((content == "kameloso^"), content);
        assert((channel == "#flerrp"), channel);
        assert((aux == "+v"), aux);
     }

     /+
     [17:10:44] [NUMERIC] irc.uworld.se (kameloso): "To connect type /QUOTE PONG 3705964477" (#513)
     :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
     +/
     immutable e12 = parser.toIRCEvent(":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477");
     with (e12)
     {
        assert((sender.address == "irc.uworld.se"), sender.address);
        assert((type == IRCEvent.Type.ERR_BADPING), type.to!string);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((aux == "3705964477"), aux);
        assert((content == "PONG"), content);
     }

    /+
    [20:55:14] [ERR_UNKNOWNCOMMAND] karatkievich.freenode.net (kameloso^) <systemd,#kde,#kubuntu,#archlinux, ...>
    :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...
    +/
    immutable e13 = parser.toIRCEvent(":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...");
    with (e13)
    {
        assert((sender.address == "karatkievich.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "systemd,#kde,#kubuntu,#archlinux ..."), content);
    }

    /+
    :asimov.freenode.net 421 kameloso^ sudo :Unknown command
    +/
    immutable e14 = parser.toIRCEvent(":asimov.freenode.net 421 kameloso^ sudo :Unknown command");
    with (e14)
    {
        assert((sender.address == "asimov.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "sudo"), content);
        assert((aux == "Unknown command"), aux);
    }

    /+
    :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :PING 1495974267 590878
    +/
    immutable e15 = parser.toIRCEvent(":wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :" ~
                     IRCControlCharacter.ctcp ~ "PING 1495974267 590878" ~
                     IRCControlCharacter.ctcp);
    with (e15)
    {
        assert((sender.nickname == "wob^2"), sender.nickname);
        assert((type == IRCEvent.Type.CTCP_PING), type.to!string);
        assert((content == "1495974267 590878"), content);
        assert((aux == "PING"), aux);
    }

    /+
    :beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas
    +/
    immutable e16 = parser.toIRCEvent(":beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas");
    with (e16)
    {
        assert((sender.nickname == "beLAban"), sender.nickname);
        assert((type == IRCEvent.Type.CHAN), type.to!string);
        assert((channel == "##networking"), channel);
        assert((content == "start at cpasdcas"), content);
    }

    /+
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :ACTION test test content
    +/
    immutable e17 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :" ~
                     IRCControlCharacter.ctcp ~ "ACTION 123 test test content" ~
                     IRCControlCharacter.ctcp);
    with (e17)
    {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.EMOTE), type.to!string);
        assert((channel == "#flerrp"), channel);
        assert((content == "123 test test content"), content);
    }

    /+
    :tmi.twitch.tv HOSTTARGET #lirik :h1z1 -
    +/
    immutable e18 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :h1z1 -");
    with (e18)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTSTART), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((content == "h1z1"), content);
        assert((!aux.length), aux);
    }

    /+
    :tmi.twitch.tv HOSTTARGET #hosting_channel :- [<number-of-viewers>]
    +/
    immutable e19 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :- 178");
    with (e19)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTEND), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((aux == "178"), aux);
    }

    /+
    :tmi.twitch.tv HOSTTARGET #lirik chu8 270
    +/
    immutable e20 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :chu8 270");
    with (e20)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTSTART), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((content == "chu8"), content);
        assert((aux == "270"), aux);
    }

    immutable e21 = parser.toIRCEvent(":kameloso_!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso__");
    with (e21)
    {
        assert((sender.nickname == "kameloso_"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.NICK), type.to!string);
        assert((target.nickname == "kameloso__"), target.nickname);
    }

    immutable e22 = parser.toIRCEvent(":kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_");
    with (e22)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.SELFNICK), type.to!string);
        assert((target.nickname == "kameloso_"), target.nickname);
        assert(parser.bot.updated);
        assert((parser.bot.nickname == "kameloso_"), parser.bot.nickname);
    }
}


struct IRCParser
{
    alias Type = IRCEvent.Type;
    alias Daemon = IRCServer.Daemon;

    IRCBot bot;

    //Daemon serverDaemon;

    Type[1024] typenums = Typenums.base;

    IRCEvent toIRCEvent(const string raw)
    {
        return .toIRCEvent(this, raw);
    }

    this(IRCBot bot)
    {
        this.bot = bot;
    }

    @disable this(this);

    /*Daemon daemon() const @property
    {
        return serverDaemon;
    }*/

    void daemon(const Daemon daemon) @property
    {
        import kameloso.common;

        /// https://upload.wikimedia.org/wikipedia/commons/d/d5/IRCd_software_implementations3.svg

        // Reset
        typenums = Typenums.base;
        //this.serverDaemon = daemon;
        bot.server.daemon = daemon;
        bot.updated = true;

        with (Typenums)
        with (Daemon)
        final switch (daemon)
        {
        case unreal:
            Typenums.unreal.meldInto(typenums);
            break;

        case inspircd:
            Typenums.inspIRCd.meldInto(typenums);
            break;

        case bahamut:
            Typenums.bahamut.meldInto(typenums);
            break;

        case ratbox:
            Typenums.ratBox.meldInto(typenums);
            break;

        case u2:
            // unknown!
            break;

        case rizon:
            Typenums.hybrid.meldInto(typenums);
            Typenums.rizon.meldInto(typenums);
            break;

        case hybrid:
            Typenums.hybrid.meldInto(typenums);
            break;

        case ircu:
            Typenums.ircu.meldInto(typenums);
            break;

        case aircd:
            Typenums.aircd.meldInto(typenums);
            break;

        case rfc1459:
            Typenums.rfc1459.meldInto(typenums);
            break;

        case rfc2812:
            Typenums.rfc2812.meldInto(typenums);
            break;

        case quakenet:
            Typenums.quakenet.meldInto(typenums);
            break;

        case nefarious:
            Typenums.nefarious.meldInto(typenums);
            break;

        case rusnet:
            Typenums.rusnet.meldInto(typenums);
            break;

        case austhex:
            Typenums.austHex.meldInto(typenums);
            break;

        case ircnet:
            Typenums.ircNet.meldInto(typenums);
            break;

        case ptlink:
            Typenums.ptlink.meldInto(typenums);
            break;

        case ultimate:
            Typenums.ultimate.meldInto(typenums);
            break;

        case charybdis:
            Typenums.charybdis.meldInto(typenums);
            break;

        case ircdseven:
            // Nei | freenode is based in charybdis which is based on ratbox iirc
            Typenums.hybrid.meldInto(typenums);
            Typenums.ratBox.meldInto(typenums);
            Typenums.charybdis.meldInto(typenums);
            break;

        case undernet:
            Typenums.undernet.meldInto(typenums);
            break;

        case anothernet:
            //Typenums.anothernet.meldInto(typenums);
            break;

        case sorircd:
            //Typenums.sorircd.meldInto(typenums);
            break;

        case bdqircd:
            //Typenums.bdqIrcD.meldInto(typenums);
            break;

        case chatircd:
            //Typenums.chatIRCd.meldInto(typenums);
            break;

        case irch:
            //Typenums.irch.meldInto(typenums);
            break;

        case ithildin:
            //Typenums.ithildin.meldInto(typenums);
            break;

        case twitch:
            // do nothing, their events aren't numerical?
            break;

        case unknown:
            // do nothing...
            break;
        }
    }
}

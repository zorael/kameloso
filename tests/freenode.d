import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    {
        immutable event = parser.toIRCEvent(":sinisalo.freenode.net 004 kameloso^ sinisalo.freenode.net ircd-seven-1.1.7 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "sinisalo.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI"), content);
            assert((aux == "ircd-seven-1.1.7"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemonstring = "ircd-seven-1.1.7";
    server.daemon = IRCServer.Daemon.ircdseven;
    */

    with (parser.client)
    {
        assert((server.daemonstring == "ircd-seven-1.1.7"), server.daemonstring);
        assert((server.daemon == IRCServer.Daemon.ircdseven), Enum!(IRCServer.Daemon).toString(server.daemon));
    }

    {
        immutable event = parser.toIRCEvent(":sinisalo.freenode.net 005 kameloso^ CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "sinisalo.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.daemonstring = "freenode";
    server.caseMapping = IRCServer.CaseMapping.rfc1459;
    */

    with (parser.client)
    {
        assert((server.daemonstring == "freenode"), server.daemonstring);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), Enum!(IRCServer.CaseMapping).toString(server.caseMapping));
    }

    {
        immutable event = parser.toIRCEvent(":sinisalo.freenode.net 005 kameloso^ CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,jrxz CLIENTVER=3.0 WHOX KNOCK ETRACE :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "sinisalo.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,jrxz CLIENTVER=3.0 WHOX KNOCK ETRACE"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.maxNickLength = 16;
    server.maxChannelLength = 50;
    server.extbanPrefix = '$';
    server.extbanTypes = "jrxz";
    */

    with (parser.client)
    {
        assert((server.maxNickLength == 16), server.maxNickLength.to!string);
        assert((server.maxChannelLength == 50), server.maxChannelLength.to!string);
        assert((server.extbanPrefix == '$'), server.extbanPrefix.to!string);
        assert((server.extbanTypes == "jrxz"), server.extbanTypes);
    }

    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    immutable e1 = parser.toIRCEvent(":tepper.freenode.net NOTICE * :*** Checking Ident");
    with (e1)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.NOTICE), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.ERR_NICKNAMEINUSE), Enum!(IRCEvent.Type).toString(type));
        assert((content == "Nickname is already in use."), content);
        assert((num == 433), num.to!string);
    }

    parser.client.nickname = "kameloso^";

    /+
    [RPL_WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = parser.toIRCEvent(":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
    with (e3)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WELCOME), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.RPL_ENDOFMOTD), Enum!(IRCEvent.Type).toString(type));
        assert((content == "End of /MOTD command."), content);
        assert((num == 376), num.to!string);
    }

    /+
    [QUERY] zorael (kameloso^): "sudo privmsg zorael :derp"
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp
     +/
    immutable e6 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp");
    with (e6)
    {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.QUERY), Enum!(IRCEvent.Type).toString(type)); // Will this work?
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
        assert((type == IRCEvent.Type.RPL_WHOISUSER), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "zurael"), target.nickname);
        assert((content == "zorael"), content);
        assert((target.account == "zorael"), target.account);
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
        assert((type == IRCEvent.Type.PONG), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.QUIT), Enum!(IRCEvent.Type).toString(type));
        assert(!target.nickname.length, target.nickname);
        assert((content == "Remote host closed the connection"), content);
    }

    /+
    [20:55:14] [ERR_UNKNOWNCOMMAND] karatkievich.freenode.net (kameloso^) <systemd,#kde,#kubuntu,#archlinux, ...>
    :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...
    +/
    immutable e13 = parser.toIRCEvent(":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...");
    with (e13)
    {
        assert((sender.address == "karatkievich.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), Enum!(IRCEvent.Type).toString(type));
        assert((content == "systemd,#kde,#kubuntu,#archlinux ..."), content);
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
        assert((type == IRCEvent.Type.CTCP_PING), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
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
        assert((type == IRCEvent.Type.EMOTE), Enum!(IRCEvent.Type).toString(type));
        assert((channel == "#flerrp"), channel);
        assert((content == "123 test test content"), content);
    }

    immutable e21 = parser.toIRCEvent(":kameloso_!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso__");
    with (e21)
    {
        assert((sender.nickname == "kameloso_"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.NICK), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "kameloso__"), target.nickname);
    }

    immutable e22 = parser.toIRCEvent(":kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_");
    with (e22)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.SELFNICK), Enum!(IRCEvent.Type).toString(type));
        assert((target.nickname == "kameloso_"), target.nickname);
        assert((parser.client.nickname == "kameloso_"), parser.client.nickname);
    }
    {
        parser.client.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: KICK #flerrp kameloso^ :kameloso^");

        with (event)
        {
            assert((type == IRCEvent.Type.SELFKICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
            assert((channel == "#flerrp"), channel);
            assert((content == "kameloso^"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":livingstone.freenode.net 249 kameloso p :dax (dax@freenode/staff/dax)");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_STATSDEBUG), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "livingstone.freenode.net"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "dax (dax@freenode/staff/dax)"), content);
            assert((aux == "p"), aux);
            assert((num == 249), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":livingstone.freenode.net 219 kameloso p :End of /STATS report");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_ENDOFSTATS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "livingstone.freenode.net"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "End of /STATS report"), content);
            assert((aux == "p"), aux);
            assert((num == 219), num.to!string);
        }
    }

    parser.client.nickname = "kameloso^";

    {
        immutable event = parser.toIRCEvent(":rajaniemi.freenode.net 718 kameloso Freyjaun ~FREYJAUN@41.39.229.6 :is messaging you, and you have umode +g.");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_UMODEGMSG), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "rajaniemi.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "Freyjaun"), target.nickname);
            assert((target.ident == "~FREYJAUN"), target.ident);
            assert((target.address == "41.39.229.6"), target.address);
            assert((content == "is messaging you, and you have umode +g."), content);
            assert((num == 718), num.to!string);
        }
    }
}


unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "irc.freenode.net";
        server.daemon = IRCServer.Daemon.ircdseven;
        server.network = "freenode";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

    {
        immutable event = parser.toIRCEvent(":nick!~identh@unaffiliated/nick JOIN #freenode login :realname");
        with (event)
        {
            assert((type == IRCEvent.Type.JOIN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "nick"), sender.nickname);
            assert((sender.ident == "~identh"), sender.ident);
            assert((sender.address == "unaffiliated/nick"), sender.address);
            assert((sender.account == "login"), sender.account);
            assert((channel == "#freenode"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(`:zorael!~NaN@ns3363704.ip-94-23-253.eu PART #flerrp :"WeeChat 1.6"`);
        with (event)
        {
            assert((type == IRCEvent.Type.PART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((channel == "#flerrp"), channel);
            assert((content == "WeeChat 1.6"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":kameloso^!~NaN@81-293-105-62-no80.tbcn.telia.com NICK :kameloso_");
        with (event)
        {
            assert((type == IRCEvent.Type.NICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso^"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "81-293-105-62-no80.tbcn.telia.com"), sender.address);
            assert((target.nickname == "kameloso_"), target.nickname);
        }
    }
    {
        immutable event = parser.toIRCEvent(":g7adszon!~gertsson@938.174.245.107 QUIT :Client Quit");
        with (event)
        {
            assert((type == IRCEvent.Type.QUIT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "g7adszon"), sender.nickname);
            assert((sender.ident == "~gertsson"), sender.ident);
            assert((sender.address == "938.174.245.107"), sender.address);
            assert((content == "Client Quit"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu KICK #flerrp kameloso^ :this is a reason");
        with (event)
        {
            assert((type == IRCEvent.Type.KICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((channel == "#flerrp"), channel);
            assert((target.nickname == "kameloso^"), target.nickname);
            assert((content == "this is a reason"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: INVITE kameloso :#hirrsteff");
        with (event)
        {
            assert((type == IRCEvent.Type.INVITE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
            assert((channel == "#hirrsteff"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~zorael@ns3363704.ip-94-23-253.eu INVITE kameloso #hirrsteff");
        with (event)
        {
            assert((type == IRCEvent.Type.INVITE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~zorael"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((channel == "#hirrsteff"), channel);
        }
    }
    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 403 kameloso archlinux :No such channel");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_NOSUCHCHANNEL), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "archlinux"), channel);
            assert((content == "No such channel"), content);
            assert((num == 403), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsma +kameloso @zorael @m @k");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_NAMREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "kameloso^ ombudsma +kameloso @zorael @m @k"), content);
            assert((num == 353), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 352 kameloso ##linux LP9NDWY7Cy gentoo/contributor/Foldy moon.freenode.net Foldy H :0 Ni!");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_WHOREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "##linux"), channel);
            assert((target.nickname == "Foldy"), target.nickname);
            assert((target.address == "gentoo/contributor/Foldy"), target.address);
            assert((content == "Ni!"), content);
            assert((num == 352), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tolkien.freenode.net 315 kameloso^ ##linux :End of /WHO list.");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ENDOFWHO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "##linux"), channel);
            assert((content == "End of /WHO list."), content);
            assert((num == 315), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_WHOISHOST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "wilhelm.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "kameloso^"), target.nickname);
            assert((content == "81-233-105-62-no80.tbcn.telia.com"), content);
            assert((aux == "81.233.105.62"), aux);
            assert((num == 378), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 421 kameloso^ sudo :Unknown command");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Unknown command"), content);version(TwitchSupport)
            assert((aux == "sudo"), aux);
            assert((num == 421), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 252 kameloso^ 31 :IRC Operators online");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LUSEROP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "IRC Operators online"), content);
            assert((aux == "31"), aux);
            assert((num == 252), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 253 kameloso^ 13 :unknown connection(s)");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LUSERUNKNOWN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "unknown connection(s)"), content);
            assert((aux == "13"), aux);
            assert((num == 253), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 254 kameloso^ 54541 :channels formed");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LUSERCHANNELS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "channels formed"), content);
            assert((aux == "54541"), aux);
            assert((num == 254), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 432 kameloso^ @nickname :Erroneous Nickname");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_ERRONEOUSNICKNAME), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Erroneous Nickname"), content);
            assert((aux == "@nickname"), aux);
            assert((num == 432), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 461 kameloso^ JOIN :Not enough parameters");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_NEEDMOREPARAMS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Not enough parameters"), content);
            assert((aux == "JOIN"), aux);
            assert((num == 461), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 265 kameloso^ 6500 11061 :Current local users 6500, max 11061");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LOCALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current local users 6500, max 11061"), content);
            assert((aux == "6500 11061"), aux);
            assert((num == 265), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":orwell.freenode.net 311 kameloso^ kameloso ~NaN ns3363704.ip-94-23-253.eu * : kameloso");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_WHOISUSER), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "orwell.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "kameloso"), target.nickname);
            assert((target.ident == "~NaN"), target.ident);
            assert((target.address == "ns3363704.ip-94-23-253.eu"), target.address);
            assert((content == "kameloso"), content);
            assert((num == 311), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_WHOISSERVER), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "sinisalo.freenode.net"), content);
            assert((aux == "SE"), aux);
            assert((num == 312), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "xurael"), target.nickname);
            assert((target.account == "zorael"), target.account);
            assert((content == "zorael"), content);
            assert((num == 330), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":niven.freenode.net 451 * :You have not registered");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_NOTREGISTERED), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "You have not registered"), content);
            assert((num == 451), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.harblwefwoi.org 451 WHOIS :You have not registered");
        with (event)
        {
            assert((type == IRCEvent.Type.ERR_NOTREGISTERED), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.harblwefwoi.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "You have not registered"), content);
            assert((aux == "WHOIS"), aux);
            assert((num == 451), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 704 kameloso^ index :Help topics available to users:");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_HELPSTART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Help topics available to users:"), content);
            assert((aux == "index"), aux);
            assert((num == 704), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":rajaniemi.freenode.net 364 kameloso^ rajaniemi.freenode.net rajaniemi.freenode.net :0 Helsinki, FI, EU");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LINKS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "rajaniemi.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Helsinki, FI, EU"), content);
            assert((aux == "rajaniemi.freenode.net"), aux);
            assert((num == 364), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":wolfe.freenode.net 205 kameloso^ User v6users zorael[~NaN@2001:41d0:2:80b4::] (255.255.255.255) 16 :536");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_TRACEUSER), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "wolfe.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "zorael[~NaN@2001:41d0:2:80b4::] (255.255.255.255) 16"), content);
            assert((aux == "v6users"), aux);
            assert((num == 205), num.to!string);
            assert((count == 536), count.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 706 kameloso^ index :End of /HELP.");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ENDOFHELP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "End of /HELP."), content);
            assert((aux == "index"), aux);
            assert((num == 706), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":livingstone.freenode.net 249 kameloso p :1 staff members");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_STATSDEBUG), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "livingstone.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "1 staff members"), content);
            assert((aux == "p"), aux);
            assert((num == 249), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":verne.freenode.net 263 kameloso^ STATS :This command could not be completed because it has been used recently, and is rate-limited");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_TRYAGAIN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "verne.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "This command could not be completed because it has been used recently, and is rate-limited"), content);
            assert((aux == "STATS"), aux);
            assert((num == 263), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":verne.freenode.net 262 kameloso^ verne.freenode.net :End of TRACE");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_TRACEEND), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "verne.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "End of TRACE"), content);
            assert((aux == "verne.freenode.net"), aux);
            assert((num == 262), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 332 kameloso^ #garderoben :Are you employed, sir?");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_TOPIC), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "Are you employed, sir?"), content);
            assert((num == 332), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFNAMES), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "End of /NAMES list."), content);
            assert((num == 366), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":services. 328 kameloso^ #ubuntu :http://www.ubuntu.com");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNEL_URL), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "services."), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#ubuntu"), channel);
            assert((content == "http://www.ubuntu.com"), content);
            assert((num == 328), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 477 kameloso^ #archlinux :Cannot join channel (+r) - you need to be identified with services");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NEEDREGGEDNICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#archlinux"), channel);
            assert((content == "Cannot join channel (+r) - you need to be identified with services"), content);
            assert((num == 477), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_NAMREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "kameloso^ ombudsman +kameloso @zorael @maku @klarrt"), content);
            assert((num == 353), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 352 kameloso ##linux LP9NDWY7Cy gentoo/contributor/Fieldy moon.freenode.net Fieldy H :0 Ni!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "##linux"), channel);
            assert((target.nickname == "Fieldy"), target.nickname);
            assert((target.address == "gentoo/contributor/Fieldy"), target.address);
            assert((content == "Ni!"), content);
            assert((num == 352), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 352 kameloso ##linux ~rahlff b29beb9d.rev.stofanet.dk orwell.freenode.net Axton H :0 Michael Rahlff");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "##linux"), channel);
            assert((target.nickname == "Axton"), target.nickname);
            assert((target.ident == "~rahlff"), target.ident);
            assert((target.address == "b29beb9d.rev.stofanet.dk"), target.address);
            assert((content == "Michael Rahlff"), content);
            assert((num == 352), num.to!string);
        }
    }
    {
        parser.client.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":tolkien.freenode.net 301 kameloso^ jcjordyn120 :Idle");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_AWAY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "jcjordyn120"), target.nickname);
            assert((content == "Idle"), content);
            assert((num == 301), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_MOTD), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "- In particular we would like to thank the sponsor"), content);
            assert((num == 372), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 005 CHANTYPES=# EXCEPTS INVEX MODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "EXCEPTS INVEX MODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459"), content);
            assert((num == 5), num.to!string);
        }
        assert((parser.client.server.network == "freenode"), parser.client.server.network);
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI"), content);
            assert((aux == "ircd-seven-1.1.4"), aux);
            assert((num == 4), num.to!string);
        }
        assert(parser.client.server.daemon == IRCServer.daemon.ircdseven);
        assert(parser.client.server.daemonstring == "ircd-seven-1.1.4");
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_TOPICWHOTIME), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com"), content);
            assert((aux == "1476294377"), aux);
            assert((num == 333), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,...");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_UNKNOWNCOMMAND), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "karatkievich.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "systemd,#kde,#kubuntu,..."), content);
            assert((num == 421), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":rajaniemi.freenode.net 317 kameloso zorael 0 1510219961 :seconds idle, signon time");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISIDLE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "rajaniemi.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "0"), content);
            assert((aux == "1510219961"), aux);
            assert((num == 317), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 266 kameloso^ 85267 92341 :Current global users 85267, max 92341");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current global users 85267, max 92341"), content);
            assert((aux == "85267 92341"), aux);
            assert((num == 266), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 265 kameloso 3385 6820 :Current local users 3385, max 6820");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current local users 3385, max 6820"), content);
            assert((aux == "3385 6820"), aux);
            assert((num == 265), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 266 kameloso 87056 93012 :Current global users 87056, max 93012");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current global users 87056, max 93012"), content);
            assert((aux == "87056 93012"), aux);
            assert((num == 266), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 671 kameloso^ zorael :is using a secure connection");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISSECURE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "is using a secure connection"), content);
            assert((num == 671), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 318 kameloso^ zorael :End of /WHOIS list.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFWHOIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "End of /WHOIS list."), content);
            assert((num == 318), num.to!string);
        }
    }
    {
        assert((parser.client.nickname == "kameloso^"), parser.client.nickname);
        immutable event = parser.toIRCEvent(":asimov.freenode.net 433 kameloso^ kameloso :Nickname is already in use.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NICKNAMEINUSE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Nickname is already in use."), content);
            assert((num == 433), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 401 kameloso^ cherryh.freenode.net :No such nick/channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NOSUCHNICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "cherryh.freenode.net"), aux);
            assert((content == "No such nick/channel"), content);
            assert((num == 401), num.to!string);
        }
    }
    {
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE"
        immutable event = parser.toIRCEvent(":lightning.ircstorm.net 313 kameloso^ NickServ :is a Network Service");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISOPERATOR), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "lightning.ircstorm.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "NickServ"), target.nickname);
            assert((content == "is a Network Service"), content);
            assert((num == 313), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":adams.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WELCOME), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "adams.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"), content);
            assert((num == 1), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_HELPTXT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "ACCEPT\tADMIN\tAWAY\tCHALLENGE"), content);
            assert((aux == "index"), aux);
            assert((num == 705), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 706 kameloso^ index :End of /HELP.// :leguin.freenode.net 706 kameloso^ index :End of /HELP.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFHELP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "End of /HELP.// :leguin.freenode.net 706 kameloso^ index :End of /HELP."), content);
            assert((aux == "index"), aux);
            assert((num == 706), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_BANONCHAN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#d3d9"), channel);
            assert((content == "Cannot change nickname while banned on channel"), content);
            assert((aux == "kameloso^^"), aux);
            assert((num == 435), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: TOPIC #garderoben :en greps av hybris, sen var de bara fyra");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == TOPIC), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "en greps av hybris, sen var de bara fyra"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 900 kameloso kameloso!NaN@194.117.188.126 kameloso :You are now logged in as kameloso.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOGGEDIN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "kameloso"), target.nickname);
            assert((target.ident == "NaN"), target.ident);
            assert((target.address == "194.117.188.126"), target.address);
            assert((target.account == "kameloso"), target.account);
            assert((content == "You are now logged in as kameloso."), content);
            assert((num == 900), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":skix77!~quassel@ip5b435007.dynamic.kabel-deutschland.de ACCOUNT skix77");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ACCOUNT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "skix77"), sender.nickname);
            assert((sender.ident == "~quassel"), sender.ident);
            assert((sender.address == "ip5b435007.dynamic.kabel-deutschland.de"), sender.address);
            assert((sender.account == "skix77"), sender.account);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "skix77"), aux);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 321 kameloso^ Channel :Users  Name");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LISTSTART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((num == 321), num.to!string);
        }
    }
    {
        parser.client.nickname = "kameloso";
        immutable event = parser.toIRCEvent(":wolfe.freenode.net 470 kameloso #linux ##linux :Forwarding to another channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_LINKCHANNEL), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "wolfe.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#linux"), channel);
            assert((content == "##linux"), content);
            assert((num == 470), num.to!string);
        }
    }
    {
        parser.client.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":orwell.freenode.net 443 kameloso^ kameloso #flerrp :is already on channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_USERONCHANNEL), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "orwell.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "is already on channel"), content);
            assert((num == 443), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflohomeOnlyw] Make sure your nick is registered, then please try again to join ##linux.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "ChanServ"), sender.nickname);
            assert((sender.ident == "ChanServ"), sender.ident);
            assert((sender.address == "services."), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "[##linux-overflohomeOnlyw] Make sure your nick is registered, then please try again to join ##linux."), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "ChanServ"), sender.nickname);
            assert((sender.ident == "ChanServ"), sender.ident);
            assert((sender.address == "services."), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "[#ubuntu] Welcome to #ubuntu! Please read the channel topic."), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":tolkien.freenode.net NOTICE * :*** Checking Ident");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "*** Checking Ident"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "test test content"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == QUERY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "kameloso^"), target.nickname);
            assert((content == "test test content"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "kameloso^"), content);
            assert((aux == "+v"), aux);
        }
    }
    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((aux == "+i"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":niven.freenode.net MODE #sklabjoier +ns");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#sklabjoier"), channel);
            assert((aux == "+ns"), aux);
        }
    }

    parser.client.nickname = "kameloso^";

    {
        immutable event = parser.toIRCEvent(":kameloso^ MODE kameloso^ :+i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == SELFMODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso^"), sender.nickname);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "+i"), aux);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 005 CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST :are supported by this server");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST"), content);
            assert((num == 5), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":server.net 465 kameloso :You are banned from this server- Your irc client seems broken and is flooding lots of channels. Banned for 240 min, if in error, please contact kline@freenode.net. (2017/12/1 21.08)");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_YOUREBANNEDCREEP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "server.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "You are banned from this server- Your irc client seems broken and is flooding lots of channels. Banned for 240 min, if in error, please contact kline@freenode.net. (2017/12/1 21.08)"), content);
            assert((num == 465), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":ASDphBa|zzZ!~ASDphBa@a.asdphs-tech.com PRIVMSG #d :does anyone know how the unittest stuff is working with cmake-d?");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "ASDphBa|zzZ"), sender.nickname);
            assert((sender.ident == "~ASDphBa"), sender.ident);
            assert((sender.address == "a.asdphs-tech.com"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#d"), channel);
            assert((content == "does anyone know how the unittest stuff is working with cmake-d?"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 324 kameloso #flerrp +ns");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNELMODEIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((aux == "+ns"), aux);
            assert((num == 324), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 329 kameloso #flerrp 1512995737");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CREATIONTIME), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((aux == "1512995737"), aux);
            assert((num == 329), num.to!string);
        }
    }
    {
        parser.client.nickname = "kameloso";
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_BANLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), "channel is " ~ channel);
            assert((content == "harbl!harbl@snarbl.com"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1513899521"), aux);
            assert((num == 367), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNELMODEIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "##linux"), channel);
            assert((content == "##linux-overflow"), content);
            assert((aux == "+CLPcnprtf"), aux);
            assert((num == 324), num.to!string);
        }
    }
    {
        parser.client.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_INVITELIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "asdf!fdas@asdf.net"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1514405089"), aux);
            assert((num == 346), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_QUIETLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "qqqq!*@asdf.net"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1514405101"), aux);
            assert((num == 728), num.to!string);
        }
    }
}

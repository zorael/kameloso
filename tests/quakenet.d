import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    {
        immutable event = parser.toIRCEvent(":underworld1.no.quakenet.org 004 kameloso underworld1.no.quakenet.org u2.10.12.10+snircd(1.3.4a) dioswkgxRXInP biklmnopstvrDcCNuMT bklov");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "underworld1.no.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "dioswkgxRXInP biklmnopstvrDcCNuMT bklov"), content);
            assert((aux == "u2.10.12.10+snircd(1.3.4a)"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.snircd;
    server.daemonstring = "u2.10.12.10+snircd(1.3.4a)";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.snircd), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "u2.10.12.10+snircd(1.3.4a)"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":underworld1.no.quakenet.org 005 kameloso WHOX WALLCHOPS WALLVOICES USERIP CPRIVMSG CNOTICE SILENCE=15 MODES=6 MAXCHANNELS=20 MAXBANS=45 NICKLEN=15 :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "underworld1.no.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "WHOX WALLCHOPS WALLVOICES USERIP CPRIVMSG CNOTICE SILENCE=15 MODES=6 MAXCHANNELS=20 MAXBANS=45 NICKLEN=15"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.maxNickLength = 15;
    */

    with (parser.client)
    {
        assert((server.maxNickLength == 15), server.maxNickLength.to!string);
    }

    {
        immutable event = parser.toIRCEvent(":underworld1.no.quakenet.org 005 kameloso MAXNICKLEN=15 TOPICLEN=250 AWAYLEN=160 KICKLEN=250 CHANNELLEN=200 MAXCHANNELLEN=200 CHANTYPES=#& PREFIX=(ov)@+ STATUSMSG=@+ CHANMODES=b,k,l,imnpstrDducCNMT CASEMAPPING=rfc1459 NETWORK=QuakeNet :are supported by this server$");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "underworld1.no.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "MAXNICKLEN=15 TOPICLEN=250 AWAYLEN=160 KICKLEN=250 CHANNELLEN=200 MAXCHANNELLEN=200 CHANTYPES=#& PREFIX=(ov)@+ STATUSMSG=@+ CHANMODES=b,k,l,imnpstrDducCNMT CASEMAPPING=rfc1459 NETWORK=QuakeNet"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.network = "QuakeNet";
    server.daemonstring = "QuakeNet";
    server.aModes = "b";
    server.cModes = "l";
    server.dModes = "imnpstrDducCNMT";
    server.chantypes = "#&";
    server.caseMapping = IRCServer.CaseMapping.rfc1459;
    */

    with (parser.client)
    {
        assert((server.network == "QuakeNet"), server.network);
        assert((server.daemonstring == "QuakeNet"), server.daemonstring);
        assert((server.aModes == "b"), server.aModes);
        assert((server.cModes == "l"), server.cModes);
        assert((server.dModes == "imnpstrDducCNMT"), server.dModes);
        assert((server.chantypes == "#&"), server.chantypes);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), Enum!(IRCServer.CaseMapping).toString(server.caseMapping));
    }

    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 221 kameloso +i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_UMODEIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "+i"), aux);
            assert((num == 221), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 353 kameloso = #garderoben :@kameloso");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_NAMREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "@kameloso"), content);
            assert((num == 353), num.to!string);
        }
    }
}

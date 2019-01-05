import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    {
        immutable event = parser.toIRCEvent(":Portlane.SE.EU.GameSurge.net 004 kameloso Portlane.SE.EU.GameSurge.net u2.10.12.18(gs2) diOoswkgxnI biklmnopstvrDdRcCz bklov");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "Portlane.SE.EU.GameSurge.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "diOoswkgxnI biklmnopstvrDdRcCz bklov"), content);
            assert((aux == "u2.10.12.18(gs2)"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.u2;
    server.daemonstring = "u2.10.12.18(gs2)";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.u2), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "u2.10.12.18(gs2)"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":Portlane.SE.EU.GameSurge.net 005 kameloso WHOX WALLCHOPS WALLVOICES USERIP CPRIVMSG CNOTICE SILENCE=25 MODES=6 MAXCHANNELS=75 MAXBANS=100 NICKLEN=30 :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "Portlane.SE.EU.GameSurge.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "WHOX WALLCHOPS WALLVOICES USERIP CPRIVMSG CNOTICE SILENCE=25 MODES=6 MAXCHANNELS=75 MAXBANS=100 NICKLEN=30"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.maxNickLength = 30;
    */

    with (parser.client)
    {
        assert((server.maxNickLength == 30), server.maxNickLength.to!string);
    }

    {
        immutable event = parser.toIRCEvent(":Portlane.SE.EU.GameSurge.net 005 kameloso MAXNICKLEN=30 TOPICLEN=300 AWAYLEN=200 KICKLEN=300 CHANNELLEN=200 MAXCHANNELLEN=200 CHANTYPES=#& PREFIX=(ov)@+ STATUSMSG=@+ CHANMODES=b,k,l,imnpstrDdRcC CASEMAPPING=rfc1459 NETWORK=GameSurge :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "Portlane.SE.EU.GameSurge.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "MAXNICKLEN=30 TOPICLEN=300 AWAYLEN=200 KICKLEN=300 CHANNELLEN=200 MAXCHANNELLEN=200 CHANTYPES=#& PREFIX=(ov)@+ STATUSMSG=@+ CHANMODES=b,k,l,imnpstrDdRcC CASEMAPPING=rfc1459 NETWORK=GameSurge"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.network = "GameSurge";
    server.daemonstring = "GameSurge";
    server.aModes = "b";
    server.cModes = "l";
    server.dModes = "imnpstrDdRcC";
    server.chantypes = "#&";
    server.caseMapping = IRCServer.CaseMapping.rfc1459;
    */

    with (parser.client)
    {
        assert((server.network == "GameSurge"), server.network);
        assert((server.daemonstring == "GameSurge"), server.daemonstring);
        assert((server.aModes == "b"), server.aModes);
        assert((server.cModes == "l"), server.cModes);
        assert((server.dModes == "imnpstrDdRcC"), server.dModes);
        assert((server.chantypes == "#&"), server.chantypes);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), Enum!(IRCServer.CaseMapping).toString(server.caseMapping));
    }

    {
        immutable event = parser.toIRCEvent(":TAL.DE.EU.GameSurge.net 396 kameloso ~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4 :is now your hidden host");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_HOSTHIDDEN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "TAL.DE.EU.GameSurge.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4"), content);
            assert((aux == "is now your hidden host"), aux);
            assert((num == 396), num.to!string);
        }
    }

}

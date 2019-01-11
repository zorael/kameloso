import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    {
        immutable event = parser.toIRCEvent(":eggbert.ca.na.irchighway.net 004 kameloso eggbert.ca.na.irchighway.net InspIRCd-2.0 BIRSWghiorswx ACDIMNORSTabcdehiklmnopqrstvz Iabdehkloqv");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "eggbert.ca.na.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "BIRSWghiorswx ACDIMNORSTabcdehiklmnopqrstvz Iabdehkloqv"), content);
            assert((aux == "InspIRCd-2.0"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.inspircd;
    server.daemonstring = "InspIRCd-2.0";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.inspircd), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "InspIRCd-2.0"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":eggbert.ca.na.irchighway.net 005 kameloso AWAYLEN=200 CALLERID=g CASEMAPPING=rfc1459 CHANMODES=Ibe,k,dl,ACDMNORSTcimnprstz CHANNELLEN=64 CHANTYPES=# CHARSET=ascii ELIST=MU ESILENCE EXCEPTS=e EXTBAN=,ACNORSTUcjmz FNC INVEX=I :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "eggbert.ca.na.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "AWAYLEN=200 CALLERID=g CASEMAPPING=rfc1459 CHANMODES=Ibe,k,dl,ACDMNORSTcimnprstz CHANNELLEN=64 CHANTYPES=# CHARSET=ascii ELIST=MU ESILENCE EXCEPTS=e EXTBAN=,ACNORSTUcjmz FNC INVEX=I"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.maxChannelLength = 64;
    server.aModes = "Ibe";
    server.cModes = "dl";
    server.dModes = "ACDMNORSTcimnprstz";
    server.caseMapping = IRCServer.CaseMapping.rfc1459;
    server.extbanPrefix = '$';
    server.extbanTypes = "ACNORSTUcjmz";
    server.exceptsChar = 'e';
    server.invexChar = 'I';
    */

    with (parser.client)
    {
        assert((server.maxChannelLength == 64), server.maxChannelLength.to!string);
        assert((server.aModes == "Ibe"), server.aModes);
        assert((server.cModes == "dl"), server.cModes);
        assert((server.dModes == "ACDMNORSTcimnprstz"), server.dModes);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), Enum!(IRCServer.CaseMapping).toString(server.caseMapping));
        assert((server.extbanPrefix == '$'), server.extbanPrefix.to!string);
        assert((server.extbanTypes == "ACNORSTUcjmz"), server.extbanTypes);
        assert((server.exceptsChar == 'e'), server.exceptsChar.to!string);
        assert((server.invexChar == 'I'), server.invexChar.to!string);
    }

    {
        immutable event = parser.toIRCEvent(":eggbert.ca.na.irchighway.net 005 kameloso KICKLEN=255 MAP MAXBANS=60 MAXCHANNELS=30 MAXPARA=32 MAXTARGETS=20 MODES=20 NAMESX NETWORK=irchighway NICKLEN=31 PREFIX=(qaohv)~&@%+ SILENCE=32 SSL=10.0.30.4:6697 :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "eggbert.ca.na.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "KICKLEN=255 MAP MAXBANS=60 MAXCHANNELS=30 MAXPARA=32 MAXTARGETS=20 MODES=20 NAMESX NETWORK=irchighway NICKLEN=31 PREFIX=(qaohv)~&@%+ SILENCE=32 SSL=10.0.30.4:6697"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.network = "irchighway";
    server.daemonstring = "irchighway";
    server.maxNickLength = 31;
    server.prefixes = "qaohv";
    */

    with (parser.client)
    {
        assert((server.network == "irchighway"), server.network);
        assert((server.daemonstring == "irchighway"), server.daemonstring);
        assert((server.maxNickLength == 31), server.maxNickLength.to!string);
        assert((server.prefixes == "qaohv"), server.prefixes);
    }

    {
        immutable event = parser.toIRCEvent(":eggbert.ca.na.irchighway.net 005 kameloso STARTTLS STATUSMSG=~&@%+ TOPICLEN=307 UHNAMES USERIP VBANLIST WALLCHOPS WALLVOICES :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "eggbert.ca.na.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "STARTTLS STATUSMSG=~&@%+ TOPICLEN=307 UHNAMES USERIP VBANLIST WALLCHOPS WALLVOICES"), content);
            assert((num == 5), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":caliburn.pa.us.irchighway.net 042 kameloso 132AAMJT5 :your unique ID");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_YOURID), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "caliburn.pa.us.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "your unique ID"), content);
            assert((aux == "132AAMJT5"), aux);
            assert((num == 42), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":genesis.ks.us.irchighway.net CAP 867AAF66L LS :away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CAP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "genesis.ks.us.irchighway.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names"), content);
            assert((aux == "LS"), aux);
        }
    }
}

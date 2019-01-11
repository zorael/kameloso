import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    {
        immutable event = parser.toIRCEvent(":helix.oftc.net 004 kameloso helix.oftc.net hybrid-7.2.2+oftc1.7.3 CDGPRSabcdfgijklnorsuwxyz bciklmnopstvzeIMRS bkloveI");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "helix.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CDGPRSabcdfgijklnorsuwxyz bciklmnopstvzeIMRS bkloveI"), content);
            assert((aux == "hybrid-7.2.2+oftc1.7.3"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.hybrid;
    server.daemonstring = "hybrid-7.2.2+oftc1.7.3";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.hybrid), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "hybrid-7.2.2+oftc1.7.3"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":helix.oftc.net 005 kameloso CALLERID CASEMAPPING=rfc1459 DEAF=D KICKLEN=160 MODES=4 NICKLEN=30 PREFIX=(ov)@+ STATUSMSG=@+ TOPICLEN=391 NETWORK=OFTC MAXLIST=beI:100 MAXTARGETS=1 CHANTYPES=# :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "helix.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CALLERID CASEMAPPING=rfc1459 DEAF=D KICKLEN=160 MODES=4 NICKLEN=30 PREFIX=(ov)@+ STATUSMSG=@+ TOPICLEN=391 NETWORK=OFTC MAXLIST=beI:100 MAXTARGETS=1 CHANTYPES=#"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.network = "OFTC";
    server.daemonstring = "OFTC";
    server.maxNickLength = 30;
    server.caseMapping = IRCServer.CaseMapping.rfc1459;
    */

    with (parser.client)
    {
        assert((server.network == "OFTC"), server.network);
        assert((server.daemonstring == "OFTC"), server.daemonstring);
        assert((server.maxNickLength == 30), server.maxNickLength.to!string);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), Enum!(IRCServer.CaseMapping).toString(server.caseMapping));
    }

    {
        immutable event = parser.toIRCEvent(":helix.oftc.net 005 kameloso CHANLIMIT=#:90 CHANNELLEN=50 CHANMODES=eIqb,k,l,cimnpstzMRS AWAYLEN=160 KNOCK ELIST=CMNTU SAFELIST EXCEPTS=e INVEX=I :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "helix.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CHANLIMIT=#:90 CHANNELLEN=50 CHANMODES=eIqb,k,l,cimnpstzMRS AWAYLEN=160 KNOCK ELIST=CMNTU SAFELIST EXCEPTS=e INVEX=I"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.maxChannelLength = 50;
    server.aModes = "eIqb";
    server.cModes = "l";
    server.dModes = "cimnpstzMRS";
    server.exceptsChar = 'e';
    server.invexChar = 'I';
    */

    with (parser.client)
    {
        assert((server.maxChannelLength == 50), server.maxChannelLength.to!string);
        assert((server.aModes == "eIqb"), server.aModes);
        assert((server.cModes == "l"), server.cModes);
        assert((server.dModes == "cimnpstzMRS"), server.dModes);
        assert((server.exceptsChar == 'e'), server.exceptsChar.to!string);
        assert((server.invexChar == 'I'), server.invexChar.to!string);
    }

    {
        immutable event = parser.toIRCEvent(":helix.oftc.net 042 kameloso 4G4AAA7BH :your unique ID");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_YOURID), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "helix.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "your unique ID"), content);
            assert((aux == "4G4AAA7BH"), aux);
            assert((num == 42), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":kinetic.oftc.net 338 kameloso wh00nix 255.255.255.255 :actually using host");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISACTUALLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "kinetic.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "wh00nix"), target.nickname);
            assert((target.address == "255.255.255.255"), target.address);
            assert((content == "actually using host"), content);
            assert((num == 338), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.oftc.net 345 kameloso #garderoben :End of Channel Quiet List");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFQUIETLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            //assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "End of Channel Quiet List"), content);
            assert((num == 345), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.oftc.net 344 kameloso #garderoben harbl!snarbl@* kameloso!~NaN@194.117.188.126 1515418362");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_QUIETLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.oftc.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "harbl!snarbl@*"), content);
            assert((aux == "kameloso!~NaN@194.117.188.126 1515418362"), aux);
            assert((num == 344), num.to!string);
        }
    }
}

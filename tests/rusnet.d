import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    {
        immutable event = parser.toIRCEvent(":irc.run.net 004 kameloso irc.run.net 1.5.24/uk_UA.KOI8-U aboOirswx abcehiIklmnoOpqrstvz");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.run.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "aboOirswx abcehiIklmnoOpqrstvz"), content);
            assert((aux == "1.5.24/uk_UA.KOI8-U"), aux);
            assert((num == 4), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.unknown;
    server.daemonstring = "1.5.24/uk_UA.KOI8-U";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.unknown), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "1.5.24/uk_UA.KOI8-U"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":irc.run.net 005 kameloso PREFIX=(ohv)@%+ CODEPAGES MODES=3 CHANTYPES=#&!+ MAXCHANNELS=20 NICKLEN=31 TOPICLEN=255 KICKLEN=255 NETWORK=RusNet CHANMODES=beI,k,l,acimnpqrstz :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.run.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "PREFIX=(ohv)@%+ CODEPAGES MODES=3 CHANTYPES=#&!+ MAXCHANNELS=20 NICKLEN=31 TOPICLEN=255 KICKLEN=255 NETWORK=RusNet CHANMODES=beI,k,l,acimnpqrstz"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    server.daemon = IRCServer.Daemon.rusnet;
    server.daemonstring = "RusNet";
    server.maxNickLength = 31;
    server.aModes = "beI";
    server.cModes = "l";
    server.dModes = "acimnpqrstz";
    server.prefixes = "ohv";
    server.chantypes = "#&!+";
    */

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.rusnet), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "RusNet"), server.daemonstring);
        assert((server.maxNickLength == 31), server.maxNickLength.to!string);
        assert((server.aModes == "beI"), server.aModes);
        assert((server.cModes == "l"), server.cModes);
        assert((server.dModes == "acimnpqrstz"), server.dModes);
        assert((server.prefixes == "ohv"), server.prefixes);
        assert((server.chantypes == "#&!+"), server.chantypes);
    }

    {
        immutable event = parser.toIRCEvent(":irc.run.net 222 kameloso KOI8-U :is your charset now");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_CODEPAGE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.run.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "is your charset now"), content);
            assert((aux == "KOI8-U"), aux);
            assert((num == 222), num.to!string);
        }
    }
}

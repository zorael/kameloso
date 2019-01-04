import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    parser.client.nickname = "kameloso";

    {
        immutable event = parser.toIRCEvent(":lamia.uk.SpotChat.org 926 kameloso #stuffwecantdiscuss :Channel #stuffwecantdiscuss is forbidden: This channel is closed by request of the channel operators.");
        with (event)
        {
            assert((type == IRCEvent.Type.CHANNELFORBIDDEN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "lamia.uk.SpotChat.org"), sender.address);
            assert((channel == "#stuffwecantdiscuss"), channel);
            assert((content == "Channel #stuffwecantdiscuss is forbidden: This channel is closed by request of the channel operators."), content);
            assert((num == 926), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":lamia.ca.SpotChat.org 940 kameloso #garderoben :End of channel spamfilter list");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ENDOFSPAMFILTERLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "lamia.ca.SpotChat.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            //assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "End of channel spamfilter list"), content);
            assert((num == 940), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":lamia.ca.SpotChat.org 221 kameloso :+ix");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_UMODEIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "lamia.ca.SpotChat.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "+ix"), aux);
            assert((num == 221), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":Halcy0n!~Halcy0n@SpotChat-rauo6p.dyn.suddenlink.net AWAY :I'm busy");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == AWAY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "Halcy0n"), sender.nickname);
            assert((sender.ident == "~Halcy0n"), sender.ident);
            assert((sender.address == "SpotChat-rauo6p.dyn.suddenlink.net"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "I'm busy"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":Halcy0n!~Halcy0n@SpotChat-rauo6p.dyn.suddenlink.net AWAY");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == BACK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "Halcy0n"), sender.nickname);
            assert((sender.ident == "~Halcy0n"), sender.ident);
            assert((sender.address == "SpotChat-rauo6p.dyn.suddenlink.net"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
        }
    }
}


unittest
{
    IRCParser parser;

    with (parser.client)
    {
        server.daemon = IRCServer.Daemon.inspircd;
        server.network = "SpotChat";
        server.daemonstring = "inspircd";
    }

    {
        immutable event = parser.toIRCEvent(":medusa.us.SpotChat.org 005 kameloso AWAYLEN=200 CALLERID=g CASEMAPPING=rfc1459 CHANMODES=Ibeg,k,Jl,ACKMNOPQRSTcimnprstz CHANNELLEN=64 CHANTYPES=# CHARSET=ascii ELIST=MU EXCEPTS=e EXTBAN=,ACNOQRSTUcmz FNC INVEX=I KICKLEN=255 :are supported by this server");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "medusa.us.SpotChat.org"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "AWAYLEN=200 CALLERID=g CASEMAPPING=rfc1459 CHANMODES=Ibeg,k,Jl,ACKMNOPQRSTcimnprstz CHANNELLEN=64 CHANTYPES=# CHARSET=ascii ELIST=MU EXCEPTS=e EXTBAN=,ACNOQRSTUcmz FNC INVEX=I KICKLEN=255"), content);
            assert((num == 5), num.to!string);
        }
    }

    /*
    with (parser.client)
    {
        server.maxChannelLength = 64;
        server.aModes = "Ibeg";
        server.cModes = "Jl";
        server.dModes = "ACKMNOPQRSTcimnprstz";
        server.caseMapping = IRCServer.CaseMapping.rfc1459;
        server.extbanTypes = "ACNOQRSTUcmz";
    }
    */

    with (parser.client)
    {
        assert((server.maxChannelLength == 64), server.maxChannelLength.to!string);
        assert((server.aModes == "Ibeg"), server.aModes);
        assert((server.cModes == "Jl"), server.cModes);
        assert((server.dModes == "ACKMNOPQRSTcimnprstz"), server.dModes);
        assert((server.caseMapping == IRCServer.CaseMapping.rfc1459), server.caseMapping.to!string);
        assert((server.extbanTypes == "ACNOQRSTUcmz"), server.extbanTypes);
    }
}

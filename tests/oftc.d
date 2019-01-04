import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "irc.oftc.net";
        server.daemon = IRCServer.Daemon.hybrid;
        server.network = "OFTC";
        server.daemonstring = "hybrid-oftc";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

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
        version(none)
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

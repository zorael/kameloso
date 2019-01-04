import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "irc.gamesurge.net";
        server.daemon = IRCServer.Daemon.u2;
        server.network = "GameSurge";
        server.daemonstring = "u2";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

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

import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "irc.run.net";
        server.daemon = IRCServer.Daemon.rusnet;
        server.network = "rusnet";
        server.daemonstring = "rusnet";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

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

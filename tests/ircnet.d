import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "www.ircnet.net";
        server.daemon = IRCServer.Daemon.ircnet;
        server.network = "IRCnet";
        server.daemonstring = "ircnet";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

    {
        immutable event = parser.toIRCEvent(":irc.atw-inter.net 344 kameloso #debian.de towo!towo@littlelamb.szaf.org");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_REOPLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.atw-inter.net"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#debian.de"), channel);
            assert((content == "towo!towo@littlelamb.szaf.org"), content);
            assert((num == 344), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.atw-inter.net 345 kameloso #debian.de :End of Channel Reop List");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_ENDOFREOPLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.atw-inter.net"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#debian.de"), channel);
            assert((content == "End of Channel Reop List"), content);
            assert((num == 345), num.to!string);
        }
    }
}

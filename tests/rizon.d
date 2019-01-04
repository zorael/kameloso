import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    with (parser.client)
    {
        server.address = "irc.rizon.net";
        server.daemon = IRCServer.Daemon.rizon;
        server.network = "Rizon";
        server.daemonstring = "rizon";
        server.aModes = "eIbq";
        server.bModes = "k";
        server.cModes = "flj";
        server.dModes = "CFLMPQScgimnprstz";
        server.prefixchars = ['v':'+', 'o':'@'];
        server.prefixes = "ov";
    }

    parser.typenums = typenumsOf(parser.client.server.daemon);

    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 352 kameloso^^ * ~NaN C2802314.E23AD7D8.E9841504.IP * kameloso^^ H :0  kameloso!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "kameloso^^"), target.nickname);
            assert((target.ident == "~NaN"), target.ident);
            assert((target.address == "C2802314.E23AD7D8.E9841504.IP"), target.address);
            assert((content == "kameloso!"), content);
            assert((num == 352), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 265 kameloso^^ :Current local users: 14552  Max: 19744");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current local users: 14552  Max: 19744"), content);
            assert((num == 265), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 266 kameloso^^ :Current global users: 14552  Max: 19744");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current global users: 14552  Max: 19744"), content);
            assert((num == 266), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 265 kameloso^^ :Current local users: 16115  Max: 17360");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Current local users: 16115  Max: 17360"), content);
            assert((num == 265), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISREGNICK), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.x2x.cc"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "py-ctcp"), target.nickname);
            assert((content == "py-ctcp"), content);
            assert((num == 307), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NEEDPONG), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "PONG 3705964477"), content);
            assert((num == 513), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 524 kameloso^^ 502 :Help not found");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_HELPNOTFOUND), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Help not found"), content);
            assert((aux == "502"), aux);
            assert((num == 524), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 472 kameloso^^ X :is unknown mode char to me");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_UNKNOWNMODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "is unknown mode char to me"), content);
            assert((aux == "X"), aux);
            assert((num == 472), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 314 kameloso^^ kameloso ~NaN C2802314.E23AD7D8.E9841504.IP * : kameloso!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOWASUSER), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "~NaN C2802314.E23AD7D8.E9841504.IP *"), content);
            assert((aux == "kameloso!"), aux);
            assert((num == 314), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 351 kameloso^^ plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no :TS6ow");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_VERSION), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no"), content);
            assert((aux == "TS6ow"), aux);
            assert((num == 351), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 315 kameloso^^ * :End of /WHO list.");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ENDOFWHO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "End of /WHO list."), content);
            assert((num == 315), num.to!string);
        }
    }
}

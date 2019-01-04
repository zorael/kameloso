import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    parser.client.nickname = "kameloso";

    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 221 kameloso +i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_UMODEIS), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "+i"), aux);
            assert((num == 221), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 353 kameloso = #garderoben :@kameloso");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_NAMREPLY), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#garderoben"), channel);
            assert((content == "@kameloso"), content);
            assert((num == 353), num.to!string);
        }
    }
}

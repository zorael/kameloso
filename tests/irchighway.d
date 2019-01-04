import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;

    parser.client.nickname = "kameloso";

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

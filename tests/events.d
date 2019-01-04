import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;


unittest
{
    IRCParser parser;

    parser.client.nickname = "kameloso";

    {
        immutable event = parser.toIRCEvent("ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERROR), Enum!(IRCEvent.Type).toString(type));
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent("NOTICE kameloso :*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now."), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":miranda.chathispano.com 465 kameloso 1511086908 :[1511000504768] G-Lined by ChatHispano Network. Para mas informacion visite http://chathispano.com/gline/?id=<id> (expires at Dom, 19/11/2017 11:21:48 +0100).");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_YOUREBANNEDCREEP), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "miranda.chathispano.com"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "[1511000504768] G-Lined by ChatHispano Network. Para mas informacion visite http://chathispano.com/gline/?id=<id> (expires at Dom, 19/11/2017 11:21:48 +0100)."), content);
            assert((aux == "1511086908"), aux);
            assert((num == 465), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.RomaniaChat.eu 322 kameloso #GameOfThrones 1 :[+ntTGfB]");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.RomaniaChat.eu"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#gameofthrones"), channel);
            assert((content == "[+ntTGfB]"), content);
            assert((aux == "1"), aux);
            assert((num == 322), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.RomaniaChat.eu 322 kameloso #radioclick 63 :[+ntr]  Bun venit pe #Radioclick! Site oficial www.radioclick.ro sau servere irc.romaniachat.eu, irc.radioclick.ro");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.RomaniaChat.eu"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#radioclick"), channel);
            assert((content == "[+ntr]  Bun venit pe #Radioclick! Site oficial www.radioclick.ro sau servere irc.romaniachat.eu, irc.radioclick.ro"), content);
            assert((aux == "63"), aux);
            assert((num == 322), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":cadance.canternet.org 379 kameloso kameloso :is using modes +ix");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISMODES), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cadance.canternet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((aux == "+ix"), aux);
            assert((num == 379), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":Miyabro!~Miyabro@DA8192E8:4D54930F:650EE60D:IP CHGHOST ~Miyabro Miyako.is.mai.waifu");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHGHOST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "Miyabro"), sender.nickname);
            assert((sender.ident == "~Miyabro"), sender.ident);
            assert((sender.address == "Miyako.is.mai.waifu"), sender.address);
            assert((sender.class_ != IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
        }
    }
    {
        immutable event = parser.toIRCEvent(":Iasdf666!~Iasdf666@The.Breakfast.Club PRIVMSG #uk :be more welcoming you negative twazzock");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == CHAN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "Iasdf666"), sender.nickname);
            assert((sender.ident == "~Iasdf666"), sender.ident);
            assert((sender.address == "The.Breakfast.Club"), sender.address);
            assert((channel == "#uk"), channel);
            assert((content == "be more welcoming you negative twazzock"), content);
        }
    }
    {
        immutable event = parser.toIRCEvent(":gallon!~MO.11063@482c29a5.e510bf75.97653814.IP4 PART :#cncnet-yr");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == PART), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "gallon"), sender.nickname);
            assert((sender.ident == "~MO.11063"), sender.ident);
            assert((sender.address == "482c29a5.e510bf75.97653814.IP4"), sender.address);
            assert((channel == "#cncnet-yr"), channel);
        }
    }
    {
        immutable e24 = parser.toIRCEvent(":like.so 513 kameloso :To connect, type /QUOTE PONG 3705964477");
        with (e24)
        {
            assert((sender.address == "like.so"), sender.address);
            assert((type == IRCEvent.Type.ERR_NEEDPONG), Enum!(IRCEvent.Type).toString(type));
            assert((content == "PONG 3705964477"), content);
        }
    }
}


unittest
{
    IRCParser parser;

    immutable daemon = IRCServer.Daemon.inspircd;
    parser.typenums = typenumsOf(daemon);
    parser.client.server.daemon = daemon;
    parser.client.server.daemonstring = "inspircd";

    {
        immutable event = parser.toIRCEvent(":cadance.canternet.org 953 kameloso^ #flerrp :End of channel exemptchanops list");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ENDOFEXEMPTOPSLIST), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "cadance.canternet.org"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((channel == "#flerrp"), channel);
            assert((content == "End of channel exemptchanops list"), content);
             assert((num == 953), num.to!string);
        }
    }
}


unittest
{
    IRCParser parser;

    {
        immutable event = parser.toIRCEvent(":irc.portlane.se 020 * :Please wait while we process your connection.");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_HELLO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.portlane.se"), sender.address);
            assert((sender.class_ == special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Please wait while we process your connection."), content);
            assert((num == 20), num.to!string);
        }
    }

    with (parser.client)
    {
        assert(updated);
        assert((server.resolvedAddress == "irc.portlane.se"), server.resolvedAddress);
    }
}

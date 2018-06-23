import kameloso.irc;
import std.conv : to;

unittest
{
    IRCParser parser;
    parser.bot.nickname = "kameloso";

    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    immutable e1 = parser.toIRCEvent(":tepper.freenode.net NOTICE * :*** Checking Ident");
    with (e1)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert((content == "*** Checking Ident"), content);
    }

    /+
    [ERR_NICKNAMEINUSE] tepper.freenode.net (kameloso): "Nickname is already in use." (#433)
    :tepper.freenode.net 433 * kameloso :Nickname is already in use.
     +/
    immutable e2 = parser.toIRCEvent(":tepper.freenode.net 433 * kameloso :Nickname is already in use.");
    with (e2)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_NICKNAMEINUSE), type.to!string);
        assert((content == "Nickname is already in use."), content);
        assert((num == 433), num.to!string);
    }

    parser.bot.nickname = "kameloso^";

    /+
    [RPL_WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = parser.toIRCEvent(":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
    with (e3)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WELCOME), type.to!string);
        assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"),
               content);
        assert((num == 1), num.to!string);
    }

    /+
    [RPL_ENDOFMOTD] tepper.freenode.net (kameloso^): "End of /MOTD command." (#376)
    :tepper.freenode.net 376 kameloso^ :End of /MOTD command.
     +/
    immutable e4 = parser.toIRCEvent(":tepper.freenode.net 376 kameloso^ :End of /MOTD command.");
    with (e4)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_ENDOFMOTD), type.to!string);
        assert((content == "End of /MOTD command."), content);
        assert((num == 376), num.to!string);
    }

    /+
    [SELFMODE] kameloso^ (kameloso^) <+i>
    :kameloso^ MODE kameloso^ :+i
     +/
    immutable e5 = parser.toIRCEvent(":kameloso^ MODE kameloso^ :+i");
    with (e5)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((type == IRCEvent.Type.SELFMODE), type.to!string);
        assert((aux == "+i"), aux);
    }

    /+
    [QUERY] zorael (kameloso^): "sudo privmsg zorael :derp"
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp
     +/
    immutable e6 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp");
    with (e6)
    {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.QUERY), type.to!string); // Will this work?
        assert((target.nickname == "kameloso^"), target.nickname);
        assert((content == "sudo privmsg zorael :derp"), content);
    }

    /+
    [RPL_WHOISUSER] tepper.freenode.net (zorael): "~NaN ns3363704.ip-94-23-253.eu" <jr> (#311)
    :tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr
     +/
    immutable e7 = parser.toIRCEvent(":tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr");
    with (e7)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WHOISUSER), type.to!string);
        assert((target.nickname == "zorael"), target.nickname);
        assert((target.ident == "~NaN"), target.ident);
        assert((target.address == "ns3363704.ip-94-23-253.eu"), target.address);
        assert((content == "jr"), content);
        assert((num == 311), num.to!string);
    }

    /+
    [WHOISLOGIN] tepper.freenode.net (zurael): "is logged in as" <zorael> (#330)
    :tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as
     +/
    immutable e8 = parser.toIRCEvent(":tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as");
    with (e8)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WHOISACCOUNT), type.to!string);
        assert((target.nickname == "zurael"), target.nickname);
        assert((content == "zorael"), content);
        assert((target.account == "zorael"), target.account);
        assert((num == 330), num.to!string);
    }

    /+
    [PONG] tepper.freenode.net
    :tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net
     +/
    immutable e9 = parser.toIRCEvent(":tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net");
    with (e9)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.PONG), type.to!string);
        assert(!target.nickname.length, target.nickname); // More than the server and type is never parsed
    }

    /+
    [QUIT] wonderworld: "Remote host closed the connection"
    :wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection
     +/
    immutable e10 = parser.toIRCEvent(":wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de " ~
        "QUIT :Remote host closed the connection");
    with (e10)
    {
        assert((sender.nickname == "wonderworld"), sender.nickname);
        assert((type == IRCEvent.Type.QUIT), type.to!string);
        assert(!target.nickname.length, target.nickname);
        assert((content == "Remote host closed the connection"), content);
    }

    /+
    [MODE] zorael (kameloso^) [#flerrp] <+v>
    :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
     +/
     immutable e11 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^");
     with (e11)
     {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.MODE), type.to!string);
        assert((content == "kameloso^"), content);
        assert((channel == "#flerrp"), channel);
        assert((aux == "+v"), aux);
     }

     /+
     [17:10:44] [NUMERIC] irc.uworld.se (kameloso): "To connect type /QUOTE PONG 3705964477" (#513)
     :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
     +/
     immutable e12 = parser.toIRCEvent(":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477");
     with (e12)
     {
        assert((sender.address == "irc.uworld.se"), sender.address);
        assert((type == IRCEvent.Type.ERR_BADPING), type.to!string);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "PONG 3705964477"), content);
     }

    /+
    [20:55:14] [ERR_UNKNOWNCOMMAND] karatkievich.freenode.net (kameloso^) <systemd,#kde,#kubuntu,#archlinux, ...>
    :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...
    +/
    immutable e13 = parser.toIRCEvent(":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...");
    with (e13)
    {
        assert((sender.address == "karatkievich.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "systemd,#kde,#kubuntu,#archlinux ..."), content);
    }

    /+
    :asimov.freenode.net 421 kameloso^ sudo :Unknown command
    +/
    immutable e14 = parser.toIRCEvent(":asimov.freenode.net 421 kameloso^ sudo :Unknown command");
    with (e14)
    {
        assert((sender.address == "asimov.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "sudo"), content);
        assert((aux == "Unknown command"), aux);
    }

    /+
    :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :PING 1495974267 590878
    +/
    immutable e15 = parser.toIRCEvent(":wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :" ~
                     IRCControlCharacter.ctcp ~ "PING 1495974267 590878" ~
                     IRCControlCharacter.ctcp);
    with (e15)
    {
        assert((sender.nickname == "wob^2"), sender.nickname);
        assert((type == IRCEvent.Type.CTCP_PING), type.to!string);
        assert((content == "1495974267 590878"), content);
        assert((aux == "PING"), aux);
    }

    /+
    :beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas
    +/
    immutable e16 = parser.toIRCEvent(":beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas");
    with (e16)
    {
        assert((sender.nickname == "beLAban"), sender.nickname);
        assert((type == IRCEvent.Type.CHAN), type.to!string);
        assert((channel == "##networking"), channel);
        assert((content == "start at cpasdcas"), content);
    }

    /+
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :ACTION test test content
    +/
    immutable e17 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :" ~
                     IRCControlCharacter.ctcp ~ "ACTION 123 test test content" ~
                     IRCControlCharacter.ctcp);
    with (e17)
    {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.EMOTE), type.to!string);
        assert((channel == "#flerrp"), channel);
        assert((content == "123 test test content"), content);
    }

    version(TwitchSupport)
    {
        /+
        :tmi.twitch.tv HOSTTARGET #lirik :h1z1 -
        +/
        immutable e18 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :h1z1 -");
        with (e18)
        {
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((type == IRCEvent.Type.TWITCH_HOSTSTART), type.to!string);
            assert((channel == "#lirik"), channel);
            assert((content == "h1z1"), content);
            assert(!num, num.to!string);
        }

        /+
        :tmi.twitch.tv HOSTTARGET #hosting_channel :- [<number-of-viewers>]
        +/
        immutable e19 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :- 178");
        with (e19)
        {
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((type == IRCEvent.Type.TWITCH_HOSTEND), type.to!string);
            assert((channel == "#lirik"), channel);
            assert((num == 178), num.to!string);
        }

        /+
        :tmi.twitch.tv HOSTTARGET #lirik chu8 270
        +/
        immutable e20 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :chu8 270");
        with (e20)
        {
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((type == IRCEvent.Type.TWITCH_HOSTSTART), type.to!string);
            assert((channel == "#lirik"), channel);
            assert((content == "chu8"), content);
            assert((num == 270), num.to!string);
        }
    }

    immutable e21 = parser.toIRCEvent(":kameloso_!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso__");
    with (e21)
    {
        assert((sender.nickname == "kameloso_"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.NICK), type.to!string);
        assert((target.nickname == "kameloso__"), target.nickname);
    }

    immutable e22 = parser.toIRCEvent(":kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_");
    with (e22)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.SELFNICK), type.to!string);
        assert((target.nickname == "kameloso_"), target.nickname);
        assert((parser.bot.nickname == "kameloso_"), parser.bot.nickname);
    }
    /+
     [17:10:44] [NUMERIC] irc.uworld.se (kameloso): "To connect type /QUOTE PONG 3705964477" (#513)
     :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
     +/
    immutable e24 = parser.toIRCEvent(":like.so 513 kameloso :To connect, type /QUOTE PONG 3705964477");
    with (e24)
    {
        assert((sender.address == "like.so"), sender.address);
        assert((type == IRCEvent.Type.ERR_BADPING), type.to!string);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((content == "PONG 3705964477"), content);
    }

    {
        parser.bot.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: KICK #flerrp kameloso^ :kameloso^");

        with (event)
        {
            assert((type == IRCEvent.Type.SELFKICK), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
            assert((channel == "#flerrp"), channel);
            assert((content == "kameloso^"), content);
        }
    }
}


unittest
{
    IRCParser parser;

    {
        immutable event = parser.toIRCEvent("ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERROR), type.to!string);
            assert(sender.special, sender.special.to!string);
            assert((content == "Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent("@badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type= :asdcsa!asdcss@asdcsd.tmi.twitch.tv PRIVMSG #lirik :lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), type.to!string);
            assert((sender.nickname == "asdcsa"), sender.nickname);
            assert((sender.ident == "asdcss"), sender.ident);
            assert((sender.address == "asdcsd.tmi.twitch.tv"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#lirik"), channel);
            assert((content == "lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL"), content);
            assert((tags == "badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type="), tags);
        }
    }

    {
        immutable event = parser.toIRCEvent("NOTICE kameloso :*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), type.to!string);
            assert(sender.special, sender.special.to!string);
            assert((content == "*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now."), content);
        }
    }

    {
        immutable event = parser.toIRCEvent("@broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #zorael");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ROOMSTATE), type.to!string);
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#zorael"), channel);
            assert((tags == "broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0"), tags);
        }
    }

    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 353 kameloso = #garderoben :@kameloso");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_NAMREPLY), type.to!string);
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "@kameloso"), content);
            assert((num == 353), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 403 kameloso archlinux :No such channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NOSUCHCHANNEL), type.to!string);
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "archlinux"), channel);
            assert((content == "No such channel"), content);
            assert((num == 403), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 332 kameloso^ #garderoben :Are you employed, sir?");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_TOPIC), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "Are you employed, sir?"), content);
            assert((num == 332), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFNAMES), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "End of /NAMES list."), content);
            assert((num == 366), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":services. 328 kameloso^ #ubuntu :http://www.ubuntu.com");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNEL_URL), type.to!string);
            assert((sender.address == "services."), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#ubuntu"), channel);
            assert((content == "http://www.ubuntu.com"), content);
            assert((num == 328), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 477 kameloso^ #archlinux :Cannot join channel (+r) - you need to be identified with services");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NEEDREGGEDNICK), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#archlinux"), channel);
            assert((content == "Cannot join channel (+r) - you need to be identified with services"), content);
            assert((num == 477), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_NAMREPLY), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "kameloso^ ombudsman +kameloso @zorael @maku @klarrt"), content);
            assert((num == 353), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 352 kameloso ##linux LP9NDWY7Cy gentoo/contributor/Fieldy moon.freenode.net Fieldy H :0 Ni!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), type.to!string);
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "##linux"), channel);
            assert((target.nickname == "Fieldy"), target.nickname);
            assert((target.address == "gentoo/contributor/Fieldy"), target.address);
            assert((content == "Ni!"), content);
            assert((num == 352), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":moon.freenode.net 352 kameloso ##linux ~rahlff b29beb9d.rev.stofanet.dk orwell.freenode.net Axton H :0 Michael Rahlff");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), type.to!string);
            assert((sender.address == "moon.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "##linux"), channel);
            assert((target.nickname == "Axton"), target.nickname);
            assert((target.ident == "~rahlff"), target.ident);
            assert((target.address == "b29beb9d.rev.stofanet.dk"), target.address);
            assert((content == "Michael Rahlff"), content);
            assert((num == 352), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 352 kameloso^^ * ~NaN C2802314.E23AD7D8.E9841504.IP * kameloso^^ H :0  kameloso!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOREPLY), type.to!string);
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "kameloso^^"), target.nickname);
            assert((target.ident == "~NaN"), target.ident);
            assert((target.address == "C2802314.E23AD7D8.E9841504.IP"), target.address);
            assert((content == "kameloso!"), content);
            assert((num == 352), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":tolkien.freenode.net 315 kameloso^ ##linux :End of /WHO list.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFWHO), type.to!string);
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "##linux"), channel);
            assert((content == "End of /WHO list."), content);
            assert((num == 315), num.to!string);
        }
    }

    {
        parser.bot.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":tolkien.freenode.net 301 kameloso^ jcjordyn120 :Idle");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_AWAY), type.to!string);
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "jcjordyn120"), target.nickname);
            assert((content == "Idle"), content);
            assert((num == 301), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_MOTD), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "- In particular we would like to thank the sponsor"), content);
            assert((num == 372), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 005 CHANTYPES=# EXCEPTS INVEX MODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ISUPPORT), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "EXCEPTS INVEX MODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459"), content);
            assert((num == 5), num.to!string);
        }
        assert((parser.bot.server.network == "freenode"), parser.bot.server.network);
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_MYINFO), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI"), content);
            assert((aux == "ircd-seven-1.1.4"), aux);
            assert((num == 4), num.to!string);
        }
        assert(parser.bot.server.daemon == IRCServer.daemon.ircdseven);
    }

    version(TwitchSupport)
    {
        {
            parser.bot.server.address = "tmi.twitch.tv";
            immutable event = parser.toIRCEvent(":tmi.twitch.tv 004 zorael :-");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == RPL_MYINFO), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert((num == 4), num.to!string);
            }
            assert((parser.bot.server.network == "Twitch"), parser.bot.server.network);
            assert(parser.bot.server.daemon == IRCServer.daemon.twitch);
        }
    }


    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_TOPICWHOTIME), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com"), content);
            assert((aux == "1476294377"), aux);
            assert((num == 333), num.to!string);
        }
    }

    {
        assert((parser.bot.nickname == "kameloso^"), parser.bot.nickname);
        immutable event = parser.toIRCEvent(":wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISHOST), type.to!string);
            assert((sender.address == "wilhelm.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "81-233-105-62-no80.tbcn.telia.com"), content);
            assert((aux == "81.233.105.62"), aux);
            assert((num == 378), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,...");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_UNKNOWNCOMMAND), type.to!string);
            assert((sender.address == "karatkievich.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "systemd,#kde,#kubuntu,..."), content);
            assert((num == 421), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 421 kameloso^ sudo :Unknown command");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_UNKNOWNCOMMAND), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "sudo"), content);
            assert((aux == "Unknown command"), aux);
            assert((num == 421), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":rajaniemi.freenode.net 317 kameloso zorael 0 1510219961 :seconds idle, signon time");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISIDLE), type.to!string);
            assert((sender.address == "rajaniemi.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "0"), content);
            assert((aux == "1510219961"), aux);
            assert((num == 317), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 252 kameloso^ 31 :IRC Operators online");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LUSEROP), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "IRC Operators online"), content);
            assert((aux == "31"), aux);
            assert((num == 252), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 253 kameloso^ 13 :unknown connection(s)");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LUSERUNKNOWN), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "unknown connection(s)"), content);
            assert((aux == "13"), aux);
            assert((num == 253), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 254 kameloso^ 54541 :channels formed");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LUSERCHANNELS), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "channels formed"), content);
            assert((aux == "54541"), aux);
            assert((num == 254), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 432 kameloso^ @nickname :Erroneous Nickname");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_ERRONEOUSNICKNAME), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Erroneous Nickname"), content);
            assert((aux == "@nickname"), aux);
            assert((num == 432), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 461 kameloso^ JOIN :Not enough parameters");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NEEDMOREPARAMS), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Not enough parameters"), content);
            assert((aux == "JOIN"), aux);
            assert((num == 461), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 265 kameloso^ 6500 11061 :Current local users 6500, max 11061");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current local users 6500, max 11061"), content);
            assert((aux == "6500 11061"), aux);
            assert((num == 265), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 266 kameloso^ 85267 92341 :Current global users 85267, max 92341");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current global users 85267, max 92341"), content);
            assert((aux == "85267 92341"), aux);
            assert((num == 266), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 265 kameloso^^ :Current local users: 14552  Max: 19744");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), type.to!string);
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current local users: 14552  Max: 19744"), content);
            assert((num == 265), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 266 kameloso^^ :Current global users: 14552  Max: 19744");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), type.to!string);
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current global users: 14552  Max: 19744"), content);
            assert((num == 266), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 265 kameloso 3385 6820 :Current local users 3385, max 6820");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), type.to!string);
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current local users 3385, max 6820"), content);
            assert((aux == "3385 6820"), aux);
            assert((num == 265), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 266 kameloso 87056 93012 :Current global users 87056, max 93012");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_GLOBALUSERS), type.to!string);
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current global users 87056, max 93012"), content);
            assert((aux == "87056 93012"), aux);
            assert((num == 266), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 265 kameloso^^ :Current local users: 16115  Max: 17360");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOCALUSERS), type.to!string);
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Current local users: 16115  Max: 17360"), content);
            assert((num == 265), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":orwell.freenode.net 311 kameloso^ kameloso ~NaN ns3363704.ip-94-23-253.eu * : kameloso");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISUSER), type.to!string);
            assert((sender.address == "orwell.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.ident == "~NaN"), target.ident);
            assert((target.address == "ns3363704.ip-94-23-253.eu"), target.address);
            assert((content == "kameloso"), content);
            assert((num == 311), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 671 kameloso^ zorael :is using a secure connection");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISSECURE), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "is using a secure connection"), content);
            assert((num == 671), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 318 kameloso^ zorael :End of /WHOIS list.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFWHOIS), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "zorael"), target.nickname);
            assert((content == "End of /WHOIS list."), content);
            assert((num == 318), num.to!string);
        }
    }

    {
        assert((parser.bot.nickname == "kameloso^"), parser.bot.nickname);
        immutable event = parser.toIRCEvent(":asimov.freenode.net 433 kameloso^ kameloso :Nickname is already in use.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NICKNAMEINUSE), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Nickname is already in use."), content);
            assert((num == 433), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 401 kameloso^ cherryh.freenode.net :No such nick/channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_NOSUCHNICK), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((aux == "cherryh.freenode.net"), aux);
            assert((content == "No such nick/channel"), content);
            assert((num == 401), num.to!string);
        }
    }

    {
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE"
        immutable event = parser.toIRCEvent(":lightning.ircstorm.net 313 kameloso^ NickServ :is a Network Service");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISOPERATOR), type.to!string);
            assert((sender.address == "lightning.ircstorm.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "NickServ"), target.nickname);
            assert((content == "is a Network Service"), content);
            assert((num == 313), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISACCOUNT), type.to!string);
            assert((sender.address == "asimov.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "xurael"), target.nickname);
            assert((target.account == "zorael"), target.account);
            assert((content == "zorael"), content);
            assert((num == 330), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISREGNICK), type.to!string);
            assert((sender.address == "irc.x2x.cc"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "py-ctcp"), target.nickname);
            assert((content == "py-ctcp"), content);
            assert((num == 307), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.x2x.cc 307 kameloso^^ wob^2 :has identified for this nick:irc.harblwefwoi.org 451 WHOIS :You have not registered");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISREGNICK), type.to!string);
            assert((sender.address == "irc.x2x.cc"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "wob^2"), target.nickname);
            assert((content == "wob^2"), content);
            assert((num == 307), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":adams.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WELCOME), type.to!string);
            assert((sender.address == "adams.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"), content);
            assert((num == 1), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_BADPING), type.to!string);
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "PONG 3705964477"), content);
            assert((num == 513), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 704 kameloso^ index :Help topics available to users:");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_HELPSTART), type.to!string);
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "Help topics available to users:"), content);
            assert((aux == "index"), aux);
            assert((num == 704), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_HELPTXT), type.to!string);
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "ACCEPT\tADMIN\tAWAY\tCHALLENGE"), content);
            assert((aux == "index"), aux);
            assert((num == 705), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":leguin.freenode.net 706 kameloso^ index :End of /HELP.// :leguin.freenode.net 706 kameloso^ index :End of /HELP.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ENDOFHELP), type.to!string);
            assert((sender.address == "leguin.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "End of /HELP.// :leguin.freenode.net 706 kameloso^ index :End of /HELP."), content);
            assert((aux == "index"), aux);
            assert((num == 706), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_BANONCHAN), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#d3d9"), channel);
            assert((content == "Cannot change nickname while banned on channel"), content);
            assert((aux == "kameloso^^"), aux);
            assert((num == 435), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":tmi.twitch.tv CAP * LS :twitch.tv/tags twitch.tv/commands twitch.tv/membership");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CAP), type.to!string);
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "twitch.tv/tags twitch.tv/commands twitch.tv/membership"), content);
            assert((aux == "LS"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":genesis.ks.us.irchighway.net CAP 867AAF66L LS :away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CAP), type.to!string);
            assert((sender.address == "genesis.ks.us.irchighway.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names"), content);
            assert((aux == "LS"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: TOPIC #garderoben :en greps av hybris, sen var de bara fyra");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == TOPIC), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "en greps av hybris, sen var de bara fyra"), content);
        }
    }

    version(TwitchSupport)
    {
        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv USERSTATE #zorael");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == USERSTATE), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert(!content.length, content);
                assert((channel == "#zorael"), channel);
            }
        }

        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv ROOMSTATE #zorael");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == ROOMSTATE), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert(!content.length, content);
                assert((channel == "#zorael"), channel);
            }
        }

        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #andymilonakis :zombie_barricades -");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == TWITCH_HOSTSTART), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert((channel == "#andymilonakis"), channel);
                assert((content == "zombie_barricades"), content);
            }
        }

        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv USERNOTICE #drdisrespectlive :ooooo weee, it's a meeeee, Moweee!");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == USERNOTICE), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert((channel == "#drdisrespectlive"), channel);
                assert((content == "ooooo weee, it's a meeeee, Moweee!"), content);
            }
        }

        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv USERNOTICE #lirik");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == USERNOTICE), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert((channel == "#lirik"), channel);
            }
        }

        {
            immutable event = parser.toIRCEvent(":tmi.twitch.tv CLEARCHAT #channel :user");
            with (IRCEvent.Type)
            with (event)
            {
                assert((type == CLEARCHAT), type.to!string);
                assert((sender.address == "tmi.twitch.tv"), sender.address);
                assert(sender.special, sender.special.to!string);
                assert((channel == "#channel"), channel);
                assert((target.nickname == "user"), target.nickname);
            }
        }
    }

    {
        immutable event = parser.toIRCEvent(":weber.freenode.net 900 kameloso kameloso!NaN@194.117.188.126 kameloso :You are now logged in as kameloso.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LOGGEDIN), type.to!string);
            assert((sender.address == "weber.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "kameloso"), target.nickname);
            assert((target.ident == "NaN"), target.ident);
            assert((target.address == "194.117.188.126"), target.address);
            assert((target.account == "kameloso"), target.account);
            assert((content == "You are now logged in as kameloso."), content);
            assert((num == 900), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":ski7777!~quassel@ip5b435007.dynamic.kabel-deutschland.de ACCOUNT ski7777");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ACCOUNT), type.to!string);
            assert((sender.nickname == "ski7777"), sender.nickname);
            assert((sender.ident == "~quassel"), sender.ident);
            assert((sender.address == "ip5b435007.dynamic.kabel-deutschland.de"), sender.address);
            assert((sender.account == "ski7777"), sender.account);
            assert(!sender.special, sender.special.to!string);
            assert((content == "ski7777"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 351 kameloso^^ plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no :TS6ow");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_VERSION), type.to!string);
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no"), content);
            assert((aux == "TS6ow"), aux);
            assert((num == 351), num.to!string);
        }
    }


    {
        parser.setDaemon(IRCServer.Daemon.u2, "GameSurge");
        immutable event = parser.toIRCEvent(":TAL.DE.EU.GameSurge.net 396 kameloso ~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4 :is now your hidden host");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_HOSTHIDDEN), type.to!string);
            assert((sender.address == "TAL.DE.EU.GameSurge.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4"), content);
            assert((aux == "is now your hidden host"), aux);
            assert((num == 396), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":caliburn.pa.us.irchighway.net 042 kameloso 132AAMJT5 :your unique ID");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_YOURID), type.to!string);
            assert((sender.address == "caliburn.pa.us.irchighway.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "your unique ID"), content);
            assert((aux == "132AAMJT5"), aux);
            assert((num == 42), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.rizon.no 524 kameloso^^ 502 :Help not found");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_HELPNOTFOUND), type.to!string);
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert(sender.special, sender.special.to!string);
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
            assert((type == ERR_UNKNOWNMODE), type.to!string);
            assert((sender.address == "irc.rizon.no"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "is unknown mode char to me"), content);
            assert((aux == "X"), aux);
            assert((num == 472), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":miranda.chathispano.com 465 kameloso 1511086908 :[1511000504768] G-Lined by ChatHispano Network. Para mas informacion visite http://chathispano.com/gline/?id=<id> (expires at Dom, 19/11/2017 11:21:48 +0100).");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_YOUREBANNEDCREEP), type.to!string);
            assert((sender.address == "miranda.chathispano.com"), sender.address);
            assert(sender.special, sender.special.to!string);
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
            assert((type == RPL_LIST), type.to!string);
            assert((sender.address == "irc.RomaniaChat.eu"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#GameOfThrones"), channel);
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
            assert((type == RPL_LIST), type.to!string);
            assert((sender.address == "irc.RomaniaChat.eu"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#radioclick"), channel);
            assert((content == "[+ntr]  Bun venit pe #Radioclick! Site oficial www.radioclick.ro sau servere irc.romaniachat.eu, irc.radioclick.ro"), content);
            assert((aux == "63"), aux);
            assert((num == 322), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 321 kameloso^ Channel :Users  Name");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_LISTSTART), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((num == 321), num.to!string);
        }
    }

    {
        parser.bot.nickname = "kameloso";
        immutable event = parser.toIRCEvent(":wolfe.freenode.net 470 kameloso #linux ##linux :Forwarding to another channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_LINKCHANNEL), type.to!string);
            assert((sender.address == "wolfe.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#linux"), channel);
            assert((content == "##linux"), content);
            assert((num == 470), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cadance.canternet.org 379 kameloso kameloso :is using modes +ix");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISMODES), type.to!string);
            assert((sender.address == "cadance.canternet.org"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((aux == "+ix"), aux);
            assert((num == 379), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.uworld.se 314 kameloso^^ kameloso ~NaN C2802314.E23AD7D8.E9841504.IP * : kameloso!");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOWASUSER), type.to!string);
            assert((sender.address == "irc.uworld.se"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "~NaN C2802314.E23AD7D8.E9841504.IP *"), content);
            assert((aux == "kameloso!"), aux);
            assert((num == 314), num.to!string);
        }
    }

    {
        parser.bot.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":orwell.freenode.net 443 kameloso^ kameloso #flerrp :is already on channel");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_USERONCHANNEL), type.to!string);
            assert((sender.address == "orwell.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "is already on channel"), content);
            assert((num == 443), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":port80b.se.quakenet.org 221 kameloso +i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_UMODEIS), type.to!string);
            assert((sender.address == "port80b.se.quakenet.org"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((aux == "+i"), aux);
            assert((num == 221), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflohomeOnlyw] Make sure your nick is registered, then please try again to join ##linux.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), type.to!string);
            assert((sender.nickname == "ChanServ"), sender.nickname);
            assert((sender.ident == "ChanServ"), sender.ident);
            assert((sender.address == "services."), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "[##linux-overflohomeOnlyw] Make sure your nick is registered, then please try again to join ##linux."), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), type.to!string);
            assert((sender.nickname == "ChanServ"), sender.nickname);
            assert((sender.ident == "ChanServ"), sender.ident);
            assert((sender.address == "services."), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "[#ubuntu] Welcome to #ubuntu! Please read the channel topic."), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":tolkien.freenode.net NOTICE * :*** Checking Ident");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == NOTICE), type.to!string);
            assert((sender.address == "tolkien.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "*** Checking Ident"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "test test content"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == QUERY), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((target.nickname == "kameloso^"), target.nickname);
            assert((content == "test test content"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "kameloso^"), content);
            assert((aux == "+v"), aux);
        }
    }


    {
        immutable event = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), type.to!string);
            assert((sender.nickname == "zorael"), sender.nickname);
            assert((sender.ident == "~NaN"), sender.ident);
            assert((sender.address == "ns3363704.ip-94-23-253.eu"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((aux == "+i"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":niven.freenode.net MODE #sklabjoier +ns");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == MODE), type.to!string);
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#sklabjoier"), channel);
            assert((aux == "+ns"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":kameloso^ MODE kameloso^ :+i");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == SELFMODE), type.to!string);
            assert((sender.nickname == "kameloso^"), sender.nickname);
            assert(!sender.special, sender.special.to!string);
            assert((aux == "+i"), aux);
        }
    }

    {
        immutable event = parser.toIRCEvent(":cherryh.freenode.net 005 CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST :are supported by this server");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_ISUPPORT), type.to!string);
            assert((sender.address == "cherryh.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST"), content);
            assert((num == 5), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":server.net 465 kameloso :You are banned from this server- Your irc client seems broken and is flooding lots of channels. Banned for 240 min, if in error, please contact kline@freenode.net. (2017/12/1 21.08)");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ERR_YOUREBANNEDCREEP), type.to!string);
            assert((sender.address == "server.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "You are banned from this server- Your irc client seems broken and is flooding lots of channels. Banned for 240 min, if in error, please contact kline@freenode.net. (2017/12/1 21.08)"), content);
            assert((num == 465), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":ASDphBa|zzZ!~ASDphBa@a.asdphs-tech.com PRIVMSG #d :does anyone know how the unittest stuff is working with cmake-d?");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHAN), type.to!string);
            assert((sender.nickname == "ASDphBa|zzZ"), sender.nickname);
            assert((sender.ident == "~ASDphBa"), sender.ident);
            assert((sender.address == "a.asdphs-tech.com"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((channel == "#d"), channel);
            assert((content == "does anyone know how the unittest stuff is working with cmake-d?"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 324 kameloso #flerrp +ns");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNELMODEIS), type.to!string);
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((aux == "+ns"), aux);
            assert((num == 324), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 329 kameloso #flerrp 1512995737");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CREATIONTIME), type.to!string);
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((aux == "1512995737"), aux);
            assert((num == 329), num.to!string);
        }
    }

    {
        parser.bot.nickname = "kameloso";
        immutable event = parser.toIRCEvent(":kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_BANLIST), type.to!string);
            assert((sender.address == "kornbluth.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), "channel is " ~ channel);
            assert((content == "harbl!harbl@snarbl.com"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1513899521"), aux);
            assert((num == 367), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":lamia.ca.SpotChat.org 940 kameloso #garderoben :End of channel spamfilter list");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ENDOFSPAMFILTERLIST), type.to!string);
            assert((sender.address == "lamia.ca.SpotChat.org"), sender.address);
            assert(sender.special, sender.special.to!string);
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
            assert((type == RPL_UMODEIS), type.to!string);
            assert((sender.address == "lamia.ca.SpotChat.org"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((aux == "+ix"), aux);
            assert((num == 221), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":Halcy0n!~Halcy0n@SpotChat-rauo6p.dyn.suddenlink.net AWAY :I'm busy");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == AWAY), type.to!string);
            assert((sender.nickname == "Halcy0n"), sender.nickname);
            assert((sender.ident == "~Halcy0n"), sender.ident);
            assert((sender.address == "SpotChat-rauo6p.dyn.suddenlink.net"), sender.address);
            assert(!sender.special, sender.special.to!string);
            assert((content == "I'm busy"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":Halcy0n!~Halcy0n@SpotChat-rauo6p.dyn.suddenlink.net AWAY");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == BACK), type.to!string);
            assert((sender.nickname == "Halcy0n"), sender.nickname);
            assert((sender.ident == "~Halcy0n"), sender.ident);
            assert((sender.address == "SpotChat-rauo6p.dyn.suddenlink.net"), sender.address);
            assert(!sender.special, sender.special.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":irc.oftc.net 345 kameloso #garderoben :End of Channel Quiet List");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_INVITED), type.to!string);
            assert((sender.address == "irc.oftc.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            //assert((target.nickname == "kameloso"), target.nickname);
            assert((content == "End of Channel Quiet List"), content);
            assert((num == 345), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_CHANNELMODEIS), type.to!string);
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "##linux"), channel);
            assert((content == "##linux-overflow"), content);
            assert((aux == "+CLPcnprtf"), aux);
            assert((num == 324), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":caliburn.pa.us.irchighway.net 042 kameloso 132AAMJT5 :your unique ID");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_YOURID), type.to!string);
            assert((sender.address == "caliburn.pa.us.irchighway.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((content == "your unique ID"), content);
            assert((aux == "132AAMJT5"), aux);
            assert((num == 42), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":kinetic.oftc.net 338 kameloso wh00nix 255.255.255.255 :actually using host");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_WHOISACTUALLY), type.to!string);
            assert((sender.address == "kinetic.oftc.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((target.nickname == "wh00nix"), target.nickname);
            assert((target.address == "255.255.255.255"), target.address);
            assert((content == "actually using host"), content);
            assert((num == 338), num.to!string);
        }
    }

    {
        parser.bot.nickname = "kameloso^";
        immutable event = parser.toIRCEvent(":niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_INVITELIST), type.to!string);
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "asdf!fdas@asdf.net"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1514405089"), aux);
            assert((num == 346), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_QUIETLIST), type.to!string);
            assert((sender.address == "niven.freenode.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "qqqq!*@asdf.net"), content);
            assert((aux == "zorael!~NaN@2001:41d0:2:80b4:: 1514405101"), aux);
            assert((num == 728), num.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":Miyabro!~Miyabro@DA8192E8:4D54930F:650EE60D:IP CHGHOST ~Miyabro Miyako.is.mai.waifu");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == CHGHOST), type.to!string);
            assert((sender.nickname == "Miyabro"), sender.nickname);
            assert((sender.ident == "~Miyabro"), sender.ident);
            assert((sender.address == "Miyako.is.mai.waifu"), sender.address);
            assert(!sender.special, sender.special.to!string);
        }
    }

    {
        immutable event = parser.toIRCEvent(":Iasdf666!~Iasdf666@The.Breakfast.Club PRIVMSG #uk :be more welcoming you negative twazzock");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == CHAN), type.to!string);
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
            assert((type == PART), type.to!string);
            assert((sender.nickname == "gallon"), sender.nickname);
            assert((sender.ident == "~MO.11063"), sender.ident);
            assert((sender.address == "482c29a5.e510bf75.97653814.IP4"), sender.address);
            assert((channel == "#cncnet-yr"), channel);
        }
    }
}

unittest
{
    IRCParser parser;
    parser.setDaemon(IRCServer.Daemon.hybrid, "hybrid-oftc");

    {
        immutable event = parser.toIRCEvent(":irc.oftc.net 344 kameloso #garderoben harbl!snarbl@* kameloso!~NaN@194.117.188.126 1515418362");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == RPL_QUIETLIST), type.to!string);
            assert((sender.address == "irc.oftc.net"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#garderoben"), channel);
            assert((content == "harbl!snarbl@*"), content);
            assert((aux == "kameloso!~NaN@194.117.188.126 1515418362"), aux);
            assert((num == 344), num.to!string);
        }
    }
}

unittest
{
    IRCParser parser;
    parser.setDaemon(IRCServer.Daemon.inspircd, "inspircd");

    {
        immutable event = parser.toIRCEvent(":cadance.canternet.org 953 kameloso^ #flerrp :End of channel exemptchanops list");
        with (IRCEvent.Type)
        with (event)
        {
            assert((type == ENDOFEXEMPTOPSLIST), type.to!string);
            assert((sender.address == "cadance.canternet.org"), sender.address);
            assert(sender.special, sender.special.to!string);
            assert((channel == "#flerrp"), channel);
            assert((content == "End of channel exemptchanops list"), content);
             assert((num == 953), num.to!string);
        }
    }
}

unittest
{
    IRCParser parser;
    parser.setDaemon(IRCServer.Daemon.ircnet, "IRCnet");

    {
        immutable event = parser.toIRCEvent(":irc.atw-inter.net 344 kameloso #debian.de towo!towo@littlelamb.szaf.org");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_REOPLIST), type.to!string);
            assert((sender.address == "irc.atw-inter.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
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
            assert((type == RPL_ENDOFREOPLIST), type.to!string);
            assert((sender.address == "irc.atw-inter.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((channel == "#debian.de"), channel);
            assert((content == "End of Channel Reop List"), content);
            assert((num == 345), num.to!string);
        }
    }
}

unittest
{
    IRCParser parser;
    parser.bot.nickname = "kameloso";
    parser.setDaemon(IRCServer.Daemon.ircdseven, "freenode");

    {
        immutable event = parser.toIRCEvent(":livingstone.freenode.net 249 kameloso p :dax (dax@freenode/staff/dax)");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_STATSDEBUG), type.to!string);
            assert((sender.address == "livingstone.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "dax (dax@freenode/staff/dax)"), content);
            assert((aux == "p"), aux);
            assert((num == 249), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":livingstone.freenode.net 219 kameloso p :End of /STATS report");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_ENDOFSTATS), type.to!string);
            assert((sender.address == "livingstone.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "End of /STATS report"), content);
            assert((aux == "p"), aux);
            assert((num == 219), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":verne.freenode.net 211 kameloso^ kameloso^[~NaN@194.117.188.126] 0 109 8 15 0 :40 0 -");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_STATSLINKINFO), type.to!string);
            assert((sender.address == "verne.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "40 0 -"), content);
            assert((aux == "kameloso^[~NaN@194.117.188.126] 0 109 8 15 0"), aux);
            assert((num == 211), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":verne.freenode.net 263 kameloso^ STATS :This command could not be completed because it has been used recently, and is rate-limited");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_TRYAGAIN), type.to!string);
            assert((sender.address == "verne.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "This command could not be completed because it has been used recently, and is rate-limited"), content);
            assert((aux == "STATS"), aux);
            assert((num == 263), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":verne.freenode.net 262 kameloso^ verne.freenode.net :End of TRACE");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_TRACEEND), type.to!string);
            assert((sender.address == "verne.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "End of TRACE"), content);
            assert((aux == "verne.freenode.net"), aux);
            assert((num == 262), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":wolfe.freenode.net 205 kameloso^ User v6users zorael[~NaN@2001:41d0:2:80b4::] (255.255.255.255) 16 :536");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_TRACEUSER), type.to!string);
            assert((sender.address == "wolfe.freenode.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "536"), content);
            assert((aux == "User v6users zorael[~NaN@2001:41d0:2:80b4::] (255.255.255.255) 16"), aux);
            assert((num == 205), num.to!string);
        }
    }
    {
        immutable event = parser.toIRCEvent(":irc.run.net 222 kameloso KOI8-U :is your charset now");
        with (IRCEvent.Type)
        with (IRCUser.Class)
        with (event)
        {
            assert((type == RPL_CODEPAGE), type.to!string);
            assert((sender.address == "irc.run.net"), sender.address);
            assert((sender.class_ == special), sender.class_.to!string);
            assert((content == "is your charset now"), content);
            assert((aux == "KOI8-U"), aux);
            assert((num == 222), num.to!string);
        }
    }
}

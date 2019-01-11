import kameloso.conv : Enum;
import kameloso.irc;
import std.conv : to;


unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

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
    parser.client.nickname = "kameloso^";  // Because we removed the default value

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


unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    with (parser.client)
    {
        server.address = "efnet.port80.se";
    }

    {
        immutable event = parser.toIRCEvent(":efnet.port80.se 004 kameloso efnet.port80.se ircd-ratbox-3.0.9 oiwszcrkfydnxbauglZCD biklmnopstveIrS bkloveI");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "efnet.port80.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "oiwszcrkfydnxbauglZCD biklmnopstveIrS bkloveI"), content);
            assert((aux == "ircd-ratbox-3.0.9"), aux);
            assert((num == 4), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.ratbox), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "ircd-ratbox-3.0.9"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":efnet.port80.se 005 kameloso CHANTYPES=&# EXCEPTS INVEX CHANMODES=eIb,k,l,imnpstS CHANLIMIT=&#:50 PREFIX=(ov)@+ MAXLIST=beI:100 MODES=4 NETWORK=EFnet KNOCK STATUSMSG=@+ CALLERID=g :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "efnet.port80.se"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CHANTYPES=&# EXCEPTS INVEX CHANMODES=eIb,k,l,imnpstS CHANLIMIT=&#:50 PREFIX=(ov)@+ MAXLIST=beI:100 MODES=4 NETWORK=EFnet KNOCK STATUSMSG=@+ CALLERID=g"), content);
            assert((num == 5), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.network == "EFnet"), server.network);
        assert((server.daemonstring == "EFnet"), server.daemonstring);
        assert((server.aModes == "eIb"), server.aModes);
        assert((server.bModes == "k"), server.bModes);
        assert((server.cModes == "l"), server.cModes);
        assert((server.dModes == "imnpstS"), server.dModes);
        assert((server.prefixchars == ['+':'v', '@':'o']), server.prefixchars.to!string);
        assert((server.prefixes == "ov"), server.prefixes);
        assert((server.chantypes == "&#"), server.chantypes);
    }
}


unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    with (parser.client)
    {
        server.address = "bitcoin.uk.eu.dal.net";
    }

    {
        immutable event = parser.toIRCEvent(":bitcoin.uk.eu.dal.net NOTICE AUTH :*** Looking up your hostname...");
        with (event)
        {
            assert((type == IRCEvent.Type.NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "bitcoin.uk.eu.dal.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "*** Looking up your hostname..."), content);
        }
    }

    with (parser.client)
    {
        assert((server.resolvedAddress == "bitcoin.uk.eu.dal.net"), server.resolvedAddress);
    }

    {
        immutable event = parser.toIRCEvent(":bitcoin.uk.eu.dal.net 004 kameloso bitcoin.uk.eu.dal.net bahamut-2.1.4 aAbcCdefFghHiIjkKmnoOPrRsSwxXy AbceiIjklLmMnoOpPrRsStv");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "bitcoin.uk.eu.dal.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "aAbcCdefFghHiIjkKmnoOPrRsSwxXy AbceiIjklLmMnoOpPrRsStv"), content);
            assert((aux == "bahamut-2.1.4"), aux);
            assert((num == 4), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.bahamut), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "bahamut-2.1.4"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":bitcoin.uk.eu.dal.net 005 kameloso NETWORK=DALnet SAFELIST MAXBANS=200 MAXCHANNELS=50 CHANNELLEN=32 KICKLEN=307 NICKLEN=30 TOPICLEN=307 MODES=6 CHANTYPES=# CHANLIMIT=#:50 PREFIX=(ov)@+ STATUSMSG=@+ :are available on this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "bitcoin.uk.eu.dal.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "NETWORK=DALnet SAFELIST MAXBANS=200 MAXCHANNELS=50 CHANNELLEN=32 KICKLEN=307 NICKLEN=30 TOPICLEN=307 MODES=6 CHANTYPES=# CHANLIMIT=#:50 PREFIX=(ov)@+ STATUSMSG=@+"), content);
            assert((num == 5), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.network == "DALnet"), server.network);
        assert((server.daemonstring == "DALnet"), server.daemonstring);
        assert((server.maxNickLength == 30), server.maxNickLength.to!string);
        assert((server.maxChannelLength == 32), server.maxChannelLength.to!string);
        assert((server.prefixchars == ['+':'v', '@':'o']), server.prefixchars.to!string);
        assert((server.prefixes == "ov"), server.prefixes);
    }

    {
        immutable event = parser.toIRCEvent(":bitcoin.uk.eu.dal.net 005 kameloso CASEMAPPING=ascii WATCH=128 SILENCE=10 ELIST=cmntu EXCEPTS INVEX CHANMODES=beI,k,jl,cimMnOprRsSt MAXLIST=b:200,e:100,I:100 TARGMAX=DCCALLOW:,JOIN:,KICK:4,KILL:20,NOTICE:20,PART:,PRIVMSG:20,WHOIS:,WHOWAS: :are available on this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "bitcoin.uk.eu.dal.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CASEMAPPING=ascii WATCH=128 SILENCE=10 ELIST=cmntu EXCEPTS INVEX CHANMODES=beI,k,jl,cimMnOprRsSt MAXLIST=b:200,e:100,I:100 TARGMAX=DCCALLOW:,JOIN:,KICK:4,KILL:20,NOTICE:20,PART:,PRIVMSG:20,WHOIS:,WHOWAS:"), content);
            assert((num == 5), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.aModes == "beI"), server.aModes);
        assert((server.bModes == "k"), server.bModes);
        assert((server.cModes == "jl"), server.cModes);
        assert((server.dModes == "cimMnOprRsSt"), server.dModes);
    }

    {
        immutable event = parser.toIRCEvent(":NickServ!service@dal.net NOTICE kameloso :Password accepted for kameloso.");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_LOGGEDIN), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "NickServ"), sender.nickname);
            assert((sender.ident == "service"), sender.ident);
            assert((sender.address == "dal.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "Password accepted for kameloso."), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":kameloso MODE kameloso :+i");
        with (event)
        {
            assert((type == IRCEvent.Type.SELFMODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso"), sender.nickname);
            assert((aux == "+i"), aux);
        }
    }

    with (parser.client)
    {
        assert((modes == "i"), modes);
    }

    {
        immutable event = parser.toIRCEvent(":kameloso MODE kameloso :+r");
        with (event)
        {
            assert((type == IRCEvent.Type.SELFMODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso"), sender.nickname);
            assert((aux == "+r"), aux);
        }
    }

    with (parser.client)
    {
        assert((modes == "ir"), modes);
    }
}


unittest
{
    IRCParser parser;
    parser.client.nickname = "kameloso";  // Because we removed the default value

    with (parser.client)
    {
        server.address = "irc.geekshed.net";
    }

    {
        immutable event = parser.toIRCEvent(":fe-00107.GeekShed.net NOTICE AUTH :*** Looking up your hostname...");
        with (event)
        {
            assert((type == IRCEvent.Type.NOTICE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "fe-00107.GeekShed.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "*** Looking up your hostname..."), content);
        }
    }

    with (parser.client)
    {
        assert((server.resolvedAddress == "fe-00107.GeekShed.net"), server.resolvedAddress);
    }

    {
        immutable event = parser.toIRCEvent("PING :E21567FB");
        with (event)
        {
            assert((type == IRCEvent.Type.PING), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "irc.geekshed.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "E21567FB"), content);
        }
    }

    {
        immutable event = parser.toIRCEvent(":fe-00107.GeekShed.net 004 kameloso fe-00107.GeekShed.net Unreal3.2.10.3-gs iowghraAsORTVSxNCWqBzvdHtGpIDc lvhopsmntikrRcaqOALQbSeIKVfMCuzNTGjUZ");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_MYINFO), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "fe-00107.GeekShed.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "iowghraAsORTVSxNCWqBzvdHtGpIDc lvhopsmntikrRcaqOALQbSeIKVfMCuzNTGjUZ"), content);
            assert((aux == "Unreal3.2.10.3-gs"), aux);
            assert((num == 4), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.daemon == IRCServer.Daemon.unreal), Enum!(IRCServer.Daemon).toString(server.daemon));
        assert((server.daemonstring == "Unreal3.2.10.3-gs"), server.daemonstring);
    }

    {
        immutable event = parser.toIRCEvent(":fe-00107.GeekShed.net 005 kameloso CMDS=KNOCK,MAP,DCCALLOW,USERIP,STARTTLS UHNAMES NAMESX SAFELIST HCN MAXCHANNELS=100 CHANLIMIT=#:100 MAXLIST=b:60,e:60,I:60 NICKLEN=30 CHANNELLEN=32 TOPICLEN=307 KICKLEN=307 AWAYLEN=307 :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "fe-00107.GeekShed.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "CMDS=KNOCK,MAP,DCCALLOW,USERIP,STARTTLS UHNAMES NAMESX SAFELIST HCN MAXCHANNELS=100 CHANLIMIT=#:100 MAXLIST=b:60,e:60,I:60 NICKLEN=30 CHANNELLEN=32 TOPICLEN=307 KICKLEN=307 AWAYLEN=307"), content);
            assert((num == 5), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.maxNickLength == 30), server.maxNickLength.to!string);
        assert((server.maxChannelLength == 32), server.maxChannelLength.to!string);
    }

    {
        immutable event = parser.toIRCEvent(":fe-00107.GeekShed.net 005 kameloso MAXTARGETS=20 WALLCHOPS WATCH=128 WATCHOPTS=A SILENCE=15 MODES=12 CHANTYPES=# PREFIX=(qaohv)~&@%+ CHANMODES=beI,kfL,lj,psmntirRcOAQKVCuzNSMTGUZ NETWORK=GeekShed CASEMAPPING=ascii EXTBAN=~,qjncrRaT ELIST=MNUCT :are supported by this server");
        with (event)
        {
            assert((type == IRCEvent.Type.RPL_ISUPPORT), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "fe-00107.GeekShed.net"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((content == "MAXTARGETS=20 WALLCHOPS WATCH=128 WATCHOPTS=A SILENCE=15 MODES=12 CHANTYPES=# PREFIX=(qaohv)~&@%+ CHANMODES=beI,kfL,lj,psmntirRcOAQKVCuzNSMTGUZ NETWORK=GeekShed CASEMAPPING=ascii EXTBAN=~,qjncrRaT ELIST=MNUCT"), content);
            assert((num == 5), num.to!string);
        }
    }

    with (parser.client)
    {
        assert((server.network == "GeekShed"), server.network);
        assert((server.daemonstring == "GeekShed"), server.daemonstring);
        assert((server.aModes == "beI"), server.aModes);
        assert((server.bModes == "kfL"), server.bModes);
        assert((server.cModes == "lj"), server.cModes);
        assert((server.dModes == "psmntirRcOAQKVCuzNSMTGUZ"), server.dModes);
        assert((server.prefixchars == ['&':'a', '+':'v', '@':'o', '%':'h', '~':'q']), server.prefixchars.to!string);
        assert((server.prefixes == "qaohv"), server.prefixes);
        assert((server.extbanPrefix == '~'), server.extbanPrefix.to!string);
        assert((server.extbanTypes == "qjncrRaT"), server.extbanTypes);
    }

    {
        immutable event = parser.toIRCEvent(":kameloso MODE kameloso :+iRx");
        with (event)
        {
            assert((type == IRCEvent.Type.SELFMODE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.nickname == "kameloso"), sender.nickname);
            assert((aux == "+iRx"), aux);
        }
    }

    with (parser.client)
    {
        assert((modes == "Rix"), modes);
    }
}

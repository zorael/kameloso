/++
 +  Functions needed to parse raw IRC event strings into
 +  `kameloso.ircdefs.IRCEvent`s.
 +/
module kameloso.irc;

public import kameloso.ircdefs;

import kameloso.string : has, nom;

@safe:

private:

version(AsAnApplication)
{
    /+
        As an application; log sanity check failures to screen. Parsing proceeds
        and plugins are processed.
     +/
    version = PrintSanityFailures;
}
else
{
    /+
        As a library; throw an exception on sanity check failures. Parsing halts
        and the event dies mid-flight. However, no Logger will be imported,
        leaving the library headless.

        Comment this if you want parsing sanity check failures to be silently
        ignored, with the errors stored in `IRCEvent.errors`.
     +/
    version = ThrowSanityFailures;
}


// parseBasic
/++
 +  Parses the most basic of IRC events; `PING`, `ERROR`, `PONG`, `NOTICE`
 +  (plus `NOTICE AUTH`), and `AUTHENTICATE`.
 +
 +  They syntactically differ from other events in that they are not prefixed
 +  by their sender.
 +
 +  The `kameloso.ircdefs.IRCEvent` is finished at the end of this function.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to start working
 +          on.
 +/
void parseBasic(ref IRCParser parser, ref IRCEvent event) pure
{
    string slice = event.raw;
    string typestring;

    if (slice.has(':'))
    {
        typestring = slice.nom(" :");
    }
    else if (slice.has(' '))
    {
        typestring = slice.nom(' ');
    }
    else
    {
        typestring = slice;
    }

    with (IRCEvent.Type)
    with (parser)
    switch (typestring)
    {
    case "PING":
        // PING :3466174537
        // PING :weber.freenode.net
        event.type = PING;

        if (slice.has('.'))
        {
            event.sender.address = slice;
        }
        else
        {
            event.content = slice;
        }
        break;

    case "ERROR":
        // ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)
        event.type = ERROR;
        event.content = slice;
        break;

    case "NOTICE AUTH":
    case "NOTICE":
        // QuakeNet/Undernet
        // NOTICE AUTH :*** Couldn't look up your hostname
        event.type = NOTICE;
        event.content = slice;

        if (bot.server.address != IRCServer.init.address)
        {
            // No sender known and the address has been set to something
            // Inherit that as sender
            event.sender.address = bot.server.address;
        }
        break;

    case "PONG":
        // PONG :tmi.twitch.tv
        event.type = PONG;
        event.sender.address = slice;
        break;

    case "AUTHENTICATE":
        event.content = slice;
        event.type = SASL_AUTHENTICATE;
        break;

    default:
        import kameloso.string : beginsWith;

        if (event.raw.beginsWith("NOTICE"))
        {
            // Probably NOTICE <bot.nickname>
            // NOTICE kameloso :*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now.
            goto case "NOTICE";
        }
        else
        {
            import std.conv : text;
            throw new IRCParseException(text("Unknown basic type: ",
                typestring, " : please report this"), event);
        }
    }

    event.sender.special = true;
}

unittest
{
    import std.conv : to;

    IRCParser parser;

    IRCEvent e1;
    with (e1)
    {
        raw = "PING :irc.server.address";
        parser.parseBasic(e1);
        assert((type == IRCEvent.Type.PING), type.to!string);
        assert((sender.address == "irc.server.address"), sender.address);
        assert(!sender.nickname.length, sender.nickname);
    }

    IRCEvent e2;
    with (e2)
    {
        // QuakeNet and others not having the sending server as prefix
        raw = "NOTICE AUTH :*** Couldn't look up your hostname";
        parser.parseBasic(e2);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert(!sender.nickname.length, sender.nickname);
        assert((content == "*** Couldn't look up your hostname"));
    }

    IRCEvent e3;
    with (e3)
    {
        raw = "ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)";
        parser.parseBasic(e3);
        assert((type == IRCEvent.Type.ERROR), type.to!string);
        assert(!sender.nickname.length, sender.nickname);
        assert((content == "Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"), content);
    }
}


// parsePrefix
/++
 +  Takes a slice of a raw IRC string and starts parsing it into an
 +  `kameloso.ircdefs.IRCEvent` struct.
 +
 +  This function only focuses on the prefix; the sender, be it nickname and
 +  ident or server address.
 +
 +  The `kameloso.ircdefs.IRCEvent` is not finished at the end of this function.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to start working
 +          on.
 +      slice = Reference to the *slice* of the raw IRC string.
 +/
void parsePrefix(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    auto prefix = slice.nom(' ');

    with (event.sender)
    {
        if (prefix.has('!'))
        {
            // user!~ident@address
            nickname = prefix.nom('!');
            ident = prefix.nom('@');
            address = prefix;
        }
        else if (prefix.has('.'))
        {
            // dots signify an address
            address = prefix;
        }
        else
        {
            // When does this happen?
            nickname = prefix;
        }
    }

    event.sender.special = parser.isSpecial(event);
}

unittest
{
    import std.conv : to;

    IRCParser parser;

    IRCEvent e1;
    with (e1)
    with (e1.sender)
    {
        raw = ":zorael!~NaN@some.address.org PRIVMSG kameloso :this is fake";
        string slice1 = raw[1..$];  // mutable
        parser.parsePrefix(e1, slice1);
        assert((nickname == "zorael"), nickname);
        assert((ident == "~NaN"), ident);
        assert((address == "some.address.org"), address);
        assert(!special);
    }

    IRCEvent e2;
    with (e2)
    with (e2.sender)
    {
        raw = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
        string slice2 = raw[1..$];  // mutable
        parser.parsePrefix(e2, slice2);
        assert((nickname == "NickServ"), nickname);
        assert((ident == "NickServ"), ident);
        assert((address == "services."), address);
        assert(special);
    }

    IRCEvent e3;
    with (e3)
    with (e3.sender)
    {
        raw = ":kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp";
        string slice3 = raw[1..$];  // mutable
        parser.parsePrefix(e3, slice3);
        assert((nickname == "kameloso^^"), nickname);
        assert((ident == "~NaN"), ident);
        assert((address == "C2802314.E23AD7D8.E9841504.IP"), address);
        assert(!special);
    }

    IRCEvent e4;
    with (parser)
    with (e4)
    with (e4.sender)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice4 = raw[1..$];
        parser.parsePrefix(e4, slice4);
        assert((nickname == "Q"), nickname);
        assert((ident == "TheQBot"), ident);
        assert((address == "CServe.quakenet.org"), address);
        assert(special);
    }
}


// parseTypestring
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an
 +  `kameloso.ircdefs.IRCEvent` struct.
 +
 +  This function only focuses on the *typestring*; the part that tells what
 +  kind of event happened, like `PRIVMSG` or `MODE` or `NICK` or `KICK`, etc;
 +  in string format.
 +
 +  The `kameloso.ircdefs.IRCEvent` is not finished at the end of this function.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void parseTypestring(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string : toEnum;
    import std.conv : ConvException, to;

    string typestring;

    if (slice.has(' '))
    {
        typestring = slice.nom(' ');
    }
    else
    {
        typestring = slice;
        // Simulate advancing slice to the end
        slice = string.init;
    }

    if ((typestring[0] >= '0') && (typestring[0] <= '9'))
    {
        try
        {
            immutable number = typestring.to!uint;
            event.num = number;
            event.type = parser.typenums[number];

            alias T = IRCEvent.Type;
            event.type = (event.type == T.UNSET) ? T.NUMERIC : event.type;
        }
        catch (const ConvException e)
        {
            throw new IRCParseException(e.msg, event, e.file, e.line);
        }
    }
    else
    {
        try event.type = typestring.toEnum!(IRCEvent.Type);
        catch (const ConvException e)
        {
            throw new IRCParseException(e.msg, event, e.file, e.line);
        }
    }
}

unittest
{
    import std.conv : to;

    IRCParser parser;

    IRCEvent e1;
    with (e1)
    {
        raw = /*":port80b.se.quakenet.org */"421 kameloso åäö :Unknown command";
        string slice = raw;  // mutable
        parser.parseTypestring(e1, slice);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((num == 421), num.to!string);
    }

    IRCEvent e2;
    with (e2)
    {
        raw = /*":port80b.se.quakenet.org */"353 kameloso = #garderoben :@kameloso'";
        string slice = raw;  // mutable
        parser.parseTypestring(e2, slice);
        assert((type == IRCEvent.Type.RPL_NAMREPLY), type.to!string);
        assert((num == 353), num.to!string);
    }

    IRCEvent e3;
    with (e3)
    {
        raw = /*":zorael!~NaN@ns3363704.ip-94-23-253.eu */"PRIVMSG kameloso^ :test test content";
        string slice = raw;
        parser.parseTypestring(e3, slice);
        assert((type == IRCEvent.Type.PRIVMSG), type.to!string);
    }

    IRCEvent e4;
    with (e4)
    {
        raw = /*`:zorael!~NaN@ns3363704.ip-94-23-253.eu */`PART #flerrp :"WeeChat 1.6"`;
        string slice = raw;
        parser.parseTypestring(e4, slice);
        assert((type == IRCEvent.Type.PART), type.to!string);
    }
}


// parseSpecialcases
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an
 +  `kameloso.ircdefs.IRCEvent` struct.
 +
 +  This function only focuses on specialcasing the remaining line, dividing it
 +  into fields like `target`, `channel`, `content`, etc.
 +
 +  IRC events are *riddled* with inconsistencies, so this function is very very
 +  long, but by neccessity.
 +
 +  The `kameloso.ircdefs.IRCEvent` is finished at the end of this function.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void parseSpecialcases(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string;

    with (parser)
    with (IRCEvent.Type)
    switch (event.type)
    {
    case NOTICE:
        parser.onNotice(event, slice);
        break;

    case JOIN:
        // :nick!~identh@unaffiliated/nick JOIN #freenode login :realname
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com JOIN #flerrp
        // :kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp
        event.type = (event.sender.nickname == bot.nickname) ? SELFJOIN : JOIN;

        if (slice.has(' '))
        {
            // :nick!user@host JOIN #channelname accountname :Real Name
            // :nick!user@host JOIN #channelname * :Real Name
            // :nick!~identh@unaffiliated/nick JOIN #freenode login :realname
            // :kameloso!~NaN@2001:41d0:2:80b4:: JOIN #hirrsteff2 kameloso : kameloso!
            event.channel = slice.nom(' ');
            event.sender.account = slice.nom(" :");
            //event.content = slice.stripped;  // no need for full name...
        }
        else
        {
            event.channel = slice.beginsWith(':') ? slice[1..$] : slice;
        }
        break;

    case PART:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PART #flerrp :"WeeChat 1.6"
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com PART #flerrp
        // :Swatas!~4--Uos3UH@9e19ee35.915b96ad.a7c9320c.IP4 PART :#cncnet-mo
        // :gallon!~MO.11063@482c29a5.e510bf75.97653814.IP4 PART :#cncnet-yr
        event.type = (event.sender.nickname == bot.nickname) ? SELFPART : PART;

        if (slice.has(' '))
        {
            event.channel = slice.nom(" :");
            event.content = slice;
            event.content = event.content.unquoted;
        }
        else
        {
            // Seen on GameSurge
            if (slice.beginsWith(':')) slice = slice[1..$];

            event.channel = slice;
        }
        break;

    case NICK:
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_
        event.target.nickname = slice[1..$];

        if (event.sender.nickname == bot.nickname)
        {
            event.type = SELFNICK;
            bot.nickname = event.target.nickname;
            bot.updated = true;
        }
        break;

    case QUIT:
        // :g7zon!~gertsson@178.174.245.107 QUIT :Client Quit
        event.type = (event.sender.nickname == bot.nickname) ? SELFQUIT : QUIT;
        event.content = slice[1..$].unquoted;

        if (event.content.beginsWith("Quit: "))
        {
            event.content.nom("Quit: ");
        }
        break;

    case PRIVMSG:
        parser.onPRIVMSG(event, slice);
        break;

    case MODE:
        parser.onMode(event, slice);
        break;

    case KICK:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu KICK #flerrp kameloso^ :this is a reason
        event.channel = slice.nom(' ');
        event.target.nickname = slice.nom(" :");
        event.type = (event.target.nickname == bot.nickname) ? SELFKICK : KICK;
        event.content = slice;
        break;

    case INVITE:
        // (freenode) :zorael!~NaN@2001:41d0:2:80b4:: INVITE kameloso :#hirrsteff
        // (quakenet) :zorael!~zorael@ns3363704.ip-94-23-253.eu INVITE kameloso #hirrsteff
        event.target.nickname = slice.nom(' ');
        event.channel = slice;
        event.channel = slice.beginsWith(':') ? slice[1..$] : slice;
        break;

    case AWAY:
        // :Halcy0n!~Halcy0n@SpotChat-rauo6p.dyn.suddenlink.net AWAY :I'm busy
        if (slice.length)
        {
            // :I'm busy
            slice = slice[1..$];
            event.content = slice;
        }
        else
        {
            event.type = BACK;
        }
        break;

    case ERR_NOSUCHCHANNEL: // 403
        // :moon.freenode.net 403 kameloso archlinux :No such channel
        slice.nom(' ');  // bot nickname
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_NAMREPLY: // 353
        // :asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt
        slice.nom(' ');  // bot nickname
        slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;  // .strippedRight;
        break;

    case RPL_WHOREPLY: // 352
        // :moon.freenode.net 352 kameloso ##linux LP9NDWY7Cy gentoo/contributor/Fieldy moon.freenode.net Fieldy H :0 Ni!
        // :moon.freenode.net 352 kameloso ##linux sid99619 gateway/web/irccloud.com/x-eviusxrezdarwcpk moon.freenode.net tjsimmons G :0 T.J. Simmons
        // :moon.freenode.net 352 kameloso ##linux sid35606 gateway/web/irccloud.com/x-rvrdncbvklhxwjrr moon.freenode.net Whisket H :0 Whisket
        // :moon.freenode.net 352 kameloso ##linux ~rahlff b29beb9d.rev.stofanet.dk orwell.freenode.net Axton H :0 Michael Rahlff
        // :moon.freenode.net 352 kameloso ##linux ~wzhang sea.mrow.org card.freenode.net wzhang H :0 wzhang
        // :irc.rizon.no 352 kameloso^^ * ~NaN C2802314.E23AD7D8.E9841504.IP * kameloso^^ H :0  kameloso!
        // :irc.rizon.no 352 kameloso^^ * ~zorael Rizon-64330364.ip-94-23-253.eu * wob^2 H :0 zorael
        // "<channel> <user> <host> <server> <nick> ( "H" / "G" > ["*"] [ ( "@" / "+" ) ] :<hopcount> <real name>"
        slice.nom(' ');  // bot nickname
        event.channel = slice.nom(' ');
        if (event.channel == "*") event.channel = string.init;

        immutable userOrIdent = slice.nom(' ');
        if (userOrIdent.beginsWith('~')) event.target.ident = userOrIdent;

        event.target.address = slice.nom(' ');
        slice.nom(' ');  // server
        event.target.nickname = slice.nom(' ');

        immutable hg = slice.nom(' ');  // H|G
        if (hg.length > 1)
        {
            import std.conv : to;
            // H
            // H@
            // H+
            // H@+
            event.aux = hg[1..$];
        }

        slice.nom(' ');  // hopcount
        event.content = slice.strippedLeft;
        break;

    case RPL_ENDOFWHO: // 315
        // :tolkien.freenode.net 315 kameloso^ ##linux :End of /WHO list.
        // :irc.rizon.no 315 kameloso^^ * :End of /WHO list.
        slice.nom(' ');  // bot nickname
        event.channel = slice.nom(" :");
        if (event.channel == "*") event.channel = string.init;
        event.content = slice;
        break;

    case RPL_ISUPPORT: // 005
        parser.onISUPPORT(event, slice);
        break;

    case RPL_MYINFO: // 004
        parser.onMyInfo(event, slice);
        break;

    case RPL_QUIETLIST: // 728, oftc/hybrid 344
        // :niven.freenode.net 728 kameloso^ #flerrp q qqqq!*@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405101
        // :irc.oftc.net 344 kameloso #garderoben harbl!snarbl@* kameloso!~NaN@194.117.188.126 1515418362
        slice.nom(' ');  // bot nickname
        event.channel = slice.has(" q ") ? slice.nom(" q ") : slice.nom(' ');
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case RPL_WHOISHOST: // 378
        // :wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62
        // TRIED TO NOM TOO MUCH:'kameloso :is connecting from NaN@194.117.188.126 194.117.188.126' with ' :is connecting from *@'
        slice.nom(' ');  // bot nickname
        event.target.nickname = slice.nom(" :is connecting from ");
        event.target.ident = slice.nom('@');
        if (event.target.ident == "*") event.target.ident = string.init;
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case ERR_UNKNOWNCOMMAND: // 421
        slice.nom(' ');  // bot nickname

        if (slice.has(':'))
        {
            // :asimov.freenode.net 421 kameloso^ sudo :Unknown command
            event.content = slice.nom(" :");
            event.aux = slice;
        }
        else
        {
            // :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,...
            event.content = slice;
        }
        break;

    case RPL_WHOISIDLE: //  317
        // :rajaniemi.freenode.net 317 kameloso zorael 0 1510219961 :seconds idle, signon time
        slice.nom(' ');  // bot nickname
        event.target.nickname = slice.nom(' ');
        event.content = slice.nom(' ');
        event.aux = slice.nom(" :");
        break;

    case RPL_LUSEROP: // 252
    case RPL_LUSERUNKNOWN: // 253
    case RPL_LUSERCHANNELS: // 254
    case ERR_ERRONEOUSNICKNAME: // 432
    case ERR_NEEDMOREPARAMS: // 461
    case RPL_LOCALUSERS: // 265
    case RPL_GLOBALUSERS: // 266
        // :asimov.freenode.net 252 kameloso^ 31 :IRC Operators online
        // :asimov.freenode.net 253 kameloso^ 13 :unknown connection(s)
        // :asimov.freenode.net 254 kameloso^ 54541 :channels formed
        // :asimov.freenode.net 432 kameloso^ @nickname :Erroneous Nickname
        // :asimov.freenode.net 461 kameloso^ JOIN :Not enough parameters
        // :asimov.freenode.net 265 kameloso^ 6500 11061 :Current local users 6500, max 11061
        // :asimov.freenode.net 266 kameloso^ 85267 92341 :Current global users 85267, max 92341
        // :irc.uworld.se 265 kameloso^^ :Current local users: 14552  Max: 19744
        // :irc.uworld.se 266 kameloso^^ :Current global users: 14552  Max: 19744
        // :weber.freenode.net 265 kameloso 3385 6820 :Current local users 3385, max 6820"
        // :weber.freenode.net 266 kameloso 87056 93012 :Current global users 87056, max 93012
        // :irc.rizon.no 265 kameloso^^ :Current local users: 16115  Max: 17360
        // :irc.rizon.no 266 kameloso^^ :Current global users: 16115  Max: 17360
        slice.nom(' ');  // bot nickname

        if (slice.has(" :"))
        {
            event.aux = slice.nom(" :");
            event.content = slice;
        }
        else
        {
            event.content = slice[1..$];
        }
        break;

    case RPL_WHOISUSER: // 311
        // :orwell.freenode.net 311 kameloso^ kameloso ~NaN ns3363704.ip-94-23-253.eu * : kameloso
        slice.nom(' ');  // bot nickname
        event.target.nickname = slice.nom(' ');
        event.target.ident = slice.nom(' ');
        event.target.address = slice.nom(" * :");
        event.content = slice.strippedLeft;
        break;

    case RPL_WHOISSERVER: // 312
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE
        slice.nom(' ');  // bot nickname
        event.target.nickname = slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice;
        break;

    case RPL_WHOISACCOUNT: // 330
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        slice.nom(' ');  // bot nickname
        event.target.nickname = slice.nom(' ');
        event.target.account = slice.nom(" :");
        event.content = event.target.account;
        break;

    case RPL_WHOISREGNICK: // 307
        // :irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick
        // :irc.x2x.cc 307 kameloso^^ wob^2 :has identified for this nick
        slice.nom(' '); // bot nickname
        event.target.nickname = slice.nom(" :");
        event.content = event.target.nickname;
        break;

    case RPL_WHOISACTUALLY: // 75
        // :kinetic.oftc.net 338 kameloso wh00nix 255.255.255.255 :actually using host
        slice.nom(' '); // bot nickname
        event.target.nickname = slice.nom(' ');
        event.target.address = slice.nom(" :");
        event.content = slice;
        break;

    case PONG:
        event.content = string.init;
        break;

    case ERR_NOTREGISTERED: // 451
        if (slice.beginsWith('*'))
        {
            // :niven.freenode.net 451 * :You have not registered
            slice.nom("* :");
            event.content = slice;
        }
        else
        {
            // :irc.harblwefwoi.org 451 WHOIS :You have not registered
            event.aux = slice.nom(" :");
            event.content = slice;
        }
        break;

    case ERR_BADPING: // 513
        /++
         +  "Also known as ERR_NEEDPONG (Unreal/Ultimate) for use during
         +  registration, however it's not used in Unreal (and might not be used
         +  in Ultimate either)."
         +/
        // :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477

        if (slice.has(" :To connect"))
        {
            event.target.nickname = slice.nom(" :To connect");

            if (slice.beginsWith(','))
            {
                // ngircd?
                /* "NOTICE %s :To connect, type /QUOTE PONG %ld",
                    Client_ID(Client), auth_ping)) */
                // :like.so 513 kameloso :To connect, type /QUOTE PONG 3705964477
                // "To connect, type /QUOTE PONG <id>"
                //            ^
                slice = slice[1..$];
            }

            slice.nom(" type /QUOTE ");
            event.content = slice;
        }
        else
        {
            throw new IRCParseException("Unknown variant of to-connect-type?", event);
        }
        break;

    case RPL_HELPSTART: // 704
    case RPL_HELPTXT: // 705
    case RPL_ENDOFHELP: // 706
    case RPL_CODEPAGE: // 222
        // :irc.run.net 222 kameloso KOI8-U :is your charset now
        // :leguin.freenode.net 704 kameloso^ index :Help topics available to users:
        // :leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        // :leguin.freenode.net 706 kameloso^ index :End of /HELP.
        slice.nom(' '); // bot nickname
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case ERR_BANONCHAN: // 435
        // :cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel
        event.target.nickname = slice.nom(' ');
        event.aux = slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case CAP:
        if (slice.has('*'))
        {
            // :tmi.twitch.tv CAP * LS :twitch.tv/tags twitch.tv/commands twitch.tv/membership
            slice.nom("* ");
        }
        else
        {
            // :genesis.ks.us.irchighway.net CAP 867AAF66L LS :away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names
            //immutable id = slice.nom(' ');
            slice.nom(' ');
        }

        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    version(TwitchSupport)
    {
        import std.conv : to;

        case HOSTTARGET:
            if (slice.has(" :-"))
            {
                event.type = HOSTEND;
                goto case HOSTEND;
            }
            else
            {
                event.type = HOSTSTART;
                goto case HOSTSTART;
            }

        case HOSTSTART:
            // :tmi.twitch.tv HOSTTARGET #hosting_channel <channel> [<number-of-viewers>]
            // :tmi.twitch.tv HOSTTARGET #andymilonakis :zombie_barricades -
            event.channel = slice.nom(" :");
            event.content = slice.nom(' ');
            event.num = (slice == "-") ? 0 : slice.to!uint;
            break;

        case HOSTEND:
            // :tmi.twitch.tv HOSTTARGET #hosting_channel :- [<number-of-viewers>]
            event.channel = slice.nom(" :- ");
            event.num = slice.to!uint;
            break;

        case CLEARCHAT:
            // :tmi.twitch.tv CLEARCHAT #zorael
            // :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            if (slice.has(" :"))
            {
                // Banned
                // Whether it's a tempban or a permban is decided in the Twitch plugin
                event.channel = slice.nom(" :");
                event.target.nickname = slice;
            }
            else
            {
                event.channel = slice;
            }
            break;
    }

    case RPL_LOGGEDIN: // 900
        // :weber.freenode.net 900 kameloso kameloso!NaN@194.117.188.126 kameloso :You are now logged in as kameloso.
        // :NickServ!NickServ@services. NOTICE kameloso^ :You are now identified for kameloso.
        if (slice.has('!'))
        {
            event.target.nickname = slice.nom(' ');  // bot nick
            slice.nom('!');  // user
            event.target.ident = slice.nom('@');
            event.target.address = slice.nom(' ');
            event.target.account = slice.nom(" :");
        }
        event.content = slice;
        break;

    case ACCOUNT:
        //:ski7777!~quassel@ip5b435007.dynamic.kabel-deutschland.de ACCOUNT ski7777
        event.sender.account = slice;
        event.content = slice;  // to make it visible?
        break;

    case RPL_HOSTHIDDEN: // 396
    case RPL_VERSION: // 351
        // :irc.rizon.no 351 kameloso^^ plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no :TS6ow
        // :TAL.DE.EU.GameSurge.net 396 kameloso ~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4 :is now your hidden host
        slice.nom(' '); // bot nickname
        event.content = slice.nom(" :");
        event.aux = slice;
        break;

    case RPL_YOURID: // 42
    case ERR_YOUREBANNEDCREEP: // 465
    case ERR_HELPNOTFOUND: // 524, also ERR_QUARANTINED
    case ERR_UNKNOWNMODE: // 472
        // :caliburn.pa.us.irchighway.net 042 kameloso 132AAMJT5 :your unique ID
        // :irc.rizon.no 524 kameloso^^ 502 :Help not found
        // :irc.rizon.no 472 kameloso^^ X :is unknown mode char to me
        // :miranda.chathispano.com 465 kameloso 1511086908 :[1511000504768] G-Lined by ChatHispano Network. Para mas informacion visite http://chathispano.com/gline/?id=<id> (expires at Dom, 19/11/2017 11:21:48 +0100).
        // event.time was 1511000921
        // TRIED TO NOM TOO MUCH:':You are banned from this server- Your irc client seems broken and is flooding lots of channels. Banned for 240 min, if in error, please contact kline@freenode.net. (2017/12/1 21.08)' with ' :'
        string misc = slice.nom(" :");
        event.content = slice;

        if (misc.has(' '))
        {
            misc.nom(' ');
            event.aux = misc;
        }

        break;

    case RPL_UMODEIS:
        // :lamia.ca.SpotChat.org 221 kameloso :+ix
        // :port80b.se.quakenet.org 221 kameloso +i
        // The general heuristics is good enough for this but places modes in
        // content rather than aux, which is inconsistent with other mode events
        slice.nom(' '); // bot nickname

        if (slice.beginsWith(':'))
        {
            slice = slice[1..$];
        }

        event.aux = slice;
        break;

    case RPL_CHANNELMODEIS: // 324
        // :niven.freenode.net 324 kameloso^ ##linux +CLPcnprtf ##linux-overflow
        // :kornbluth.freenode.net 324 kameloso #flerrp +ns
        slice.nom(' '); // bot nickname
        event.channel = slice.nom(' ');

        if (slice.has(' '))
        {
            event.aux = slice.nom(' ');
            //event.content = slice.nom(' ');
            event.content = slice;
        }
        else
        {
            event.aux = slice;
        }
        break;

    case RPL_CREATIONTIME: // 329
        // :kornbluth.freenode.net 329 kameloso #flerrp 1512995737
        slice.nom(' ');
        event.channel = slice.nom(' ');
        event.aux = slice;
        break;

    case RPL_LIST: // 322
        // :irc.RomaniaChat.eu 322 kameloso #GameOfThrones 1 :[+ntTGfB]
        // :irc.RomaniaChat.eu 322 kameloso #radioclick 63 :[+ntr]  Bun venit pe #Radioclick! Site oficial www.radioclick.ro sau servere irc.romaniachat.eu, irc.radioclick.ro
        // :eggbert.ca.na.irchighway.net 322 kameloso * 3 :
        /*
            (asterisk channels)
            milky | channel isn't public nor are you a member
            milky | Unreal inserts that instead of not sending the result
            milky | Other IRCd may do same because they are all derivatives
         */
        slice.nom(' '); // bot nickname
        event.channel = slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_LISTSTART: // 321
        // :cherryh.freenode.net 321 kameloso^ Channel :Users  Name
        // none of the fields are interesting...
        break;

    case RPL_ENDOFQUIETLIST: // 729, oftc/hybrid 345
        // :niven.freenode.net 729 kameloso^ #hirrsteff q :End of Channel Quiet List
        // :irc.oftc.net 345 kameloso #garderoben :End of Channel Quiet List
        slice.nom(' ');
        event.channel = slice.has(" q :") ? slice.nom(" q :") : slice.nom(" :");
        event.content = slice;
        break;

    case RPL_WHOISMODES: // 379
        // :cadance.canternet.org 379 kameloso kameloso :is using modes +ix
        slice.nom(' '); // bot nickname
        event.target.nickname = slice.nom(" :is using modes ");
        event.aux = slice;
        break;

    case RPL_WHOWASUSER: // 314
        // :irc.uworld.se 314 kameloso^^ kameloso ~NaN C2802314.E23AD7D8.E9841504.IP * : kameloso!
        slice.nom(' '); // bot nickname
        event.target.nickname = slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice.stripped;
        break;

    case CHGHOST:
        // :Miyabro!~Miyabro@DA8192E8:4D54930F:650EE60D:IP CHGHOST ~Miyabro Miyako.is.mai.waifu
        event.sender.ident = slice.nom(' ');
        event.sender.address = slice;
        event.content = slice;
        break;

    case RPL_HELLO: // 020
        // :irc.run.net 020 irc.run.net :*** You are connected to RusNet. Please wait...
        slice.nom(" :");
        event.content = slice;
        break;

    case SPAMFILTERLIST: // 941
        // :siren.de.SpotChat.org 941 kameloso #linuxmint-help spotify.com/album Butterfly 1513796216
        slice.nom(' '); // bot nickname
        event.channel = slice.nom(' ');
        event.content = slice.nom(' ');
        slice.nom(' ');  // nickname that set the mode. no appropriate field.
        event.aux = slice;
        break;

    default:
        if ((event.type == NUMERIC) || (event.type == UNSET))
        {
            throw new IRCParseException("Uncaught NUMERIC or UNSET", event);
        }

        parser.parseGeneralCases(event, slice);
    }
}


// parseGeneralCases
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an
 +  `kameloso.ircdefs.IRCEvent` struct.
 +
 +  This function only focuses on applying general heuristics to the remaining
 +  line, dividing it into fields like `target`, `channel`, `content`, etc; not
 +  based by its type but rather by how the string looks.
 +
 +  The `kameloso.ircdefs.IRCEvent` is finished at the end of this function.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void parseGeneralCases(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string;

    with (parser)
    {
        if (slice.has(" :"))
        {
            // Has colon-content
            string targets = slice.nom(" :");

            if (targets.has(' '))
            {
                // More than one target
                immutable firstTarget = targets.nom(' ');

                if ((firstTarget == bot.nickname) || (firstTarget == "*"))
                {
                    // More than one target, first is bot
                    // Can't use isChan here since targets may contain spaces

                    if (targets.beginsWith('#'))
                    {
                        // More than one target, first is bot
                        // Second target is/begins with a channel

                        if (targets.has(' '))
                        {
                            // More than one target, first is bot
                            // Second target is more than one, first is channel
                            // assume third is content
                            event.channel = targets.nom(' ');
                            event.content = targets;
                        }
                        else
                        {
                            // More than one target, first is bot
                            // Only one second

                            if (targets.beginsWith('#'))
                            {
                                // First is bot, second is chanenl
                                event.channel = targets;
                            }
                            else
                            {
                                /*logger.warning("Non-channel second target. Report this.");
                                logger.trace(event.raw);*/
                                event.target.nickname = targets;
                            }
                        }
                    }
                    else
                    {
                        // More than one target, first is bot
                        // Second is not a channel

                        if (targets.has(' '))
                        {
                            // More than one target, first is bot
                            // Second target is more than one
                            // Assume third is channel
                            event.target.nickname = targets.nom(' ');
                            event.channel = targets;
                        }
                        else
                        {
                            // Only one second target

                            if (targets.beginsWith('#'))
                            {
                                // Second is a channel
                                event.channel = targets;
                            }
                            else
                            {
                                // Second is not a channel
                                event.target.nickname = targets;
                            }
                        }
                    }
                }
                else
                {
                    // More than one target, first is not bot

                    if (firstTarget.beginsWith('#'))
                    {
                        // First target is a channel
                        // Assume second is a nickname
                        event.channel = firstTarget;
                        event.target.nickname = targets;
                    }
                    else
                    {
                        // First target is not channel, assume nick
                        // Assume secod is channel
                        event.target.nickname = firstTarget;
                        event.channel = targets;
                    }
                }
            }
            else if (targets.beginsWith('#'))
            {
                // Only one target, it is a channel
                event.channel = targets;
            }
            else
            {
                // Only one target, not a channel
                event.target.nickname = targets;
            }
        }
        else
        {
            // Does not have colon-content
            if (slice.has(' '))
            {
                // More than one target
                immutable target = slice.nom(' ');

                if (target.beginsWith('#'))
                {
                    // More than one target, first is a channel
                    // Assume second is content
                    event.channel = target;
                    event.content = slice;
                }
                else
                {
                    // More than one target, first is not a channel
                    // Assume first is nickname and second is aux
                    event.target.nickname = target;

                    if ((target == parser.bot.nickname) && slice.has(' '))
                    {
                        // First target is bot, and there is more
                        // :asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377
                        // :kornbluth.freenode.net 367 kameloso #flerrp harbl!harbl@snarbl.com zorael!~NaN@2001:41d0:2:80b4:: 1513899521
                        // :niven.freenode.net 346 kameloso^ #flerrp asdf!fdas@asdf.net zorael!~NaN@2001:41d0:2:80b4:: 1514405089
                        // :irc.run.net 367 kameloso #Help *!*@broadband-5-228-255-*.moscow.rt.ru
                        // :irc.atw-inter.net 344 kameloso #debian.de towo!towo@littlelamb.szaf.org

                        if (slice.beginsWith('#') && slice.has(' '))
                        {
                            // Second target is channel
                            event.channel = slice.nom(' ');

                            if (slice.has(' '))
                            {
                                // Remaining slice has at least two fields;
                                // separate into content and aux
                                event.content = slice.nom(' ');
                                event.aux = slice;
                            }
                            else
                            {
                                // Remaining slice is one bit of text
                                event.content = slice;
                            }
                        }
                        else
                        {
                            // No-channel second target
                            // When does this happen?
                            event.content = slice;
                        }
                    }
                    else
                    {
                        // No second target
                        // :port80b.se.quakenet.org 221 kameloso +i
                        event.aux = slice;
                    }
                }
            }
            else
            {
                // Only one target

                if (slice.beginsWith('#'))
                {
                    // Target is a channel
                    event.channel = slice;
                }
                else
                {
                    // Target is a nickname
                    event.target.nickname = slice;
                }
            }
        }

        // If content is empty and slice hasn't already been used, assign it
        if (!event.content.length && (slice != event.channel) &&
            (slice != event.target.nickname))
        {
            event.content = slice;
        }
    }
}


// postparseSanityCheck
/++
 +  Checks for some specific erroneous edge cases in an
 +  `kameloso.ircdefs.IRCEvent`, complains about all of them and corrects some.
 +
 +  If version `PrintSanityFailures` it will print warning messages to the
 +  screen. If version `ThrowSanityFailures` it will throw an
 +  `IRCParseException` instead. If neither versions it will silently let the
 +  event pass on.
 +
 +  Unsure if it's wrong to mark as trusted, but we're only using
 +  `stdout.flush`, which surely *must* be trusted if `writeln` to `stdout` is?
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +/
void postparseSanityCheck(const ref IRCParser parser, ref IRCEvent event) @trusted
{
    import kameloso.string : beginsWith;

    import std.array : Appender;
    Appender!string sink;
    //sink.reserve(128);

    if (event.target.nickname.has(' ') || event.channel.has(' '))
    {
        sink.put("Spaces in target nickname or channel");
    }

    if (event.target.nickname.length && parser.bot.server.chantypes.has(event.target.nickname[0]))
    {
        if (sink.data.length) sink.put(". ");
        sink.put("Target nickname is a channel");
    }

    if (event.channel.length &&
        !parser.bot.server.chantypes.has(event.channel[0]) &&
        (event.type != IRCEvent.Type.ERR_NOSUCHCHANNEL) &&
        (event.type != IRCEvent.Type.RPL_ENDOFWHO) &&
        (event.type != IRCEvent.Type.RPL_NAMREPLY) &&
        (event.type != IRCEvent.Type.RPL_ENDOFNAMES) &&
        (event.type != IRCEvent.Type.RPL_LIST))  // Some channels can be asterisks if they aren't public
    {
        if (sink.data.length) sink.put(". ");
        sink.put("Channel is not a channel");
    }

    if (event.target.nickname == parser.bot.nickname)
    {
        with (IRCEvent.Type)
        switch (event.type)
        {
        case MODE:
        case QUERY:
        case JOIN:
        case SELFNICK:
        case RPL_WHOREPLY:
        case RPL_LOGGEDIN:
            break;

        default:
            event.target.nickname = string.init;
            break;
        }
    }

    if (!sink.data.length) return;

    version(PrintSanityFailures)
    {
        import kameloso.common : logger, printObject;
        import std.stdio : writeln;
        version(Cygwin_) import std.stdio : stdout;

        logger.warning(sink.data);
        event.errors = sink.data;
        printObject(event);

        version(Cygwin_) stdout.flush();
    }
    else version(ThrowSanityFailures)
    {
        event.errors = sink.data;
        throw new IRCParseException(sink.data, event);
    }
    else
    {
        // Silently let pass
        event.errors = sink.data;
    }
}


// isSpecial
/++
 +  Judges whether the sender of an `kameloso.ircdefs.IRCEvent` is *special*.
 +
 +  Special senders include services and staff, administrators and the like. The
 +  use of this is contested and the notion may be removed at a later date. For
 +  now, the only thing it does is add an asterisk to the sender's nickname, in
 +  the `kameloso.plugins.printer.PrinterPlugin` output.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event =  `kameloso.ircdefs.IRCEvent` to examine.
 +/
bool isSpecial(const ref IRCParser parser, const IRCEvent event) pure
{
    import kameloso.string : sharedDomains;
    import std.string : toLower;

    with (event)
    with (parser)
    {
        if (sender.isServer || (sender.address == bot.server.address) ||
            (sender.address == bot.server.resolvedAddress) ||
            (sender.address == "services."))
        {
            return true;
        }

        immutable service = event.sender.nickname.toLower();

        switch (service)
        {
        case "nickserv":
        case "saslserv":
            switch (sender.ident)
            {
            case "NickServ":
            case "SaslServ":
                if (sender.address == "services.") return true;
                break;

            case "services":
            case "service":
                // known idents, drop to after switch
                break;

            default:
                // Unknown ident, try the generic address check after the switch
                break;
            }
            break;

        case "global":
        case "chanserv":
        case "operserv":
        case "memoserv":
        case "hostserv":
        case "botserv":
        case "infoserv":
        case "reportserv":
        case "moraleserv":
        case "gameserv":
        case "groupserv":
        case "helpserv":
        case "statserv":
        case "userserv":
        case "alis":
        case "chanfix":
        case "c":
        case "spamserv":
        case "services.":
            // Known services that are not nickname services
            return true;

        case "q":
            // :Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.
            return ((sender.ident == "TheQBot") && (sender.address == "CServe.quakenet.org"));

        case "authserv":
            // :AuthServ!AuthServ@Services.GameSurge.net NOTICE kameloso :Could not find your account
            return ((sender.ident == "AuthServ") && (sender.address == "Services.GameSurge.net"));

        default:
            break;
        }

        if ((parser.bot.server.daemon != IRCServer.Daemon.twitch) &&
            ((sharedDomains(event.sender.address, parser.bot.server.address) >= 2) ||
            (sharedDomains(event.sender.address, parser.bot.server.resolvedAddress) >= 2)))
        {
            return true;
        }
        else if (event.sender.address.has("/staff/"))
        {
            return true;
        }
        else
        {
            return false;
        }
    }
}


// onNotice
/++
 +  Handle `NOTICE` events.
 +
 +  These are all(?) sent by the server and/or services. As such they often
 +  convey important `special` things, so parse those.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
            on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void onNotice(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string : beginsWith, sharedDomains;
    import std.string : toLower;
    // :ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflow] Make sure your nick is registered, then please try again to join ##linux.
    // :ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.
    // :tolkien.freenode.net NOTICE * :*** Checking Ident

    // At least Twitch sends NOTICEs to channels, maybe other daemons do too
    immutable channelOrNickname = slice.nom(" :");
    event.content = slice;

    if (channelOrNickname.length && channelOrNickname[0].matchesChantypes(parser.bot.server))
    {
        event.channel = channelOrNickname;
    }

    with (parser)
    {
        event.sender.special = parser.isSpecial(event);

        if (!bot.server.resolvedAddress.length && event.content.beginsWith("***"))
        {
            // This is where we catch the resolved address
            assert(!event.sender.nickname.length, event.sender.nickname);
            bot.server.resolvedAddress = event.sender.address;
            bot.updated = true;
        }

        if (!event.sender.isServer && parser.isFromAuthService(event))
        {
            //event.sender.special = true; // by definition

            if (event.content.toLower.has("/msg nickserv identify"))
            {
                event.type = IRCEvent.Type.AUTH_CHALLENGE;
                return;
            }

            // FIXME: This obviously doesn't scale either

            enum AuthSuccess
            {
                freenode = "You are now identified for",
                rizon = "Password accepted - you are now recognized.",
                quakenet = "You are now logged in as",
                gamesurge = "I recognize you.",
                dalnet = "Password accepted for",
            }

            with (event)
            with (AuthSuccess)
            {
                if ((content.beginsWith(freenode)) ||
                    (content.beginsWith(quakenet)) || // also Freenode SASL
                    (content.beginsWith(dalnet)) ||
                    (content == rizon) ||
                    (content == gamesurge))
                {
                    type = IRCEvent.Type.RPL_LOGGEDIN;

                    // Restart with the new type
                    return parser.parseSpecialcases(event, slice);
                }
            }

            enum AuthFailure
            {
                rizon = "Your nick isn't registered.",
                quakenet = "Username or password incorrect.",
                freenodeInvalid = "is not a registered nickname.",
                freenodeRejected = "Invalid password for",
                dalnet = "is not registered.",
                unreal = "isn't registered.",
                gamesurge = "Could not find your account -- did you register yet?",
            }

            with (event)
            with (AuthFailure)
            {
                if ((content == rizon) ||
                    (content == quakenet) ||
                    (content == gamesurge) ||
                     content.has(cast(string)freenodeInvalid) ||
                     content.beginsWith(cast(string)freenodeRejected) ||
                     content.has(cast(string)dalnet) ||
                     content.has(cast(string)unreal))
                {
                    event.type = IRCEvent.Type.AUTH_FAILURE;
                }
            }
        }
    }

    // FIXME: support
    // *** If you are having problems connecting due to ping timeouts, please type /quote PONG j`ruV\rcn] or /raw PONG j`ruV\rcn] now.
}


// onPRIVMSG
/++
 +  Handle `QUERY` and `CHAN` messages (`PRIVMSG`).
 +
 +  Whether it is a private query message or a channel message is only obvious
 +  by looking at the target field of it; if it starts with a `#`, it is a
 +  channel message.
 +
 +  Also handle `ACTION` events (`/me slaps foo with a large trout`), and change
 +  the type to `CTCP_`-types if applicable.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void onPRIVMSG(const ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string : beginsWith;

    immutable target = slice.nom(" :");
    event.content = slice;

    /*  When a server sends a PRIVMSG/NOTICE to someone else on behalf of a
        client connected to it – common when multiple clients are connected to a
        bouncer – it is called a self-message. With the echo-message capability,
        they are also sent in reply to every PRIVMSG/NOTICE a client sends.
        These are represented by a protocol message looking like this:

        :yournick!~foo@example.com PRIVMSG someone_else :Hello world!

        They should be put in someone_else's query and displayed as though they
        they were sent by the connected client themselves. This page displays
        which clients properly parse and display this type of echo'd
        PRIVMSG/NOTICE.

        http://defs.ircdocs.horse/info/selfmessages.html

        (common requested cap: znc.in/self-message)
     */

    if (target.isValidChannel(parser.bot.server))
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content
        event.type = (event.sender.nickname == parser.bot.nickname) ?
            IRCEvent.Type.SELFCHAN : IRCEvent.Type.CHAN;
        event.channel = target;
    }
    else
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content
        event.type = (event.sender.nickname == parser.bot.nickname) ?
            IRCEvent.Type.SELFQUERY : IRCEvent.Type.QUERY;
        event.target.nickname = target;
    }

    if (slice.length < 3) return;

    if ((slice[0] == IRCControlCharacter.ctcp) && (slice[$-1] == IRCControlCharacter.ctcp))
    {
        slice = slice[1..$-1];
        immutable ctcpEvent = slice.has(' ') ? slice.nom(' ') : slice;
        event.content = slice;

        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :ACTION test test content
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :ACTION test test content
        // :py-ctcp!ctcp@ctcp-scanner.rizon.net PRIVMSG kameloso^^ :VERSION
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :TIME
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :PING 1495974267 590878
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :CLIENTINFO
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :DCC
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :SOURCE
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :USERINFO
        // :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :FINGER

        import std.traits : EnumMembers;

        /++
         +  This iterates through all `kameloso.ircdefs.IRCEvent.Type`s that
         +  begin with `CTCP_` and generates switch cases for the string of
         +  each. Inside it will assign `event.type` to the corresponding
         +  `kameloso.ircdefs.IRCEvent.Type`.
         +
         +  Like so, except automatically generated through compile-time
         +  introspection:
         +
         +      case "CTCP_PING":
         +          event.type = CTCP_PING;
         +          event.aux = "PING";
         +          break;
         +/

        with (IRCEvent.Type)
        top:
        switch (ctcpEvent)
        {
        case "ACTION":
            // We already sliced away the control characters and nommed the
            // "ACTION" ctcpEvent string, so just set the type and break.
            event.type = IRCEvent.Type.EMOTE;
            break;

        foreach (immutable type; EnumMembers!(IRCEvent.Type))
        {
            import std.conv : to;

            enum typestring = type.to!string;

            static if (typestring.beginsWith("CTCP_"))
            {
                case typestring[5..$]:
                    event.type = type;
                    event.aux = typestring[5..$];
                    break top;
            }
        }

        default:
            throw new IRCParseException("Unknown CTCP event: " ~ ctcpEvent, event);
        }
    }
}


// onMode
/++
 +  Handles `MODE` changes.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void onMode(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    immutable target = slice.nom(' ');

    if (target.isValidChannel(parser.bot.server))
    {
        event.channel = target;

        if (slice.has(' '))
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
            event.aux = slice.nom(' ');
            // save target in content; there may be more than one
            event.content = slice;
        }
        else
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i
            // :niven.freenode.net MODE #sklabjoier +ns
            //event.type = IRCEvent.Type.USERMODE;
            event.aux = slice;
        }
    }
    else
    {
        import kameloso.string : beginsWith;
        import std.algorithm.iteration : filter, uniq;
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.string : representation;

        // :kameloso^ MODE kameloso^ :+i
        // :<something> MODE kameloso :ix
        // Does not always have the plus sign. Strip it if it's there.

        event.type = IRCEvent.Type.SELFMODE;
        if (slice.beginsWith(':')) slice = slice[1..$];

        bool subtractive;
        string modechange = slice;

        if (!slice.length) return;  // Just to safeguard before indexing [0]

        switch (slice[0])
        {
        case '-':
            subtractive = true;
            goto case '+';

        case '+':
            slice = slice[1..$];
            break;

        default:
            // No sign, implicitly additive
            modechange = '+' ~ slice;
        }

        event.aux = modechange;

        if (subtractive)
        {
            // Remove the mode from bot.modes
            foreach (immutable c; slice.representation)
            {
                parser.bot.modes = cast(string)parser.bot.modes
                    .representation
                    .filter!((a) => a != c)
                    .array
                    .idup;
            }
        }
        else
        {
            // Add the new mode to bot.modes
            auto modes = parser.bot.modes.dup.representation;
            modes ~= slice;
            parser.bot.modes = cast(string)modes
                .sort()
                .uniq
                .array
                .idup;
        }

        parser.bot.updated = true;
    }
}

///
unittest
{
    IRCParser parser;
    parser.bot.nickname = "kameloso^";
    parser.bot.modes = "x";

    {
        IRCEvent event;
        string slice = /*":kameloso^ MODE */"kameloso^ :+i";
        parser.onMode(event, slice);
        assert((parser.bot.modes == "ix"), parser.bot.modes);
    }
    {
        IRCEvent event;
        string slice = /*":kameloso^ MODE */"kameloso^ :-i";
        parser.onMode(event, slice);
        assert((parser.bot.modes == "x"), parser.bot.modes);
    }
    {
        IRCEvent event;
        string slice = /*":kameloso^ MODE */"kameloso^ :+abc";
        parser.onMode(event, slice);
        assert((parser.bot.modes == "abcx"), parser.bot.modes);
    }
    {
        IRCEvent event;
        string slice = /*":kameloso^ MODE */"kameloso^ :-bx";
        parser.onMode(event, slice);
        assert((parser.bot.modes == "ac"), parser.bot.modes);
    }
}

// onISUPPORT
/++
 +  Handles `ISUPPORT` events.
 +
 +  `ISUPPORT` contains a bunch of interesting information that changes how we
 +  look at the `kameloso.ircdefs.IRCServer`. Notably which *network* the server
 +  is of and its max channel and nick lengths, and available modes. Then much
 +  more that we're currently ignoring.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void onISUPPORT(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import kameloso.string : toEnum;
    import std.algorithm.iteration : splitter;
    import std.conv : ConvException, to;
    import std.string : toLower;

    // :cherryh.freenode.net 005 CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server
    // :cherryh.freenode.net 005 CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST :are supported by this server
    slice.nom(' ');

    if (slice.has(" :"))
    {
        event.content = slice.nom(" :");
    }

    try
    {
        foreach (value; event.content.splitter(' '))
        {
            if (!value.has('='))
            {
                // switch on value for things like EXCEPTS, INVEX, CPRIVMSG, etc
                continue;
            }

            immutable key = value.nom('=');

            /// http://www.irc.org/tech_docs/005.html

            with (parser.bot.server)
            switch (key)
            {
            case "PREFIX":
                // PREFIX=(Yqaohv)!~&@%+
                import std.format : formattedRead;

                string modes;
                string prefixes;
                value.formattedRead("(%s)%s", modes, prefixes);

                foreach (immutable i; 0..modes.length)
                {
                    prefixchars[prefixes[i]] = modes[i];
                    prefixes ~= modes[i];
                }
                break;

            case "CHANTYPES":
                // CHANTYPES=#
                // ...meaning which characters may prefix channel names.
                chantypes = value;
                break;

            case "CHANMODES":
                /++
                +  This is a list of channel modes according to 4 types.
                +
                +  A = Mode that adds or removes a nick or address to a list.
                +      Always has a parameter.
                +  B = Mode that changes a setting and always has a parameter.
                +  C = Mode that changes a setting and only has a parameter when
                +      set.
                +  D = Mode that changes a setting and never has a parameter.
                +
                +  Freenode: CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz
                +/
                string modeslice = value;
                aModes = modeslice.nom(',');
                bModes = modeslice.nom(',');
                cModes = modeslice.nom(',');
                dModes = modeslice;
                assert(!dModes.has(','), "Bad chanmodes; dModes has comma");
                break;

            case "NETWORK":
                import std.algorithm.searching : endsWith;

                network = value;

                if (value == "RusNet")
                {
                    // RusNet servers do not advertise an easily-identifiable
                    // daemonstring like "1.5.24/uk_UA.KOI8-U", so fake the daemon
                    // here.
                    parser.setDaemon(IRCServer.Daemon.rusnet, value);
                }
                else if (value == "IRCnet")
                {
                    // Likewise IRCnet only advertises the daemon version and not
                    // the daemon name.
                    parser.setDaemon(IRCServer.Daemon.ircnet, value);
                }
                break;

            case "NICKLEN":
                maxNickLength = value.to!uint;
                break;

            case "CHANNELLEN":
                maxChannelLength = value.to!uint;
                break;

            case "CASEMAPPING":
                caseMapping = value.toEnum!(IRCServer.CaseMapping);
                break;

            case "EXTBAN":
                // EXTBAN=$,ajrxz
                extbanPrefix = value.nom(',').to!char;
                extbanTypes = value;
                break;

            case "EXCEPTS":
                exceptsChar = value.length ? value.to!char : 'e';
                break;

            case "INVEX":
                invexChar = value.length ? value.to!char : 'I';
                break;

            default:
                break;
            }
        }

        parser.bot.updated = true;
    }
    catch (const ConvException e)
    {
        throw new IRCParseException(e.msg, event, e.file, e.line);
    }
    catch (const Exception e)
    {
        throw new IRCParseException(e.msg, event, e.file, e.line);
    }
}


// onMyInfo
/++
 +  Handle `MYINFO` events.
 +
 +  `MYINFO` contains information about which *daemon* the server is running.
 +  We want that to be able to meld together a good `typenums` array.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to continue working
 +          on.
 +      slice = Reference to the slice of the raw IRC string.
 +/
void onMyInfo(ref IRCParser parser, ref IRCEvent event, ref string slice) pure
{
    import std.string : toLower;

    /*
    cadance.canternet.org                   InspIRCd-2.0
    barjavel.freenode.net                   ircd-seven-1.1.4
    irc.uworld.se                           plexus-4(hybrid-8.1.20)
    port80c.se.quakenet.org                 u2.10.12.10+snircd(1.3.4a)
    Ashburn.Va.Us.UnderNet.org              u2.10.12.18
    irc2.unrealircd.org                     UnrealIRCd-4.0.16-rc1
    nonstop.ix.me.dal.net                   bahamut-2.0.7
    TAL.DE.EU.GameSurge.net                 u2.10.12.18(gs2)
    efnet.port80.se                         ircd-ratbox-3.0.9
    conclave.il.us.SwiftIRC.net             Unreal3.2.6.SwiftIRC(10)
    caliburn.pa.us.irchighway.net           InspIRCd-2.0
    (twitch)                                -
    irc.RomaniaChat.eu                      Unreal3.2.10.6
    Defiant.GeekShed.net                    Unreal3.2.10.3-gs
    irc.inn.at.euirc.net                    euIRCd 1.3.4-c09c980819
    irc.krstarica.com                       UnrealIRCd-4.0.9
    XxXChatters.Com                         UnrealIRCd-4.0.3.1
    noctem.iZ-smart.net                     Unreal3.2.10.4-iZ
    fedora.globalirc.it                     InspIRCd-2.0
    ee.ircworld.org                         charybdis-3.5.0.IRCWorld
    Armida.german-elite.net                 Unreal3.2.7
    procrastinate.idlechat.net              Unreal3.2.10.4
    irc2.chattersweb.nl                     UnrealIRCd-4.0.11
    Heol.Immortal-Anime.Net                 Unreal3.2.10.5
    brlink.vircio.net                       InspIRCd-2.2
    MauriChat.s2.de.GigaIRC.net             UnrealIRCd-4.0.10
    IRC.101Systems.Com.BR                   UnrealIRCd-4.0.15
    IRC.Passatempo.Org                      UnrealIRCd-4.0.14
    irc01-green.librairc.net                InspIRCd-2.0
    irc.place2chat.com                      UnrealIRCd-4.0.10
    irc.ircportal.net                       Unreal3.2.10.1
    irc.de.icq-chat.com                     InspIRCd-2.0
    lightning.ircstorm.net                  CR1.8.03-Unreal3.2.10.1
    irc.chat-garden.nl                      UnrealIRCd-4.0.10
    alpha.noxether.net                      UnrealIRCd-4.0-Noxether
    CraZyPaLaCe.Be_ChatFun.Be_Webradio.VIP  CR1.8.03-Unreal3.2.8.1
    redhispana.org                          Unreal3.2.8+UDB-3.6.1
    */

    // :asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI
    // :tmi.twitch.tv 004 zorael :-

    slice.nom(' ');  // nickname

    version(TwitchSupport)
    {
        if ((slice == ":-") && (parser.bot.server.address.has(".twitch.tv")))
        {
            parser.setDaemon(IRCServer.Daemon.twitch, "Twitch");
            parser.bot.server.network = "Twitch";
            parser.bot.updated = true;
            return;
        }
    }

    slice.nom(' ');  // server address
    immutable daemonstringRaw = slice.nom(' ');
    immutable daemonstring_ = daemonstringRaw.toLower();
    event.content = slice;
    event.aux = daemonstringRaw;

    // https://upload.wikimedia.org/wikipedia/commons/d/d5/IRCd_software_implementations3.svg

    with (IRCServer.Daemon)
    {
        IRCServer.Daemon daemon;

        if (parser.bot.server.daemon != IRCServer.Daemon.init)
        {
            // Daemon remained from previous connects.
            // Trust that the typenums did as well.
            return;
        }
        else if (daemonstring_.has("unreal"))
        {
            daemon = unreal;
        }
        else if (daemonstring_.has("inspircd"))
        {
            daemon = inspircd;
        }
        else if (daemonstring_.has("snircd"))
        {
            daemon = snircd;
        }
        else if (daemonstring_.has("u2."))
        {
            daemon = u2;
        }
        else if (daemonstring_.has("bahamut"))
        {
            daemon = bahamut;
        }
        else if (daemonstring_.has("hybrid"))
        {
            if (parser.bot.server.address.has(".rizon."))
            {
                daemon = rizon;
            }
            else
            {
                daemon = hybrid;
            }
        }
        else if (daemonstring_.has("ratbox"))
        {
            daemon = ratbox;
        }
        else if (daemonstring_.has("charybdis"))
        {
            daemon = charybdis;
        }
        else if (daemonstring_.has("ircd-seven"))
        {
            daemon = ircdseven;
        }
        else
        {
            daemon = unknown;
        }

        parser.setDaemon(daemon, daemonstringRaw);
    }
}


// toIRCEvent
/++
 +  Parses an IRC string into an `kameloso.ircdefs.IRCEvent`.
 +
 +  Parsing goes through several phases (prefix, typestring, specialcases) and
 +  this is the function that calls them, in order.
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      raw = Raw IRC string to parse.
 +
 +  Returns:
 +      A finished `kameloso.ircdefs.IRCEvent`.
 +/
IRCEvent toIRCEvent(ref IRCParser parser, const string raw)
{
    import kameloso.string : strippedRight;
    import std.datetime.systime : Clock;

    if (!raw.length) throw new IRCParseException("Tried to parse empty string");

    IRCEvent event;

    event.time = Clock.currTime.toUnixTime;

    // We don't need to .idup here; it has already been done in the Generator
    // when yielding
    event.raw = raw;

    if (raw[0] != ':')
    {
        if (raw[0] == '@')
        {
            // IRCv3 tags
            // @badges=broadcaster/1;color=;display-name=Zorael;emote-sets=0;mod=0;subscriber=0;user-type= :tmi.twitch.tv USERSTATE #zorael
            // @broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #zorael
            // @badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type= :asdcsa!asdcss@asdcsd.tmi.twitch.tv PRIVMSG #lirik :lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL
            import std.algorithm.iteration : splitter;

            // Get rid of the prepended @
            auto newRaw = event.raw[1..$];
            immutable tags = newRaw.nom(' ');
            event = parser.toIRCEvent(newRaw);
            event.tags = tags;
            return event;
        }
        else
        {
            parser.parseBasic(event);
            return event;
        }
    }

    auto slice = event.raw[1..$]; // advance past first colon

    // First pass: prefixes. This is the sender
    parser.parsePrefix(event, slice);

    // Second pass: typestring. This is what kind of action the event is of
    parser.parseTypestring(event, slice);

    // Third pass: specialcases. This splits up the remaining bits into
    // useful strings, like sender, target and content
    parser.parseSpecialcases(event, slice);

    // Final cosmetic touches
    event.content = event.content.strippedRight;

    // Final pass: sanity check. This verifies some fields and gives
    // meaningful error messages if something doesn't look right.
    parser.postparseSanityCheck(event);

    return event;
}


public:


// decodeIRCv3String
/++
 +  Decodes an IRCv3 tag string, replacing some characters.
 +
 +  IRCv3 tags need to be free of spaces, so by neccessity they're encoded into
 +  `\s`. Likewise; since tags are separated by semicolons, semicolons in tag
 +  string are encoded into `\:`, and literal backslashes `\\`.
 +
 +  Example:
 +  ---
 +  string encoded = `This\sline\sis\sencoded\:\swith\s\\s`;
 +  string decoded = decodeIRCv3String(encoded);
 +  assert(decoded == "This line is encoded; with \\s");
 +  ---
 +
 +  Params:
 +      line = Original line to decode.
 +
 +  Returns:
 +      A decoded string without `\s` in it.
 +/
string decodeIRCv3String(const string line)
{
    import std.array : Appender;
    import std.string : representation;

    /++
     +  http://ircv3.net/specs/core/message-tags-3.2.html
     +
     +  If a lone \ exists at the end of an escaped value (with no escape
     +  character following it), then there SHOULD be no output character.
     +  For example, the escaped value test\ should unescape to test.
     +/

    if (!line.length) return string.init;

    Appender!string sink;
    bool escaping;

    foreach (immutable c; line.representation)
    {
        if (escaping)
        {
            switch (c)
            {
            case '\\':
                sink.put('\\');
                break;

            case ':':
                sink.put(';');
                break;

            case 's':
                sink.put(' ');
                break;

            case 'n':
                sink.put('\n');
                break;

            case 't':
                sink.put('\t');
                break;

            case 'r':
                sink.put('\r');
                break;

            case '0':
                sink.put('\0');
                break;

            default:
                // Unknown escape
                sink.put(c);
            }

            escaping = false;
        }
        else
        {
            switch (c)
            {
            case '\\':
                escaping = true;
                break;

            default:
                sink.put(c);
            }
        }
    }

    return sink.data;
}

///
unittest
{
    immutable s1 = decodeIRCv3String(`kameloso\sjust\ssubscribed\swith\sa\s` ~
        `$4.99\ssub.\skameloso\ssubscribed\sfor\s40\smonths\sin\sa\srow!`);
    assert((s1 == "kameloso just subscribed with a $4.99 sub. " ~
        "kameloso subscribed for 40 months in a row!"), s1);

    immutable s2 = decodeIRCv3String(`stop\sspamming\scaps,\sautomated\sby\sNightbot`);
    assert((s2 == "stop spamming caps, automated by Nightbot"), s2);

    immutable s3 = decodeIRCv3String(`\:__\:`);
    assert((s3 == ";__;"), s3);

    immutable s4 = decodeIRCv3String(`\\o/ \\o\\ /o/ ~o~`);
    assert((s4 == `\o/ \o\ /o/ ~o~`), s4);

    immutable s5 = decodeIRCv3String(`This\sis\sa\stest\`);
    assert((s5 == "This is a test"), s5);

    immutable s6 = decodeIRCv3String(`9\sraiders\sfrom\sVHSGlitch\shave\sjoined\n!`);
    assert((s6 == "9 raiders from VHSGlitch have joined\n!"), s6);
}


// isFromAuthService
/++
 +  Looks at an  and decides whether it is from nickname services.
 +
 +  Example:
 +  ---
 +  IRCEvent event;
 +  if (parser.isFromAuthService(event))
 +  {
 +      // ...
 +  }
 +  ---
 +
 +  Params:
 +      parser = Reference to the current `IRCParser`.
 +      event = `kameloso.ircdefs.IRCEvent` to examine.
 +
 +  Returns:
 +      `true` if the sender is judged to be from nicknam services, `false` if
 +      not.
 +/
bool isFromAuthService(const ref IRCParser parser, const IRCEvent event) pure
{
    import kameloso.string : sharedDomains;
    import std.algorithm.searching : endsWith;
    import std.string : toLower;

    immutable service = event.sender.nickname.toLower();

    with (parser)
    with (event)
    switch (service)
    {
    case "nickserv":
    case "saslserv":
        switch (sender.ident)
        {
        case "NickServ":
        case "SaslServ":
            if (sender.address == "services.") return true;
            break;

        case "services":
        case "service":
            // known idents, drop to after switch
            break;

        default:
            // Unknown ident, try the generic address check after the switch
            break;
        }
        break;

    case "global":
    case "chanserv":
    case "operserv":
    case "memoserv":
    case "hostserv":
    case "botserv":
    case "infoserv":
    case "reportserv":
    case "moraleserv":
    case "gameserv":
    case "groupserv":
    case "helpserv":
    case "statserv":
    case "userserv":
    case "alis":
    case "chanfix":
    case "c":
    case "spamserv":
    case "services.":
        // Known services that are not nickname services
        return false;

    case "q":
        // :Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.
        return ((sender.ident == "TheQBot") && (sender.address == "CServe.quakenet.org"));

    case "authserv":
        // :AuthServ!AuthServ@Services.GameSurge.net NOTICE kameloso :Could not find your account
        return ((sender.ident == "AuthServ") && (sender.address == "Services.GameSurge.net"));

    default:
        if (sender.address.has("/staff/"))
        {
            // Staff notice
            return false;
        }

        // Not a known nick registration nick
        /*logger.warningf("Unknown nickname service nick: %s!%s@%s",
            sender.nickname, sender.ident, sender.address);
        printObject(event);*/
        return false;
    }

    if ((sharedDomains(event.sender.address, parser.bot.server.address) >= 2) ||
        (sharedDomains(event.sender.address, parser.bot.server.resolvedAddress) >= 2))
    {
        return true;
    }
    else
    {
        return false;
    }
}

unittest
{
    IRCParser parser;

    IRCEvent e1;
    with (e1)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice = raw[1..$];  // mutable
        parser.parsePrefix(e1, slice);
        assert(parser.isFromAuthService(e1));
    }

    IRCEvent e2;
    with (e2)
    {
        raw = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
        string slice = raw[1..$];
        parser.parsePrefix(e2, slice);
        assert(parser.isFromAuthService(e2));
    }

    IRCEvent e3;
    with (e3)
    {
        parser.bot.server.address = "irc.rizon.net";
        parser.bot.server.resolvedAddress = "irc.uworld.se";
        raw = ":NickServ!service@rizon.net NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,";
        string slice = raw[1..$];
        parser.parsePrefix(e3, slice);
        assert(parser.isFromAuthService(e3));
    }

    // Enabling this stops us from being alerted of unknown services
    /*IRCEvent e4;
    with (e4)
    {
        raw = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp";
        string slice = raw[1..$];
        parser.parsePrefix(e4, slice);
        assert(!parser.isFromAuthService(e4));
    }*/
}


// isValidChannel
/++
 +  Examines a string and decides whether it *looks* like a channel.
 +
 +  It needs to be passed an `kameloso.ircdefs.IRCServer` to know the max
 +  channel name length. An alternative would be to change the
 +  `kameloso.ircdefs.IRCServer` parameter to be an `uint`.
 +
 +  Example:
 +  ---
 +  IRCServer server;
 +  assert("#channel".isValidChannel(server));
 +  assert("##channel".isValidChannel(server));
 +  assert(!"!channel".isValidChannel(server));
 +  assert(!"#ch#annel".isValidChannel(server));
 +  ---
 +
 +  Params:
 +      line = String of a potential channel name.
 +      server = The current `kameloso.ircdefs.IRCServer` with all its settings.
 +
 +  Returns:
 +      `true` if the string content is judged to be a channel, `false` if not.
 +/
bool isValidChannel(const string line, const IRCServer server) pure @nogc
{
    import std.string : representation;

    /++
     +  Channels names are strings (beginning with a '&' or '#' character) of
     +  length up to 200 characters.  Apart from the the requirement that the
     +  first character being either '&' or '#'; the only restriction on a
     +  channel name is that it may not contain any spaces (' '), a control G
     +  (^G or ASCII 7), or a comma (',' which is used as a list item
     +  separator by the protocol).
     +
     +  https://tools.ietf.org/html/rfc1459.html
     +/
    if ((line.length < 2) || (line.length > server.maxChannelLength))
    {
        // Too short or too long a line
        return false;
    }

    if (!line[0].matchesChantypes(server)) return false;

    if (line.has(' ') ||
        line.has(',') ||
        line.has(7))
    {
        // Contains spaces, commas or byte 7
        return false;
    }

    if (line.length == 2) return !line[1].matchesChantypes(server);
    else if (line.length == 3) return !line[2].matchesChantypes(server);
    else if (line.length > 3)
    {
        // Allow for two ##s (or &&s) in the name but no more
        foreach (immutable chansign; server.chantypes.representation)
        {
            if (line[2..$].has(chansign)) return false;
        }
        return true;
    }
    else
    {
        return false;
    }
}

///
unittest
{
    IRCServer s;
    s.chantypes = "#&";

    assert("#channelName".isValidChannel(s));
    assert("&otherChannel".isValidChannel(s));
    assert("##freenode".isValidChannel(s));
    assert(!"###froonode".isValidChannel(s));
    assert(!"#not a channel".isValidChannel(s));
    assert(!"notAChannelEither".isValidChannel(s));
    assert(!"#".isValidChannel(s));
    assert(!"".isValidChannel(s));
    assert(!"##".isValidChannel(s));
    assert(!"&&".isValidChannel(s));
    assert("#d".isValidChannel(s));
    assert("#uk".isValidChannel(s));
    assert(!"###".isValidChannel(s));
    assert(!"#a#".isValidChannel(s));
    assert(!"a".isValidChannel(s));
    assert(!" ".isValidChannel(s));
    assert(!"".isValidChannel(s));
}


// matchesChantypes
/++
 +  Checks whether passed character is one of those in `CHANTYPES`.
 +
 +  Params:
 +      character = Character to evaluate whether or not it is a chantype
 +          character.
 +      server = The current IRCServer, from which we fetch the chantypes.
 +
 +  Returns:
 +      True if it is, false if it isn't.
 +/
bool matchesChantypes(const char character, const IRCServer server) pure nothrow @safe @nogc
{
    import std.string : representation;

    foreach (immutable chansign; server.chantypes.representation)
    {
        if (character == chansign)
        {
            return true;
        }
    }

    return false;
}

///
unittest
{
    IRCServer server;
    server.chantypes = "#%+";

    assert("#channel"[0].matchesChantypes(server));
    assert('%'.matchesChantypes(server));
    assert(!'~'.matchesChantypes(server));
}


// isValidNickname
/++
 +  Checks if a string *looks* like a nickname.
 +
 +  It only looks for invalid characters in the name as well as it length.
 +
 +  Example:
 +  ---
 +  assert("kameloso".isValidNickname);
 +  assert("kameloso^".isValidNickname);
 +  assert("kamelåså".isValidNickname);
 +  assert(!"#kameloso".isValidNickname);
 +  assert(!"k&&me##so".isValidNickname);
 +  ---
 +
 +  Params:
 +      nickname = String nickname.
 +      server = The current `kameloso.ircdefs.IRCServer` with all its settings.
 +
 +  Returns:
 +      `true` if the nickname string is judged to be a nickname, `false` if
 +      not.
 +/
bool isValidNickname(const string nickname, const IRCServer server)
{
    import std.string : representation;

    if (!nickname.length || (nickname.length > server.maxNickLength))
    {
        return false;
    }

    foreach (immutable c; nickname.representation)
    {
        if (!c.isValidNicknameCharacter) return false;
    }

    return true;
}

///
unittest
{
    import std.range : repeat;
    import std.conv : to;

    IRCServer s;

    immutable validNicknames =
    [
        "kameloso",
        "kameloso^",
        "zorael-",
        "hirr{}",
        "asdf`",
        "[afk]me",
        "a-zA-Z0-9",
        `\`,
    ];

    immutable invalidNicknames =
    [
        "",
        "X".repeat(s.maxNickLength+1).to!string,
        "åäöÅÄÖ",
        "\n",
        "¨",
        "@pelle",
        "+calvin",
        "&hobbes",
        "#channel",
        "$deity",
    ];

    foreach (nickname; validNicknames)
    {
        assert(nickname.isValidNickname(s), nickname);
    }

    foreach (nickname; invalidNicknames)
    {
        assert(!nickname.isValidNickname(s), nickname);
    }
}


// isValidNicknameCharacter
/++
 +  Determines whether a passed `char` can be part of a nickname.
 +
 +  The IRC standard describes nicknames as being a string of any of the
 +  following characters:
 +
 +  `[a-z] [A-Z] [0-9] _-\[]{}^`|`
 +
 +  Example:
 +  ---
 +  assert('a'.isValidNicknameCharacter);
 +  assert('9'.isValidNicknameCharacter);
 +  assert('`'.isValidNicknameCharacter);
 +  assert(!(' '.isValidNicknameCharacter));
 +  ---
 +
 +  Params:
 +      c = Character to compare with the list of accepted characters in a
 +          nickname.
 +
 +  Returns:
 +      `true` if the character is in the list of valid characters for
 +      nicknames, `false` if not.
 +/
bool isValidNicknameCharacter(const char c)
{
    switch (c)
    {
    case 'a':
    ..
    case 'z':
    case 'A':
    ..
    case 'Z':
    case '0':
    ..
    case '9':
    case '_':
    case '-':
    case '\\':
    case '[':
    case ']':
    case '{':
    case '}':
    case '^':
    case '`':
    case '|':
        return true;
    default:
        return false;
    }
}

///
unittest
{
    import std.string : representation;

    {
        immutable line = "abcDEFghi0{}29304_[]`\\^|---";
        foreach (char c; line.representation)
        {
            assert(c.isValidNicknameCharacter, c ~ "");
        }
    }

    assert(!(' '.isValidNicknameCharacter));
}


// stripModesign
/++
 +  Takes a nickname and strips it of any prepended mode signs, like the `@` in
 +  `@nickname`. Saves the stripped signs in the ref string `modesigns`.
 +
 +  Example:
 +  ---
 +  IRCServer server;
 +  immutable signed = "@+kameloso";
 +  string signs;
 +  immutable nickname = server.stripModeSign(signed, signs);
 +  assert((nickname == "kameloso"), nickname);
 +  assert((signs == "@+"), signs);
 +  ---
 +
 +  Params:
 +      server = `kameloso.ircdefs.IRCServer`, with all its settings.
 +      nickname = String with a signed nickname.
 +      modesigns = Reference string to write the stripped modesigns to.
 +
 +  Returns:
 +      The nickname without any prepended prefix signs.
 +/
string stripModesign(const IRCServer server, const string nickname,
    ref string modesigns) pure nothrow @nogc
{
    if (!nickname.length) return string.init;

    size_t i;

    for (i = 0; i<nickname.length; ++i)
    {
        if (nickname[i] !in server.prefixchars)
        {
            break;
        }
    }

    modesigns = nickname[0..i];
    return nickname[i..$];
}

///
unittest
{
    IRCServer server;
    server.prefixchars =
    [
        '@' : 'o',
        '+' : 'v',
        '%' : 'h',
    ];

    {
        immutable signed = "@kameloso";
        string signs;
        immutable nickname = server.stripModesign(signed, signs);
        assert((nickname == "kameloso"), nickname);
        assert((signs == "@"), signs);
    }

    {
        immutable signed = "kameloso";
        string signs;
        immutable nickname = server.stripModesign(signed, signs);
        assert((nickname == "kameloso"), nickname);
        assert(!signs.length, signs);
    }

    {
        immutable signed = "@+kameloso";
        string signs;
        immutable nickname = server.stripModesign(signed, signs);
        assert((nickname == "kameloso"), nickname);
        assert((signs == "@+"), signs);
    }
}


// stripModesign
/++
 +  Convenience function to `stripModesign` that doesn't take a ref string
 +  parameter to store the stripped modesign characters in.
 +
 +  Example:
 +  ---
 +  IRCServer server;
 +  immutable signed = "@+kameloso";
 +  immutable nickname = server.stripModeSign(signed);
 +  assert((nickname == "kameloso"), nickname);
 +  assert((signs == "@+"), signs);
 +  ---
 +/
string stripModesign(const IRCServer server, const string nickname) pure nothrow @nogc
{
    string nothing;
    return stripModesign(server, nickname, nothing);
}

///
unittest
{
    IRCServer server;
    server.prefixchars =
    [
        '@' : 'o',
        '+' : 'v',
        '%' : 'h',
    ];

    {
        immutable signed = "@+kameloso";
        immutable nickname = server.stripModesign(signed);
        assert((nickname == "kameloso"), nickname);
    }
}


// IRCParser
/++
 +  State needed to parse IRC events.
 +/
struct IRCParser
{
    @safe:

    alias Type = IRCEvent.Type;
    alias Daemon = IRCServer.Daemon;

    /++
     +  The current `kameloso.ircdefs.IRCBot` with all the state needed for
     +  parsing.
     +/
    IRCBot bot;

    /// An `IRCEvent.Type[1024]` reverse lookup table for fast numeric lookups.
    Type[1024] typenums = Typenums.base;

    // toIRCEvent
    /++
    +  Parses an IRC string into an `kameloso.ircdefs.IRCEvent`.
    +
    +  Proxies the call to the top-level `toIRCEvent(IRCParser, string)`.
    +/
    IRCEvent toIRCEvent(const string raw)
    {
        return .toIRCEvent(this, raw);
    }

    /++
     +  Create a new `IRCParser` with the passed `kameloso.ircdefs.IRCBot` as
     +  base.
     +/
    this(IRCBot bot) pure
    {
        this.bot = bot;
    }

    /// Disallow copying of this struct.
    @disable this(this);

    // setDaemon
    /++
     +  Sets the server daemon and melds together the needed typenums.
     +
     +  ---
     +  IRCParser parser;
     +  parser.setDaemon(IRCServer.Daemon.unreal, daemonstring);
     +  ---
     +/
    void setDaemon(const Daemon daemon, const string daemonstring) pure nothrow @nogc
    {
        import kameloso.meld : meldInto;
        import std.typecons : Flag, No, Yes;

        /// https://upload.wikimedia.org/wikipedia/commons/d/d5/IRCd_software_implementations3.svg

        // Reset
        typenums = Typenums.base;

        bot.server.daemon = daemon;
        bot.server.daemonstring = daemonstring;
        bot.updated = true;

        with (Typenums)
        with (Daemon)
        final switch (bot.server.daemon)
        {
        case unreal:
            Typenums.unreal.meldInto!(Yes.overwrite)(typenums);
            break;

        case inspircd:
            Typenums.inspIRCd.meldInto!(Yes.overwrite)(typenums);
            break;

        case bahamut:
            Typenums.bahamut.meldInto!(Yes.overwrite)(typenums);
            break;

        case ratbox:
            Typenums.ratBox.meldInto!(Yes.overwrite)(typenums);
            break;

        case u2:
            // unknown!
            break;

        case rizon:
            // Rizon is hybrid but has some own extras
            Typenums.hybrid.meldInto!(Yes.overwrite)(typenums);
            Typenums.rizon.meldInto!(Yes.overwrite)(typenums);
            break;

        case hybrid:
            Typenums.hybrid.meldInto!(Yes.overwrite)(typenums);
            break;

        case ircu:
            Typenums.ircu.meldInto!(Yes.overwrite)(typenums);
            break;

        case aircd:
            Typenums.aircd.meldInto!(Yes.overwrite)(typenums);
            break;

        case rfc1459:
            Typenums.rfc1459.meldInto!(Yes.overwrite)(typenums);
            break;

        case rfc2812:
            Typenums.rfc2812.meldInto!(Yes.overwrite)(typenums);
            break;

        case snircd:
            // snircd is based on ircu
            Typenums.ircu.meldInto!(Yes.overwrite)(typenums);
            Typenums.snircd.meldInto!(Yes.overwrite)(typenums);
            break;

        case nefarious:
            // Both nefarious and nefarious2 are based on ircu
            Typenums.ircu.meldInto!(Yes.overwrite)(typenums);
            Typenums.nefarious.meldInto!(Yes.overwrite)(typenums);
            break;

        case rusnet:
            Typenums.rusnet.meldInto!(Yes.overwrite)(typenums);
            break;

        case austhex:
            Typenums.austHex.meldInto!(Yes.overwrite)(typenums);
            break;

        case ircnet:
            Typenums.ircNet.meldInto!(Yes.overwrite)(typenums);
            break;

        case ptlink:
            Typenums.ptlink.meldInto!(Yes.overwrite)(typenums);
            break;

        case ultimate:
            Typenums.ultimate.meldInto!(Yes.overwrite)(typenums);
            break;

        case charybdis:
            Typenums.charybdis.meldInto!(Yes.overwrite)(typenums);
            break;

        case ircdseven:
            // Nei | freenode is based in charybdis which is based on ratbox iirc
            Typenums.hybrid.meldInto!(Yes.overwrite)(typenums);
            Typenums.ratBox.meldInto!(Yes.overwrite)(typenums);
            Typenums.charybdis.meldInto!(Yes.overwrite)(typenums);
            break;

        case undernet:
            Typenums.undernet.meldInto!(Yes.overwrite)(typenums);
            break;

        case anothernet:
            //Typenums.anothernet.meldInto!(Yes.overwrite)(typenums);
            break;

        case sorircd:
            Typenums.charybdis.meldInto!(Yes.overwrite)(typenums);
            Typenums.sorircd.meldInto!(Yes.overwrite)(typenums);
            break;

        case bdqircd:
            //Typenums.bdqIrcD.meldInto!(Yes.overwrite)(typenums);
            break;

        case chatircd:
            //Typenums.chatIRCd.meldInto!(Yes.overwrite)(typenums);
            break;

        case irch:
            //Typenums.irch.meldInto!(Yes.overwrite)(typenums);
            break;

        case ithildin:
            //Typenums.ithildin.meldInto!(Yes.overwrite)(typenums);
            break;

        case twitch:
            // do nothing, their events aren't numerical?
            break;

        case unknown:
        case unset:
            // do nothing...
            break;
        }
    }
}

unittest
{
    import kameloso.meld : meldInto;
    import std.typecons : Flag, No, Yes;

    IRCParser parser;

    alias T = IRCEvent.Type;

    with (parser)
    {
        typenums = Typenums.base;

        assert(typenums[344] == T.init);
        Typenums.hybrid.meldInto!(Yes.overwrite)(typenums);
        assert(typenums[344] != T.init);
    }
}


// setMode
/++
 +  Sets a new or removes a `Mode`.
 +
 +  `Mode`s that are merely a character in `modechars` are simpy removed if
 +   the *sign* of the mode change is negative, whereas a more elaborate
 +  `Mode` in the `modes` array are only replaced or removed if they match a
 +   comparison test.
 +
 +  Several modes can be specified at once, including modes that take a
 +  `data` argument, assuming they are in the proper order (where the
 +  `data`-taking modes are at the end of the string).
 +
 +  Example:
 +  ---
 +  IRCChannel channel;
 +  channel.setMode("+oo zorael!NaN@* kameloso!*@*")
 +  assert(channel.modes.length == 2);
 +  channel.setMode("-o kameloso!*@*");
 +  assert(channel.modes.length == 1);
 +  channel.setMode("-o *!*@*");
 +  assert(!channel.modes.length);
 +  ---
 +
 +  Params:
 +      channel = `kameloso.ircdefs.IRCChannel` whose modes are being set.
 +      signedModestring = String of the raw mode command, including the
 +          prefixing sign (+ or -).
 +      data = Appendix to the signed modestring; arguments to the modes that
 +          are being set.
 +      server = The current `kameloso.ircdefs.IRCServer` with all its settings.
 +/
void setMode(ref IRCChannel channel, const string signedModestring,
    const string data, IRCServer server) pure
{
    import kameloso.string : beginsWith, has, nom;
    import std.array : array;
    import std.algorithm.iteration : splitter;
    import std.algorithm.mutation : remove;
    import std.conv : to;
    import std.range : StoppingPolicy, retro, zip;

    if (!signedModestring.length) return;

    char sign = signedModestring[0];
    string modestring;

    if ((sign == '+') || (sign == '-'))
    {
        // Explicitly plus or minus
        sign = signedModestring[0];
        modestring = signedModestring[1..$];
    }
    else
    {
        // No sign, implicitly plus (and don't slice it away)
        sign = '+';
        modestring = signedModestring;
    }

    with (channel)
    {
        auto datalines = data.splitter(" ").array.retro;
        auto moderange = modestring.retro;
        auto ziprange = zip(StoppingPolicy.longest, moderange, datalines);

        Mode[] newModes;
        IRCUser[] carriedExemptions;

        foreach (modechar, datastring; ziprange)
        {
            Mode newMode;
            newMode.modechar = modechar.to!char;

            if ((modechar == server.exceptsChar) || (modechar == server.invexChar))
            {
                // Exemption, carry it to the next aMode
                carriedExemptions ~= IRCUser(datastring);
                continue;
            }

            if (!datastring.beginsWith(server.extbanPrefix) && datastring.has('!') && datastring.has('@'))
            {
                // Looks like a user and not an extban
                newMode.user = IRCUser(datastring);
            }
            else if (datastring.beginsWith(server.extbanPrefix))
            {
                // extban; https://freenode.net/kb/answer/extbans
                // https://defs.ircdocs.horse/defs/extbans.html
                // Does not support a mix of normal and second form bans
                // e.g. *!*@*$#channel

                /+ extban format:
                "$a:dannylee$##arguments"
                "$a:shr000ms"
                "$a:deadfrogs"
                "$a:b4b"
                "$a:terabits$##arguments"
                // "$x:*0x71*"
                "$a:DikshitNijjer"
                "$a:NETGEAR_WNDR3300"
                "$~a:eir"+/
                string slice = datastring[1..$];

                if (slice[0] == '~')
                {
                    // Negated extban
                    newMode.negated = true;
                    slice = slice[1..$];
                }

                switch (slice[0])
                {
                case 'a':
                case 'R':
                    // Match account
                    if (slice.has(':'))
                    {
                        // More than one field
                        slice.nom(':');

                        if (slice.has('$'))
                        {
                            // More than one field, first is account
                            newMode.user.account = slice.nom('$');
                            newMode.data = slice;
                        }
                        else
                        {
                            // Whole slice is an account
                            newMode.user.account = slice;
                        }
                    }
                    else
                    {
                        // "$~a"
                        // "$R"
                        // FIXME: Figure out how to express this.
                        if (slice.length)
                        {
                            newMode.data = slice;
                        }
                        else
                        {
                            newMode.data = datastring;
                        }
                    }
                    break;

                case 'j':
                //case 'c':  // Conflicts with colour ban
                    // Match channel
                    slice.nom(':');
                    newMode.channel = slice;
                    break;

                /*case 'r':
                    // GECOS/Real name, which we aren't saving currently.
                    // Can be done if there's a use-case for it.
                    break;*/

                /*case 's':
                    // Which server the user(s) the mode refers to are connected to
                    // which we aren't saving either. Can also be fixed.
                    break;*/

                default:
                    // Unhandled extban mode
                    newMode.data = datastring;
                    break;
                }
            }
            else
            {
                // Normal, non-user non-extban mode
                newMode.data = datastring;
            }

            if (sign == '+')
            {
                if (server.prefixes.has(modechar))
                {
                    import std.algorithm.searching : canFind;

                    // Register users with prefix modes (op, halfop, voice, ...)
                    auto prefixedUsers = newMode.modechar in channel.mods;
                    if (prefixedUsers && (*prefixedUsers).canFind(newMode.data))
                    {
                        continue;
                    }

                    channel.mods[newMode.modechar] ~= newMode.data;
                    continue;
                }

                if (server.aModes.has(modechar))
                {
                    /++
                     +  A = Mode that adds or removes a nick or address to a
                     +  list. Always has a parameter.
                     +/

                    // STACKS.
                    // If an identical Mode exists, add exemptions and skip
                    foreach (mode; modes)
                    {
                        if (mode == newMode)
                        {
                            mode.exemptions ~= carriedExemptions;
                            carriedExemptions.length = 0;
                            continue;
                        }
                    }

                    newMode.exemptions ~= carriedExemptions;
                    carriedExemptions.length = 0;
                }
                else if (server.bModes.has(modechar) || server.cModes.has(modechar))
                {
                    /++
                     +  B = Mode that changes a setting and always has a
                     +  parameter.
                     +
                     +  C = Mode that changes a setting and only has a
                     +  parameter when set.
                     +/

                    // DOES NOT STACK.
                    // If an identical Mode exists, overwrite
                    foreach (immutable i, mode; modes)
                    {
                        if (mode.modechar == modechar)
                        {
                            modes[i] = newMode;
                            continue;
                        }
                    }
                }
                else /*if (server.dModes.has(modechar))*/
                {
                    // Some clients assume that any mode not listed is of type D
                    if (!modechars.has(modechar)) modechars ~= modechar;
                    continue;
                }

                newModes ~= newMode;
            }
            else if (sign == '-')
            {
                if (server.prefixes.has(modechar))
                {
                    import std.algorithm.mutation : remove;
                    import std.algorithm.searching : countUntil;

                    // Remove users with prefix modes (op, halfop, voice, ...)
                    auto prefixedUsers = newMode.modechar in channel.mods;
                    if (!prefixedUsers) continue;

                    immutable index = (*prefixedUsers).countUntil(newMode.data);
                    if (index != -1) *prefixedUsers = (*prefixedUsers).remove(index);
                }

                if (server.aModes.has(modechar))
                {
                    /++
                     +  A = Mode that adds or removes a nick or address to a
                     +  a list. Always has a parameter.
                     +/

                    // If a comparison matches, remove
                    size_t[] toRemove;

                    foreach (immutable i, mode; modes)
                    {
                        if (mode == newMode)
                        {
                            toRemove ~= i;
                        }
                    }

                    foreach_reverse (i; toRemove)
                    {
                        modes = modes.remove(i);
                    }
                }
                else if (server.bModes.has(modechar) || server.cModes.has(modechar))
                {
                    /++
                     +  B = Mode that changes a setting and always has a
                     +  parameter.
                     +
                     +  C = Mode that changes a setting and only has a
                     +  parameter when set.
                     +/

                    // If the modechar matches, remove
                    foreach (immutable i, mode; modes)
                    {
                        if (mode.modechar == newMode.modechar)
                        {
                            modes = modes.remove(i);
                            break;
                        }
                    }
                }
                else /*if (server.dModes.has(modechar))*/
                {
                    // Some clients assume that any mode not listed is of type D
                    import std.string : indexOf;

                    immutable modecharIndex = modechars.indexOf(modechar);
                    if (modecharIndex == -1) continue;

                    if (modecharIndex != (modechars.length-1))
                    {
                        modechars = modechars[1..modecharIndex] ~ modechars[modecharIndex+1..$];
                    }
                    else
                    {
                        modechars = modechars[0..modecharIndex];
                    }
                }
            }
            else
            {
                assert(0, "Invalid mode sign: " ~ sign);
            }

        }

        if (sign == '+')
        {
            modes ~= newModes;
        }
    }
}

///
unittest
{
    import std.stdio;
    import std.conv;

    IRCServer server;
    // Freenode: CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz
    server.aModes = "eIbq";
    server.bModes = "k";
    server.cModes = "flj";
    server.dModes = "CFLMPQScgimnprstz";

    // SpotChat: PREFIX=(Yqaohv)!~&@%+
    server.prefixes = "Yaohv";
    server.prefixchars =
    [
        '!' : 'Y',
        '~' : 'q',
        '&' : 'a',
        '@' : 'o',
        '%' : 'h',
        '+' : 'v',
    ];

    {
        IRCChannel chan;

        chan.topic = "Huerbla";

        chan.setMode("+b", "kameloso!~NaN@aasdf.freenode.org", server);
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert(chan.modes.length == 1);

        chan.setMode("+bbe", "hirrsteff!*@* harblsnarf!ident@* NICK!~IDENT@ADDRESS", server);
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert(chan.modes.length == 3);

        chan.setMode("-b", "*!*@*", server);
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert(chan.modes.length == 0);

        chan.setMode("+i", string.init, server);
        assert(chan.modechars == "i", chan.modechars);

        chan.setMode("+v", "harbl", server);
        assert(chan.modechars == "i", chan.modechars);

        chan.setMode("-i", string.init, server);
        assert(!chan.modechars.length, chan.modechars);

        chan.setMode("+l", "200", server);
        IRCChannel.Mode lMode;
        lMode.modechar = 'l';
        lMode.data = "200";
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert((chan.modes[0] == lMode), chan.modes[0].toString());

        chan.setMode("+l", "100", server);
        lMode.modechar = 'l';
        lMode.data = "100";
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert((chan.modes[0] == lMode), chan.modes[0].toString());
    }

    {
        IRCChannel chan;

        chan.setMode("+CLPcnprtf", "##linux-overflow", server);
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert(chan.modes[0].data == "##linux-overflow");
        assert(chan.modes.length == 1);
        assert(chan.modechars.length == 8);

        chan.setMode("+bee", "mynick!myident@myaddress abc!def@ghi jkl!*@*", server);
        //foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        //writeln("-------------------------------------");
        assert(chan.modes.length == 2);
        assert(chan.modes[1].exemptions.length == 2);
    }

    {
        IRCChannel chan;

        chan.setMode("+ns", string.init, server);
        foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        assert(chan.modes.length == 0);
        assert(chan.modechars == "sn", chan.modechars);

        chan.setMode("-sn", string.init, server);
        foreach (i, mode; chan.modes) writefln("%2d: %s", i, mode);
        assert(chan.modes.length == 0);
        assert(chan.modechars.length == 0);
    }

    {
        IRCChannel chan;
        chan.setMode("+oo", "kameloso zorael", server);
        assert(chan.mods['o'].length == 2);
        chan.setMode("-o", "kameloso", server);
        assert(chan.mods['o'].length == 1);
        chan.setMode("-o", "zorael", server);
        assert(!chan.mods['o'].length);
    }

    {
        IRCChannel chan;
        server.extbanPrefix = '$';

        chan.setMode("+b", "$a:hirrsteff", server);
        assert(chan.modes.length);
        with (chan.modes[0])
        {
            assert((modechar == 'b'), modechar.text);
            assert((user.account == "hirrsteff"), user.account);
        }

        chan.setMode("+q", "$~a:blarf", server);
        assert((chan.modes.length == 2), chan.modes.length.text);
        with (chan.modes[1])
        {
            assert((modechar == 'q'), modechar.text);
            assert((user.account == "blarf"), user.account);
            assert(negated);
            IRCUser blarf;
            blarf.nickname = "blarf";
            blarf.account = "blarf";
            assert(blarf.matchesByMask(user));
        }
    }
}


// IRCParseException
/++
 +  IRC Parsing Exception, thrown when there were errors parsing.
 +
 +  It is a normal `Exception` but with an attached `kameloso.ircdefs.IRCEvent`.
 +/
final class IRCParseException : Exception
{
    /// Bundled `kameloso.ircdefs.IRCEvent`, parsing which threw this exception.
    IRCEvent event;

    /++
     +  Create a new `IRCParseException`, without attaching an
     +  `kameloso.ircdefs.IRCEvent`.
     +/
    this(const string message, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        super(message, file, line);
    }

    /++
     +  Create a new `IRCParseException`, attaching an
     +  `kameloso.ircdefs.IRCEvent` to it.
     +/
    this(const string message, const IRCEvent event, const string file = __FILE__, const size_t line = __LINE__) pure
    {
        this.event = event;
        super(message, file, line);
    }
}

///
unittest
{
    import std.exception : assertThrown;

    IRCEvent event;

    assertThrown!IRCParseException((){ throw new IRCParseException("adf"); }());

    assertThrown!IRCParseException(()
    {
        throw new IRCParseException("adf", event);
    }());

    assertThrown!IRCParseException(()
    {
        throw new IRCParseException("adf", event, "somefile.d");
    }());

    assertThrown!IRCParseException(()
    {
        throw new IRCParseException("adf", event, "somefile.d", 9999U);
    }());
}


/// Certain characters that signal specific meaning in an IRC context.
enum IRCControlCharacter
{
    ctcp = 1,
    bold = 2,
    colour = 3,
    italics = 29,
    underlined = 31,
}

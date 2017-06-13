module kameloso.irc;

import kameloso.common;
import kameloso.constants;

import std.format : format, formattedRead;
import std.string : indexOf;

@safe:

private:

/// State variables and configuration for the IRC bot.
IRCBot bot;

/// Max nickname length as per IRC specs, but not the de facto standard
uint maxNickLength = 9;

/// Max channel name length as per IRC specs
uint maxChannelLength = 200;

/// Function hooks to call upon certain pre-defined events
IRCParserHooks hooks;


// parseBasic
/++
 +  Parses the most basic of IRC events; PING, ERROR, PONG and NOTICE.
 +
 +  They syntactically differ from other events in that they are not prefixed
 +  by their sender.
 +
 +  The IRCEvent is finished at the end of this function.
 +
 +  Params:
 +      ref event = the IRCEvent to fill out the members of.
 +/
void parseBasic(ref IRCEvent event)
{
    mixin(scopeguard(failure));

    string raw = event.raw;
    string slice;
    raw.formattedRead("%s :%s", event.typestring, slice);

    switch (event.typestring)
    {
    case "PING":
        event.type = IRCEvent.Type.PING;
        event.sender = slice;
        break;

    case "ERROR":
        // ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)
        event.type = IRCEvent.Type.ERROR;
        event.content = slice;
        break;

    case "NOTICE":
        import std.string : stripRight;
        // QuakeNet/Undernet
        // NOTICE AUTH :*** Couldn't look up your hostname
        // Unsure how formattedRead is doing this...
        bot.server.network = IRCServer.Network.quakenet;  // only available locally
        event.type = IRCEvent.Type.NOTICE;
        event.content = raw;
        event.aux = slice.stripRight();
        event.special = true;
        break;

    case "PONG":
        // PONG :tmi.twitch.tv
        event.sender = slice;
        break;

    default:
        writeln(Foreground.lightred, "Unknown basic type: ", event.raw);
        writeln(Foreground.lightred, "Please report this.");
        break;
    }
}

unittest
{
    import std.conv : to;

    IRCEvent e1;
    with (e1)
    {
        raw = "PING :irc.server.address";
        e1.parseBasic();
        assert((raw == "PING :irc.server.address"), raw);
        assert((type == IRCEvent.Type.PING), type.to!string);
        assert((sender == "irc.server.address"), sender);
    }

    IRCEvent e2;
    with (e2)
    {
        // QuakeNet and others not having the sending server as prefix
        raw = "NOTICE AUTH :*** Couldn't look up your hostname";
        e2.parseBasic();
        assert((raw == "NOTICE AUTH :*** Couldn't look up your hostname"), raw);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert(!sender.length, sender);
        assert((content == "*** Couldn't look up your hostname"));
    }

    IRCEvent e3;
    with (e3)
    {
        raw = "ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)";
        e3.parseBasic();
        assert((raw == "ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"), raw);
        assert((type == IRCEvent.Type.ERROR), type.to!string);
        assert(!sender.length, sender);
        assert((content == "Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"), content);
    }
}


// parsePrefix
/++
 +  Takes a slice of a raw IRC string and starts parsing it into an IRCEvent struct.
 +
 +  This function only focuses on the prefix; the sender, be it nickname and ident
 +  or server address.
 +
 +  The IRCEvent is not finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent to start working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parsePrefix(ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : nom;
    import std.algorithm.searching : endsWith;

    auto prefix = slice.nom(' ');

    with(event)
    if (prefix.indexOf('!') != -1)
    {
        // user!~ident@address
        prefix.formattedRead("%s!%s@%s", &sender, &ident, &address);

        // FIXME: This obviously doesn't scale
        special = (address == "services.") ||
                  ((ident == "service") && (address == "rizon.net")) ||
                  (address.endsWith(".rizon.net")) ||
                  (address.endsWith(".quakenet.org"));
    }
    else
    {
        sender = prefix;
    }
}

unittest
{
    import std.conv : to;

    IRCEvent e1;
    with (e1)
    {
        raw = ":zorael!~NaN@some.address.org PRIVMSG kameloso :this is fake";
        string slice1 = raw[1..$];  // mutable
        e1.parsePrefix(slice1);
        assert((sender == "zorael"), sender);
        assert((ident == "~NaN"), ident);
        assert((address == "some.address.org"), address);
        assert(!special);
    }

    IRCEvent e2;
    with (e2)
    {
        raw = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
        string slice2 = raw[1..$];  // mutable
        e2.parsePrefix(slice2);
        assert((sender == "NickServ"), sender);
        assert((ident == "NickServ"), ident);
        assert((address == "services."), address);
        assert(special);
    }

    IRCEvent e3;
    with (e3)
    {
        raw = ":kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp";
        string slice3 = raw[1..$];  // mutable
        e3.parsePrefix(slice3);
        assert((sender == "kameloso^^"), sender);
        assert((ident == "~NaN"), ident);
        assert((address == "C2802314.E23AD7D8.E9841504.IP"), address);
        assert(!special);
    }

    IRCEvent e4;
    with (e4)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice4 = raw[1..$];
        e4.parsePrefix(slice4);
        assert((sender == "Q"), sender);
        assert((ident == "TheQBot"), ident);
        assert((address == "CServe.quakenet.org"), address);
        assert(special);
    }
}


// parseTypestring
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an IRCEvent struct.
 +
 +  This function only focuses on the typestring; the part that tells what kind of event
 +  happened, like PRIVMSG or MODE or NICK or KICK, etc; in string format.
 +
 +  The IRCEvent is not finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent to continue working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseTypestring(ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : nom, toEnum;
    import std.conv : to;

    event.typestring = slice.nom(' ');

    if ((event.typestring[0] > 47) && (event.typestring[0] < 58))
    {
        // typestring is a number (ascii 48 is 0, 57 is 9)
        try
        {
            immutable number = event.typestring.to!uint;
            event.num = number;
            event.type = IRCEvent.typenums[number];

            with (IRCEvent.Type)
            event.type = (event.type == UNSET) ? NUMERIC : event.type;
        }
        catch (Exception e)
        {
            writefln("------------------ %s ----------------", e.msg);
            printObjects(event);
        }
    }
    else
    {
        try event.type = event.typestring.toEnum!(IRCEvent.Type);
        catch (Exception e)
        {
            writefln("------------------ %s ----------------", e.msg);
            printObjects(event);
        }
    }
}

unittest
{
    import std.conv : to;

    IRCEvent e1;
    with (e1)
    {
        raw = /*":port80b.se.quakenet.org */"421 kameloso åäö :Unknown command";
        string slice = raw;  // mutable
        e1.parseTypestring(slice);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((num == 421), num.to!string);
    }

    IRCEvent e2;
    with (e2)
    {
        raw = /*":port80b.se.quakenet.org */"353 kameloso = #garderoben :@kameloso'";
        string slice = raw;  // mutable
        e2.parseTypestring(slice);
        assert((type == IRCEvent.Type.RPL_NAMREPLY), type.to!string);
        assert((num == 353), num.to!string);
    }

    IRCEvent e3;
    with (e3)
    {
        raw = /*":zorael!~NaN@ns3363704.ip-94-23-253.eu */"PRIVMSG kameloso^ :test test content";
        string slice = raw;
        e3.parseTypestring(slice);
        assert((type == IRCEvent.Type.PRIVMSG), type.to!string);
    }

    IRCEvent e4;
    with (e4)
    {
        raw = /*`:zorael!~NaN@ns3363704.ip-94-23-253.eu */`PART #flerrp :"WeeChat 1.6"`;
        string slice = raw;
        e4.parseTypestring(slice);
        assert((type == IRCEvent.Type.PART), type.to!string);
    }
}


// parseSpecialcases
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an IRCEvent struct.
 +
 +  This function only focuses on specialcasing the remaining line, dividing it
 +  into fields like target, channel, content, etc.
 +
 +  The IRCEvent is finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent to finish working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseSpecialcases(ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils;

    scope(failure)
    {
        writeln(Foreground.lightred, "--------- PARSE SPECIALCASES FAILURE");
        printObjects(event);
        writeln(Foreground.lightred, "------------------------------------");
    }

    with (IRCEvent.Type)
    switch (event.type)
    {
    case NOTICE:
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflow] Make sure your nick is registered, then please try again to join ##linux.
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.

        slice.formattedRead("%s :%s", &event.target, &event.content);

        // FIXME: This obviously doesn't scale either
        if (event.target == "*") event.special = true;
        else if ((event.ident == "service") && (event.address == "rizon.net"))
        {
            event.special = true;
        }

        event.target = string.init;

        if (!bot.server.resolvedAddress.length && event.content.beginsWith("***"))
        {
            bot.server.resolvedAddress = event.sender;
        }

        if (event.isFromAuthService)
        {
            event.special = true;  // by definition

            if ((event.content.indexOf("/msg NickServ IDENTIFY") != -1) ||
                (event.content.indexOf("/msg NickServ identify") != -1))
            {
                event.type = AUTHCHALLENGE;
            }
            else
            {
                // FIXME: This obviously doesn't scale either

                enum AuthServiceAcceptance
                {
                    freenode = "You are now identified for",
                    rizon = "Password accepted - you are now recognized.",
                    quakenet = "You are now logged in as",
                    gamesurge = "I recognize you.",
                }

                with (AuthServiceAcceptance)
                {
                    if ((event.content.beginsWith(freenode)) ||
                        (event.content.beginsWith(quakenet)) ||
                        (event.content == rizon) ||
                        (event.content == gamesurge))
                    {
                        event.type = AUTHACCEPTANCE;
                    }
                }
            }
        }
        break;

    case JOIN:
        import std.string : munch;

        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com JOIN #flerrp
        // :kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp
        event.type = (event.sender == bot.nickname) ? SELFJOIN : JOIN;
        event.channel = slice;
        event.channel.munch(":");
        break;

    case PART:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PART #flerrp :"WeeChat 1.6"
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com PART #flerrp
        event.type = (event.sender == bot.nickname) ? SELFPART : PART;

        if (slice.indexOf(' ') != -1)
        {
            slice.formattedRead("%s :%s", &event.channel, &event.content);
            event.content = event.content.unquoted;
        }
        else
        {
            event.channel = slice;
        }
        break;

    case NICK:
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_
        event.type = (event.sender == bot.nickname) ? SELFNICK : NICK;
        event.content = slice[1..$];

        if (event.type == SELFNICK)
        {
            bot.nickname = event.content;
            hooks.onNewBot(bot);  // Propagate the new bot
        }
        break;

    case QUIT:
        // :g7zon!~gertsson@178.174.245.107 QUIT :Client Quit
        event.type = (event.sender == bot.nickname) ? SELFQUIT : QUIT;
        event.content = slice[1..$].unquoted;

        if (event.content.beginsWith("Quit: "))
        {
            event.content.nom("Quit: ");
        }
        break;

    case PRIVMSG:
        immutable targetOrChannel = slice.nom(" :");
        event.content = slice;

        if (targetOrChannel.isValidChannel)
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content
            event.type = CHAN;
            event.channel = targetOrChannel;
            break;
        }
        else
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content
            event.type = QUERY;
            event.target = targetOrChannel;
        }

        if (slice.length < 3) break;

        if ((slice[0] == IRCControlCharacter.ctcp) &&
            (slice[$-1] == IRCControlCharacter.ctcp))
        {
            slice = slice[1..$-1];
            immutable ctcpEvent = (slice.indexOf(' ') != -1) ? slice.nom(' ') : slice;
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
             +  This iterates through all IRCEvent.Types that begin with
             +  "CTCP_" and generates switch cases for the string of each.
             +  Inside it will assign event.type to the corresponding
             +  IRCEvent.Type.
             +
             +  Like so, except automatically generated through compile-time
             +  introspection:
             +
             +      case "CTCP_PING":
             +          event.type = CTCP_PING;
             +          event.aux = "PING";
             +          break;
             +/

            top:
            switch (ctcpEvent)
            {
            case "ACTION":
                // ignore, handled elsewhere
                break;

            foreach (immutable type; EnumMembers!(IRCEvent.Type))
            {
                import std.conv : to;

                enum typestring = type.to!string;

                static if ((typestring.length > 5) && (typestring[0..5] == "CTCP_"))
                {
                    case typestring[5..$]:
                        mixin("event.type = " ~ typestring ~ ";");
                        event.aux = typestring[5..$];
                        break top;
                }
            }
            default:
                writeln(Foreground.red, "-------------------- UNKNOWN CTCP EVENT -----------");
                printObjects(event);
                break;
            }
        }
        break;

    case MODE:
        immutable targetOrChannel = slice.nom(' ');

        if (targetOrChannel.isValidChannel)
        {
            event.channel = targetOrChannel;

            if (slice.indexOf(' ') != -1)
            {
                // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
                // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i
                event.type = CHANMODE;
                slice.formattedRead("%s %s", &event.aux, &event.target);
            }
            else
            {
                event.type = USERMODE;
                event.aux = slice;
            }
        }
        else
        {
            // :kameloso^ MODE kameloso^ :+i
            event.type = SELFMODE;
            event.aux = slice[1..$];
        }
        break;

    case KICK:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu KICK #flerrp kameloso^ :this is a reason
        event.type = (event.target == bot.nickname) ? SELFKICK : KICK;
        slice.formattedRead("%s %s :%s", &event.channel, &event.target, &event.content);
        break;

    case INVITE:
        // (freenode) :zorael!~NaN@2001:41d0:2:80b4:: INVITE kameloso :#hirrsteff
        // (quakenet) :zorael!~zorael@ns3363704.ip-94-23-253.eu INVITE kameloso #hirrsteff
        slice.formattedRead("%s %s", &event.target, &event.channel);

        if (event.channel[0] == ':')
        {
            event.channel = event.channel[1..$];
        }
        break;

    case ERR_INVITEONLYCHAN: // 473
    case RPL_ENDOFNAMES: // 366
    case RPL_TOPIC: // 332
    case CHANNELURL: // 328
    case NEEDAUTHTOJOIN: // 477
        // :asimov.freenode.net 332 kameloso^ #garderoben :Are you employed, sir?
        // :asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.
        // :services. 328 kameloso^ #ubuntu :http://www.ubuntu.com
        // :cherryh.freenode.net 477 kameloso^ #archlinux :Cannot join channel (+r) - you need to be identified with services
        slice.formattedRead("%s %s :%s", &event.target, &event.channel, &event.content);
        break;

    case RPL_NAMREPLY: // 353
        import std.string : stripRight;

        // :asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt
        event.target  = slice.nom(' ');
        slice.nom(' ');
        slice.formattedRead("%s :%s", &event.channel, &event.content);
        event.content = event.content.stripRight();
        break;

    case RPL_MOTD: // 372
    case RPL_LUSERCLIENT: // 251
        // :asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor
        slice.formattedRead("%s :%s", &event.target, &event.content);
        break;

    case RPL_ISUPPORT: // 004-005
        import std.algorithm.iteration : splitter;
        import std.conv : to;
        import std.string : toLower;

        // :cherryh.freenode.net 005 CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server
        // :cherryh.freenode.net 005 CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST :are supported by this server
        // :asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI
        slice.formattedRead("%s %s", &event.target, &event.content);

        if (event.content.indexOf(" :") != -1)
        {
            event.aux = event.content.nom(" :");
        }

        foreach (value; event.aux.splitter(' '))
        {
            if (value.indexOf('=') == -1) continue;

            immutable key = value.nom('=');

            /// http://www.irc.org/tech_docs/005.html

            switch (key)
            {
            case "CHANTYPES":
                // TODO: Logic here to register channel prefix signs
                break;

            case "NETWORK":
                writeln(Foreground.cyan, "NETWORK: ", value);

                try
                {
                    immutable thisNetwork = value.toLower.to!(IRCServer.Network);
                    writeln(Foreground.lightgreen, thisNetwork);

                    if (thisNetwork != bot.server.network)
                    {
                        bot.server.network = thisNetwork;
                        hooks.onNewBot(bot);
                    }
                }
                catch (Exception e)
                {
                    writeln(Foreground.lightred, e.msg);
                }
                break;

            case "NICKLEN":
                try maxNickLength = value.to!uint;
                catch (Exception e)
                {
                    writeln(Foreground.lightred, e.msg);
                }
                break;

            case "CHANNELLEN":
                try maxChannelLength = value.to!uint;
                catch (Exception e)
                {
                    writeln(Foreground.lightred, e.msg);
                }
                break;

            default:
                break;
            }
        }

        break;

    case TOPICSETTIME: // 333
        // :asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377
        slice.formattedRead("%s %s %s %s", &event.target, &event.channel,
                            &event.content, &event.aux);
        break;

    case CONNECTINGFROM: // 378
        //:wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62
        slice.nom(' ');

        try
        {
            slice.formattedRead("%s :is connecting from *@%s %s",
                                &event.target, &event.content, &event.aux);
        }
        catch (Exception e)
        {
            writeln(Foreground.lightred, e.msg);
        }
        break;

    case ERR_UNKNOWNCOMMAND: // 421
        if (slice.indexOf(':') == -1)
        {
            // :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux,#hirrsteff,#xorg,#steamlug,#d3d9,##networking,#manjaro,#antergos,#freenode,#chakra,#lubuntu,#xubuntu,#gnome,#fluxbuntu,#flerrp,#ubuntu,##linux,#systemd,#kde,#kubuntu,#archlinux,#hirrsteff,#xorg,#steamlug,#d3d9,##networking,#manjaro,#antergos,#freenode,#chakra,#lubuntu,#xubuntu,#gnome,#fluxbuntu,#flerrp,#ubuntu,##linux,#systemd,#kde,#kubuntu,#archlinux,#hirrsteff,#xorg,#steamlug,#d3d9,##networking,#manjaro,#antergos,#freenode,#chakra
            event.target = slice.nom(' ');
            event.aux = slice;
        }
        else
        {
            // :asimov.freenode.net 421 kameloso^ sudo :Unknown command
            slice.formattedRead("%s %s :%s", &event.target, &event.aux, &event.content);
        }
        break;

    case RPL_LUSEROP: // 252
    case RPL_LUSERUNKNOWN: // 253
    case RPL_LUSERCHANNELS: // 254
    case RPL_WHOISIDLE: //  317
    case ERR_ERRONEOUSNICKNAME: // 432
    case ERR_NEEDMOREPARAMS: // 461
    case USERCOUNTLOCAL: // 265
    case USERCOUNTGLOBAL: // 266
        // :asimov.freenode.net 252 kameloso^ 31 :IRC Operators online
        // :asimov.freenode.net 253 kameloso^ 13 :unknown connection(s)
        // :asimov.freenode.net 254 kameloso^ 54541 :channels formed
        // :asimov.freenode.net 432 kameloso^ @nickname :Erroneous Nickname
        // :asimov.freenode.net 461 kameloso^ JOIN :Not enough parameters
        // :asimov.freenode.net 265 kameloso^ 6500 11061 :Current local users 6500, max 11061
        // :asimov.freenode.net 266 kameloso^ 85267 92341 :Current global users 85267, max 92341
        slice.formattedRead("%s %s :%s", &event.target, &event.aux, &event.content);
        break;

    case RPL_WHOISUSER: // 311
        // :orwell.freenode.net 311 kameloso^ kameloso ~NaN ns3363704.ip-94-23-253.eu * : kameloso
        // Hard to use formattedRead here
        import std.string : stripLeft;

        slice.nom(' ');
        event.target  = slice.nom(' ');
        event.content = slice.nom(" *");
        slice.nom(" :");
        event.aux = slice.stripLeft();
        break;

    case RPL_WHOISCHANNELS: // 319
        // :leguin.freenode.net 319 kameloso^ zorael :#flerrp
        import std.string : stripRight;

        slice = slice.stripRight();
        goto case RPL_ENDOFWHOIS;

    case WHOISSECURECONN: // 671
    case RPL_ENDOFWHOIS: // 318
    case ERR_NICKNAMEINUSE: // 433
    case ERR_NOSUCHNICK: // 401
        // :asimov.freenode.net 671 kameloso^ zorael :is using a secure connection
        // :asimov.freenode.net 318 kameloso^ zorael :End of /WHOIS list.
        // :asimov.freenode.net 433 kameloso^ kameloso :Nickname is already in use.
        // :cherryh.freenode.net 401 kameloso^ cherryh.freenode.net :No such nick/channel
        slice.nom(' ');
        slice.formattedRead("%s :%s", &event.target, &event.content);
        break;

    case RPL_WHOISSERVER: // 312
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE
        slice.nom(' ');
        slice.formattedRead("%s %s :%s", &event.target, &event.content, &event.aux);
        break;

    case WHOISLOGIN: // 330
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        slice.nom(' ');
        slice.formattedRead("%s %s :%s", &event.target, &event.aux, &event.content);
        break;

    case HASTHISNICK: // 307
        // :irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick
        // :irc.x2x.cc 307 kameloso^^ wob^2 :has identified for this nick
        slice.nom(' '); // bot nick
        event.target = slice.nom(" :");
        event.aux = event.target;
        event.content = slice;

        break;

    case PONG:
        event.content = string.init;
        break;

    case ERR_NOTREGISTERED: // 451
        if (slice[0] == '*')
        {
            // :niven.freenode.net 451 * :You have not registered
            slice.formattedRead("* :%s", &event.content);
        }
        else
        {
            // :irc.harblwefwoi.org 451 WHOIS :You have not registered
            slice.formattedRead("%s :%s", &event.aux, &event.content);
        }
        break;

    case WELCOME: // 001
        // :adams.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
        slice.formattedRead("%s :%s", &event.target, &event.content);
        bot.nickname = event.target;
        break;

    case TOCONNECTTYPE: // 513
        // :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
        if (slice.indexOf(" :To connect type ") == -1)
        {
            writeln(Foreground.lightred, "Unknown variant of TOCONNECTTYPE");
            printObjects(event);
            break;
        }

        slice.formattedRead("%s :To connect type %s", &event.target, &event.aux);
        event.aux.nom("/QUOTE ");
        event.content = event.aux.nom(" ");
        break;

    case HELP_TOPICS: // 704
    case HELP_ENTRIES: // 705
    case HELP_END: // 706
        // :leguin.freenode.net 704 kameloso^ index :Help topics available to users:
        // :leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        // :leguin.freenode.net 706 kameloso^ index :End of /HELP.
        slice.formattedRead("%s :%s", &event.aux, &event.content);
        break;

    case CANTCHANGENICK: // 435
        // :cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel
        slice.formattedRead("%s %s %s :%s", &event.target, &event.aux,
                            &event.channel, &event.content);
        break;

    case CAP:
        if (slice.indexOf('*') != -1)
        {
            // :tmi.twitch.tv CAP * LS :twitch.tv/tags twitch.tv/commands twitch.tv/membership
            slice.formattedRead("* %s :%s", &event.aux, &event.content);
        }
        else
        {
            // :genesis.ks.us.irchighway.net CAP 867AAF66L LS :away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names
            string id;  // what do we do with you
            slice.formattedRead("%s %s :%s", id, event.aux, event.content);
        }
        break;

    default:
        if ((event.type == NUMERIC) || (event.type == UNSET))
        {
            writeln();
            writeln(Foreground.lightred, "--------- UNCAUGHT NUMERIC OR UNSET");
            printObjects(event);
            writeln(Foreground.lightred, "-----------------------------------");
            writeln();
        }

        if (slice.indexOf(" :") != -1)
        {
            slice.formattedRead("%s :%s", &event.target, &event.content);
        }
        else
        {
            // :port80b.se.quakenet.org 221 kameloso +i
            slice.formattedRead("%s %s", &event.target, &event.aux);
        }

        import std.algorithm.searching : endsWith;

        if (event.content.endsWith(" "))
        {
            import std.string : stripRight;

            event.content = event.content.stripRight(); // wise?
        }

        break;
    }

    if ((event.type != IRCEvent.Type.CHANMODE) &&
        ((event.target.indexOf(' ') != -1) ||
        (event.channel.indexOf(' ') != -1)))
    {
        writeln();
        writeln(Foreground.lightred, "--------------- SPACES, NEEDS REVISION");
        printObjects(event);
        writeln(Foreground.lightred, "--------------------------------------");
        writeln();
    }

    if ((event.type != IRCEvent.Type.TOPIC) &&
        ((event.target.indexOf(' ') != -1) ||
        (event.channel.indexOf(' ') != -1)))
    {
        writeln();
        writeln(Foreground.lightred, "--------------- CHANNEL/TARGET REVISION");
        printObjects(event);
        writeln(Foreground.lightred, "---------------------------------------");
        writeln();
    }

    if ((event.target == bot.nickname) &&
        (event.type != IRCEvent.Type.MODE) &&
        (event.type != IRCEvent.Type.CHANMODE) &&
        (event.type != IRCEvent.Type.WELCOME))
    {
        event.target = string.init;
    }
}


// networkOf
/++
 +  Tries to guess the network of an IRC server based on its address.
 +
 +  This is done early on before connecting. After registering, we can (usually)
 +  get the correct answer from the CAP LS event.
 +
 +  Params:
 +      address = the IRC server address to evaluate.
 +
 +  Returns:
 +      a member of the IRCServer.Network enum type signifying which network
 +      the server was guessed to be part of.
 +/
IRCServer.Network networkOf(const string address)
{
    with (IRCServer.Network)
    {
        import std.algorithm.searching : endsWith;

        immutable IRCServer.Network[string] networkMap =
        [
            ".freenode.net"   : freenode,
            ".rizon.net"      : rizon,
            ".quakenet.org"   : quakenet,
            ".undernet.org"   : undernet,
            ".gamesurge.net"  : gamesurge,
            ".twitch.tv"      : twitch,
            ".unrealircd.org" : unreal,
        ];

        foreach (addressTail, net; networkMap)
        {
            if (address.endsWith(addressTail))
            {
                return networkMap[addressTail];
            }
        }

        return unknown;
    }
}

unittest
{
    import std.conv : to;

    with (IRCServer.Network)
    {
        immutable n1 = networkOf("irc.freenode.net");
        assert(n1 == freenode, n1.to!string);

        immutable n2 = networkOf("harbl.hhorlb.rizon.net");
        assert(n2 == rizon, n2.to!string);

        immutable n3 = networkOf("under.net.undernet.org");
        assert(n3 == undernet, n3.to!string);

        immutable n4 = networkOf("irc.irc.irc.gamesurge.net");
        assert(n4 == gamesurge, n4.to!string);

        immutable n5 = networkOf("irc.chat.twitch.tv");
        assert(n5 == twitch, n5.to!string);

        immutable n6 = networkOf("irc.unrealircd.org");
        assert(n6 == unreal, n6.to!string);
    }
}


public:

/// Takes an IRCBot and stores it, so that certain operations in the parsing
/// has the context it needs.
void loadBot(IRCBot bot)
{
    .bot = bot;
}


// registerParserHooks
/++
 +  Takes an IRCParserHooks and stores it.
 +
 +  These contain function pointers which will be clled upon certain events,
 +  currently only when the local IRCBot has been updated, and the change should
 +  propagate down the stack.
 +
 +  Params:
 +      hooks = a struct instance with function pointers.
 +/
void registerParserHooks(const IRCParserHooks hooks)
{
    .hooks = hooks;
}


// IRCParserHooks
/++
 +  Aggregate struct conaining function pointers to be called when certain
 +  events occur, currently only when the local IRCBot has been updated.
 +/
struct IRCParserHooks
{
    /// Function to call when bot has changed and the change needs to propagate.
    static void function(const IRCBot) @trusted onNewBot;

    //static void function(const IRCServer) onNewServer;

    //static void function(const IRCServer) onNewNetwork;
}

/// Aggregate collecting all the relevant settings, options and state needed
struct IRCBot
{
    string nickname   = "kameloso";
    string user       = "kameloso!";
    string ident      = "NaN";
    string quitReason = "beep boop I am a bot";
    string master;
    string authLogin;

    @Hidden
    {
        string authPassword;
        string pass;
    }

    @Separator(",")
    {
        string[] homes;
        string[] friends;
        string[] channels;
    }

    @Unconfigurable
    {
        IRCServer server;
        string origNickname;
        bool startedRegistering;
        bool finishedRegistering;
        bool startedAuth;
        bool finishedAuth;
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        sink("%s:%s!~%s | homes:%s | chans:%s | friends:%s | server:%s"
             .format(nickname, authLogin, ident, homes, channels, friends, server));
    }
}


/// Aggregate of all information and state pertaining to the connected IRC server.
struct IRCServer
{
    /// A list of known networks as reported in the CAP LS message.
    enum Network
    {
        unknown,
        freenode,
        rizon,
        quakenet,
        undernet,
        gamesurge,
        twitch,
        unreal,
        efnet,
        ircnet,
        swiftirc,
        irchighway,
    }

    Network network;
    string address = "irc.freenode.net";
    ushort port = 6667;

    @Unconfigurable
    {
        string resolvedAddress;
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        sink("[Network.%s] %s:%d (%s)".format(network, address, port, resolvedAddress));
    }

    void resolveNetwork()
    {
        network = networkOf(address);
    }
}


/// An aggregate of string fields that represents a single user.
struct IRCUser
{
    string nickname, ident, address, login;
    bool special;

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : formattedWrite;

        sink.formattedWrite("%s:%s!~%s@%s%s",
            nickname, login, ident, address, special ? " (*)" : string.init);
    }
}


// IRCEvent
/++
 +  A single IRC event, parsed from server input.
 +
 +  The IRCEvent struct is aconstruct with fields extracted from raw server strings.
 +  Since structs are not polymorphic the Type enum dictates what kind of event it is.
 +/
struct IRCEvent
{
    /// Taken from https://tools.ietf.org/html/rfc1459 with many additions
    enum Type
    {
        UNSET, ANY, ERROR, NUMERIC,
        PRIVMSG, CHAN, QUERY, EMOTE, // ACTION
        JOIN, PART, QUIT, KICK, INVITE,
        NOTICE,
        PING, PONG,
        NICK,
        MODE, CHANMODE, USERMODE,
        SELFQUIT, SELFJOIN, SELFPART,
        SELFMODE, SELFNICK, SELFKICK,
        TOPIC, CAP,
        CTCP_VERSION, CTCP_TIME, CTCP_PING,
        CTCP_CLIENTINFO, CTCP_DCC, CTCP_SOURCE,
        CTCP_USERINFO, CTCP_FINGER,
        AUTHCHALLENGE,
        AUTHACCEPTANCE, // = 900        // <nickname>!<ident>@<address> <nickname> :You are now logged in as <nickname>
        USERSTATS_1, // = 250           // "Highest connection count: <n> (<n> clients) (<m> connections received)"
        USERSTATS_2, // = 265           // "Current local users <n>, max <m>"
        USERSTATS_3, // = 266           // "Current global users <n>, max <m>"
        WELCOME, // = 001,              // ":Welcome to <server name> <user>"
        SERVERINFO, // = 002-003        // (server information)
        RPL_ISUPPORT, // = 004-005      // (server information, different syntax)
        TOPICSETTIME, // = 333          // "#channel user!~ident@address 1476294377"
        USERCOUNTLOCAL, // = 265        // "Current local users n, max m"
        USERCOUNTGLOBAL, // = 266       // "Current global users n, max m"
        CONNECTIONRECORD, // = 250      // "Highest connection count: n (m clients) (v connections received)"
        CHANNELURL, // = 328            // "http://linux.chat"
        WHOISSECURECONN, // = 671       // "<nickname> :is using a secure connection"
        WHOISLOGIN, // = 330            // "<nickname> <login> :is logged in as"
        CHANNELFORWARD, // = 470        // <#original> <#new> :Forwarding to another channel
        CONNECTINGFROM, // = 378        // <nickname> :is connecting from *@<address> <ip>
        TOCONNECTTYPE, // = 513,        // <nickname> :To connect type /QUOTE PONG <number>
        HASTHISNICK, // = 307           // <nickname> :has identified for this nick
        INVALIDCHARACTERS, // = 455     // <nickname> :Your username <nickname> contained the invalid character(s) <characters> and has been changed to mrkaufma. Please use only the characters 0-9 a-z A-Z _ - or . in your username. Your username is the part before the @ in your email address.
        HELP_TOPICS, // = 704           // <nickname> index :Help topics available to users:
        HELP_ENTRIES, // = 705          // <nickname> index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        HELP_END, // = 706              // <nickname> index :End of /HELP.
        NEEDAUTHTOJOIN, // = 477        // <nickname> <channel> :Cannot join channel (+r) - you need to be identified with services
        CANTCHANGENICK, // = 435        // <nickname> <target nickname> <channel> :Cannot change nickname while banned on channel
        YOURHIDDENHOST, // = 396 ,      // <nickname> <host> :is now your hidden host
        MESSAGENEEDSADDRESS, // = 487   // <nickname> :Error! "/msg NickServ" is no longer supported. Use "/msg NickServ@services.dal.net" or "/NickServ" instead.
        NICKCHANUNAVAILABLE, // = 437   // <nickname> <channel> :Nick/channel is temporarily unavailable
        YOURUNIQUEID, // = 042,         // <nickname> <id> :your unique ID
        ERR_NOSUCHNICK, // = 401,       // "<nickname> :No such nick/channel"
        ERR_NOSUCHSERVER, // = 402,     // "<server name> :No such server"
        ERR_NOSUCHCHANNEL, // = 403,    // "<channel name> :No such channel"
        ERR_CANNOTSENDTOCHAN, // = 404, // "<channel name> :Cannot send to channel"
        ERR_TOOMANYCHANNELS, // = 405,  // "<channel name> :You have joined too many channels"
        ERR_WASNOSUCHNICK, // = 406,    // "<nickname> :There was no such nickname"
        ERR_TOOMANYTARGETS, // = 407,   // "<target> :Duplicate recipients. No message delivered""
        ERR_NOORIGIN, // = 409,         // ":No origin specified"
        ERR_NORECIPIENT, // = 411,      // ":No recipient given (<command>)"
        ERR_NOTEXTTOSEND, // = 412,     // ":No text to send"
        ERR_NOTOPLEVEL, // = 413,       // "<mask> :No toplevel domain specified"
        ERR_WILDTOPLEVEL, // = 414,     // "<mask> :Wildcard in toplevel domain"
        ERR_UNKNOWNCOMMAND, // = 421,   // "<command> :Unknown command"
        ERR_NOMOTD, // = 422,           // ":MOTD File is missing"
        ERR_NOADMININFO, // = 423,      // "<server> :No administrative info available"
        ERR_FILEERROR, // = 424,        // ":File error doing <file op> on <file>"
        ERR_NONICKNAMEGIVEN, // = 431,  // ":No nickname given"
        ERR_ERRONEOUSNICKNAME, // = 432,// "<nick> :Erroneus nickname"
        ERR_NICKNAMEINUSE, // = 433,    // "<nick> :Nickname is already in use"
        ERR_NICKCOLLISION, // = 436,    // "<nick> :Nickname collision KILL"
        ERR_USERNOTINCHANNEL, // = 441, // "<nick> <channel> :They aren't on that channel"
        ERR_NOTONCHANNEL, // = 442,     // "<channel> :You're not on that channel"
        ERR_USERONCHANNEL, // = 443,    // "<user> <channel> :is already on channel"
        ERR_NOLOGIN, // = 444,          // "<user> :User not logged in"
        ERR_SUMMONDISABLED, // = 445,   // ":SUMMON has been disabled"
        ERR_USERSDISABLED, // = 446,    // ":USERS has been disabled"
        ERR_NOTREGISTERED, // = 451,    // ":You have not registered"
        ERR_NEEDMOREPARAMS, // = 461,   // "<command> :Not enough parameters"
        ERR_ALREADYREGISTERED, // = 462,// ":You may not reregister"
        ERR_NOPERMFORHOST, // = 463,    // ":Your host isn't among the privileged"
        ERR_PASSWDMISMATCH, // = 464,   // ":Password incorrect"
        ERR_YOUREBANNEDCREEP, // = 465, // ":You are banned from this server"
        ERR_KEYSET, // = 467,           // "<channel> :Channel key already set"
        ERR_CHANNELISFULL, // = 471,    // "<channel> :Cannot join channel (+l)"
        ERR_UNKNOWNMODE, // = 472,      // "<char> :is unknown mode char to me"
        ERR_INVITEONLYCHAN, // = 473,   // "<channel> :Cannot join channel (+i)"
        ERR_BANNEDFROMCHAN, // = 474,   // "<channel> :Cannot join channel (+b)"
        ERR_BADCHANNELKEY, // = 475,    // "<channel> :Cannot join channel (+k)"
        ERR_NOPRIVILEGES, // = 481,     // ":Permission Denied- You're not an IRC operator"
        ERR_CHANOPRIVSNEEDED, // = 482, // [sic] "<channel> :You're not channel operator"
        ERR_CANTKILLSERVER, // = 483,   // ":You cant kill a server!"
        ERR_NOOPERHOST, // = 491,       // ":No O-lines for your host"
        ERR_UNKNOWNMODEFLAG, // = 501,  // ":Unknown MODE flag"
        ERR_USERSDONTMATCH, // = 502,   // ":Cant change mode for other users"
        RPL_NONE, // = 300,             // Dummy reply number. Not used.
        RPL_AWAY, // = 301              // "<nick> :<away message>"
        RPL_USERHOST, // = 302          // ":[<reply>{<space><reply>}]"
        RPL_ISON, // = 303,             // ":[<nick> {<space><nick>}]"
        RPL_UNAWAY, // = 305,           // ":You are no longer marked as being away"
        RPL_NOWAWAY, // = 306,          // ":You have been marked as being away"
        RPL_WHOISUSER, // = 311,        // "<nick> <user> <host> * :<real name>"
        RPL_WHOISSERVER, // = 312,      // "<nick> <server> :<server info>"
        RPL_WHOISOPERATOR, // = 313,    // "<nick> :is an IRC operator"
        RPL_WHOWASUSER, // = 314,       // "<nick> <user> <host> * :<real name>"
        RPL_ENDOFWHO, // = 315,         // "<name> :End of /WHO list"
        RPL_WHOISIDLE, // = 317,        // "<nick> <integer> :seconds idle"
        RPL_ENDOFWHOIS, // = 318,       // "<nick> :End of /WHOIS list"
        RPL_WHOISCHANNELS, // = 319,    // "<nick> :{[@|+]<channel><space>}"
        RPL_LISTSTART, // = 321,        // "Channel :Users  Name"
        RPL_LIST, // = 322,             // "<channel> <# visible> :<topic>"
        RPL_LISTEND, // = 323,          // ":End of /LIST"
        RPL_CHANNELMODEIS, // = 324,    // "<channel> <mode> <mode params>"
        RPL_NOTOPIC, // = 331,          // "<channel> :No topic is set"
        RPL_TOPIC, // = 332,            // "<channel> :<topic>"
        RPL_INVITING, // = 341,         // "<channel> <nick>"
        RPL_SUMMONING, // = 342,        // "<user> :Summoning user to IRC"
        RPL_VERSION, // = 351,          // "<version>.<debuglevel> <server> :<comments>"
        RPL_WHOREPLY, // = 352,         // "<channel> <user> <host> <server> <nick> | <H|G>[*][@|+] :<hopcount> <real name>"
        RPL_NAMREPLY, // = 353,         // "<channel> :[[@|+]<nick> [[@|+]<nick> [...]]]"
        RPL_LINKS, // = 364,            // "<mask> <server> :<hopcount> <server info>"
        RPL_ENDOFLINKS, // = 365,       // "<mask> :End of /LINKS list"
        RPL_ENDOFNAMES, // = 366,       // "<channel> :End of /NAMES list"
        RPL_BANLIST, // = 367,          // "<channel> <banid>"
        RPL_ENDOFBANLIST, // = 368,     // "<channel> :End of channel ban list"
        RPL_ENDOFWHOWAS, // = 369,      // "<nick> :End of WHOWAS"
        RPL_INFO, // = 371,             // ":<string>"
        RPL_MOTD, // = 372,             // ":- <text>"
        RPL_ENDOFINFO, // = 374,        //  ":End of /INFO list"
        RPL_MOTDSTART, // = 375,        // ":- <server> Message of the day - "
        RPL_ENDOFMOTD, // = 376,        // ":End of /MOTD command"
        RPL_YOUREOPER, // = 381,        // ":You are now an IRC operator"
        RPL_REHASHING, // = 382,        // "<config file> :Rehashing"
        RPL_TIME, // = 391,             // "<server> :<string showing server's local time>"
        RPL_USERSTART, // = 392,        // ":UserID   Terminal  Host"
        RPL_USERS, // = 393,            // ":%-8s %-9s %-8s"
        RPL_ENDOFUSERS, // = 394,       // ":End of users"
        RPL_NOUSERS, // = 395,          // ":Nobody logged in"
        RPL_TRACELINK, // = 200,        // "Link <version & debug level> <destination> <next server>"
        RPL_TRACECONNECTING, // = 201,  // "Try. <class> <server>"
        RPL_TRACEHANDSHAKE, // = 202,   // "H.S. <class> <server>"
        RPL_TRACEUNKNOWN, // = 203,     // "???? <class> [<client IP address in dot form>]"
        RPL_TRACEOPERATOR, // = 204,    // "Oper <class> <nick>"
        RPL_TRACEUSER, // = 205,        // "User <class> <nick>"
        RPL_TRACESERVER, // = 206,      // "Serv <class> <int>S <int>C <server> <nick!user|*!*>@<host|server>"
        RPL_TRACENEWTYPE, // = 208,     // "<newtype> 0 <client name>"
        RPL_STATSLINKINFO, // = 211,    // "<linkname> <sendq> <sent messages> <sent bytes> <received messages> <received bytes> <time open>"
        RPL_STATSCOMMAND, // = 212,     // "<command> <count>"
        RPL_STATSCLINE, // = 213,       // "C <host> * <name> <port> <class>"
        RPL_STATSNLINE, // = 214,       // "N <host> * <name> <port> <class>"
        RPL_STATSILINE, // = 215,       // "I <host> * <host> <port> <class>"
        RPL_STATSKLINE, // = 216,       // "K <host> * <username> <port> <class>"
        RPL_STATSYLINE, // = 218        // "Y <class> <ping frequency> <connect frequency> <max sendq>"
        RPL_ENDOFSTATS, // = 219,       // "<stats letter> :End of /STATS report"
        RPL_UMODEIS, // = 221,          // "<user mode string>"
        RPL_STATSLLINE, // = 241,       // "L <hostmask> * <servername> <maxdepth>"
        RPL_STATSUPTIME, // = 242,      // ":Server Up %d days %d:%02d:%02d"
        RPL_STATSOLINE, // = 243,       // "O <hostmask> * <name>"
        RPL_STATSHLINE, // = 244,       // "H <hostmask> * <servername>"
        RPL_LUSERCLIENT, // = 251,      // ":There are <integer> users and <integer> invisible on <integer> servers"
        RPL_LUSEROP, // = 252,          // "<integer> :operator(s) online"
        RPL_LUSERUNKNOWN, // = 253,     // "<integer> :unknown connection(s)"
        RPL_LUSERCHANNELS, // = 254,    // "<integer> :channels formed"
        RPL_LUSERME, // = 255,          // ":I have <integer> clients and <integer> servers"
        RPL_ADMINME, // = 256,          // "<server> :Administrative info"
        RPL_ADMINLOC1, // = 257,        // ":<admin info>"
        RPL_ADMINLOC2, // = 258,        // ":<admin info>"
        RPL_ADMINEMAIL, // = 259,       // ":<admin info>"
        RPL_TRACELOG, // = 261,         // "File <logfile> <debug level>"

        RPL_TRACECLASS, // = 209,       // (reserved numeric)
        RPL_STATSQLINE, // = 217,       // (reserved numeric)
        RPL_SERVICEINFO, // = 231,      // (reserved numeric)
        RPL_ENDOFSERVICES, // = 232,    // (reserved numeric)
        RPL_SERVICE, // = 233,          // (reserved numeric)
        RPL_SERVLIST, // = 234,         // (reserved numeric)
        RPL_SERVLISTEND, // = 235,      // (reserved numeric)
        RPL_WHOISCHANOP, // = 316,      // (reserved numeric)
        RPL_KILLDONE, // = 361,         // (reserved numeric)
        RPL_CLOSING, // = 362,          // (reserved numeric)
        RPL_CLOSEEND, // = 363,         // (reserved numeric)
        RPL_INFOSTART, // = 373,        // (reserved numeric)
        RPL_MYPORTIS, // = 384,         // (reserved numeric)
        ERR_YOUWILLBEBANNED, // = 466   // (reserved numeric)
        ERR_BADCHANMASK, // = 476,      // (reserved numeric)
        ERR_NOSERVICEHOST, // = 492,    // (reserved numeric)
    }

    /*
        /// Run this to generate the Type[n] map.
        void generateTypenums()
        {
            import std.regex;
            import std.algorithm;
            import std.stdio;

            static pattern = ctRegex!` *([A-Z0-9_]+), // = ([0-9]+).*`;
            string[768] arr;

            writeln("static immutable Type[768] typenums =\n[");

            foreach (line; s.splitter("\n"))
            {
                auto hits = line.matchFirst(pattern);
                if (hits.length < 2) continue;
                arr[hits[2].to!size_t] = hits[1];
            }

            foreach (i, val; arr)
            {
                if (!val.length) continue;

                writefln("    %03d : Type.%s,", i, val);
            }

            writeln("];");
        }
    */

    /// Reverse mapping of Types to their numeric form, to speed up conversion
    static immutable Type[1024] typenums =
    [
        001 : Type.WELCOME,
        002 : Type.SERVERINFO,
        003 : Type.SERVERINFO,
        004 : Type.RPL_ISUPPORT,
        005 : Type.RPL_ISUPPORT,
         42 : Type.YOURUNIQUEID,
        200 : Type.RPL_TRACELINK,
        201 : Type.RPL_TRACECONNECTING,
        202 : Type.RPL_TRACEHANDSHAKE,
        203 : Type.RPL_TRACEUNKNOWN,
        204 : Type.RPL_TRACEOPERATOR,
        205 : Type.RPL_TRACEUSER,
        206 : Type.RPL_TRACESERVER,
        208 : Type.RPL_TRACENEWTYPE,
        209 : Type.RPL_TRACECLASS,
        211 : Type.RPL_STATSLINKINFO,
        212 : Type.RPL_STATSCOMMAND,
        213 : Type.RPL_STATSCLINE,
        214 : Type.RPL_STATSNLINE,
        215 : Type.RPL_STATSILINE,
        216 : Type.RPL_STATSKLINE,
        217 : Type.RPL_STATSQLINE,
        218 : Type.RPL_STATSYLINE,
        219 : Type.RPL_ENDOFSTATS,
        221 : Type.RPL_UMODEIS,
        231 : Type.RPL_SERVICEINFO,
        232 : Type.RPL_ENDOFSERVICES,
        233 : Type.RPL_SERVICE,
        234 : Type.RPL_SERVLIST,
        235 : Type.RPL_SERVLISTEND,
        241 : Type.RPL_STATSLLINE,
        242 : Type.RPL_STATSUPTIME,
        243 : Type.RPL_STATSOLINE,
        244 : Type.RPL_STATSHLINE,
        250 : Type.CONNECTIONRECORD,
        251 : Type.RPL_LUSERCLIENT,
        252 : Type.RPL_LUSEROP,
        253 : Type.RPL_LUSERUNKNOWN,
        254 : Type.RPL_LUSERCHANNELS,
        255 : Type.RPL_LUSERME,
        256 : Type.RPL_ADMINME,
        257 : Type.RPL_ADMINLOC1,
        258 : Type.RPL_ADMINLOC2,
        259 : Type.RPL_ADMINEMAIL,
        261 : Type.RPL_TRACELOG,
        265 : Type.USERCOUNTLOCAL,
        266 : Type.USERCOUNTGLOBAL,
        300 : Type.RPL_NONE,
        301 : Type.RPL_AWAY,
        302 : Type.RPL_USERHOST,
        303 : Type.RPL_ISON,
        305 : Type.RPL_UNAWAY,
        306 : Type.RPL_NOWAWAY,
        307 : Type.HASTHISNICK,
        311 : Type.RPL_WHOISUSER,
        312 : Type.RPL_WHOISSERVER,
        313 : Type.RPL_WHOISOPERATOR,
        314 : Type.RPL_WHOWASUSER,
        315 : Type.RPL_ENDOFWHO,
        316 : Type.RPL_WHOISCHANOP,
        317 : Type.RPL_WHOISIDLE,
        318 : Type.RPL_ENDOFWHOIS,
        319 : Type.RPL_WHOISCHANNELS,
        321 : Type.RPL_LISTSTART,
        322 : Type.RPL_LIST,
        323 : Type.RPL_LISTEND,
        324 : Type.RPL_CHANNELMODEIS,
        328 : Type.CHANNELURL,
        330 : Type.WHOISLOGIN,
        331 : Type.RPL_NOTOPIC,
        332 : Type.RPL_TOPIC,
        333 : Type.TOPICSETTIME,
        341 : Type.RPL_INVITING,
        342 : Type.RPL_SUMMONING,
        351 : Type.RPL_VERSION,
        352 : Type.RPL_WHOREPLY,
        353 : Type.RPL_NAMREPLY,
        361 : Type.RPL_KILLDONE,
        362 : Type.RPL_CLOSING,
        363 : Type.RPL_CLOSEEND,
        364 : Type.RPL_LINKS,
        365 : Type.RPL_ENDOFLINKS,
        366 : Type.RPL_ENDOFNAMES,
        367 : Type.RPL_BANLIST,
        368 : Type.RPL_ENDOFBANLIST,
        369 : Type.RPL_ENDOFWHOWAS,
        371 : Type.RPL_INFO,
        372 : Type.RPL_MOTD,
        373 : Type.RPL_INFOSTART,
        374 : Type.RPL_ENDOFINFO,
        375 : Type.RPL_MOTDSTART,
        376 : Type.RPL_ENDOFMOTD,
        378 : Type.CONNECTINGFROM,
        381 : Type.RPL_YOUREOPER,
        382 : Type.RPL_REHASHING,
        384 : Type.RPL_MYPORTIS,
        391 : Type.RPL_TIME,
        392 : Type.RPL_USERSTART,
        393 : Type.RPL_USERS,
        394 : Type.RPL_ENDOFUSERS,
        395 : Type.RPL_NOUSERS,
        396 : Type.YOURHIDDENHOST,
        401 : Type.ERR_NOSUCHNICK,
        402 : Type.ERR_NOSUCHSERVER,
        403 : Type.ERR_NOSUCHCHANNEL,
        404 : Type.ERR_CANNOTSENDTOCHAN,
        405 : Type.ERR_TOOMANYCHANNELS,
        406 : Type.ERR_WASNOSUCHNICK,
        407 : Type.ERR_TOOMANYTARGETS,
        409 : Type.ERR_NOORIGIN,
        411 : Type.ERR_NORECIPIENT,
        412 : Type.ERR_NOTEXTTOSEND,
        413 : Type.ERR_NOTOPLEVEL,
        414 : Type.ERR_WILDTOPLEVEL,
        421 : Type.ERR_UNKNOWNCOMMAND,
        422 : Type.ERR_NOMOTD,
        423 : Type.ERR_NOADMININFO,
        424 : Type.ERR_FILEERROR,
        431 : Type.ERR_NONICKNAMEGIVEN,
        432 : Type.ERR_ERRONEOUSNICKNAME,
        433 : Type.ERR_NICKNAMEINUSE,
        435 : Type.CANTCHANGENICK,
        436 : Type.ERR_NICKCOLLISION,
        437 : Type.NICKCHANUNAVAILABLE,
        441 : Type.ERR_USERNOTINCHANNEL,
        442 : Type.ERR_NOTONCHANNEL,
        443 : Type.ERR_USERONCHANNEL,
        444 : Type.ERR_NOLOGIN,
        445 : Type.ERR_SUMMONDISABLED,
        446 : Type.ERR_USERSDISABLED,
        451 : Type.ERR_NOTREGISTERED,
        455 : Type.INVALIDCHARACTERS,
        461 : Type.ERR_NEEDMOREPARAMS,
        462 : Type.ERR_ALREADYREGISTERED,
        463 : Type.ERR_NOPERMFORHOST,
        464 : Type.ERR_PASSWDMISMATCH,
        465 : Type.ERR_YOUREBANNEDCREEP,
        466 : Type.ERR_YOUWILLBEBANNED,
        467 : Type.ERR_KEYSET,
        470 : Type.CHANNELFORWARD,
        471 : Type.ERR_CHANNELISFULL,
        472 : Type.ERR_UNKNOWNMODE,
        473 : Type.ERR_INVITEONLYCHAN,
        474 : Type.ERR_BANNEDFROMCHAN,
        475 : Type.ERR_BADCHANNELKEY,
        476 : Type.ERR_BADCHANMASK,
        477 : Type.NEEDAUTHTOJOIN,
        481 : Type.ERR_NOPRIVILEGES,
        482 : Type.ERR_CHANOPRIVSNEEDED,
        483 : Type.ERR_CANTKILLSERVER,
        487 : Type.MESSAGENEEDSADDRESS,
        491 : Type.ERR_NOOPERHOST,
        492 : Type.ERR_NOSERVICEHOST,
        501 : Type.ERR_UNKNOWNMODEFLAG,
        502 : Type.ERR_USERSDONTMATCH,
        513 : Type.TOCONNECTTYPE,
        671 : Type.WHOISSECURECONN,
        704 : Type.HELP_TOPICS,
        705 : Type.HELP_ENTRIES,
        706 : Type.HELP_END,
        900 : Type.AUTHACCEPTANCE,
    ];

    /// The event type, signifying what *kind* of event this is.
    Type type;

    /// The raw IRC string, untouched.
    string raw;

    /// The name of whoever (or whatever) sent this event.
    string sender;

    /// The IDENT identification of the sender.
    string ident;

    /// The address of the sender.
    string address;

    /// The type in string form; a by-product of parsing.
    string typestring;

    /// The channel the event transpired in, or is otherwise related to.
    string channel;

    /// The target of the event. May be a nickname or a channel.
    string target;

    /// The main body of the event.
    string content;

    /// The auxiliary storage, containing type-specific extra bits of information.
    string aux;

    /// With a numeric event, the number of the event type.
    uint num;

    /// A flag that we set when we're sure the event originated from the server or its services.
    bool special;

    /// A timestamp of when the event occured.
    long time;
}


// toIRCEvent
/++
 +  Parser an IRC string into an IRCEvent.
 +
 +  It passes it to the different parsing functions to get a finished IRCEvent.
 +  Parsing goes through several phases (prefix, typestring, specialcases) and
 +  this is the function that calls them.
 +
 +  Params:
 +      raw = The raw IRC string to parse.
 +
 +  Returns:
 +      A finished IRCEvent.
 +/
IRCEvent toIRCEvent(const string raw)
{
    import std.datetime : Clock;

    IRCEvent event;

    event.time = Clock.currTime.toUnixTime;

    // We don't need to .idup here; it has already been done in the Generator
    event.raw = raw;

    try
    {
        if (raw[0] != ':')
        {
            parseBasic(event);
            return event;
        }

        auto slice = event.raw[1..$]; // advance past first colon

        // First pass: prefixes. This is the sender
        parsePrefix(event, slice);

        // Second pass: typestring. This is what kind of action the event is of
        parseTypestring(event, slice);

        // Third pass: specialcases. This splits up the remaining bits into
        // useful strings, like sender, target and content
        parseSpecialcases(event, slice);
    }
    catch (Exception e)
    {
        writeln(Foreground.lightred, "toIRCEvent: ", e.msg);
    }

    return event;
}


// userFromEvent
/++
 +  Takes an IRCEvent and builds an IRCUser from its fields.
 +
 +  Params:
 +      event = IRCEvent to extract an IRCUser out of.
 +
 +  Returns:
 +      A freshly generated IRCUser.
 +/
IRCUser userFromEvent(const IRCEvent event)
{
    IRCUser user;

    with (IRCEvent.Type)
    switch (event.type)
    {
    case RPL_WHOISUSER:
        // These events are sent by the server, *describing* a user
        // :asimov.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :Full Name Here
        string content = event.content;

        with (user)
        {
            nickname  = event.target;
            login     = event.aux;
            special   = event.special;
            content.formattedRead("%s %s", &ident, &address);
        }
        break;

    case WHOISLOGIN:
    case HASTHISNICK:
        // WHOISLOGIN is shaped differently, no addres or ident
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        with (user)
        {
            nickname = event.target;
            login    = event.aux;
        }
        break;

    default:
        if (!event.ident.length)
        {
            // Server events don't have ident
            writefln(Foreground.lightred,
                "There was a server %s event and we naïvely tried to build a user from it",
                event.type);
            goto case WHOISLOGIN;
        }

        with (user)
        {
            nickname = event.sender;
            ident    = event.ident;
            address  = event.address;
            special  = event.special;
        }
        break;
    }

    return user;
}

unittest
{
    import std.conv : to;

    immutable e1 = ":zorael!~zorael@ns3363704.ip-94-23-253.eu INVITE kameloso #hirrsteff"
                   .toIRCEvent();
    immutable u1 = userFromEvent(e1);
    with (u1)
    {
        assert((nickname == "zorael"), nickname);
        assert((ident == "~zorael"), ident);
        assert((address == "ns3363704.ip-94-23-253.eu"), address);
        assert(!special);
    }

    immutable e2 = ":asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as"
                   .toIRCEvent();
    assert((e2.type == IRCEvent.Type.WHOISLOGIN), e2.type.to!string);
    immutable u2 = userFromEvent(e2);
    with (u2)
    {
        assert((nickname == "xurael"), nickname);
        assert((login == "zorael"), login);
        assert(!special);
    }

    immutable e3 = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered."
                   .toIRCEvent();
    immutable u3 = userFromEvent(e3);
    with (u3)
    {
        assert((nickname == "NickServ"), nickname);
        assert((ident == "NickServ"), ident);
        assert((address == "services."), address);
        assert(special);
    }
}

/// This simply looks at an event and decides whether it is from a nickname
/// registration service.
bool isFromAuthService(const IRCEvent event)
{
    import std.algorithm.searching : endsWith;

    with (event)
    {
        if (sender == "NickServ")
        {
            if ((ident == "NickServ") && (address == "services.")) return true;  // Freenode
            if ((ident == "service")  && (address == "rizon.net")) return true;  // Rizon
            if (((ident == "NickServ") || (ident == "services")) &&
                bot.server.resolvedAddress.endsWith(address))
            {
                // writeln(Foreground.lightcyan, "Sensible guess that it's the real NickServ");
                return true; // sensible
            }
            if ((ident == "NickServ") || (ident == "services"))
            {
                // writeln(Foreground.lightcyan, "Naïve guess that it's the real NickServ");
                return true;  // NAÏVE
            }
        }
        else if ((sender == "Q") && (ident == "TheQBot") && (address == "CServe.quakenet.org"))
        {
            // Quakenet
            // writeln(Foreground.lightcyan, "100% that it's QuakeNet's C");
            return true;
        }
        else if ((sender == "AuthServ") && (ident == "AuthServ") && (address == "Services.GameSurge.net"))
        {
            // GameSurge
            // AuthServ!AuthServ@Services.GameSurge.net NOTICE kameloso :No help on that topic.
            return true;
        }
    }

    return false;
}

unittest
{
    IRCEvent e1;
    with (e1)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice = raw[1..$];  // mutable
        e1.parsePrefix(slice);
        assert(e1.isFromAuthService);
    }

    IRCEvent e2;
    with (e2)
    {
        raw = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
        string slice = raw[1..$];
        e2.parsePrefix(slice);
        assert(e2.isFromAuthService);
    }

    IRCEvent e3;
    with (e3)
    {
        raw = ":NickServ!service@rizon.net NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,";
        string slice = raw[1..$];
        e3.parsePrefix(slice);
        assert(e3.isFromAuthService);
    }

    IRCEvent e4;
    with (e4)
    {
        raw = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp";
        string slice = raw[1..$];
        e4.parsePrefix(slice);
        assert(!e4.isFromAuthService);
    }
}


/// Checks whether a string *looks* like a channel.
bool isValidChannel(const string line)
{
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

    if ((line.indexOf(' ') != -1) ||
        (line.indexOf(',') != -1) ||
        (line.indexOf(7) != -1))
    {
        return false;
    }

    if ((line.length <= 1) || (line.length > maxChannelLength)) return false;

    if ((line[0] == '#') || (line[0] == '&'))
    {
        if (line.length > 3)
        {
           return (line[2..$].indexOf('#') == -1) &&
                  (line[2..$].indexOf('&') == -1);
        }

        return true;
    }

    return false;
}

unittest
{
    assert("#channelName".isValidChannel);
    assert("&otherChannel".isValidChannel);
    assert("##freenode".isValidChannel);
    assert(!"###froonode".isValidChannel);
    assert(!"#not a channel".isValidChannel);
    assert(!"notAChannelEither".isValidChannel);
    assert(!"#".isValidChannel);
    assert(!"".isValidChannel);
}

/// Checks if a string *looks* like a nickname.
bool isValidNickname(const string nickname)
{
    import std.regex : ctRegex, matchAll;
    import std.string : representation;

    // allowed in nicks: [a-z] [A-Z] [0-9] _-\[]{}^`|

    if (!nickname.length || (nickname.length > maxNickLength)) return false;

    enum validCharactersPattern = r"^([a-zA-Z0-9_\\\[\]{}\^`|-]+)$";
    static engine = ctRegex!validCharactersPattern;

    auto characterMatches = nickname.matchAll(engine);

    // Assertion error, https://issues.dlang.org/show_bug.cgi?id=17458
    //if (characterMatches.hit.length) return true;

    if (characterMatches.pre.length || characterMatches.post.length) return false;
    else return true;
}

unittest
{
    const validNicknames =
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

    const invalidNicknames =
    [
        "",
        "1234567890", // length > 9, max per standard
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
        assert(nickname.isValidNickname, nickname);
    }

    foreach (nickname; invalidNicknames)
    {
        assert(!nickname.isValidNickname, nickname);
    }
}

// stripModeSign
/++
 +  Takes a nickname and strips it of any prepended mode signs, like the @ in @nickname.
 +
 +  The list of signs should be added to when more are discovered.
 +
 +  Params:
 +      nickname = The signed nickname.
 +
 +  Returns:
 +      The nickname with the sign sliced off.
 +/
string stripModeSign(const string nickname)
{
    if (!nickname.length) return string.init;

    switch (nickname[0])
    {
        case '@':
        case '+':
        case '~':
        case '%':
        // case '&': // channel prefix?
            return nickname[1..$];

        default:
            // no sign
            return nickname;
    }
}

unittest
{
    assert("@nickname".stripModeSign == "nickname");
    assert("+kameloso".stripModeSign == "kameloso");
    assert(!"".stripModeSign.length);
}


unittest
{
    import std.conv : to;

    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    immutable e1 = ":tepper.freenode.net NOTICE * :*** Checking Ident".toIRCEvent();
    with (e1)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert((content == "*** Checking Ident"), content);
    }

    /+
    [ERR_NICKNAMEINUSE] tepper.freenode.net (kameloso): "Nickname is already in use." (#433)
    :tepper.freenode.net 433 * kameloso :Nickname is already in use.
     +/
    immutable e2 = ":tepper.freenode.net 433 * kameloso :Nickname is already in use.".toIRCEvent();
    with (e2)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.ERR_NICKNAMEINUSE), type.to!string);
        // assert((target == "kameloso"), target);
        assert((content == "Nickname is already in use."), content);
        assert((num == 433), num.to!string);
    }

    /+
    [WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = ":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^"
                   .toIRCEvent();
    with (e3)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.WELCOME), type.to!string);
        assert((target == "kameloso^"), target);
        assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"),
               content);
        assert((num == 1), num.to!string);
    }

    /+
    [RPL_ENDOFMOTD] tepper.freenode.net (kameloso^): "End of /MOTD command." (#376)
    :tepper.freenode.net 376 kameloso^ :End of /MOTD command.
     +/
    immutable e4 = ":tepper.freenode.net 376 kameloso^ :End of /MOTD command.".toIRCEvent();
    with (e4)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.RPL_ENDOFMOTD), type.to!string);
        //assert((target == "kameloso^"), target);
        assert((content == "End of /MOTD command."), content);
        assert((num == 376), num.to!string);
    }

    /+
    [SELFMODE] kameloso^ (kameloso^) <+i>
    :kameloso^ MODE kameloso^ :+i
     +/
    immutable e5 = ":kameloso^ MODE kameloso^ :+i".toIRCEvent();
    with (e5)
    {
        assert((sender == "kameloso^"), sender);
        assert((type == IRCEvent.Type.SELFMODE), type.to!string);
        assert((aux == "+i"), aux);
    }

    /+
    [QUERY] zorael (kameloso^): "sudo privmsg zorael :derp"
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp
     +/
    immutable e6 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp"
                   .toIRCEvent();
    with (e6)
    {
        assert((sender == "zorael"), sender);
        assert((type == IRCEvent.Type.QUERY), type.to!string); // Will this work?
        //assert((target == "kameloso^", target);
        assert((content == "sudo privmsg zorael :derp"), content);
    }

    /+
    [RPL_WHOISUSER] tepper.freenode.net (zorael): "~NaN ns3363704.ip-94-23-253.eu" <jr> (#311)
    :tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr
     +/
    immutable e7 = ":tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr"
                   .toIRCEvent();
    with (e7)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.RPL_WHOISUSER), type.to!string);
        assert((content == "~NaN ns3363704.ip-94-23-253.eu"), content);
        assert((aux == "jr"), aux);
        assert((num == 311), num.to!string);
    }

    /+
    [WHOISLOGIN] tepper.freenode.net (zurael): "is logged in as" <zorael> (#330)
    :tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as
     +/
    immutable e8 = ":tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as"
                   .toIRCEvent();
    with (e8)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.WHOISLOGIN), type.to!string);
        assert((target == "zurael"), target);
        assert((content == "is logged in as"), content);
        assert((aux == "zorael"), aux);
        assert((num == 330), num.to!string);
    }

    /+
    [PONG] tepper.freenode.net
    :tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net
     +/
    immutable e9 = ":tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net"
                   .toIRCEvent();
    with (e9)
    {
        assert((sender == "tepper.freenode.net"), sender);
        assert((type == IRCEvent.Type.PONG), type.to!string);
        assert(!target.length, target); // More than the server and type is never parsed
    }

    /+
    [QUIT] wonderworld: "Remote host closed the connection"
    :wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection
     +/
    immutable e10 = ":wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection"
                    .toIRCEvent();
    with (e10)
    {
        assert((sender == "wonderworld"), sender);
        assert((type == IRCEvent.Type.QUIT), type.to!string);
        assert(!target.length, target);
        assert((content == "Remote host closed the connection"), content);
    }

    /+
    [CHANMODE] zorael (kameloso^) [#flerrp] <+v>
    :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
     +/
     immutable e11 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^"
                     .toIRCEvent();
     with (e11)
     {
        assert((sender == "zorael"), sender);
        assert((type == IRCEvent.Type.CHANMODE), type.to!string);
        assert((target == "kameloso^"), target);
        assert((channel == "#flerrp"), channel);
        assert((aux == "+v"), aux);
     }

     /+
     [17:10:44] [NUMERIC] irc.uworld.se (kameloso): "To connect type /QUOTE PONG 3705964477" (#513)
     :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
     +/
     immutable e12 = ":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477"
                     .toIRCEvent();
     with (e12)
     {
        assert((sender == "irc.uworld.se"), sender);
        assert((type == IRCEvent.Type.TOCONNECTTYPE), type.to!string);
        // assert((target == "kameloso"), target);
        assert((aux == "3705964477"), aux);
        assert((content == "PONG"), content);
     }

    /+
    [20:55:14] [ERR_UNKNOWNCOMMAND] karatkievich.freenode.net (kameloso^) <systemd,#kde,#kubuntu,#archlinux, ...>
    :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...
    +/
    immutable e13 = ":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ..."
                    .toIRCEvent();
    with (e13)
    {
        assert((sender == "karatkievich.freenode.net"), sender);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((aux == "systemd,#kde,#kubuntu,#archlinux ..."), aux);
    }

    /+
    :asimov.freenode.net 421 kameloso^ sudo :Unknown command
    +/
    immutable e14 = ":asimov.freenode.net 421 kameloso^ sudo :Unknown command".toIRCEvent();
    with (e14)
    {
        assert((sender == "asimov.freenode.net"), sender);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "Unknown command"), content);
        assert((aux == "sudo"), aux);
    }

    /+
    :wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :PING 1495974267 590878
    +/
    immutable e15 = (":wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :" ~
                     IRCControlCharacter.ctcp ~ "PING 1495974267 590878" ~
                     IRCControlCharacter.ctcp).toIRCEvent();
    with (e15)
    {
        assert((sender == "wob^2"), sender);
        assert((type == IRCEvent.Type.CTCP_PING), type.to!string);
        assert((content == "1495974267 590878"), content);
        assert((aux == "PING"), aux);
    }

    /+
    :beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas
    +/
    immutable e16 = ":beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas"
                    .toIRCEvent();
    with (e16)
    {
        assert((sender == "beLAban"), sender);
        assert((type == IRCEvent.Type.CHAN), type.to!string);
        assert((channel == "##networking"), channel);
        assert((content == "start at cpasdcas"), content);
    }
}

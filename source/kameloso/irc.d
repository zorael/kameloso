module kameloso.irc;

public import kameloso.ircstructs;

import kameloso.common;
import kameloso.constants;
import kameloso.stringutils : nom;

import std.format : format, formattedRead;
import std.string : indexOf;
import std.stdio;

@safe:

private:

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
void parseBasic(ref IRCParser parser, ref IRCEvent event) @trusted
{
    import std.algorithm.searching : canFind;

    mixin(scopeguard(failure));

    string slice = event.raw;

    // This is malformed for some strings but works anyway.
    //slice.formattedRead("%s :%s", event.typestring, slice);
    string typestring;

    if ((cast(ubyte[])slice).canFind(':'))
    {
        typestring = slice.nom(" :");
    }
    else if ((cast(ubyte[])slice).canFind(' '))
    {
        typestring = slice.nom(' ');
    }
    else
    {
        typestring = slice;
    }

    with (parser)
    switch (typestring)
    {
    case "PING":
        // PING :3466174537
        // PING :weber.freenode.net
        event.type = IRCEvent.Type.PING;

        if (slice.indexOf('.') != -1)
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
        event.type = IRCEvent.Type.ERROR;
        event.content = slice;
        break;

    case "NOTICE AUTH":
    case "NOTICE":
        // QuakeNet/Undernet
        // NOTICE AUTH :*** Couldn't look up your hostname
        // Unsure how formattedRead is doing this...
        // adam_d_ruppe | but it will read a string up until whitespace and
        //                call that the first one
        // adam_d_ruppe | then ... well i'm not sure, it might just skip
        //                everything up until the colon
        // adam_d_ruppe | tbh i try to avoid these formattedRead (and the whole
        //                family of functions) since their behavior is always
        //                strange to me
        event.type = IRCEvent.Type.NOTICE;
        event.content = slice;
        event.sender.special = true;

        if (bot.server.address != typeof(bot.server).init.address)
        {
            // No sender known and the address has been set to something
            // Inherit that as sender
            event.sender.address = bot.server.address;
        }
        break;

    case "PONG":
        // PONG :tmi.twitch.tv
        event.sender.address = slice;
        break;

    case "AUTHENTICATE":
        event.content = slice;
        event.type = IRCEvent.Type.SASL_AUTHENTICATE;
        break;

    default:
        import kameloso.stringutils : beginsWith;

        if (event.raw.beginsWith("NOTICE"))
        {
            // Probably NOTICE <bot.nickname>
            // NOTICE kameloso :*** If you are having problems connecting due to ping timeouts, please type /notice F94828E6 nospoof now.
            goto case "NOTICE";
        }
        else if (event.raw.beginsWith('@'))
        {
            // @badges=broadcaster/1;color=;display-name=Zorael;emote-sets=0;mod=0;subscriber=0;user-type= :tmi.twitch.tv USERSTATE #zorael
            // @broadcaster-lang=;emote-only=0;followers-only=-1;mercury=0;r9k=0;room-id=22216721;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE #zorael
            // @badges=subscriber/3;color=;display-name=asdcassr;emotes=560489:0-6,8-14,16-22,24-30/560510:39-46;id=4d6bbafb-427d-412a-ae24-4426020a1042;mod=0;room-id=23161357;sent-ts=1510059590512;subscriber=1;tmi-sent-ts=1510059591528;turbo=0;user-id=38772474;user-type= :asdcsa!asdcss@asdcsd.tmi.twitch.tv PRIVMSG #lirik :lirikFR lirikFR lirikFR lirikFR :sled: lirikLUL

            import kameloso.stringutils : nom;
            import std.algorithm.iteration : splitter;

            // Get rid of the prepended @
            string raw = event.raw[1..$];
            // Save tags so we can restore it in our new event
            immutable tags = raw.nom(" ");

            event = parser.toIRCEvent(raw);

            event.tags = tags;
            parser.parseTwitchTags(event);  // FIXME: support any IRCv3 server
        }
        else
        {
            logger.warning("Unknown basic type: ", typestring);
            logger.trace(event.raw);
            logger.info("Please report this.");
        }

        break;
    }
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
void parsePrefix(ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : nom;
    import std.algorithm.searching : endsWith;

    auto prefix = slice.nom(' ');

    with (event.sender)
    if (prefix.indexOf('!') != -1)
    {
        // user!~ident@address
        //prefix.formattedRead("%s!%s@%s", sender, ident, address);
        nickname = prefix.nom('!');
        ident = prefix.nom('@');
        address = prefix;

        // FIXME: This obviously doesn't scale
        special = (address == "services.") ||
                  ((ident == "service") && (address == "rizon.net")) ||
                  (address.endsWith(".rizon.net")) ||
                  (address.endsWith(".quakenet.org"));
    }
    else if (prefix.indexOf('.') != -1)
    {
        // dots signify an address
        address = prefix;
    }
    else
    {
        nickname = prefix;
    }
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
void parseTypestring(ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : nom, toEnum;
    import std.conv : to;

    immutable typestring = slice.nom(' ');

    if ((typestring[0] >= '0') && (typestring[0] <= '9'))
    {
        // typestring is a number (ascii 48 is 0, 57 is 9)
        try
        {
            immutable number = typestring.to!uint;
            event.num = number;
            event.type = parser.typenums[number];

            with (IRCEvent.Type)
            event.type = (event.type == UNSET) ? NUMERIC : event.type;
        }
        catch (const Exception e)
        {
            logger.error(e.msg);
            printObject(event);
        }
    }
    else
    {
        try event.type = typestring.toEnum!(IRCEvent.Type);
        catch (const Exception e)
        {
            logger.error(e.msg);
            printObject(event);
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
 +  Takes a slice of a raw IRC string and continues parsing it into an IRCEvent struct.
 +
 +  This function only focuses on specialcasing the remaining line, dividing it
 +  into fields like target, channel, content, etc.
 +
 +  IRC events are *riddled* with inconsistencies, so this function is very very
 +  long but by neccessity.
 +
 +  The IRCEvent is finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent to finish working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseSpecialcases(ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils;

    import std.string : strip, stripLeft, stripRight;

    scope(failure)
    {
        logger.warning("--------- PARSE SPECIALCASES FAILURE");
        printObject(event);
        logger.warning("------------------------------------");
    }

    with (parser)
    with (IRCEvent)
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

        if (slice.indexOf(' ') != -1)
        {
            // :nick!user@host JOIN #channelname accountname :Real Name
            // :nick!user@host JOIN #channelname * :Real Name
            // :nick!~identh@unaffiliated/nick JOIN #freenode login :realname
            // :kameloso!~NaN@2001:41d0:2:80b4:: JOIN #hirrsteff2 kameloso : kameloso!
            event.channel = slice.nom(' ');
            event.sender.login = slice.nom(" :");
            //event.content = slice.strip();  // no need for full name...
        }
        else
        {
            if (slice.length && (slice[0] == ':'))
            {
                event.channel = slice[1..$];
            }
            else
            {
                event.channel = slice;
            }
        }
        break;

    case PART:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PART #flerrp :"WeeChat 1.6"
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com PART #flerrp
        event.type = (event.sender.nickname == bot.nickname) ? SELFPART : PART;

        if (slice.indexOf(' ') != -1)
        {
            //slice.formattedRead("%s :%s", event.channel, event.content);
            event.channel = slice.nom(" :");
            event.content = slice;
            event.content = event.content.unquoted;
        }
        else
        {
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
        event.type = (event.target.nickname == bot.nickname) ? SELFKICK : KICK;
        //slice.formattedRead("%s %s :%s", event.channel, event.target, event.content);
        event.channel = slice.nom(' ');
        event.target.nickname = slice.nom(" :");
        event.content = slice;
        if (event.type == SELFKICK) event.target.nickname = string.init;
        break;

    case INVITE:
        // (freenode) :zorael!~NaN@2001:41d0:2:80b4:: INVITE kameloso :#hirrsteff
        // (quakenet) :zorael!~zorael@ns3363704.ip-94-23-253.eu INVITE kameloso #hirrsteff
        //slice.formattedRead("%s %s", event.target, event.channel);
        event.target.nickname = slice.nom(' ');
        event.channel = slice;
        event.channel = (slice[0] == ':') ? slice[1..$] : slice;
        break;

    case ERR_INVITEONLYCHAN: // 473
    case RPL_ENDOFNAMES: // 366
    case RPL_TOPIC: // 332
    case RPL_CHANNEL_URL: // 328
    case ERR_NEEDREGGEDNICK: // 477
    case ERR_NOSUCHCHANNEL: // 403
        // :moon.freenode.net 403 kameloso archlinux :No such channel
        // :asimov.freenode.net 332 kameloso^ #garderoben :Are you employed, sir?
        // :asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.
        // :services. 328 kameloso^ #ubuntu :http://www.ubuntu.com
        // :cherryh.freenode.net 477 kameloso^ #archlinux :Cannot join channel (+r) - you need to be identified with services
        //slice.formattedRead("%s %s :%s", event.target, event.channel, event.content);
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_NAMREPLY: // 353
        // :asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');
        slice.nom(' ');
        //slice.formattedRead("%s :%s", event.channel, event.content);
        event.channel = slice.nom(" :");
        event.content = slice; //.stripRight();
        //event.content = event.content.stripRight();
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
        slice.nom(' ');
        event.channel = slice.nom(' ');
        if (event.channel == "*") event.channel = string.init;
        immutable userOrIdent = slice.nom(' ');
        if (userOrIdent[0] == '~') event.target.ident = userOrIdent;
        event.target.address = slice.nom(' ');
        slice.nom(' ');  // server
        event.target.nickname = slice.nom(' ');
        slice.nom(' ');  // H|G
        slice.nom(' ');  // hopcount
        event.content = slice.stripLeft();
        break;

    case RPL_ENDOFWHO: // 315
        // :tolkien.freenode.net 315 kameloso^ ##linux :End of /WHO list.
        // :irc.rizon.no 315 kameloso^^ * :End of /WHO list.
        slice.nom(' ');
        event.channel = slice.nom(" :");
        if (event.channel == "*") event.channel = string.init;
        event.content = slice;
        break;

    case RPL_AWAY: // 301
        // :tolkien.freenode.net 301 kameloso^ jcjordyn120 :Idle
        slice.nom(' ');
        event.target.nickname = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_MOTD: // 372
    case RPL_LUSERCLIENT: // 251
        // :asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor
        //slice.formattedRead("%s :%s", event.target, event.content);
        //event.target.nickname = slice.nom(" :");
        slice.nom(" :");
        event.content = slice;
        break;

    case RPL_ISUPPORT: // 005
        parser.onISUPPORT(event, slice);
        break;

    case RPL_MYINFO: // 004
        parser.onMyInfo(event, slice);
        break;

    case RPL_TOPICWHOTIME: // 333
        // :asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377
        /*slice.formattedRead("%s %s %s %s", event.target, event.channel,
                            event.content, event.aux);*/
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');
        event.channel = slice.nom(' ');
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case RPL_WHOISHOST: // 378
        // :wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62
        // TRIED TO NOM TOO MUCH:'kameloso :is connecting from NaN@194.117.188.126 194.117.188.126' with ' :is connecting from *@'
        slice.nom(' ');

        /*slice.formattedRead("%s :is connecting from *@%s %s",
                            event.target, event.content, event.aux);*/
        // can this happen with others as target?
        event.target.nickname = slice.nom(" :is connecting from ");
        event.target.ident = slice.nom('@');
        if (event.target.ident == "*") event.target.ident = string.init;
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case ERR_UNKNOWNCOMMAND: // 421
        if (slice.indexOf(':') == -1)
        {
            // :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,...
            //event.target.nickname = slice.nom(' ');
            slice.nom(' ');
            event.content = slice;
        }
        else
        {
            // :asimov.freenode.net 421 kameloso^ sudo :Unknown command
            //slice.formattedRead("%s %s :%s", event.target, event.aux, event.content);
            //event.target.nickname = slice.nom(' ');
            slice.nom(' ');
            event.content = slice.nom(" :");
            event.aux = slice;
        }
        break;

    case RPL_WHOISIDLE: //  317
        // :rajaniemi.freenode.net 317 kameloso zorael 0 1510219961 :seconds idle, signon time
        slice.nom(' ');
        slice.nom(' ');
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

        //slice.formattedRead("%s %s :%s", event.target, event.aux, event.content);
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');

        if (slice.indexOf(" :") != -1)
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
        // Hard to use formattedRead here
        slice.nom(' ');
        event.target.nickname = slice.nom(' ');
        event.target.ident = slice.nom(' ');
        event.target.address = slice.nom(" * :");
        event.content = slice.stripLeft();
        break;

    /*case RPL_WHOISCHANNELS: // 319
        // :leguin.freenode.net 319 kameloso^ zorael :#flerrp
        import std.string : stripRight;
        slice = slice.stripRight();
        goto case RPL_ENDOFWHOIS;*/

    case RPL_WHOISCHANNELS: // 319
    case RPL_WHOISSECURE: // 671
    case RPL_ENDOFWHOIS: // 318
    case ERR_NICKNAMEINUSE: // 433
    case ERR_NOSUCHNICK: // 401
    case RPL_WHOISOPERATOR:
        // :asimov.freenode.net 671 kameloso^ zorael :is using a secure connection
        // :asimov.freenode.net 318 kameloso^ zorael :End of /WHOIS list.
        // :asimov.freenode.net 433 kameloso^ kameloso :Nickname is already in use.
        // :cherryh.freenode.net 401 kameloso^ cherryh.freenode.net :No such nick/channel
        // :lightning.ircstorm.net 313 kameloso NickServ :is a Network Service

        slice.nom(' ');
        //slice.formattedRead("%s :%s", event.target, event.content);
        event.target.nickname = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_WHOISSERVER: // 312
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE
        slice.nom(' ');
        //slice.formattedRead("%s %s :%s", event.target, event.content, event.aux);
        event.target.nickname = slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice;
        break;

    case RPL_WHOISACCOUNT: // 330
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        slice.nom(' ');
        //slice.formattedRead("%s %s :%s", event.target, event.aux, event.content);
        event.target.nickname = slice.nom(' ');
        event.target.login = slice.nom(" :");
        //event.content = slice;
        event.content = event.target.login;
        break;

    case RPL_WHOISREGNICK: // 307
        // :irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick
        // :irc.x2x.cc 307 kameloso^^ wob^2 :has identified for this nick
        slice.nom(' '); // bot nick
        event.target.nickname = slice.nom(" :");
        //event.aux = event.target.nickname;
        //event.content = slice;
        event.content = event.target.nickname;
        break;

    case PONG:
        event.content = string.init;
        break;

    case ERR_NOTREGISTERED: // 451
        if (slice[0] == '*')
        {
            // :niven.freenode.net 451 * :You have not registered
            //slice.formattedRead("* :%s", event.content);
            slice.nom("* :");
            event.content = slice;
        }
        else
        {
            // :irc.harblwefwoi.org 451 WHOIS :You have not registered
            //slice.formattedRead("%s :%s", event.aux, event.content);
            event.aux = slice.nom(" :");
            event.content = slice;
        }
        break;

    case RPL_WELCOME: // 001
        // :adams.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
        //slice.formattedRead("%s :%s", event.target, event.content);
        event.target.nickname = slice.nom(" :");
        event.content = slice;
        bot.nickname = event.target.nickname;
        bot.updated = true;
        break;

    case ERR_BADPING: // 513
        // :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
        if (slice.indexOf(" :To connect type ") == -1)
        {
            logger.warning("Unknown variant of TOCONNECTTYPE");
            printObject(event);
            break;
        }

        //slice.formattedRead("%s :To connect type %s", event.target, event.aux);
        event.target.nickname = slice.nom(" :To connect type ");
        event.aux = slice;
        event.aux.nom("/QUOTE ");
        event.content = event.aux.nom(' ');
        break;

    case RPL_HELPSTART: // 704
    case RPL_HELPTXT: // 705
    case RPL_ENDOFHELP: // 706
        // :leguin.freenode.net 704 kameloso^ index :Help topics available to users:
        // :leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        // :leguin.freenode.net 706 kameloso^ index :End of /HELP.
        //slice.formattedRead("%s :%s", event.aux, event.content);
        slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case ERR_BANONCHAN: // 435
        // :cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel
        /*slice.formattedRead("%s %s %s :%s", event.target, event.aux,
                            event.channel, event.content);*/
        event.target.nickname = slice.nom(' ');
        event.aux = slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case CAP:
        if (slice.indexOf('*') != -1)
        {
            // :tmi.twitch.tv CAP * LS :twitch.tv/tags twitch.tv/commands twitch.tv/membership
            //slice.formattedRead("* %s :%s", event.aux, event.content);
            slice.nom("* ");
        }
        else
        {
            // :genesis.ks.us.irchighway.net CAP 867AAF66L LS :away-notify extended-join account-notify multi-prefix sasl tls userhost-in-names
            //string id;
            //slice.formattedRead("%s %s :%s", id, event.aux, event.content);
            //immutable id = slice.nom(' ');
            slice.nom(' ');
        }

        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case TOPIC:
        // :zorael!~NaN@2001:41d0:2:80b4:: TOPIC #garderoben :en greps av hybris, sen var de bara fyra
        //slice.formattedRead("%s :%s", event.channel, event.content);
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case USERSTATE:
    case ROOMSTATE:
    case GLOBALUSERSTATE: // ?
        // :tmi.twitch.tv USERSTATE #zorael
        // :tmi.twitch.tv ROOMSTATE #zorael
        event.channel = slice;
        break;

    case HOSTTARGET:
        if (slice.indexOf(" :-") != -1)
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
        //slice.formattedRead("%s :%s %s", event.channel, event.content, event.aux);
        //if (event.aux == "-") event.aux = string.init;
        event.channel = slice.nom(" :");
        event.content = slice.nom(' ');
        event.aux = (slice == "-") ? string.init : slice;
        break;

    case HOSTEND:
        // :tmi.twitch.tv HOSTTARGET #hosting_channel :- [<number-of-viewers>]
        //slice.formattedRead("%s :- %s", event.channel, event.aux);
        event.channel = slice.nom(" :- ");
        event.aux = slice;
        break;

    case USERNOTICE:
        // :tmi.twitch.tv USERNOTICE #drdisrespectlive :ooooo weee, it's a meeeee, Moweee!
        // :tmi.twitch.tv USERNOTICE #tsm_viss :Good luck at IEM hope you guys crush it!
        // :tmi.twitch.tv USERNOTICE #lirik
        if (slice.indexOf(" :") != -1)
        {
            event.channel = slice.nom(" :");
            event.content = slice;
        }
        else
        {
            event.channel = slice;
        }

        event.role = Role.SERVER;  // FIXME
        break;

    case CLEARCHAT:
        // :tmi.twitch.tv CLEARCHAT #zorael
        // :tmi.twitch.tv CLEARCHAT #<channel> :<user>
        if (slice.indexOf(" :") != -1)
        {
            // Banned
            event.channel = slice.nom(" :");
            event.target.nickname = slice;
            event.type = event.aux.length ? TEMPBAN : PERMBAN;
        }
        else
        {
            event.channel = slice;
        }

        event.role = Role.SERVER;  // FIXME
        break;

    case RPL_LOGGEDIN: // 900
    case RPL_SASLSUCCESS: // 903
        // :weber.freenode.net 900 kameloso kameloso!NaN@194.117.188.126 kameloso :You are now logged in as kameloso.
        // :weber.freenode.net 903 kameloso :SASL authentication successful
        // :Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.
        if (event.target.nickname.indexOf(' ') != -1)
        {
            event.target.nickname = bot.nickname;
        }
        break;

    case ACCOUNT:
        //:ski7777!~quassel@ip5b435007.dynamic.kabel-deutschland.de ACCOUNT ski7777
        event.sender.login = slice;
        event.content = slice;  // to make it visible?
        break;

    case RPL_HOSTHIDDEN: // 396
    case RPL_VERSION: // 351
        // irc.rizon.no 351 kameloso^^ plexus-4(hybrid-8.1.20)(20170821_0-607). irc.rizon.no :TS6ow
        // :TAL.DE.EU.GameSurge.net 396 kameloso ~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4 :is now your hidden host
        slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice;
        break;

    case RPL_YOURID: // 42
    case ERR_YOUREBANNEDCREEP: // 465
    case ERR_HELPNOTFOUND: // 502, 524
    case ERR_UNKNOWNMODE: // 472
        // :caliburn.pa.us.irchighway.net 042 kameloso 132AAMJT5 :your unique ID
        // :irc.rizon.no 524 kameloso^^ 502 :Help not found
        // :irc.rizon.no 472 kameloso^^ X :is unknown mode char to me
        // miranda.chathispano.com 465 kameloso 1511086908 :[1511000504768] G-Lined by ChatHispano Network. Para mas informacion visite http://chathispano.com/gline/?id=<id> (expires at Dom, 19/11/2017 11:21:48 +0100).
        // event.time was 1511000921
        slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_LIST: // 322
        // :irc.RomaniaChat.eu 322 kameloso #GameOfThrones 1 :[+ntTGfB]
        // :irc.RomaniaChat.eu 322 kameloso #radioclick 63 :[+ntr]  Bun venit pe #Radioclick! Site oficial www.radioclick.ro sau servere irc.romaniachat.eu, irc.radioclick.ro
        slice.nom(' ');
        event.channel = slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_LISTSTART: // 321
        // :cherryh.freenode.net 321 kameloso^ Channel :Users  Name
        // none of the fields are interesting...
        break;

    case ERR_LINKCHANNEL: // 470
        // :wolfe.freenode.net 470 kameloso #linux ##linux :Forwarding to another channel
        slice.nom(' ');
        event.channel = slice.nom(' ');
        event.content = slice.nom(" :");
        break;

    case RPL_WHOISMODES: // 379
        // :cadance.canternet.org 379 kameloso kameloso :is using modes +ix
        slice.nom(' ');
        event.target.nickname = slice.nom(" :is using modes ");
        event.aux = slice;
        break;

    case RPL_WHOWASUSER: // 314
        // :irc.uworld.se 314 kameloso^^ kameloso ~NaN C2802314.E23AD7D8.E9841504.IP * : kameloso!
        slice.nom(' ');
        event.target.nickname = slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice.strip();
        break;

    case ERR_USERONCHANNEL: // 443
        // :orwell.freenode.net 443 kameloso^ kameloso #flerrp :is already on channel
        slice.nom(' ');
        event.target.nickname = slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    default:
        if ((event.type == NUMERIC) || (event.type == UNSET))
        {
            writeln();
            logger.warning("--------- UNCAUGHT NUMERIC OR UNSET");
            printObject(event);
            logger.warning("-----------------------------------");
            writeln();
        }

        if (slice.indexOf(" :") != -1)
        {
            //slice.formattedRead("%s :%s", event.target, event.content);
            string targets = slice.nom(" :");

            if (targets.indexOf(' ') != -1)
            {
                // More than one

                immutable probablyBot = targets.nom(' ');

                if ((probablyBot == bot.nickname) && targets.length)
                {
                    if ((targets[0] >= '0' ) && (targets[0] <= '9'))
                    {
                        // numeric
                        if (targets.indexOf(' ') != -1)
                        {
                            event.target.nickname = targets.nom(' ');
                            event.aux = targets;
                        }
                        else
                        {
                            event.aux = targets;
                        }

                        event.content = slice;
                    }
                    else if (targets[0] == '#')
                    {
                        event.channel = targets;
                    }
                    else
                    {
                        event.target.nickname = targets;
                    }
                }
                else
                {
                    // :asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.
                    //event.target.nickname = targets.nom(' ');
                    event.target.nickname = probablyBot;
                    event.channel = targets;
                    event.content = slice;
                }
            }
            else if (targets.beginsWith('#'))
            {
                logger.warning("targetOrChannel.beginsWith('#') happened. Report this.");
                printObject(event);
                event.channel = targets;
            }
            else
            {
                event.target.nickname = targets;
            }

            event.content = slice;
        }
        else
        {
            // :port80b.se.quakenet.org 221 kameloso +i
            //slice.formattedRead("%s %s", event.target, event.aux);
            event.target.nickname = slice.nom(' ');
            event.aux = slice;
        }

        break;
    }

    event.content = event.content.stripRight();
    parser.postparseSanityCheck(event);
}


// postparseSanityCheck
/++
 +  Checks for some specific erroneous edge cases in an IRCEvent, complains
 +  about all of them and corrects some.
 +
 +  Params:
 +      ref event = the IRC event to examine.
 +/
void postparseSanityCheck(const ref IRCParser parser, ref IRCEvent event)
{
    import kameloso.stringutils : beginsWith;

    if ((event.target.nickname.indexOf(' ') != -1) ||
        (event.channel.indexOf(' ') != -1))
    {
        writeln();
        logger.warning("-- SPACES IN NICK/CHAN, NEEDS REVISION");
        printObject(event);
        logger.warning("--------------------------------------");
        writeln();
    }
    else if (event.target.nickname.beginsWith('#') &&
        (event.type != IRCEvent.Type.ERR_NOSUCHNICK) &&
        (event.type != IRCEvent.Type.RPL_ENDOFWHOIS))
    {
        writeln();
        logger.warning("------ TARGET NICKNAME IS A CHANNEL?");
        printObject(event);
        logger.warning("------------------------------------");
        writeln();
    }
    else if (event.channel.length && !event.channel.beginsWith('#') &&
        (event.type != IRCEvent.Type.ERR_NOSUCHCHANNEL) &&
        (event.type != IRCEvent.Type.RPL_ENDOFWHO))
    {
        writeln();
        logger.warning("---------- CHANNEL IS NOT A CHANNEL?");
        printObject(event);
        logger.warning("------------------------------------");
        writeln();
    }
    if (event.target.nickname == parser.bot.nickname)
    {
        with (IRCEvent.Type)
        switch (event.type)
        {
        case MODE:
        case CHANMODE:
        case RPL_WELCOME:
        case QUERY:
        case JOIN:
        case SELFNICK:
        case RPL_WHOREPLY:
            break;

        default:
            event.target.nickname = string.init;
            break;
        }
    }
}


// parseTwitchTags
/++
 +  Parses a Twitch event's IRCv3 tags.
 +
 +  The event is passed by ref as many tags neccessitate changes to it.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent whose tags should be parsed.
 +/
void parseTwitchTags(const ref IRCParser parser, ref IRCEvent event)
{
    import kameloso.stringutils : nom;
    import std.algorithm.iteration : splitter;

    // https://dev.twitch.tv/docs/v5/guides/irc/#twitch-irc-capability-tags

    if (!event.tags.length) return;

    with (IRCEvent)
    foreach (tag; event.tags.splitter(";"))
    {
        immutable key = tag.nom("=");

        switch (key)
        {
        case "display-name":
            // The user’s display name, escaped as described in the IRCv3 spec.
            // This is empty if it is never set.
            event.sender.alias_ = tag;
            break;

        case "badges":
            // Comma-separated list of chat badges and the version of each
            // badge (each in the format <badge>/<version>, such as admin/1).
            // Valid badge values: admin, bits, broadcaster, global_mod,
            // moderator, subscriber, staff, turbo.

            event.rolestring = tag;

            foreach (badge; tag.splitter(","))
            {
                immutable slash = tag.indexOf('/');
                assert(slash != -1);
                event.role = prioritiseTwoRoles(event.role, tag[0..slash]);
            }
            break;

        case "mod":
        case "subscriber":
        case "turbo":
            // 1 if the user has a (moderator|subscriber|turbo) badge; otherwise, 0.
            if (tag == "0") break;
            event.role = prioritiseTwoRoles(event.role, key);
            break;

        case "ban-duration":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // (Optional) Duration of the timeout, in seconds. If omitted,
            // the ban is permanent.
            event.aux = tag;
            break;

        case "ban-reason":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // The moderator’s reason for the timeout or ban.
            event.content = decodeIRCv3String(tag);
            break;

        case "user-type":
            // The user’s type. Valid values: empty, mod, global_mod, admin, staff.
            // The broadcaster can have any of these.
            event.role = prioritiseTwoRoles(event.role, tag);
            break;

        case "system-msg":
            // The message printed in chat along with this notice.
            event.content = decodeIRCv3String(tag);
            break;

        case "emote-only":
            if (tag == "0") break;
            if (event.type == Type.CHAN) event.type = Type.EMOTE;
            break;

        case "msg-id":
            // The type of notice (not the ID) / A message ID string.
            // Can be used for i18ln. Valid values: see
            // Msg-id Tags for the NOTICE Commands Capability.
            // https://dev.twitch.tv/docs/irc#msg-id-tags-for-the-notice-commands-capability

            /*
                sub
                resub
                charity
                already_banned          <user> is already banned in this room.
                already_emote_only_off  This room is not in emote-only mode.
                already_emote_only_on   This room is already in emote-only mode.
                already_r9k_off         This room is not in r9k mode.
                already_r9k_on          This room is already in r9k mode.
                already_subs_off        This room is not in subscribers-only mode.
                already_subs_on         This room is already in subscribers-only mode.
                bad_host_hosting        This channel is hosting <channel>.
                bad_unban_no_ban        <user> is not banned from this room.
                ban_success             <user> is banned from this room.
                emote_only_off          This room is no longer in emote-only mode.
                emote_only_on           This room is now in emote-only mode.
                host_off                Exited host mode.
                host_on                 Now hosting <channel>.
                hosts_remaining         There are <number> host commands remaining this half hour.
                msg_channel_suspended   This channel is suspended.
                r9k_off                 This room is no longer in r9k mode.
                r9k_on                  This room is now in r9k mode.
                slow_off                This room is no longer in slow mode.
                slow_on                 This room is now in slow mode. You may send messages every <slow seconds> seconds.
                subs_off                This room is no longer in subscribers-only mode.
                subs_on                 This room is now in subscribers-only mode.
                timeout_success         <user> has been timed out for <duration> seconds.
                unban_success           <user> is no longer banned from this chat room.
                unrecognized_cmd        Unrecognized command: <command>
            */
            switch (tag)
            {
            case "host_on":
                event.type = Type.HOSTSTART;
                break;

            case "host_off":
            case "host_target_went_offline":
                event.type = Type.HOSTEND;
                break;

            case "sub":
                event.type = Type.SUB;
                break;

            case "resub":
                event.type = Type.RESUB;
                break;

            case "subgift":
                // [21:33:48] msg-param-recipient-display-name = 'emilypiee'
                // [21:33:48] msg-param-recipient-id = '125985061'
                // [21:33:48] msg-param-recipient-user-name = 'emilypiee'
                event.type = Type.SUBGIFT;
                break;

            default:
                logger.info("unhandled message: ", tag);
                break;
            }
            break;

        case "msg-param-receipient-display-name":
            event.target.alias_ = tag;
            break;

        case "msg-param-recipient-user-name":
            event.target.nickname = tag;
            break;

        case "msg-param-months":
            // The number of consecutive months the user has subscribed for,
            // in a resub notice.
            event.aux = event.aux.length ? (tag ~ 'x' ~ event.aux) : tag;
            break;

        case "msg-param-sub-plan":
            // The type of subscription plan being used.
            // Valid values: Prime, 1000, 2000, 3000.
            // 1000, 2000, and 3000 refer to the first, second, and third
            // levels of paid subscriptions, respectively (currently $4.99,
            // $9.99, and $24.99).
            // EVALUATE ME
            event.aux = event.aux.length ? (event.aux ~ 'x' ~ tag) : tag;
            break;

        case "color":
            // Hexadecimal RGB color code. This is empty if it is never set.
            if (tag.length) event.colour = tag[1..$];
            break;

        case "msg-param-sub-plan-name":
            // The display name of the subscription plan. This may be a default
            // name or one created by the channel owner.
        case "bits":
            /*  (Optional) The amount of cheer/bits employed by the user.
                All instances of these regular expressions:

                    /(^\|\s)<emote-name>\d+(\s\|$)/

                (where <emote-name> is an emote name returned by the Get
                Cheermotes endpoint), should be replaced with the appropriate
                emote:

                static-cdn.jtvnw.net/bits/<theme>/<type>/<color>/<size>

                * theme – light or dark
                * type – animated or static
                * color – red for 10000+ bits, blue for 5000-9999, green for
                  1000-4999, purple for 100-999, gray for 1-99
                * size – A digit between 1 and 4
            */
        case "broadcaster-lang":
            // The chat language when broadcaster language mode is enabled;
            // otherwise, empty. Examples: en (English), fi (Finnish), es-MX
            //(Mexican variant of Spanish).
        case "subs-only":
            // Subscribers-only mode. If enabled, only subscribers and
            // moderators can chat. Valid values: 0 (disabled) or 1 (enabled).
        case "r9k":
            // R9K mode. If enabled, messages with more than 9 characters must
            // be unique. Valid values: 0 (disabled) or 1 (enabled).
        case "emotes":
            /*  Information to replace text in the message with emote images.
                This can be empty. Syntax:

                <emote ID>:<first index>-<last index>,
                <another first index>-<another last index>/
                <another emote ID>:<first index>-<last index>...

                * emote ID – The number to use in this URL:
                      http://static-cdn.jtvnw.net/emoticons/v1/:<emote ID>/:<size>
                  (size is 1.0, 2.0 or 3.0.)
                * first index, last index – Character indexes. \001ACTION does
                  not count. Indexing starts from the first character that is
                  part of the user’s actual message. See the example (normal
                  message) below.
            */
        case "emote-sets":
            // A comma-separated list of emotes, belonging to one or more emote
            // sets. This always contains at least 0. Get Chat Emoticons by Set
            // gets a subset of emoticons.
        case "mercury":
            // ?
        case "followers-only":
            // Probably followers only.
        case "room-id":
            // The channel ID.
        case "slow":
            // The number of seconds chatters without moderator privileges must
            // wait between sending messages.
        case "id":
            // A unique ID for the message.
        case "sent-ts":
            // ?
        case "tmi-sent-ts":
            // ?
        case "user":
            // The name of the user who sent the notice.
        case "user-id":
            // The user’s ID.
        case "login":
            // user login? what?
        case "target-user-id":
            // The target's user ID

            // Ignore these events
            break;

        case "message":
            // The message.
        case "number-of-viewers":
            // (Optional) Number of viewers watching the host.
        default:
            // Verbosely
            logger.trace(key, " = '", tag, "'");
            break;
        }
    }
}


// prioritiseTwoRoles
/++
 +  Compares a given IRCEvent.Role to a role string and decides which of the
 +  two weighs the most; which takes precedence over the other.
 +
 +  This is used to decide what role a user has when they are of several at the
 +  same time. A moderator might be a partner and a subscriber at the same
 +  time, for instance.
 +
 +  Params:
 +      current = The right-hand-side IRCEvent.Role to compare with.
 +      newRole = A Role in lowercase, left-hand-side to compare with.
 +
 +  Returns:
 +      the IRCEvent.Role with the highest priority of the two.
 +/
IRCEvent.Role prioritiseTwoRoles(const IRCEvent.Role current, const string newRole)
{
    // Not in list: UNSET, OTHER, MEMBER

    with (IRCEvent)
    with (IRCEvent.Role)
    switch (newRole)
    {
    case "subscriber":
        if (SUBSCRIBER > current) return SUBSCRIBER;
        break;

    case "mod":
    case "moderator":
        if (MOD > current) return MOD;
        break;

    case "bits":
        if (BITS > current) return BITS;
        break;

    case "partner":
        if (PARTNER > current) return PARTNER;
        break;

    case "premium":
        if (PREMIUM > current) return PREMIUM;
        break;

    case "turbo":
        if (TURBO > current) return TURBO;
        break;

    case "broadcaster":
        if (BROADCASTER > current) return BROADCASTER;
        break;

    case "global_mod":
        if (GLOBAL_MOD > current) return GLOBAL_MOD;
        break;

    case "admin":
        if (ADMIN > current) return ADMIN;
        break;

    case "staff":
        if (STAFF > current) return STAFF;
        break;

    case "server":
        if (SERVER > current) return SERVER;
        break;

    case string.init:
        break;

    default:
        // logger.warningf("don't know what to do with role '%s'", newRole);
        break;
    }

    return current;
}


string decodeIRCv3String(const string line)
{
    import std.regex : ctRegex, replaceAll;

    static spaces = ctRegex!`\\s`;

    return line.replaceAll(spaces, " ");
}

void onNotice(ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : beginsWith;
    import std.string : indexOf;
    // :ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflohomeOnlyw] Make sure your nick is registered, then please try again to join ##linux.
    // :ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.
    // :tolkien.freenode.net NOTICE * :*** Checking Ident

    //slice.formattedRead("%s :%s", event.target, event.content);
    //event.target.nickname = slice.nom(" :");
    slice.nom(" :");
    event.content = slice;

    // FIXME: This obviously doesn't scale either
    /*if (event.target.nickname == "*") event.target.nickname = string.init;
    else*/

    with (parser)
    {
        if ((event.sender.ident == "service") &&
            (event.sender.address == "rizon.net"))
        {
            event.sender.special = true;
        }

        if (!bot.server.resolvedAddress.length && event.content.beginsWith("***"))
        {
            bot.server.resolvedAddress = event.sender.nickname;
            bot.updated = true;
        }

        if (parser.isFromAuthService(event))
        {
            event.sender.special = true;  // by definition

            if ((event.content.indexOf("/msg NickServ IDENTIFY") != -1) ||
                (event.content.indexOf("/msg NickServ identify") != -1))
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
            }

            with (event)
            with (AuthSuccess)
            {
                if ((content.beginsWith(freenode)) ||
                    (content.beginsWith(quakenet)) || // also Freenode SASL
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
                    (content.indexOf(freenodeInvalid) != -1) ||
                    (content.beginsWith(freenodeRejected)) ||
                    (content.indexOf(dalnet) != -1) ||
                    (content.indexOf(unreal) != -1))
                {
                    event.type = IRCEvent.Type.AUTH_FAILURE;
                }
            }
        }
    }

    // FIXME: support
    // *** If you are having problems connecting due to ping timeouts, please type /quote PONG j`ruV\rcn] or /raw PONG j`ruV\rcn] now.
}


void onPRIVMSG(const ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : beginsWith;

    // FIXME, change so that it assigns to the proper field

    immutable targetOrChannel = slice.nom(" :");
    event.content = slice;

    if (targetOrChannel.isValidChannel(parser.bot.server))
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content
        event.type = IRCEvent.Type.CHAN;
        event.channel = targetOrChannel;
    }
    else
    {
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content
        event.type = IRCEvent.Type.QUERY;
        event.target.nickname = targetOrChannel;
    }

    if (slice.length < 3) return;

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
            logger.warning("-------------------- UNKNOWN CTCP EVENT");
            printObject(event);
            break;
        }
    }
}


void onMode(const ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    immutable targetOrChannel = slice.nom(' ');

    if (targetOrChannel.isValidChannel(parser.bot.server))
    {
        event.channel = targetOrChannel;

        if (slice.indexOf(' ') != -1)
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i
            event.type = IRCEvent.Type.CHANMODE;
            //slice.formattedRead("%s %s", event.aux, event.target);
            event.aux = slice.nom(' ');
            // save target in content; there may be more than one
            event.content = slice;
        }
        else
        {
            event.type = IRCEvent.Type.USERMODE;
            event.aux = slice;
        }
    }
    else
    {
        // :kameloso^ MODE kameloso^ :+i
        event.type = IRCEvent.Type.SELFMODE;
        //event.target.nickname = targetOrChannel;
        event.aux = slice[1..$];
    }
}


void onISUPPORT(ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : toEnum;

    import std.algorithm.iteration : splitter;
    import std.conv : to;
    import std.string : toLower;

    // :cherryh.freenode.net 005 CHANTYPES=# EXCEPTS INVEX CHANMODES=eIbq,k,flj,CFLMPQScgimnprstz CHANLIMIT=#:120 PREFIX=(ov)@+ MAXLIST=bqeI:100 MODES=4 NETWORK=freenode STATUSMSG=@+ CALLERID=g CASEMAPPING=rfc1459 :are supported by this server
    // :cherryh.freenode.net 005 CHARSET=ascii NICKLEN=16 CHANNELLEN=50 TOPICLEN=390 DEAF=D FNC TARGMAX=NAMES:1,LIST:1,KICK:1,WHOIS:1,PRIVMSG:4,NOTICE:4,ACCEPT:,MONITOR: EXTBAN=$,ajrxz CLIENTVER=3.0 CPRIVMSG CNOTICE SAFELIST :are supported by this server
    // :asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI
    // :tmi.twitch.tv 004 zorael :-
    //slice.formattedRead("%s %s", event.target, event.content);
    //event.target.nickname = slice.nom(' ');
    slice.nom(' ');
    event.content = slice;

    if (event.content.indexOf(" :") != -1)
    {
        event.aux = event.content.nom(" :");
    }

    foreach (value; event.aux.splitter(' '))
    {
        if (value.indexOf('=') == -1) continue;

        immutable key = value.nom('=');

        /// http://www.irc.org/tech_docs/005.html

        with (parser)
        switch (key)
        {
        case "CHANTYPES":
            // TODO: Logic here to register channel prefix signs
            break;

        case "NETWORK":
            try
            {
                immutable thisNetwork = value
                    .toLower
                    .toEnum!(IRCServer.Network);

                import kameloso.common;

                logger.info("Detected network: ", value.colour(BashForeground.white));

                if (thisNetwork != bot.server.network)
                {
                    // Propagate change
                    bot.server.network = thisNetwork;
                    bot.updated = true;
                }
            }
            catch (const Exception e)
            {
                // We know the network but we don't have defintions for it
                logger.info("Unfamiliar network: ", value);
                bot.server.network = IRCServer.Network.unfamiliar;
                bot.updated = true;
            }
            break;

        case "NICKLEN":
            try
            {
                bot.server.maxNickLength = value.to!uint;
                bot.updated = true;
            }
            catch (const Exception e)
            {
                logger.error(e.msg);
            }
            break;

        case "CHANNELLEN":
            try
            {
                bot.server.maxChannelLength = value.to!uint;
                bot.updated = true;
            }
            catch (const Exception e)
            {
                logger.error(e.msg);
            }
            break;

        default:
            break;
        }
    }

    with (parser.bot.server)
    if (network == Network.init)
    {
        network = networkOf(address);
        if (network != Network.init)
        {
            logger.info("Network: ", network, "?");
        }
    }
}

void onMyInfo(ref IRCParser parser, ref IRCEvent event, ref string slice)
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

    slice.nom(' ');  // nickname

    if ((slice == ":-") && (parser.bot.server.address.indexOf(".twitch.tv") != -1))
    {
        logger.infof("Detected daemon: %s", "twitch".colour(BashForeground.white));
        parser.daemon = IRCServer.Daemon.twitch;
        parser.bot.updated = true;
        return;
    }

    slice.nom(' ');  // server address
    immutable daemonstringRaw = slice.nom(' ');
    immutable daemonstring = daemonstringRaw.toLower();
    event.content = slice;
    event.aux = daemonstringRaw;

    // https://upload.wikimedia.org/wikipedia/commons/d/d5/IRCd_software_implementations3.svg

    with (parser.bot.server)
    with (IRCServer.Daemon)
    {
        if (daemonstring.indexOf("unreal") != -1)
        {
            daemon = unreal;
        }
        else if (daemonstring.indexOf("inspircd") != -1)
        {
            daemon = inspircd;
        }
        else if (daemonstring.indexOf("u2.") != -1)
        {
            daemon = u2;
        }
        else if (daemonstring.indexOf("bahamut") != -1)
        {
            daemon = bahamut;
        }
        else if (daemonstring.indexOf("hybrid") != -1)
        {
            if (address.indexOf(".rizon.") != -1)
            {
                daemon = rizon;
            }
            else
            {
                daemon = hybrid;
            }
        }
        else if (daemonstring.indexOf("ratbox") != -1)
        {
            daemon = ratbox;
        }
        else if (daemonstring.indexOf("charybdis") != -1)
        {
            daemon = charybdis;
        }
        else if (daemonstring.indexOf("ircd-seven") != -1)
        {
            daemon = ircdseven;
        }
        /*else if (daemonstring.indexOf("") != -1)
        {
            daemon = unknown;
        }*/

        parser.daemon = daemon;
    }

    import kameloso.stringutils : enumToString;

    logger.infof("Detected daemon %s: %s", daemonstring, parser.bot.server.daemon
        .enumToString
        .colour(BashForeground.white));

    parser.bot.updated = true;
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
IRCEvent toIRCEvent(ref IRCParser parser, const string raw)
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
            parser.parseBasic(event);
            return event;
        }

        auto slice = event.raw[1..$]; // advance past first colon

        // First pass: prefixes. This is the sender
        parser.parsePrefix(event, slice);

        // Second pass: typestring. This is what kind of action the event is of
        parser.parseTypestring(event, slice);

        // Third pass: specialcases. This splits up the remaining bits into
        // useful strings, like sender, target and content
        parser.parseSpecialcases(event, slice);
    }
    catch (const Exception e)
    {
        logger.error(e.msg);
    }

    return event;
}


public:


/// This simply looks at an event and decides whether it is from a nickname
/// registration service.
bool isFromAuthService(const ref IRCParser parser, const IRCEvent event)
{
    import std.algorithm.searching : endsWith;

    with (parser)
    with (event)
    with (event.sender)
    switch (sender.nickname)
    {
    case "NickServ":
        switch (ident)
        {
        case "NickServ":
            switch (address)
            {
            case "services.":
                // Freenode
                // :NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.
                return true;

            default:
                // drop down to test generic (NickServ || services)
                break;
            }

            break;

        case "services":
            // :NickServ!services@services.unrealircd.org NOTICE kameloso :Nick kameloso isn't registered.
            switch (address)
            {
            case "services.unrealircd.org":
            case "services.irchighway.net":
            case "swiftirc.net":
                return true;

            default:
                logger.warning("Unhandled *NickServ!services* address, " ~
                    "can't tell if special");
                break;
            }

            // drop down to test generic (NickServ || services)
            break;

        case "service":
            switch (address)
            {
            case "rizon.net":
            case "dal.net":
                // :NickServ!service@rizon.net NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,
                return true;

            default:
                logger.warning("Unhandled *NickServ!service* address, " ~
                    "can't tell if special");
                logger.trace(event.raw);
                return false;
            }

        default:
            logger.warning("Unhandled *NickServ* ident, " ~
                "can't tell if special");
            logger.trace(event.raw);
            return false;
        }

        // Can only be here if we dropped down
        assert((ident == "NickServ") || (ident == "services"));

        if (bot.server.resolvedAddress.endsWith(address))
        {
            //logger.info("Sensible guess that it's the real NickServ");
            return true; // sensible
        }
        else
        {
            //logger.info("Naïve guess that it's the real NickServ");
            return true;  // NAÏVE
        }

    case "Q":
        // :Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.
        return ((ident == "TheQBot") && (address == "CServe.quakenet.org"));

    case "AuthServ":
        // :AuthServ!AuthServ@Services.GameSurge.net NOTICE kameloso :Could not find your account
        return ((ident == "AuthServ") && (address == "Services.GameSurge.net"));

    default:
        // Not a known nick registration nick
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
        raw = ":NickServ!service@rizon.net NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,";
        string slice = raw[1..$];
        parser.parsePrefix(e3, slice);
        assert(parser.isFromAuthService(e3));
    }

    IRCEvent e4;
    with (e4)
    {
        raw = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp";
        string slice = raw[1..$];
        parser.parsePrefix(e4, slice);
        assert(parser.isFromAuthService(e4));
    }
}


/// Checks whether a string *looks* like a channel.
bool isValidChannel(const string line, const IRCServer server)
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

    if ((line.length <= 1) || (line.length > server.maxChannelLength))
    {
        return false;
    }

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
    IRCServer s;
    assert("#channelName".isValidChannel(s));
    assert("&otherChannel".isValidChannel(s));
    assert("##freenode".isValidChannel(s));
    assert(!"###froonode".isValidChannel(s));
    assert(!"#not a channel".isValidChannel(s));
    assert(!"notAChannelEither".isValidChannel(s));
    assert(!"#".isValidChannel(s));
    assert(!"".isValidChannel(s));
}


/// Checks if a string *looks* like a nickname.
bool isValidNickname(const string nickname, const IRCServer server)
{
    import std.regex : ctRegex, matchAll;
    import std.string : representation;

    // allowed in nicks: [a-z] [A-Z] [0-9] _-\[]{}^`|

    if (!nickname.length || (nickname.length > server.maxNickLength))
    {
        return false;
    }

    enum validCharactersPattern = r"^([a-zA-Z0-9_\\\[\]{}\^`|-]+)$";
    static engine = ctRegex!validCharactersPattern;

    return !nickname.matchAll(engine).empty;
}

unittest
{
    import std.range : repeat;
    import std.conv : to;

    IRCServer s;

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
            // recurse, since the server may have the multi-prefix capability
            return stripModeSign(nickname[1..$]);

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


// networkOf
/++
 +  Tries to guess the network of an IRC server based on its address.
 +
 +  This is done early on before connecting. After registering, we can (usually)
 +  get the correct answer from the RPL_ISUPPORT event (NETWORK tag).
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
            ".efnet.org"      : efnet,
            ".ircnet.org"     : ircnet,
            ".swiftirc.net"   : swiftirc,
            ".SwiftIRC.net"   : swiftirc,
            ".irchighway.net" : irchighway,
            ".dal.net"        : dalnet,
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


string nickServiceOf(const IRCServer.Network network)
{
    with (IRCServer.Network)
    {
        static immutable string[14] netmap =
        [
            unknown    : "NickServ",
            unfamiliar : "NickServ",
            freenode   : "NickServ",
            rizon      : "NickServ",
            quakenet   : "Q@CServe.quakenet.org",
            undernet   : string.init,
            gamesurge  : "AuthServ@Services.GameSurge.net",
            twitch     : string.init,
            unreal     : "NickServ",
            efnet      : string.init,
            ircnet     : string.init,
            swiftirc   : "NickServ",
            irchighway : "NickServ",
            dalnet     : "NickServ@services.dal.net",
        ];

        return netmap[network];
    }
}

unittest
{
    import std.conv : to;

    IRCParser parser;

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

    /+
    [RPL_WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = parser.toIRCEvent(":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^");
    with (e3)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.RPL_WELCOME), type.to!string);
        assert((target.nickname == "kameloso^"), target.nickname);
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
        assert((target.login == "zorael"), target.login);
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
    [CHANMODE] zorael (kameloso^) [#flerrp] <+v>
    :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
     +/
     immutable e11 = parser.toIRCEvent(":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^");
     with (e11)
     {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.CHANMODE), type.to!string);
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
        assert((aux == "3705964477"), aux);
        assert((content == "PONG"), content);
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

    /+
    :tmi.twitch.tv HOSTTARGET #lirik :h1z1 -
    +/
    immutable e18 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :h1z1 -");
    with (e18)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTSTART), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((content == "h1z1"), content);
        assert((!aux.length), aux);
    }

    /+
    :tmi.twitch.tv HOSTTARGET #hosting_channel :- [<number-of-viewers>]
    +/
    immutable e19 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :- 178");
    with (e19)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTEND), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((aux == "178"), aux);
    }

    /+
    :tmi.twitch.tv HOSTTARGET #lirik chu8 270
    +/
    immutable e20 = parser.toIRCEvent(":tmi.twitch.tv HOSTTARGET #lirik :chu8 270");
    with (e20)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTSTART), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((content == "chu8"), content);
        assert((aux == "270"), aux);
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
        assert(parser.bot.updated);
        assert((parser.bot.nickname == "kameloso_"), parser.bot.nickname);
    }
}


struct IRCParser
{
    alias Type = IRCEvent.Type;
    alias Daemon = IRCServer.Daemon;

    IRCBot bot;

    //Daemon serverDaemon;

    Type[1024] typenums = Typenums.base;

    IRCEvent toIRCEvent(const string raw)
    {
        return .toIRCEvent(this, raw);
    }

    this(IRCBot bot)
    {
        this.bot = bot;
    }

    @disable this(this);

    /*Daemon daemon() const @property
    {
        return serverDaemon;
    }*/

    void daemon(const Daemon daemon) @property
    {
        import kameloso.common;

        /// https://upload.wikimedia.org/wikipedia/commons/d/d5/IRCd_software_implementations3.svg

        // Reset
        typenums = Typenums.base;
        //this.serverDaemon = daemon;
        bot.server.daemon = daemon;
        bot.updated = true;

        with (Typenums)
        with (Daemon)
        final switch (daemon)
        {
        case unreal:
            Typenums.unreal.meldInto(typenums);
            break;

        case inspircd:
            Typenums.inspIRCd.meldInto(typenums);
            break;

        case bahamut:
            Typenums.bahamut.meldInto(typenums);
            break;

        case ratbox:
            Typenums.ratBox.meldInto(typenums);
            break;

        case u2:
            // unknown!
            break;

        case rizon:
            Typenums.hybrid.meldInto(typenums);
            Typenums.rizon.meldInto(typenums);
            break;

        case hybrid:
            Typenums.hybrid.meldInto(typenums);
            break;

        case ircu:
            Typenums.ircu.meldInto(typenums);
            break;

        case aircd:
            Typenums.aircd.meldInto(typenums);
            break;

        case rfc1459:
            Typenums.rfc1459.meldInto(typenums);
            break;

        case rfc2812:
            Typenums.rfc2812.meldInto(typenums);
            break;

        case quakenet:
            Typenums.quakenet.meldInto(typenums);
            break;

        case nefarious:
            Typenums.nefarious.meldInto(typenums);
            break;

        case rusnet:
            Typenums.rusnet.meldInto(typenums);
            break;

        case austhex:
            Typenums.austHex.meldInto(typenums);
            break;

        case ircnet:
            Typenums.ircNet.meldInto(typenums);
            break;

        case ptlink:
            Typenums.ptlink.meldInto(typenums);
            break;

        case ultimate:
            Typenums.ultimate.meldInto(typenums);
            break;

        case charybdis:
            Typenums.charybdis.meldInto(typenums);
            break;

        case ircdseven:
            // Nei | freenode is based in charybdis which is based on ratbox iirc
            Typenums.hybrid.meldInto(typenums);
            Typenums.ratBox.meldInto(typenums);
            Typenums.charybdis.meldInto(typenums);
            break;

        case undernet:
            Typenums.undernet.meldInto(typenums);
            break;

        case anothernet:
            //Typenums.anothernet.meldInto(typenums);
            break;

        case sorircd:
            //Typenums.sorircd.meldInto(typenums);
            break;

        case bdqircd:
            //Typenums.bdqIrcD.meldInto(typenums);
            break;

        case chatircd:
            //Typenums.chatIRCd.meldInto(typenums);
            break;

        case irch:
            //Typenums.irch.meldInto(typenums);
            break;

        case ithildin:
            //Typenums.ithildin.meldInto(typenums);
            break;

        case twitch:
            // do nothing, their events aren't numerical?
            break;

        case unknown:
            // do nothing...
            break;
        }
    }
}

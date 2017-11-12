module kameloso.irc;

import kameloso.common;
import kameloso.constants;
import kameloso.stringutils : nom;

import std.format : format, formattedRead;
import std.string : indexOf;
import std.stdio;

@safe:

private:

/// Max nickname length as per IRC specs, but not the de facto standard
uint maxNickLength = 9;

/// Max channel name length as per IRC specs
uint maxChannelLength = 200;


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
void parseBasic(ref IRCEvent event, ref IRCBot bot) @trusted
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
        import std.string : stripRight;
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

        if (event.raw.beginsWith('@'))
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
            event = toIRCEvent(raw, bot);
            event.tags = tags;
            event.parseTwitchTags(bot);  // FIXME: support any IRCv3 server
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

    IRCBot bot;

    IRCEvent e1;
    with (e1)
    {
        raw = "PING :irc.server.address";
        e1.parseBasic(bot);
        assert((type == IRCEvent.Type.PING), type.to!string);
        assert((sender.address == "irc.server.address"), sender.address);
        assert(!sender.nickname.length, sender.nickname);
    }

    IRCEvent e2;
    with (e2)
    {
        // QuakeNet and others not having the sending server as prefix
        raw = "NOTICE AUTH :*** Couldn't look up your hostname";
        e2.parseBasic(bot);
        assert((type == IRCEvent.Type.NOTICE), type.to!string);
        assert(!sender.nickname.length, sender.nickname);
        assert((content == "*** Couldn't look up your hostname"));
    }

    IRCEvent e3;
    with (e3)
    {
        raw = "ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)";
        e3.parseBasic(bot);
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
void parsePrefix(ref IRCEvent event, ref IRCBot bot, ref string slice)
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

    IRCBot bot;

    IRCEvent e1;
    with (e1)
    with (e1.sender)
    {
        raw = ":zorael!~NaN@some.address.org PRIVMSG kameloso :this is fake";
        string slice1 = raw[1..$];  // mutable
        e1.parsePrefix(bot, slice1);
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
        e2.parsePrefix(bot, slice2);
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
        e3.parsePrefix(bot, slice3);
        assert((nickname == "kameloso^^"), nickname);
        assert((ident == "~NaN"), ident);
        assert((address == "C2802314.E23AD7D8.E9841504.IP"), address);
        assert(!special);
    }

    IRCEvent e4;
    with (e4)
    with (e4.sender)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice4 = raw[1..$];
        e4.parsePrefix(bot, slice4);
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
void parseTypestring(ref IRCEvent event, ref IRCBot bot, ref string slice)
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
            event.type = IRCEvent.typenums[number];

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

    IRCBot bot;

    IRCEvent e1;
    with (e1)
    {
        raw = /*":port80b.se.quakenet.org */"421 kameloso åäö :Unknown command";
        string slice = raw;  // mutable
        e1.parseTypestring(bot, slice);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((num == 421), num.to!string);
    }

    IRCEvent e2;
    with (e2)
    {
        raw = /*":port80b.se.quakenet.org */"353 kameloso = #garderoben :@kameloso'";
        string slice = raw;  // mutable
        e2.parseTypestring(bot, slice);
        assert((type == IRCEvent.Type.RPL_NAMREPLY), type.to!string);
        assert((num == 353), num.to!string);
    }

    IRCEvent e3;
    with (e3)
    {
        raw = /*":zorael!~NaN@ns3363704.ip-94-23-253.eu */"PRIVMSG kameloso^ :test test content";
        string slice = raw;
        e3.parseTypestring(bot, slice);
        assert((type == IRCEvent.Type.PRIVMSG), type.to!string);
    }

    IRCEvent e4;
    with (e4)
    {
        raw = /*`:zorael!~NaN@ns3363704.ip-94-23-253.eu */`PART #flerrp :"WeeChat 1.6"`;
        string slice = raw;
        e4.parseTypestring(bot, slice);
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
 +  long but by neccessity. An alternative is to break out stuff into:
 +
 +  -------------
 +  case NOTICE:
 +      onNotice(event);
 +      break;
 +  -------------
 +
 +  This might not be a dumb idea, it just hasn't been done.
 +
 +  The IRCEvent is finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IRCEvent to finish working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseSpecialcases(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
    import kameloso.stringutils;

    scope(failure)
    {
        logger.warning("--------- PARSE SPECIALCASES FAILURE");
        printObject(event);
        logger.warning("------------------------------------");
    }

    with (IRCEvent)
    with (IRCEvent.Type)
    switch (event.type)
    {
    case NOTICE:
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflow] Make sure your nick is registered, then please try again to join ##linux.
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.
        // :tolkien.freenode.net NOTICE * :*** Checking Ident

        //slice.formattedRead("%s :%s", event.target, event.content);
        //event.target.nickname = slice.nom(" :");
        slice.nom(" :");
        event.content = slice;

        // FIXME: This obviously doesn't scale either
        /*if (event.target.nickname == "*") event.target.nickname = string.init;
        else*/
        if ((event.sender.ident == "service") && (event.sender.address == "rizon.net"))
        {
            event.sender.special = true;
        }

        if (!bot.server.resolvedAddress.length && event.content.beginsWith("***"))
        {
            bot.server.resolvedAddress = event.sender.nickname;
            bot.updated = true;
        }

        if (event.isFromAuthService(bot))
        {
            event.sender.special = true;  // by definition

            if ((event.content.indexOf("/msg NickServ IDENTIFY") != -1) ||
                (event.content.indexOf("/msg NickServ identify") != -1))
            {
                event.type = AUTH_CHALLENGE;
                break;
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
                    type = AUTH_SUCCESS;

                    // Restart with the new type
                    return parseSpecialcases(event, bot, slice);
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
                    event.type = AUTH_FAILURE;
                }
            }
        }
        break;

    case JOIN:
        // :nick!~identh@unaffiliated/nick JOIN #freenode login :realname
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com JOIN #flerrp
        // :kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp

        import std.string : munch, strip;

        event.type = (event.sender.nickname == bot.nickname) ? SELFJOIN : JOIN;

        if (slice.indexOf(' ') != -1)
        {
            // :nick!user@host JOIN #channelname accountname :Real Name
            // :nick!user@host JOIN #channelname * :Real Name
            // :nick!~identh@unaffiliated/nick JOIN #freenode login :realname
            event.channel = slice.nom(' ');
            event.sender.login = slice.nom(" :");
            if (event.sender.login == "*") event.sender.login = string.init;
            event.content = slice.strip();
        }
        else
        {
            event.channel = slice;
            event.channel.munch(":");
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
        event.content = slice[1..$];

        if (event.sender.nickname == bot.nickname)
        {
            event.type = SELFNICK;
            bot.nickname = event.content;
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
        // FIXME, change so that it assigns to the proper field

        immutable targetOrChannel = slice.nom(" :");
        event.content = slice;

        if (targetOrChannel.isValidChannel)
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :test test content
            event.type = CHAN;
            event.channel = targetOrChannel;
        }
        else
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :test test content
            event.type = QUERY;
            event.target.nickname = targetOrChannel;
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
                        mixin("event.type = " ~ typestring ~ ";");
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
                //slice.formattedRead("%s %s", event.aux, event.target);
                event.aux = slice.nom(' ');
                event.target.nickname = slice;
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
            //event.target.nickname = targetOrChannel;
            event.aux = slice[1..$];
        }
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
        //slice.formattedRead("%s %s :%s", event.target, event.channel, event.content);
        //event.target.nickname = slice.nom(' ');<
        slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_NAMREPLY: // 353
        import std.string : stripRight;
        // :asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');
        slice.nom(' ');
        //slice.formattedRead("%s :%s", event.channel, event.content);
        event.channel = slice.nom(" :");
        event.content = slice.stripRight();
        //event.content = event.content.stripRight();
        break;

    case RPL_MOTD: // 372
    case RPL_LUSERCLIENT: // 251
        // :asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor
        //slice.formattedRead("%s :%s", event.target, event.content);
        //event.target.nickname = slice.nom(" :");
        slice.nom(" :");
        event.content = slice;
        break;

    case RPL_ISUPPORT: // 004-005
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

                    logger.info("Detected network: ", thisNetwork);

                    if (thisNetwork != bot.server.network)
                    {
                        // Propagate change
                        bot.server.network = thisNetwork;
                        bot.updated = true;
                    }
                }
                catch (const Exception e)
                {
                    logger.error(e.msg);
                }
                break;

            case "NICKLEN":
                try maxNickLength = value.to!uint;
                catch (const Exception e)
                {
                    logger.error(e.msg);
                }
                break;

            case "CHANNELLEN":
                try maxChannelLength = value.to!uint;
                catch (const Exception e)
                {
                    logger.error(e.msg);
                }
                break;

            default:
                break;
            }
        }

        with (bot.server)
        if (network == Network.init)
        {
            logger.info("No network detected, guessing...");
            network = networkOf(address);
            logger.info(network, "?");
        }

        break;

    case TOPICSETTIME: // 333
        // :asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377
        /*slice.formattedRead("%s %s %s %s", event.target, event.channel,
                            event.content, event.aux);*/
        //event.target.nickname = slice.nom(' ');
        slice.nom(' ');
        event.channel = slice.nom(' ');
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case CONNECTINGFROM: // 378
        //:wilhelm.freenode.net 378 kameloso^ kameloso^ :is connecting from *@81-233-105-62-no80.tbcn.telia.com 81.233.105.62
        slice.nom(' ');

        /*slice.formattedRead("%s :is connecting from *@%s %s",
                            event.target, event.content, event.aux);*/
        // can this happen with others as target?
        event.target.nickname = slice.nom(" :is connecting from *@");
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
        import std.string : stripLeft;

        slice.nom(' ');
        event.target.nickname = slice.nom(' ');
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

    case WHOISLOGIN: // 330
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        slice.nom(' ');
        //slice.formattedRead("%s %s :%s", event.target, event.aux, event.content);
        event.target.nickname = slice.nom(' ');
        event.target.login = slice.nom(" :");
        event.content = slice;
        break;

    case HASTHISNICK: // 307
        // :irc.x2x.cc 307 kameloso^^ py-ctcp :has identified for this nick
        // :irc.x2x.cc 307 kameloso^^ wob^2 :has identified for this nick
        slice.nom(' '); // bot nick
        event.target.nickname = slice.nom(" :");
        //event.aux = event.target.nickname;
        event.content = slice;
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

    case WELCOME: // 001
        // :adams.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
        //slice.formattedRead("%s :%s", event.target, event.content);
        event.target.nickname = slice.nom(" :");
        event.content = slice;
        bot.nickname = event.target.nickname;
        bot.updated = true;
        break;

    case TOCONNECTTYPE: // 513
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

    case HELP_TOPICS: // 704
    case HELP_ENTRIES: // 705
    case HELP_END: // 706
        // :leguin.freenode.net 704 kameloso^ index :Help topics available to users:
        // :leguin.freenode.net 705 kameloso^ index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        // :leguin.freenode.net 706 kameloso^ index :End of /HELP.
        //slice.formattedRead("%s :%s", event.aux, event.content);
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case CANTCHANGENICK: // 435
        // :cherryh.freenode.net 435 kameloso^ kameloso^^ #d3d9 :Cannot change nickname while banned on channel
        /*slice.formattedRead("%s %s %s :%s", event.target, event.aux,
                            event.channel, event.content);*/
        event.target.nickname = slice.nom(' ');
        event.aux = slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case CAP:
        import std.string : stripRight;

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
        event.content = slice.stripRight();
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
        // This should rarely if ever trigger

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
        }
        else
        {
            event.channel = slice;
        }

        event.role = Role.SERVER;  // FIXME
        break;

    case AUTH_SUCCESS:
    case SASL_SUCCESS:
        // :weber.freenode.net 900 kameloso kameloso!NaN@194.117.188.126 kameloso :You are now logged in as kameloso.
        // :weber.freenode.net 903 kameloso :SASL authentication successful
        // :Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.
        if (event.target.nickname.indexOf(' ') != -1)
        {
            event.target.nickname = bot.nickname;
        }

        break;

    case YOURHIDDENHOST:
        // :TAL.DE.EU.GameSurge.net 396 kameloso ~NaN@1b24f4a7.243f02a4.5cd6f3e3.IP4 :is now your hidden host
        slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice;
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
            event.target.nickname = slice.nom(" :");
            event.content = slice;
        }
        else
        {
            // :port80b.se.quakenet.org 221 kameloso +i
            //slice.formattedRead("%s %s", event.target, event.aux);
            event.target.nickname = slice.nom(' ');
            event.aux = slice;
        }

        import std.algorithm.searching : endsWith;

        if (event.content.endsWith(" "))
        {
            import std.string : stripRight;
            event.content = event.content.stripRight(); // wise?
        }

        break;
    }

    postparseSanityCheck(event, bot);
}


// postparseSanityCheck
/++
 +  Checks for some specific erroneous edge cases in an IRCEvent, complains
 +  about all of them and corrects some.
 +
 +  Params:
 +      ref event = the IRC event to examine.
 +/
void postparseSanityCheck(ref IRCEvent event, const IRCBot bot)
{
    import kameloso.stringutils : beginsWith;

    if ((event.type != IRCEvent.Type.CHANMODE) &&
        (event.type != IRCEvent.Type.TOPIC) &&
        ((event.target.nickname.indexOf(' ') != -1) ||
        (event.channel.indexOf(' ') != -1)))
    {
        writeln();
        logger.warning("-- SPACES IN NICK/CHAN, NEEDS REVISION");
        printObject(event);
        logger.warning("--------------------------------------");
        writeln();
    }

    if (event.target.nickname.beginsWith('#'))
    {
        writeln();
        logger.warning("------ TARGET NICKNAME IS A CHANNEL?");
        printObject(event);
        logger.warning("------------------------------------");
        writeln();
    }

    if (event.target.nickname == bot.nickname)
    {
        with (IRCEvent.Type)
        switch (event.type)
        {
        case MODE:
        case CHANMODE:
        case WELCOME:
        case QUERY:
        case JOIN:
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
void parseTwitchTags(ref IRCEvent event, ref IRCBot bot)
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
            event.aux = (tag.length) ? tag : "PERMANENT";
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

            default:
                logger.info("unhandled message: ", tag);
                break;
            }
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

public:


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
        bool updated;
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
        dalnet,
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
}


/// An aggregate of string fields that represents a single user.
struct IRCUser
{
    string nickname;
    string alias_;
    string ident;
    string address;
    string login;
    bool special;

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : formattedWrite;

        sink.formattedWrite("%s:%s!~%s@%s%s",
            nickname, login, ident, address, special ? " (*)" : string.init);
    }

    bool isServer() @property const
    {
        return (!nickname.length && (address.indexOf('.') != -1));
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
        USERSTATE, ROOMSTATE, GLOBALUSERSTATE,
        CLEARCHAT, USERNOTICE, HOSTTARGET,
        HOSTSTART, HOSTEND,
        SASL_AUTHENTICATE,
        SUB, RESUB,
        AUTH_CHALLENGE,
        AUTH_FAILURE,
        AUTH_SUCCESS, // = 900          // <nickname>!<ident>@<address> <nickname> :You are now logged in as <nickname>
        SASL_SUCCESS, // = 903          // :cherryh.freenode.net 903 kameloso^ :SASL authentication successful
        SASL_FAILURE, // = 904          // :irc.rizon.no 904 kameloso^^ :SASL authentication failed"
        SASL_ABORTED, // = 906          // :orwell.freenode.net 906 kameloso^ :SASL authentication aborted
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
        900 : Type.AUTH_SUCCESS,
        903 : Type.SASL_SUCCESS,
        904 : Type.SASL_FAILURE,
        906 : Type.SASL_ABORTED,
    ];

    enum Role
    {
        UNSET,
        OTHER,
        MEMBER,
        BITS,
        TURBO,
        SUBSCRIBER,
        PREMIUM,
        PARTNER,
        MOD,
        OPERATOR,
        BROADCASTER,
        ADMIN,
        GLOBAL_MOD,
        STAFF,
        SERVER,
    }

    /// The event type, signifying what *kind* of event this is.
    Type type;

    /// The role of the sender in this context
    Role role;

    /// The raw IRC string, untouched.
    string raw;

    /// The name of whoever (or whatever) sent this event.
    IRCUser sender;

    /// The IDENT identification of the sender.
    //string ident;

    /// The address of the sender.
    //string address;

    /// The channel the event transpired in, or is otherwise related to.
    string channel;

    /// The target of the event. May be a nickname or a channel.
    IRCUser target;

    /// The main body of the event.
    string content;

    /// The auxiliary storage, containing type-specific extra bits of information.
    string aux;

    /// The role in string form, may be of other values than the enum provides.
    string rolestring;

    /// The colour (RRGGBB) to tint the user's nickname with
    string colour;

    /// IRCv3 message tags attached to this event.
    string tags;

    /// With a numeric event, the number of the event type.
    uint num;

    /// A flag that we set when we're sure the event originated from the server or its services.
    //bool special;

    /// A timestamp of when the event occured.
    long time;
}


struct IRCChannel
{
    string name;

    string topic;
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
IRCEvent toIRCEvent(const string raw, ref IRCBot bot)
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
            parseBasic(event, bot);
            return event;
        }

        auto slice = event.raw[1..$]; // advance past first colon

        // First pass: prefixes. This is the sender
        parsePrefix(event, bot, slice);

        // Second pass: typestring. This is what kind of action the event is of
        parseTypestring(event, bot, slice);

        // Third pass: specialcases. This splits up the remaining bits into
        // useful strings, like sender, target and content
        parseSpecialcases(event, bot, slice);
    }
    catch (const Exception e)
    {
        logger.error(e.msg);
    }

    return event;
}


/// This simply looks at an event and decides whether it is from a nickname
/// registration service.
bool isFromAuthService(const IRCEvent event, ref IRCBot bot)
{
    import std.algorithm.searching : endsWith;

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
            logger.info("Sensible guess that it's the real NickServ");
            return true; // sensible
        }
        else
        {
            logger.info("Naïve guess that it's the real NickServ");
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
    IRCBot bot;

    IRCEvent e1;
    with (e1)
    {
        raw = ":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
        string slice = raw[1..$];  // mutable
        e1.parsePrefix(bot, slice);
        assert(e1.isFromAuthService(bot));
    }

    IRCEvent e2;
    with (e2)
    {
        raw = ":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
        string slice = raw[1..$];
        e2.parsePrefix(bot, slice);
        assert(e2.isFromAuthService(bot));
    }

    IRCEvent e3;
    with (e3)
    {
        raw = ":NickServ!service@rizon.net NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,";
        string slice = raw[1..$];
        e3.parsePrefix(bot, slice);
        assert(e3.isFromAuthService(bot));
    }

    IRCEvent e4;
    with (e4)
    {
        raw = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp";
        string slice = raw[1..$];
        e4.parsePrefix(bot, slice);
        assert(!e4.isFromAuthService(bot));
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

    return !nickname.matchAll(engine).empty;
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

unittest
{
    import std.conv : to;

    IRCBot bot;

    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    immutable e1 = ":tepper.freenode.net NOTICE * :*** Checking Ident"
                   .toIRCEvent(bot);
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
    immutable e2 = ":tepper.freenode.net 433 * kameloso :Nickname is already in use."
                   .toIRCEvent(bot);
    with (e2)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_NICKNAMEINUSE), type.to!string);
        assert((content == "Nickname is already in use."), content);
        assert((num == 433), num.to!string);
    }

    /+
    [WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = ":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^"
                   .toIRCEvent(bot);
    with (e3)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.WELCOME), type.to!string);
        assert((target.nickname == "kameloso^"), target.nickname);
        assert((content == "Welcome to the freenode Internet Relay Chat Network kameloso^"),
               content);
        assert((num == 1), num.to!string);
    }

    /+
    [RPL_ENDOFMOTD] tepper.freenode.net (kameloso^): "End of /MOTD command." (#376)
    :tepper.freenode.net 376 kameloso^ :End of /MOTD command.
     +/
    immutable e4 = ":tepper.freenode.net 376 kameloso^ :End of /MOTD command."
                   .toIRCEvent(bot);
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
    immutable e5 = ":kameloso^ MODE kameloso^ :+i".toIRCEvent(bot);
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
    immutable e6 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp"
                   .toIRCEvent(bot);
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
    immutable e7 = ":tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr"
                   .toIRCEvent(bot);
    with (e7)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
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
                   .toIRCEvent(bot);
    with (e8)
    {
        assert((sender.address == "tepper.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.WHOISLOGIN), type.to!string);
        assert((target.nickname == "zurael"), target.nickname);
        assert((content == "is logged in as"), content);
        assert((target.login == "zorael"), target.login);
        assert((num == 330), num.to!string);
    }

    /+
    [PONG] tepper.freenode.net
    :tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net
     +/
    immutable e9 = ":tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net"
                   .toIRCEvent(bot);
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
    immutable e10 = (":wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de " ~
                     "QUIT :Remote host closed the connection")
                     .toIRCEvent(bot);
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
     immutable e11 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^"
                     .toIRCEvent(bot);
     with (e11)
     {
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((type == IRCEvent.Type.CHANMODE), type.to!string);
        assert((target.nickname == "kameloso^"), target.nickname);
        assert((channel == "#flerrp"), channel);
        assert((aux == "+v"), aux);
     }

     /+
     [17:10:44] [NUMERIC] irc.uworld.se (kameloso): "To connect type /QUOTE PONG 3705964477" (#513)
     :irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477
     +/
     immutable e12 = ":irc.uworld.se 513 kameloso :To connect type /QUOTE PONG 3705964477"
                     .toIRCEvent(bot);
     with (e12)
     {
        assert((sender.address == "irc.uworld.se"), sender.address);
        assert((type == IRCEvent.Type.TOCONNECTTYPE), type.to!string);
        assert((target.nickname == "kameloso"), target.nickname);
        assert((aux == "3705964477"), aux);
        assert((content == "PONG"), content);
     }

    /+
    [20:55:14] [ERR_UNKNOWNCOMMAND] karatkievich.freenode.net (kameloso^) <systemd,#kde,#kubuntu,#archlinux, ...>
    :karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ...
    +/
    immutable e13 = ":karatkievich.freenode.net 421 kameloso^ systemd,#kde,#kubuntu,#archlinux ..."
                    .toIRCEvent(bot);
    with (e13)
    {
        assert((sender.address == "karatkievich.freenode.net"), sender.address);
        assert((type == IRCEvent.Type.ERR_UNKNOWNCOMMAND), type.to!string);
        assert((content == "systemd,#kde,#kubuntu,#archlinux ..."), content);
    }

    /+
    :asimov.freenode.net 421 kameloso^ sudo :Unknown command
    +/
    immutable e14 = ":asimov.freenode.net 421 kameloso^ sudo :Unknown command"
                    .toIRCEvent(bot);
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
    immutable e15 = (":wob^2!~zorael@2A78C947:4EDD8138:3CB17EDC:IP PRIVMSG kameloso^^ :" ~
                     IRCControlCharacter.ctcp ~ "PING 1495974267 590878" ~
                     IRCControlCharacter.ctcp).toIRCEvent(bot);
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
    immutable e16 = ":beLAban!~beLAban@onlywxs PRIVMSG ##networking :start at cpasdcas"
                    .toIRCEvent(bot);
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
    immutable e17 = (":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :" ~
                     IRCControlCharacter.ctcp ~ "ACTION 123 test test content" ~
                     IRCControlCharacter.ctcp).toIRCEvent(bot);
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
    immutable e18 = ":tmi.twitch.tv HOSTTARGET #lirik :h1z1 -".toIRCEvent(bot);
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
    immutable e19 = ":tmi.twitch.tv HOSTTARGET #lirik :- 178".toIRCEvent(bot);
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
    immutable e20 = ":tmi.twitch.tv HOSTTARGET #lirik :chu8 270"
                    .toIRCEvent(bot);
    with (e20)
    {
        assert((sender.address == "tmi.twitch.tv"), sender.address);
        assert((type == IRCEvent.Type.HOSTSTART), type.to!string);
        assert((channel == "#lirik"), channel);
        assert((content == "chu8"), content);
        assert((aux == "270"), aux);
    }

}

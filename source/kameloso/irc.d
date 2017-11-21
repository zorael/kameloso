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
void parseSpecialcases(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
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

void onNotice(ref IRCEvent event, ref IRCBot bot, ref string slice)
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
                event.type = IRCEvent.Type.AUTH_FAILURE;
            }
        }
    }

    // FIXME: support
    // *** If you are having problems connecting due to ping timeouts, please type /quote PONG j`ruV\rcn] or /raw PONG j`ruV\rcn] now.
}


void onPRIVMSG(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
    import kameloso.stringutils : beginsWith;

    // FIXME, change so that it assigns to the proper field

    immutable targetOrChannel = slice.nom(" :");
    event.content = slice;

    if (targetOrChannel.isValidChannel)
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
}


void onMode(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
    immutable targetOrChannel = slice.nom(' ');

    if (targetOrChannel.isValidChannel)
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


void onISUPPORT(ref IRCEvent event, ref IRCBot bot, ref string slice)
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

                logger.info("Detected network: ", value);

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
        network = networkOf(address);
        if (network != Network.init)
        {
            logger.info("Network: ", network, "?");
        }
    }
}

void onMyInfo(ref IRCEvent event, ref IRCBot bot, ref string slice)
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

    slice.nom(' ');  // server address
    immutable daemonstringRaw = slice.nom(' ');
    immutable daemonstring = daemonstringRaw.toLower();
    event.content = slice;
    event.aux = daemonstringRaw;

    with (IRCServer.Daemon)
    with (IRCEvent)
    {
        Type[1024] mod;

        if (daemonstring.indexOf("unreal") != -1)
        {
            bot.server.daemon = unreal;
            IRCEvent.setTypenums(unreal);
        }
        else if (daemonstring.indexOf("inspircd") != -1)
        {
            bot.server.daemon = inspircd;
            IRCEvent.setTypenums(inspircd);
        }
        else if (daemonstring.indexOf("u2.") != -1)
        {
            bot.server.daemon = u2;
            IRCEvent.setTypenums(u2);
        }
        else if (daemonstring.indexOf("bahamut") != -1)
        {
            bot.server.daemon = bahamut;
            IRCEvent.setTypenums(bahamut);
        }
        else if (daemonstring.indexOf("hybrid") != -1)
        {
            bot.server.daemon = hybrid;
            IRCEvent.setTypenums(hybrid);
        }
        else if (daemonstring.indexOf("ratbox") != -1)
        {
            bot.server.daemon = ratbox;
            IRCEvent.setTypenums(ratbox);
        }
        else if (daemonstring.indexOf("charybdis") != -1)
        {
            bot.server.daemon = charybdis;
            IRCEvent.setTypenums(charybdis);
        }
        /*else if (daemonstring.indexOf("ircd-seven") != -1)
        {
            // Freenode
            IRCEvent.setTypenums(FIXME);
        }*/
        /*else if (daemonstring.indexOf("") != -1)
        {
            IRCEvent.setTypenums();
        }*/
    }
}

public:

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
    [RPL_WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    immutable e3 = ":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^"
                   .toIRCEvent(bot);
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
    immutable e8 = ":tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as"
                   .toIRCEvent(bot);
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
        assert((content == "kameloso^"), content);
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
        assert((type == IRCEvent.Type.ERR_BADPING), type.to!string);
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

    immutable e21 = ":kameloso_!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso__"
                    .toIRCEvent(bot);
    with (e21)
    {
        assert((sender.nickname == "kameloso_"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.NICK), type.to!string);
        assert((target.nickname == "kameloso__"), target.nickname);
    }

    IRCBot bot2 = bot;

    assert((bot2.nickname == "kameloso^"), bot2.nickname);
    immutable e22 = ":kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_"
                    .toIRCEvent(bot2);
    with (e22)
    {
        assert((sender.nickname == "kameloso^"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "81-233-105-62-no80.tbcn.telia.com"), sender.address);
        assert((type == IRCEvent.Type.SELFNICK), type.to!string);
        assert((target.nickname == "kameloso_"), target.nickname);
        assert(bot2.updated);
        assert((bot2.nickname == "kameloso_"), bot2.nickname);
    }
}

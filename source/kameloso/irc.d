module kameloso.irc;

import kameloso.constants;
import kameloso.stringutils;
import kameloso.common;

public import kameloso.plugins.common;

import std.stdio  : writeln, writefln;
import std.format : format;
import std.algorithm.searching : canFind;
import std.algorithm.iteration : joiner;
import std.concurrency : Tid;


IrcBot bot;


/// A simple struct to collect all the relevant settings, options and state needed
struct IrcBot
{
    string nickname = "kameloso";
    string user     = "kameloso";
    string ident    = "NaN";
    string password;
    string master   = "zorael";
    @separator(",") string[] channels = [ "#flerrp", "#garderoben" ];
    @separator(",") string[] homes = [ "#flerrp", "#garderoben" ];
    @separator(",") string[] friends  = [ "klarrt", "maku" ];
    @transient string server;
    @transient bool registered;
    // @transient uint verbosity;
}


/// Likewise a collection of string fields that represents a single user
struct IrcUser
{
    string nickname, ident, address, login;
    bool special;
    // SysTime lastWhois;

    string toString()
    {
        return "[%s] ident:'%s' @ address:'%s' : login:'%s' (special:%s)"
               .format(nickname, ident, address, login, special);
    }
}


// userFromEvent
/++
 +  Takes an IrcEvent and builds an IrcUser from its fields.
 +
 +  Params:
 +      event = IrcEvent to extract an IrcUser out of.
 +
 +  Returns:
 +      A freshly generated IrcUser.
 +/
IrcUser userFromEvent(const IrcEvent event)
{
    IrcUser user;

    with (IrcEvent.Type)
    switch (event.type)
    {
    case RPL_WHOISUSER:
    case WHOISLOGIN:
        // These events are sent by the server, *describing* a user
        string content = event.content;
        user.nickname  = event.target;
        user.ident     = content.nom(' ');
        user.address   = content;
        user.login     = event.aux;
        user.special   = event.special;
        break;

    default:
        if (!event.sender.canFind('@'))
        {
            writefln("There was a server %s event and we naïvely tried to build a user from it");
            goto case WHOISLOGIN;
        }

        user.nickname = event.sender;
        user.ident    = event.ident;
        user.address  = event.address;
        user.special  = event.special;
        break;
    }

    return user;
}


/// This simply looks at an event and decides whether it is from NickServ
static bool isFromNickserv(const IrcEvent event)
{
    return event.special
        && (event.sender  == "NickServ")
        && (event.ident   == "NickServ")
        && (event.address == "services.");
}


// ConnectPlugin
/++
 +  A collection of functions and state needed to connect to an IRC server. This is mostly
 +  a matter of sending USER and NICK at the starting "handshake", but also incorporates
 +  logic to authenticate with NickServ.
 +/
final class ConnectPlugin : IrcPlugin
{
private:
    import core.thread;
    import std.concurrency : send;

    IrcBot bot;
    Tid mainThread;
    IrcUser[string] users;
    bool delegate()[string] queue;

    /// Makes a shared copy of the current IrcBot and sends it to the main thread for propagation
    void updateBot()
    {
        shared botCopy = cast(shared)bot;
        mainThread.send(botCopy);
    }

public:
    this(IrcBot bot, Tid tid)
    {
        mixin(scopeguard(entry, "Connect plugin"));
        this.bot = bot;
        this.mainThread = tid;
    }

    void newBot(IrcBot bot)
    {
        this.bot = bot;
    }

    // onEvent
    /++
     +  Called once for every IrcEvent generated. Whether the event is of interest to the plugin
     +  is up to the plugin itself to decide.
     +
     +  Params:
     +      event = The IrcEvent to react to.
     +/
    void onEvent(const IrcEvent event)
    {
        with (IrcEvent.Type)
        switch (event.type)
        {
        case NOTICE:
            if (!bot.registered && event.content.beginsWith("***"))
            {
                bot.registered = true;
                bot.server = event.sender;
                updateBot();

                mainThread.send(ThreadMessage.Sendline(),
                    "NICK %s".format(bot.nickname));
                mainThread.send(ThreadMessage.Sendline(),
                    "USER %s * 8 : %s".format(bot.ident, bot.user));
            }
            else if (event.isFromNickserv)
            {
                // There's no point authing if there's no bot password
                if (!bot.password.length) return;

                if (event.content.beginsWith(cast(string)NickServLines.challenge))
                {
                    mainThread.send(ThreadMessage.Sendline(),
                        "PRIVMSG NickServ@services. :IDENTIFY %s %s"
                        .format(bot.nickname, bot.password));
                }
                else if (event.content.beginsWith(cast(string)NickServLines.acceptance))
                {
                    if (!bot.channels.length) break;

                    mainThread.send(ThreadMessage.Sendline(),
                         "JOIN :%s".format(bot.channels.joiner(",")));
                }
            }
            break;

        case RPL_ENDOFMOTD:
            // FIXME: Deadlock if a password exists but there is no challenge
            if (bot.password.length) break;

            if (!bot.channels.length)
            {
                writeln("No channels to join...");
                break;
            }

            mainThread.send(ThreadMessage.Sendline(),
                "JOIN :%s".format(bot.channels.joiner(",")));
            break;

        case ERR_NICKNAMEINUSE:
            // FIXME: Could use SELFNICK instead
            bot.nickname ~= altNickSign;
            mainThread.send(ThreadMessage.Sendline(), "NICK %s".format(bot.nickname));
            updateBot();
            break;

        case SELFJOIN:
            writefln("Joined %s", event.channel);
            /*auto chanExists = bot.channels.canFind(event.channel);
            if (!chanExists)
            {
                bot.channels ~= event.channel;
            }
            updateBot();
            writeln(bot.channels);*/
            break;

        case SELFPART:
        case SELFKICK:
            writefln("Left %s", event.channel);
            /*bot.channels = bot.channels.remove(bot.channels.countUntil(event.channel));
            updateBot();
            writeln(bot.channels);*/
            break;

        default:
            break;
        }
    }

    /// ConnectPlugin has no functionality that needs tearing down
    void teardown() {}
}


// Pinger
/++
 +  The Pinger plugin simply sends a PING once every Timeout.ping.seconds. This is to workaround
 +  freenode's new behaviour of not actively PINGing clients, but rather waiting to PONG.
 +/
final class Pinger : IrcPlugin
{
    import std.concurrency : spawn, send;

    Tid mainThread, pingThread;

    void onEvent(const IrcEvent) {}

    void newBot(IrcBot) {}

    this(const IrcBot bot, Tid tid)
    {
        mixin(scopeguard((entry|failure), "Pinger plugin"));
        // Ignore bot
        mainThread = tid;

        // Spawn the pinger in a separate thread, to work concurrently with the rest
        pingThread = spawn(&pinger, tid);
    }

    /// Since the pinger runs in its own thread, it needs to be torn down when the plugin should reset
    void teardown()
    {
        try pingThread.send(ThreadMessage.Teardown());
        catch (Exception e)
        {
            writeln("Caught exception sending abort to pinger");
            writeln(e);
        }
    }
}


/// The pinging thread, spawned from Pinger
private void pinger(Tid mainThread)
{
    import std.concurrency;
    import core.time : seconds;

    mixin(scopeguard(failure));

    bool halt;

    while (!halt)
    {
        receiveTimeout(Timeout.ping.seconds,
            (ThreadMessage.Teardown t)
            {
                writeln("Pinger aborting due to ThreadMessage.Teardown");
                halt = true;
            },
            (OwnerTerminated e)
            {
                writeln("Pinger aborting due to owner terminated");
                halt = true;
            },
            (Variant v)
            {
                writefln("pinger received Variant: %s", v);
            }
        );

        if (!halt)
        {
            mainThread.send(ThreadMessage.Ping());
        }
    }
}


// IrcEvent
/++
 +  The IrcEvent struct is a parsed construct with fields extracted from raw server strings.
 +  Since structs are not polymorphic the Type enum dictates what kind of event it is.
 +/
struct IrcEvent
{
    /// Taken from https://tools.ietf.org/html/rfc1459 with some additions
    enum Type
    {
        UNSET, ERROR, NUMERIC,
        PRIVMSG, CHAN, QUERY, EMOTE, // ACTION
        JOIN, PART, QUIT, KICK, INVITE,
        NOTICE,
        PING, PONG,
        NICK,
        MODE, CHANMODE, USERMODE,
        SELFQUIT, SELFJOIN, SELFPART,
        SELFMODE, SELFNICK, SELFKICK,
        USERSTATS_1, // = 250           // "Highest connection count: <n> (<n> clients) (<m> connections received)"
        USERSTATS_2, // = 265           // "Current local users <n>, max <m>"
        USERSTATS_3, // = 266           // "Current global users <n>, max <m>"
        WELCOME, // = 001,              // ":Welcome to <server name> <user>"
        SERVERINFO, // = 002-003        // (server information)
        SERVERINFO_2, // = 004-005      // (server information, different syntax)
        TOPICSETTIME, // = 333          // "#channel user!~ident@address 1476294377"
        USERCOUNTLOCAL, // = 265        // "Current local users n, max m"
        USERCOUNTGLOBAL, // = 266       // "Current global users n, max m"
        CONNETCIONRECORD, // = 250      // "Highest connection count: n (m clients) (v connections received)"
        CHANNELURL, // = 328            // "http://linux.chat"
        WHOISSECURECONN, // = 671       // "<nickname> :is using a secure connection"
        WHOISLOGIN, // = 330            // "<nickname> <login> :is logged in as"
        CHANNELFORWARD, // = 470        // <#original> <#new> :Forwarding to another channel
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
        void generateTypenums()
        {
            static pattern = ctRegex!` *([A-Z0-9_]+), // = ([0-9]+).*`;

            writeln("static immutable Type[512] typenums = [");
            foreach (line; typeEnumAsString.splitter("\n"))
            {
                auto hits = line.matchFirst(pattern);
                if (hits.length < 2) {
                    continue;
                }
                writefln("    %s : Type.%s,", hits[2], hits[1]);
            }
            writeln("];");
        }
    */

    /// typenums is reverse mapping of Types to their numeric form, to speed up conversion
    static immutable Type[768] typenums =
    [
        001 : Type.WELCOME,
        002 : Type.SERVERINFO,
        003 : Type.SERVERINFO,
        004 : Type.SERVERINFO_2,
        005 : Type.SERVERINFO_2,
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
        436 : Type.ERR_NICKCOLLISION,
        441 : Type.ERR_USERNOTINCHANNEL,
        442 : Type.ERR_NOTONCHANNEL,
        443 : Type.ERR_USERONCHANNEL,
        444 : Type.ERR_NOLOGIN,
        445 : Type.ERR_SUMMONDISABLED,
        446 : Type.ERR_USERSDISABLED,
        451 : Type.ERR_NOTREGISTERED,
        461 : Type.ERR_NEEDMOREPARAMS,
        462 : Type.ERR_ALREADYREGISTERED,
        463 : Type.ERR_NOPERMFORHOST,
        464 : Type.ERR_PASSWDMISMATCH,
        465 : Type.ERR_YOUREBANNEDCREEP,
        467 : Type.ERR_KEYSET,
        470 : Type.CHANNELFORWARD,
        471 : Type.ERR_CHANNELISFULL,
        472 : Type.ERR_UNKNOWNMODE,
        473 : Type.ERR_INVITEONLYCHAN,
        474 : Type.ERR_BANNEDFROMCHAN,
        475 : Type.ERR_BADCHANNELKEY,
        481 : Type.ERR_NOPRIVILEGES,
        482 : Type.ERR_CHANOPRIVSNEEDED,
        483 : Type.ERR_CANTKILLSERVER,
        491 : Type.ERR_NOOPERHOST,
        501 : Type.ERR_UNKNOWNMODEFLAG,
        502 : Type.ERR_USERSDONTMATCH,
        300 : Type.RPL_NONE,
        301 : Type.RPL_AWAY,
        302 : Type.RPL_USERHOST,
        303 : Type.RPL_ISON,
        305 : Type.RPL_UNAWAY,
        306 : Type.RPL_NOWAWAY,
        311 : Type.RPL_WHOISUSER,
        312 : Type.RPL_WHOISSERVER,
        313 : Type.RPL_WHOISOPERATOR,
        314 : Type.RPL_WHOWASUSER,
        315 : Type.RPL_ENDOFWHO,
        317 : Type.RPL_WHOISIDLE,
        318 : Type.RPL_ENDOFWHOIS,
        319 : Type.RPL_WHOISCHANNELS,
        321 : Type.RPL_LISTSTART,
        322 : Type.RPL_LIST,
        323 : Type.RPL_LISTEND,
        324 : Type.RPL_CHANNELMODEIS,
        331 : Type.RPL_NOTOPIC,
        332 : Type.RPL_TOPIC,
        333 : Type.TOPICSETTIME,
        341 : Type.RPL_INVITING,
        342 : Type.RPL_SUMMONING,
        351 : Type.RPL_VERSION,
        352 : Type.RPL_WHOREPLY,
        353 : Type.RPL_NAMREPLY,
        364 : Type.RPL_LINKS,
        365 : Type.RPL_ENDOFLINKS,
        366 : Type.RPL_ENDOFNAMES,
        367 : Type.RPL_BANLIST,
        368 : Type.RPL_ENDOFBANLIST,
        369 : Type.RPL_ENDOFWHOWAS,
        371 : Type.RPL_INFO,
        372 : Type.RPL_MOTD,
        374 : Type.RPL_ENDOFINFO,
        375 : Type.RPL_MOTDSTART,
        376 : Type.RPL_ENDOFMOTD,
        381 : Type.RPL_YOUREOPER,
        382 : Type.RPL_REHASHING,
        391 : Type.RPL_TIME,
        392 : Type.RPL_USERSTART,
        393 : Type.RPL_USERS,
        394 : Type.RPL_ENDOFUSERS,
        395 : Type.RPL_NOUSERS,
        200 : Type.RPL_TRACELINK,
        201 : Type.RPL_TRACECONNECTING,
        202 : Type.RPL_TRACEHANDSHAKE,
        203 : Type.RPL_TRACEUNKNOWN,
        204 : Type.RPL_TRACEOPERATOR,
        205 : Type.RPL_TRACEUSER,
        206 : Type.RPL_TRACESERVER,
        208 : Type.RPL_TRACENEWTYPE,
        211 : Type.RPL_STATSLINKINFO,
        212 : Type.RPL_STATSCOMMAND,
        213 : Type.RPL_STATSCLINE,
        214 : Type.RPL_STATSNLINE,
        215 : Type.RPL_STATSILINE,
        216 : Type.RPL_STATSKLINE,
        218 : Type.RPL_STATSYLINE,
        219 : Type.RPL_ENDOFSTATS,
        221 : Type.RPL_UMODEIS,
        241 : Type.RPL_STATSLLINE,
        242 : Type.RPL_STATSUPTIME,
        243 : Type.RPL_STATSOLINE,
        244 : Type.RPL_STATSHLINE,
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
        209 : Type.RPL_TRACECLASS,
        217 : Type.RPL_STATSQLINE,
        231 : Type.RPL_SERVICEINFO,
        232 : Type.RPL_ENDOFSERVICES,
        233 : Type.RPL_SERVICE,
        234 : Type.RPL_SERVLIST,
        235 : Type.RPL_SERVLISTEND,
        316 : Type.RPL_WHOISCHANOP,
        361 : Type.RPL_KILLDONE,
        362 : Type.RPL_CLOSING,
        363 : Type.RPL_CLOSEEND,
        373 : Type.RPL_INFOSTART,
        384 : Type.RPL_MYPORTIS,
        466 : Type.ERR_YOUWILLBEBANNED,
        476 : Type.ERR_BADCHANMASK,
        492 : Type.ERR_NOSERVICEHOST,
        265 : Type.USERCOUNTLOCAL,
        266 : Type.USERCOUNTGLOBAL,
        250 : Type.CONNETCIONRECORD,
        328 : Type.CHANNELURL,
        671 : Type.WHOISSECURECONN,
        330 : Type.WHOISLOGIN,
    ];

    Type type;
    string raw;
    string sender, ident, address;
    string typestring, channel, target, content, aux;
    uint num;
    bool special;


    /// toString here simply creates an Appender and fills it using put
    string toString() const
    {
        import std.array : Appender;

        Appender!string app;
        app.reserve(768);
        put(app);
        return app.data;
    }

    void put(Sink)(Sink sink) const
    {
        import std.conv   : to;
        import std.format : formattedWrite;

        sink.reserve(512);
        sink.formattedWrite("[%s] %s", type.to!string, sender);

        if (target.length)  sink.formattedWrite(" (%s)",  target);
        if (channel.length) sink.formattedWrite(" [%s]",  channel);
        if (content.length) sink.formattedWrite(`: "%s"`, content);
        if (aux.length)     sink.formattedWrite(" <%s>",  aux);
        if (num > 0)        sink.formattedWrite(" (#%d)", num);
    }
}


// parseBasic
/++
 +  Parses the most basic of IRC events; PING and ERROR. They syntactically differ from other
 +  events in tht they are not prefixed by its sender.
 +
 +  Params:
 +      raw = The raw IRC string to parse.
 +
 +  Returns:
 +      A finished IrcEvent.
 +/
IrcEvent parseBasic(const char[] raw)
{
    mixin(scopeguard(failure));

    IrcEvent event;
    event.raw = raw.idup;
    auto slice = event.raw;

    event.typestring = slice.nom(" :");

    switch (event.typestring)
    {
    case "PING":
        event.type = IrcEvent.Type.PING;
        event.sender = slice;
        break;

    case "ERROR":
        event.type = IrcEvent.Type.ERROR;
        event.content = slice;
        break;

    default:
        break;
    }

    return event;
}


// stringToIrcEvent
/++
 +  Takes a raw IRC string and passes it to the different parsing functions to get a finished
 +  IrcEvent. Parsing goes through several phases (prefix, typestring, specialcases) and
 +  this is the function that calls them.
 +
 +  Params:
 +      raw = The raw IRC string to parse.
 +
 +  Returns:
 +      A finished IrcEvent.
 +/
IrcEvent stringToIrcEvent(const char[] raw)
{
    import std.exception : enforce;

    if (raw[0] != ':') return parseBasic(raw);

    IrcEvent event;
    event.raw = raw.idup;
    auto slice = event.raw[1..$]; // advance past first colon

    // First pass: prefixes. This is the sender
    parsePrefix(event, slice);
    // Second pass: typestring. This is what kind of action the event is of
    parseTypestring(event, slice);
    // Third pass: specialcases. This splits up the remaining bits into useful strings, like content
    parseSpecialcases(event, slice);

    return event;
}


// parsePrefix
/++
 +  Takes a slice of a raw IRC string and starts parsing it into an IrcEvent struct.
 +  This function only focuses on the prefix; the sender, be it nickname and ident
 +  or server address.
 +
 +  The IrcEvent is not finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IrcEvent to start working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parsePrefix(ref IrcEvent event, ref string slice)
{
    auto prefix = slice.nom(' ');

    if (prefix.canFind('!'))
    {
        // user!~ident@address
        event.sender  = prefix.nom('!');
        event.ident   = prefix.nom('@');
        event.address = prefix;
        event.special = (event.address == "services.");
    }
    else
    {
        event.sender = prefix;
    }
}


// parseTypestring
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an IrcEvent struct.
 +  This function only focuses on the typestring; the part that tells what kind of event
 +  happened, like PRIVMSG or MODE or NICK or KICK, etc.
 +
 +  The IrcEvent is not finished at the end of this function.
 +
 +  Params:
 +      ref event = A reference to the IrcEvent to continue working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseTypestring(ref IrcEvent event, ref string slice)
{
    import std.conv : to, ConvException;

    event.typestring = slice.nom(' ');

    assert(event.typestring.length, "Event typestring has no length! '%s'".format(event.raw));

    if ((event.typestring[0] > 47) && (event.typestring[0] < 58))
    {
        try
        {

            const number = event.typestring.to!uint;
            event.num = number;
            event.type = IrcEvent.typenums[number];

            with (IrcEvent.Type)
            event.type = (event.type == UNSET) ? NUMERIC : event.type;
        }
        catch (ConvException e)
        {
            writefln("------------------ %s ----------------", e.msg);
            writeln(event.raw);
        }
    }
    else
    {
        try event.type = event.typestring.to!(IrcEvent.Type);
        catch (ConvException e)
        {
            writefln("------------------ %s ----------------", e.msg);
            writeln(event.raw);
        }
    }
}


// parseSpecialcases
/++
 +  Takes a slice of a raw IRC string and continues parsing it into an IrcEvent struct.
 +  This function only focuses on specialcasing the remaining line, dividing it into fields
 +  like target, channel, content, etc.
 +
 +  The IrcEvent is finished at the end of this function. Beware its length.
 +
 +  Params:
 +      ref event = A reference to the IrcEvent to finish working on.
 +      ref slice = A reference to the slice of the raw IRC string.
 +/
void parseSpecialcases(ref IrcEvent event, ref string slice)
{
    mixin(scopeguard(failure));
    with (IrcEvent.Type)
    switch (event.type)
    {

    case NOTICE:
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[##linux-overflow] Make sure your nick is registered, then please try again to join ##linux.
        // :ChanServ!ChanServ@services. NOTICE kameloso^ :[#ubuntu] Welcome to #ubuntu! Please read the channel topic.
        event.target = slice.nom(" :");
        if (!event.special && (event.target == "*")) event.special = true;
        event.content = slice;
        break;

    case JOIN:
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com JOIN #flerrp
        writefln("event.sender(%s) == bot.nickname(%s) ? %s",
                 event.sender, bot.nickname, (event.sender == bot.nickname));
        event.type = (event.sender == bot.nickname) ? SELFJOIN : JOIN;
        event.channel = slice;
        break;

    case PART:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu PART #flerrp :"WeeChat 1.6"
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com PART #flerrp
        if (slice.canFind(' '))
        {
            event.channel = slice.nom(" :");
            event.channel = event.channel.unquoted;
        }

        writefln("event.sender(%s) == bot.nickname(%s) ? %s",
                 event.sender, bot.nickname, (event.sender == bot.nickname));
        event.type = (event.sender == bot.nickname) ? SELFPART : PART;
        event.content = slice;
        break;

    case NICK:
        // :kameloso^!~NaN@81-233-105-62-no80.tbcn.telia.com NICK :kameloso_
        // FIXME: Propagate new bot if SELFNICK
        writefln("event.sender(%s) == bot.nickname(%s) ? %s",
                 event.sender, bot.nickname, (event.sender == bot.nickname));
        event.type = (event.sender == bot.nickname) ? SELFNICK : NICK;
        event.content = slice[1..$];
        break;

    case QUIT:
        // :g7zon!~gertsson@178.174.245.107 QUIT :Client Quit
        writefln("event.sender(%s) == bot.nickname(%s) ? %s",
                 event.sender, bot.nickname, (event.sender == bot.nickname));
        event.type = (event.sender == bot.nickname) ? SELFQUIT : QUIT;
        event.content = slice[1..$].unquoted;
        break;

    case PRIVMSG:
        const targetOrChannel = slice.nom(" :");

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
            event.target = targetOrChannel;
        }

        if (slice.beginsWith(ControlCharacter.action) &&
            (slice.length > 2) && slice[1..$].beginsWith("ACTION"))
        {
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG #flerrp :ACTION test test content
            // :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :ACTION test test content
            event.type = EMOTE;
            event.content = (slice.length > 8) ? slice[8..$] : string.init;
        }
        else
        {
            event.content = slice;
        }
        break;

    case MODE:
        const targetOrChannel = slice.nom(' ');
        if (targetOrChannel.beginsWith('#'))
        {
            event.channel = targetOrChannel;

            if (slice.canFind(' '))
            {
                // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
                // :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +i
                event.type = CHANMODE;
                event.aux = slice.nom(' ');
                event.target = slice;
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
            event.target = targetOrChannel;
            event.aux = slice[1..$];
        }
        break;

    case KICK:
        // :zorael!~NaN@ns3363704.ip-94-23-253.eu KICK #flerrp kameloso^ :this is a reason
        event.type = (event.target == bot.nickname) ? SELFKICK : KICK;
        event.channel = slice.nom(' ');
        event.target  = slice.nom(" :");
        event.content = slice;
        break;

    case ERR_INVITEONLYCHAN:
    case RPL_ENDOFNAMES: // 366
    case RPL_TOPIC: // 332
    case CHANNELURL: // 328
        // :asimov.freenode.net 332 kameloso^ #garderoben :Are you employed, sir?
        // :asimov.freenode.net 366 kameloso^ #flerrp :End of /NAMES list.
        // :services. 328 kameloso^ #ubuntu :http://www.ubuntu.com
        event.target  = slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_NAMREPLY: // 353
        // :asimov.freenode.net 353 kameloso^ = #garderoben :kameloso^ ombudsman +kameloso @zorael @maku @klarrt
        event.target  = slice.nom(' ');
        slice.nom(' ');
        event.channel = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_MOTD: // 372
    case RPL_LUSERCLIENT:
        // :asimov.freenode.net 372 kameloso^ :- In particular we would like to thank the sponsor
        event.target  = slice.nom(" :");
        event.content = slice;
        break;

    case SERVERINFO_2: // 004
        // :asimov.freenode.net 004 kameloso^ asimov.freenode.net ircd-seven-1.1.4 DOQRSZaghilopswz CFILMPQSbcefgijklmnopqrstvz bkloveqjfI
        event.target  = slice.nom(' ');
        event.content = slice;
        break;

    case TOPICSETTIME: // 333
        // :asimov.freenode.net 333 kameloso^ #garderoben klarrt!~bsdrouter@h150n13-aahm-a11.ias.bredband.telia.com 1476294377
        event.target  = slice.nom(' ');
        event.channel = slice.nom(' ');
        event.content = slice.nom(' ');
        event.aux = slice;
        break;

    case RPL_LUSEROP: // 252
    case RPL_LUSERUNKNOWN: // 253
    case RPL_LUSERCHANNELS: // 254
    case RPL_WHOISIDLE: //  317
    case ERR_UNKNOWNCOMMAND: // 421
    case ERR_ERRONEOUSNICKNAME: // 432
    case ERR_NEEDMOREPARAMS: // 461
    case USERCOUNTLOCAL: // 265
    case USERCOUNTGLOBAL: // 266
        // :asimov.freenode.net 252 kameloso^ 31 :IRC Operators online
        // :asimov.freenode.net 253 kameloso^ 13 :unknown connection(s)
        // :asimov.freenode.net 254 kameloso^ 54541 :channels formed
        // :asimov.freenode.net 421 kameloso^ sudo :Unknown command
        // :asimov.freenode.net 432 kameloso^ @nickname :Erroneous Nickname
        // :asimov.freenode.net 461 kameloso^ JOIN :Not enough parameters
        // :asimov.freenode.net 265 kameloso^ 6500 11061 :Current local users 6500, max 11061
        // :asimov.freenode.net 266 kameloso^ 85267 92341 :Current global users 85267, max 92341
        event.target = slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_WHOISUSER: // 311
        // :asimov.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :Full Name Here
        slice.nom(' ');
        event.target  = slice.nom(' ');
        event.content = slice.nom(" *");
        slice.nom(" :");
        event.aux = slice;
        break;

    case RPL_WHOISCHANNELS:
        import std.string : stripRight;

        slice = slice.stripRight();
        goto case RPL_ENDOFWHOIS;

    case WHOISSECURECONN: // 671
    case RPL_ENDOFWHOIS: // 318
    case ERR_NICKNAMEINUSE: // 433
        // :asimov.freenode.net 671 kameloso^ zorael :is using a secure connection
        // :asimov.freenode.net 318 kameloso^ zorael :End of /WHOIS list.
        // :asimov.freenode.net 433 kameloso^ kameloso :Nickname is already in use.
        slice.nom(' ');
        event.target  = slice.nom(" :");
        event.content = slice;
        break;

    case RPL_WHOISSERVER: // 312
        // :asimov.freenode.net 312 kameloso^ zorael sinisalo.freenode.net :SE
        slice.nom(' ');
        event.target  = slice.nom(' ');
        event.content = slice.nom(" :");
        event.aux = slice;
        break;

    case WHOISLOGIN: // 330
        // :asimov.freenode.net 330 kameloso^ xurael zorael :is logged in as
        slice.nom(' ');
        event.target = slice.nom(' ');
        event.aux = slice.nom(" :");
        event.content = slice;
        break;

    case PONG:
        event.target  = string.init;
        event.content = string.init;
        break;

    default:
        if (event.type == NUMERIC)
        {
            writeln();
            writeln("--------------- UNCAUGHT NUMERIC --------------");
            writeln(event.raw);
            writeln(event);
            writeln("-----------------------------------------------");
            writeln();
        }

        event.target = slice.nom(" :");
        event.content = slice;
        break;
    }

    if (event.target.canFind(' ') || event.channel.canFind(' '))
    {
        writeln();
        writeln("--------------- SPACES, NEEDS REVISION --------------");
        writeln(event.raw);
        writeln(event);
        writeln("-----------------------------------------------------");
        writeln();
    }

    if ((event.target.length && (event.target[0] == '#')) || (event.channel.length &&
         event.channel[0] != '#'))
    {
        writeln();
        writeln("--------------- CHANNEL/TARGET REVISION --------------");
        writeln(event.raw);
        writeln(event);
        writeln("------------------------------------------------------");
        writeln();
    }
}


/// isValidChannel only checks whether a string *looks* like a channel.
static bool isValidChannel(const string line)
{
    import std.string : indexOf;

    return ((line.length > 1) && (line.indexOf(' ') == -1) && (line[0] == '#'));
}
unittest
{
    assert("#channelName".isValidChannel);
    assert(!"#not a channel".isValidChannel);
    assert(!"notAChannelEither".isValidChannel);
    assert(!"#".isValidChannel);
}


// stripModeSign
/++
 +  Takes a nickname and strips it of any prepended mode signs, like the @ in @nickname.
 +  The list of signs should be added to if more are discovered.
 +
 +  Params:
 +      nickname = The signed nickname.
 +
 +  Returns:
 +      The nickname with the sign sliced off.
 +/
static string stripModeSign(const string nickname)
{
    if (!nickname.length) return string.init;

    switch (nickname[0])
    {
        case '@':
        case '+':
        case '~':
        case '%':
        case '&':
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
}


unittest
{
    /+
    [NOTICE] tepper.freenode.net (*): "*** Checking Ident"
    :tepper.freenode.net NOTICE * :*** Checking Ident
     +/
    const e1 = ":tepper.freenode.net NOTICE * :*** Checking Ident".stringToIrcEvent();
    assert(e1.sender == "tepper.freenode.net");
    assert(e1.type == IrcEvent.Type.NOTICE);
    assert(e1.target == "*");
    assert(e1.content == "*** Checking Ident");

    /+
    [ERR_NICKNAMEINUSE] tepper.freenode.net (kameloso): "Nickname is already in use." (#433)
    :tepper.freenode.net 433 * kameloso :Nickname is already in use.
     +/
    const e2 = ":tepper.freenode.net 433 * kameloso :Nickname is already in use.".stringToIrcEvent();
    assert(e2.sender == "tepper.freenode.net");
    assert(e2.type == IrcEvent.Type.ERR_NICKNAMEINUSE);
    assert(e2.target == "kameloso");
    assert(e2.content == "Nickname is already in use.");
    assert(e2.num == 433);

    /+
    [WELCOME] tepper.freenode.net (kameloso^): "Welcome to the freenode Internet Relay Chat Network kameloso^" (#1)
    :tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^
     +/
    const e3 = ":tepper.freenode.net 001 kameloso^ :Welcome to the freenode Internet Relay Chat Network kameloso^"
               .stringToIrcEvent();
    assert(e3.sender == "tepper.freenode.net");
    assert(e3.type == IrcEvent.Type.WELCOME);
    assert(e3.target == "kameloso^");
    assert(e3.content == "Welcome to the freenode Internet Relay Chat Network kameloso^");
    assert(e3.num == 1);

    /+
    [RPL_ENDOFMOTD] tepper.freenode.net (kameloso^): "End of /MOTD command." (#376)
    :tepper.freenode.net 376 kameloso^ :End of /MOTD command.
     +/
    const e4 = ":tepper.freenode.net 376 kameloso^ :End of /MOTD command.".stringToIrcEvent();
    assert(e4.sender == "tepper.freenode.net");
    assert(e4.type == IrcEvent.Type.RPL_ENDOFMOTD);
    assert(e4.target == "kameloso^");
    assert(e4.content == "End of /MOTD command.");
    assert(e4.num == 376);

    /+
    [SELFMODE] kameloso^ (kameloso^) <+i>
    :kameloso^ MODE kameloso^ :+i
     +/
    const e5 = ":kameloso^ MODE kameloso^ :+i".stringToIrcEvent();
    assert(e5.sender == "kameloso^");
    assert(e5.type == IrcEvent.Type.SELFMODE);
    assert(e5.target == "kameloso^");
    assert(e5.aux == "+i");

    /+
    [QUERY] zorael (kameloso^): "sudo privmsg zorael :derp"
    :zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp
     +/
    const e6 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu PRIVMSG kameloso^ :sudo privmsg zorael :derp"
                .stringToIrcEvent();
    assert(e6.sender == "zorael");
    assert(e6.type == IrcEvent.Type.QUERY); // Will this work?
    assert(e6.target == "kameloso^");
    assert(e6.content == "sudo privmsg zorael :derp");

    /+
    [RPL_WHOISUSER] tepper.freenode.net (zorael): "~NaN ns3363704.ip-94-23-253.eu" <jr> (#311)
    :tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr
     +/
    const e7 = ":tepper.freenode.net 311 kameloso^ zorael ~NaN ns3363704.ip-94-23-253.eu * :jr"
               .stringToIrcEvent();
    assert(e7.sender == "tepper.freenode.net");
    assert(e7.type == IrcEvent.Type.RPL_WHOISUSER);
    assert(e7.content == "~NaN ns3363704.ip-94-23-253.eu");
    assert(e7.aux == "jr");
    assert(e7.num == 311);

    /+
    [WHOISLOGIN] tepper.freenode.net (zurael): "is logged in as" <zorael> (#330)
    :tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as
     +/
    const e8 = ":tepper.freenode.net 330 kameloso^ zurael zorael :is logged in as"
               .stringToIrcEvent();
    assert(e8.sender == "tepper.freenode.net");
    assert(e8.type == IrcEvent.Type.WHOISLOGIN);
    assert(e8.target == "zurael");
    assert(e8.content == "is logged in as");
    assert(e8.aux == "zorael");
    assert(e8.num == 330);

    /+
    [PONG] tepper.freenode.net
    :tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net
     +/
    const e9 = ":tepper.freenode.net PONG tepper.freenode.net :tepper.freenode.net".stringToIrcEvent();
    assert(e9.sender == "tepper.freenode.net");
    assert(e9.type == IrcEvent.Type.PONG);
    assert(e9.target == string.init); // More than the server and type is never parsed

    /+
    [QUIT] wonderworld: "Remote host closed the connection"
    :wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection
     +/
    const e10 = ":wonderworld!~ww@ip-176-198-197-145.hsi05.unitymediagroup.de QUIT :Remote host closed the connection"
                .stringToIrcEvent();
    assert(e10.sender == "wonderworld");
    assert(e10.type == IrcEvent.Type.QUIT);
    assert(e10.target == string.init);
    assert(e10.content == "Remote host closed the connection");

    /+
    [CHANMODE] zorael (kameloso^) [#flerrp] <+v>
    :zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^
     +/
     const e11 = ":zorael!~NaN@ns3363704.ip-94-23-253.eu MODE #flerrp +v kameloso^".stringToIrcEvent();
     assert(e11.sender == "zorael");
     assert(e11.type == IrcEvent.Type.CHANMODE);
     assert(e11.target == "kameloso^");
     assert(e11.channel == "#flerrp");
     assert(e11.aux == "+v");
}
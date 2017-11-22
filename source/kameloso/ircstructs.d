module kameloso.ircstructs;

import kameloso.common : Hidden, Separator, Unconfigurable;

final:
@safe:
pure:
nothrow:

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
    /// https://www.alien.net.au/irc/irc2numerics.html
    /// http://defs.ircdocs.horse/
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
        CTCP_USERINFO, CTCP_FINGER, CTCP_LAG,
        USERSTATE, ROOMSTATE, GLOBALUSERSTATE,
        CLEARCHAT, USERNOTICE, HOSTTARGET,
        HOSTSTART, HOSTEND,
        SUB, RESUB, TEMPBAN, PERMBAN, SUBGIFT,
        ACCOUNT,
        SASL_AUTHENTICATE,
        AUTH_CHALLENGE,
        AUTH_FAILURE,

        RPL_WELCOME, // = 001,          // ":Welcome to <server name> <user>"
        RPL_YOURHOST, // = 002,         // ":Your host is <servername>, running version <version>"
        RPL_CREATED, // = 003,          // ":This server was created <date>"
        RPL_MYINFO, // = 004,           // "<server_name> <version> <user_modes> <chan_modes>"
        RPL_BOUNCE, // = 005,           // CONFLICT ":Try server <server_name>, port <port_number>"
        RPL_ISUPPORT, // = 005,         // (server information, different syntax)
        RPL_MAP, // = 006,
        RPL_MAPEND, // = 007,
        RPL_SNOMASK, // = 008,          // Server notice mask (hex)
        RPL_STATMEMTOT, // = 009,
        //RPL_BOUNCE, // = 010,         // CONFLICT "<hostname> <port> :<info>",
        RPL_STATMEM, // = 010,          // deprecated
        RPL_YOURCOOKIE, // = 014,
        //RPL_MAP, // = 015,
        RPL_MAPMORE, // = 016,
        //RPL_MAPEND, // = 017,
        RPL_HELLO, // = 020,
        RPL_APASSWARN_SET, // = 030,
        RPL_APASSWARN_SECRET, // = 031,
        RPL_APASSWARN_CLEAR, // = 032,
        RPL_YOURID, // = 042,           // <nickname> <id> :your unique ID
        RPL_SAVENICK, // = 043,         // Sent to the client when their nickname was forced to change due to a collision
        RPL_ATTEMPTINGJUNC, // = 050,
        RPL_ATTEMPTINGREROUTE, // = 051,

        RPL_REMOTEISUPPORT, // 105,

        RPL_TRACELINK, // = 200,        // "Link <version & debug level> <destination> <next server>"
        RPL_TRACECONNECTING, // = 201,  // "Try. <class> <server>"
        RPL_TRACEHANDSHAKE, // = 202,   // "H.S. <class> <server>"
        RPL_TRACEUNKNOWN, // = 203,     // "???? <class> [<client IP address in dot form>]"
        RPL_TRACEOPERATOR, // = 204,    // "Oper <class> <nick>"
        RPL_TRACEUSER, // = 205,        // "User <class> <nick>"
        RPL_TRACESERVER, // = 206,      // "Serv <class> <int>S <int>C <server> <nick!user|*!*>@<host|server>"
        RPL_TRACESERVICE, // = 207,     // "Service <class> <name> <type> <active_type>
        RPL_TRACENEWTYPE, // = 208,     // "<newtype> 0 <client name>"
        RPL_TRACECLASS, // = 209,       // "Class <class> <count>"
        RPL_TRACERECONNECT, // = 210,   // CONFLICT
        RPL_STATSHELP, // = 210,        // CONFLICT
        RPL_STATS, // = 210,            // Used instead of having multiple stats numerics
        RPL_STATSLINKINFO, // = 211,    // "<linkname> <sendq> <sent messages> <sent bytes> <received messages> <received bytes> <time open>"
        RPL_STATSCOMMAND, // = 212,     // "<command> <count>"
        RPL_STATSCLINE, // = 213,       // "C <host> * <name> <port> <class>"
        RPL_STATSNLINE, // = 214,       // "N <host> * <name> <port> <class>"
        RPL_STATSILINE, // = 215,       // "I <host> * <host> <port> <class>"
        RPL_STATSKLINE, // = 216,       // "K <host> * <username> <port> <class>"
        RPL_STATSPLINE, // = 217,       // CONFLICT
        RPL_STATSQLINE, // = 217,
        RPL_STATSYLINE, // = 218        // "Y <class> <ping frequency> <connect frequency> <max sendq>"
        RPL_ENDOFSTATS, // = 219,       // "<stats letter> :End of /STATS report"
        RPL_STATSBLINE, // = 220,       // CONFLICT
        RPL_STATSWLINE, // = 220,       // CONFLICT
        //RPL_STATSPLINE, // = 220,
        RPL_UMODEIS, // = 221,          // "<user mode string>"
        //RPL_STATSBLINE, // = 222,       // CONFLICT
        RPL_SQLINE_NICK, // = 222,      // CONFLICT
        RPL_CODEPAGE, // = 222,         // CONFLICT
        RPL_STATSJLINE, // = 222,       // CONFLICT
        RPL_MODLIST, // = 222,
        RPL_STATSGLINE, // = 223,       // CONFLICT
        RPL_CHARSET, // = 223,          // CONFLICT
        RPL_STATSELINE, // = 223,
        RPL_STATSTLINE, // = 224,       // CONFLICT
        RPL_STATSFLINE, // = 224,
        //RPL_STATSELINE, // = 225,       // CONFLICT
        RPL_STATSZLINE, // = 225,       // CONFLICT
        RPL_STATSCLONE, // = 225,       // CONFLICT
        RPL_STATSDLINE, // = 225,
        //RPL_STATSNLINE, // = 226,       // CONFLICT
        RPL_STATSALINE, // = 226,       // CONFLICT
        RPL_STATSCOUNT, // = 226,
        //RPL_STATSGLINE, // = 227,       // CONFLICT
        RPL_STATSVLINE, // = 227,       // CONFLICT
        //RPL_STATSBLINE, // = 227,
        RPL_STATSBANVER, // = 228,      // CONFLICT
        //RPL_STATSQLINE, // = 228,
        RPL_STATSSPAMF, // = 229,
        RPL_STATSEXCEPTTKL, // = 230,
        RPL_SERVICEINFO, // = 231,      // (reserved numeric)
        RPL_RULES, // = 232,            // CONFLICT
        RPL_ENDOFSERVICES, // = 232,    // (reserved numeric)
        RPL_SERVICE, // = 233,          // (reserved numeric)
        RPL_SERVLIST, // = 234,         // (reserved numeric)
        RPL_SERVLISTEND, // = 235,      // (reserved numeric)
        RPL_STATSVERBOSE, // = 236,     // Verbose server list?
        RPL_STATSENGINE, // = 237,      // Engine name?
        //RPL_STATSFLINE, // = 238,       // Feature lines?
        RPL_STATSIAUTH, // = 239,
        RPL_STATSXLINE, // = 240,       // CONFLICT
        //RPL_STATSVLINE, // = 240,
        RPL_STATSLLINE, // = 241,       // "L <hostmask> * <servername> <maxdepth>"
        RPL_STATSUPTIME, // = 242,      // ":Server Up %d days %d:%02d:%02d"
        RPL_STATSOLINE, // = 243,       // "O <hostmask> * <name>"
        RPL_STATSHLINE, // = 244,       // "H <hostmask> * <servername>"
        //RPL_STATSTLINE, // = 245,       // CONFLICT
        RPL_STATSSLINE, // = 245,
        RPL_STATSSERVICE, // = 246,     // CONFLICT
        //RPL_STATSTLINE, // = 246,       // CONFLICT
        RPL_STATSULINE, // = 246,       // CONFLICT
        RPL_STATSPING, // = 246,
        //RPL_STATSXLINE, // = 247,       // CONFLICT
        //RPL_STATSGLINE, // = 247,       // CONFLICT
        //RPL_STATSBLINE, // = 247,
        RPL_STATSDEFINE, // = 248,      // CONFLICT
        //RPL_STATSULINE, // = 248,
        RPL_STATSDEBUG, // = 249,       // CONFLICT
        //RPL_STATSULINE, // = 249,
        //RPL_STATSDLINE, // = 250,       // CONFLICT
        RPL_STATSCONN, // = 250,
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
        RPL_TRACEEND, // = 262,         // CONFLICT "<server_name> <version>[.<debug_level>] :<info>"
        RPL_TRACEPING, // = 262,
        RPL_TRYAGAIN, // = 263,         // "<command> :<info>"
        RPL_USINGSSL, // = 264,
        RPL_LOCALUSERS, // = 265,       // Also known as RPL_CURRENT_LOCAL
        RPL_GLOBALUSERS, // = 266,      // Also known as RPL_CURRENT_GLOBAL
        RPL_START_NETSTAT, // = 267,
        RPL_NETSTAT, // = 268,
        RPL_END_NETSTAT, // = 269,
        RPL_MAPUSERS, // = 270,         // CONFLICT
        RPL_PRIVS, // = 270,
        RPL_SILELIST, // = 271,
        RPL_ENDOFSILELIST, // = 272,
        RPL_NOTIFY, // = 273,
        RPL_STATSDELTA, // = 274,       // CONFLICT
        RPL_ENDNOTIFY, // = 274,
        //RPL_USINGSSL, // = 275,         // CONFLICT
        //RPL_STATSDLINE, // = 275,
        RPL_VCHANEXIST, // = 276,       // CONFLICT
        RPL_WHOISCERTFP, // = 276,      // CONFLICT
        RPL_STATSRLINE, // = 276,
        RPL_VCHANLIST, // = 277,
        RPL_VCHANHELP, // = 278,
        RPL_GLIST, // = 280
        RPL_ENDOFGLIST, // = 281,       // CONFLICT
        RPL_ACCEPTLIST, // = 281,
        RPL_JUPELIST, // = 282,         // CONFLICT
        RPL_ENDOFACCEPT, // = 282,
        RPL_ENDOFJUPELIST, // = 283,    // CONFLICT
        RPL_ALIST, // = 283,
        RPL_FEATURE, // = 284,          // CONFLICT
        RPL_ENDOFALIST, // = 284,
        RPL_CHANINFO_HANDLE, // = 285,  // CONFLICT
        RPL_NEWHOSTIS, // = 285,        // CONFLICT
        RPL_GLIST_HASH, // = 285,
        RPL_CHKHEAD, // = 286,          // CONFLICT
        RPL_CHANINFO_USERS, // = 286,
        RPL_CHANUSER, // = 287          // CONFLICT
        RPL_CHANINFO_CHOPS, // = 287,
        RPL_PATCHHEAD, // = 288,        // CONFLICT
        RPL_CHANINFO_VOICES, // = 288,
        RPL_PATCHCON, // = 289,         // CONFLICT
        RPL_CHANINFO_AWAY, // = 289,
        RPL_CHANINFO_HELPHDR, // = 290, // CONFLICT
        RPL_DATASTR, // = 290,          // CONFLICT
        RPL_HELPHDR, // = 290,          // CONFLICT
        RPL_CHANINFO_OPERS, // = 290,
        RPL_ENDOFCHECK, // = 291,       // CONFLICT
        RPL_HELPOP, // = 291,           // CONFLICT
        RPL_CHANINFO_BANNED, // = 291,
        ERR_SEARCHNOMATCH, // = 292  ,  // CONFLICT
        RPL_HELPTLR, // = 292,          // CONFLICT
        RPL_CHANINFO_BANS, // = 292,
        RPL_HELPHLP, // = 293,          // CONFLICT
        RPL_CHANINFO_INVITE, // = 293,
        RPL_HELPFWD, // = 294,          // CONFLICT
        RPL_CHANINFO_INVITES, // = 294,
        RPL_HELPIGN, // = 295,          // CONFLICT
        RPL_CHANINFO_KICK, // = 295,
        RPL_CHANINFO_KICKS, // = 296,
        RPL_END_CHANINFO, // = 299,

        RPL_NONE, // = 300,             // Dummy reply number. Not used.
        RPL_AWAY, // = 301              // "<nick> :<away message>"
        RPL_USERHOST, // = 302          // ":[<reply>{<space><reply>}]"
        RPL_ISON, // = 303,             // ":[<nick> {<space><nick>}]"
        RPL_SYNTAX, // = 304,           // CONFLICT
        RPL_TEXT, // = 304,
        RPL_UNAWAY, // = 305,           // ":You are no longer marked as being away"
        RPL_NOWAWAY, // = 306,          // ":You have been marked as being away"
        RPL_SUSERHOST, // = 307,        // CONFLICT
        RPL_WHOISREGNICK, // = 307      // CONFLICT <nickname> :has identified for this nick
        RPL_USERIP, // = 307,
        RPL_WHOISADMIN, // = 308,       // CONFLICT
        RPL_RULESSTART, // = 308,       // CONFLICT
        RPL_NOTIFYACTION, // = 308,
        RPL_WHOISHELPER, // = 309,      // CONFLICT
        RPL_ENDOFRULES, // = 309,       // CONFLICT
        //RPL_WHOISADMIN, // = 309,       // CONFLICT
        RPL_NICKTRACE, // = 309,
        RPL_WHOISSERVICE, // = 310,     // CONFLICT
        RPL_WHOISHELPOP, // = 310,      // CONFLICT
        RPL_WHOISSVCMSG, // = 310,
        RPL_WHOISUSER, // = 311,        // "<nick> <user> <host> * :<real name>"
        RPL_WHOISSERVER, // = 312,      // "<nick> <server> :<server info>"
        RPL_WHOISOPERATOR, // = 313,    // "<nick> :is an IRC operator"
        RPL_WHOWASUSER, // = 314,       // "<nick> <user> <host> * :<real name>"
        RPL_ENDOFWHO, // = 315,         // "<name> :End of /WHO list"
        RPL_WHOISPRIVDEAF, // = 316     // CONFLICT
        RPL_WHOISCHANOP, // = 316,      // (reserved numeric)
        RPL_WHOISIDLE, // = 317,        // "<nick> <integer> :seconds idle"
        RPL_ENDOFWHOIS, // = 318,       // "<nick> :End of /WHOIS list"
        RPL_WHOISCHANNELS, // = 319,    // "<nick> :{[@|+]<channel><space>}"
        RPL_WHOISVIRT, // = 320,        // CONFLICT
        RPL_WHOIS_HIDDEN, // = 320,     // CONFLICT
        RPL_WHOISSPECIAL, // = 320,
        RPL_LISTSTART, // = 321,        // "Channel :Users  Name"
        RPL_LIST, // = 322,             // "<channel> <# visible> :<topic>"
        RPL_LISTEND, // = 323,          // ":End of /LIST"
        RPL_CHANNELMODEIS, // = 324,    // "<channel> <mode> <mode params>"
        RPL_WHOISWEBIRC, // = 325,      // CONFLICT
        RPL_CHANNELMLOCKIS, // = 325,   // CONFLICT
        RPL_UNIQOPIS, // = 325,         // CONFLICT
        RPL_CHANNELPASSIS, // = 325,
        RPL_NOCHANPASS, // = 326,
        RPL_WHOISHOST, // = 327,        // CONFLICT
        RPL_CHPASSUNKNOWN, // = 327,
        RPL_CHANNEL_URL, // = 328       // "http://linux.chat"
        RPL_CREATIONTIME, // = 329,
        RPL_WHOWAS_TIME, // = 330,      // CONFLICT
        RPL_WHOISACCOUNT, // = 330      // "<nickname> <login> :is logged in as"
        RPL_NOTOPIC, // = 331,          // "<channel> :No topic is set"
        RPL_TOPIC, // = 332,            // "<channel> :<topic>"
        RPL_TOPICWHOTIME, // = 333,     // "#channel user!~ident@address 1476294377"
        RPL_COMMANDSYNTAX, // = 334,    // CONFLICT
        RPL_LISTSYNTAX, // = 334,       // CONFLICT
        RPL_LISTUSAGE, // = 334,
        RPL_WHOISTEXT, // = 335,        // CONFLICT
        RPL_WHOISACCOUNTONLY, // = 335, // CONFLICT
        RPL_WHOISBOT, // = 335,         // "<nick> <othernick> :is a Bot on <server>"
        //RPL_WHOISBOT, // = 336,         // CONFLICT
        RPL_INVITELIST, // = 336,
        //RPL_WHOISTEXT, // = 337,        // CONFLICT
        RPL_ENDOFINVITELIST, // = 337,  // CONFLICT
        RPL_WHOISACTUALLY, // = 338,    // CONFLICT
        RPL_CHANPASSOK, // = 338,
        RPL_WHOISMARKS, // = 339,       // CONFLICT
        RPL_BADCHANPASS, // = 339,
        //RPL_USERIP, // = 340,
        RPL_INVITING, // = 341,         // "<channel> <nick>"
        RPL_SUMMONING, // = 342,        // "<user> :Summoning user to IRC"
        RPL_WHOISKILL, // = 343,
        RPL_INVITED, // = 345,
        //RPL_INVITELIST, // = 346,
        //RPL_ENDOFINVITELIST, // = 347,
        RPL_EXCEPTLIST, // = 348,
        RPL_ENDOFEXCEPTLIST, // = 349,
        RPL_VERSION, // = 351,          // "<version>.<debuglevel> <server> :<comments>"
        RPL_WHOREPLY, // = 352,         // "<channel> <user> <host> <server> <nick> | <H|G>[*][@|+] :<hopcount> <real name>"
        RPL_NAMREPLY, // = 353,         // "<channel> :[[@|+]<nick> [[@|+]<nick> [...]]]"
        RPL_WHOSPCRPL, // = 354,
        RPL_NAMREPLY_, // = 355,
        //RPL_MAP, // = 357,
        //RPL_MAPMORE, // = 358,
        //RPL_MAPEND, // = 359,
        RPL_WHOWASREAL, // = 360,
        RPL_KILLDONE, // = 361,         // (reserved numeric)
        RPL_CLOSING, // = 362,          // (reserved numeric)
        RPL_CLOSEEND, // = 363,         // (reserved numeric)
        RPL_LINKS, // = 364,            // "<mask> <server> :<hopcount> <server info>"
        RPL_ENDOFLINKS, // = 365,       // "<mask> :End of /LINKS list"
        RPL_ENDOFNAMES, // = 366,       // "<channel> :End of /NAMES list"
        RPL_BANLIST, // = 367,          // "<channel> <banid>"
        RPL_ENDOFBANLIST, // = 368,     // "<channel> :End of channel ban list"
        RPL_ENDOFWHOWAS, // = 369,      // "<nick> :End of WHOWAS"
        RPL_INFO, // = 371,             // ":<string>"
        RPL_MOTD, // = 372,             // ":- <text>"
        RPL_INFOSTART, // = 373,        // (reserved numeric)
        RPL_ENDOFINFO, // = 374,        //  ":End of /INFO list"
        RPL_MOTDSTART, // = 375,        // ":- <server> Message of the day - "
        RPL_ENDOFMOTD, // = 376,        // ":End of /MOTD command"
        RPL_SPAM, // = 377,             // CONFLICT
        RPL_KICKEXPIRED, // = 377,
        RPL_BANEXPIRED, // = 378,       // CONFLICT
        //RPL_MOTD, // = 378,             // CONFLICT
        //RPL_WHOISHOST, // = 378         // <nickname> :is connecting from *@<address> <ip>
        RPL_WHOISMODES, // = 379,       // CONFLICT <nickname> :is using modes <modes>
        RPL_KICKLINKED, // = 379,       // CONFLICT
        RPL_WHOWASIP, // = 379,
        RPL_YOURHELPER, // = 380,       // CONFLICT
        RPL_BANLINKED, // = 380,
        RPL_YOUREOPER, // = 381,        // ":You are now an IRC operator"
        RPL_REHASHING, // = 382,        // "<config file> :Rehashing"
        RPL_YOURESERVICE, // = 383,
        RPL_MYPORTIS, // = 384,
        RPL_NOTOPERANYMORE, // = 385,
        RPL_IRCOPS, // = 386,           // CONFLICT
        RPL_IRCOPSHEADER, // = 386,     // CONFLICT
        RPL_RSACHALLENGE, // = 386,     // CONFLICT
        RPL_QLIST, // = 386,
        RPL_ENDOFIRCOPS, // = 387,      // CONFLICT
        //RPL_IRCOPS, // = 387,           // CONFLICT
        RPL_ENDOFQLIST, // = 387,
        //RPL_ENDOFIRCOPS, // = 388,      // CONFLICT
        //RPL_ALIST, // = 388,
        //RPL_ENDOFALIST, // = 389,
        RPL_TIME, // = 391,             // "<server> :<string showing server's local time>"
        RPL_USERSTART, // = 392,        // ":UserID   Terminal  Host"
        RPL_USERS, // = 393,            // ":%-8s %-9s %-8s"
        RPL_ENDOFUSERS, // = 394,       // ":End of users"
        RPL_NOUSERS, // = 395,          // ":Nobody logged in"
        RPL_VISIBLEHOST, // = 396,      // CONFLICT
        RPL_HOSTHIDDEN, // = 396,       // <nickname> <host> :is now your hidden host

        ERR_UNKNOWNERROR, // = 400,
        ERR_NOSUCHNICK, // = 401,       // "<nickname> :No such nick/channel"
        ERR_NOSUCHSERVER, // = 402,     // "<server name> :No such server"
        ERR_NOSUCHCHANNEL, // = 403,    // "<channel name> :No such channel"
        ERR_CANNOTSENDTOCHAN, // = 404, // "<channel name> :Cannot send to channel"
        ERR_TOOMANYCHANNELS, // = 405,  // "<channel name> :You have joined too many channels"
        ERR_WASNOSUCHNICK, // = 406,    // "<nickname> :There was no such nickname"
        ERR_TOOMANYTARGETS, // = 407,   // "<target> :Duplicate recipients. No message delivered""
        ERR_NOCTRLSONCHAN, // = 408,    // CONFLICT
        ERR_NOCOLORSONCHAN, // = 408,   // CONFLICT
        ERR_NOSUCHSERVICE, // = 408,
        ERR_NOORIGIN, // = 409,         // ":No origin specified"
        ERR_INVALIDCAPCMD, // = 410,
        ERR_NORECIPIENT, // = 411,      // ":No recipient given (<command>)"
        ERR_NOTEXTTOSEND, // = 412,     // ":No text to send"
        ERR_NOTOPLEVEL, // = 413,       // "<mask> :No toplevel domain specified"
        ERR_WILDTOPLEVEL, // = 414,     // "<mask> :Wildcard in toplevel domain"
        ERR_BADMASK, // = 415,
        ERR_QUERYTOOLONG, // = 416,     // CONFLICT
        ERR_TOOMANYMATCHES, // = 416,
        ERR_INPUTTOOLONG, // = 417,
        ERR_LENGTHTRUNCATED, // = 419,
        ERR_UNKNOWNCOMMAND, // = 421,   // "<command> :Unknown command"
        ERR_NOMOTD, // = 422,           // ":MOTD File is missing"
        ERR_NOADMININFO, // = 423,      // "<server> :No administrative info available"
        ERR_FILEERROR, // = 424,        // ":File error doing <file op> on <file>"
        ERR_NOOPERMOTD, // = 425,
        ERR_TOOMANYAWAY, // = 429,
        ERR_EVENTNICKCHANGE, // = 430,
        ERR_NONICKNAMEGIVEN, // = 431,  // ":No nickname given"
        ERR_ERRONEOUSNICKNAME, // = 432,// "<nick> :Erroneus nickname"
        ERR_NICKNAMEINUSE, // = 433,    // "<nick> :Nickname is already in use"
        ERR_SERVICENAMEINUSE, // = 434,  //CONFLICT
        ERR_NORULES, // = 434,
        ERR_SERVICECONFUSED, // = 435   // CONFLICT
        ERR_BANONCHAN, // = 435         // <nickname> <target nickname> <channel> :Cannot change nickname while banned on channel
        ERR_NICKCOLLISION, // = 436,    // "<nick> :Nickname collision KILL"
        ERR_BANNICKCHANGE, // = 437,    // CONFLICT
        ERR_UNAVAILRESOURCE, // = 437,  // <nickname> <channel> :Nick/channel is temporarily unavailable
        ERR_DEAD, // = 438,             // CONFLICT
        ERR_NICKTOOFAST, // = 438,
        ERR_TARGETTOOFAST, // = 439,    // <nickname> :This server has anti-spambot mechanisms enabled.
        ERR_SERVICESDOWN, // = 440,
        ERR_USERNOTINCHANNEL, // = 441, // "<nick> <channel> :They aren't on that channel"
        ERR_NOTONCHANNEL, // = 442,     // "<channel> :You're not on that channel"
        ERR_USERONCHANNEL, // = 443,    // "<user> <channel> :is already on channel"
        ERR_NOLOGIN, // = 444,          // "<user> :User not logged in"
        ERR_SUMMONDISABLED, // = 445,   // ":SUMMON has been disabled"
        ERR_USERSDISABLED, // = 446,    // ":USERS has been disabled"
        ERR_NONICKCHANGE, // = 447,
        ERR_FORBIDDENCHANEL, // = 448,
        ERR_NOTIMPLEMENTED, // = 449,
        ERR_NOTREGISTERED, // = 451,    // ":You have not registered"
        ERR_IDCOLLISION, // = 452,
        ERR_NICKLOST, // = 453,
        //ERR_IDCOLLISION, // = 455       // <nickname> :Your username <nickname> contained the invalid character(s) <characters> and has been changed to mrkaufma. Please use only the characters 0-9 a-z A-Z _ - or . in your username. Your username is the part before the @ in your email address.
        ERR_HOSTILENAME, // = 455,
        ERR_ACCEPTFULL, // = 456
        ERR_ACCEPTEXIST, // = 457,
        ERR_ACCEPTNOT, // = 458,
        ERR_NOHIDING, // = 459,
        ERR_NOTFORHALFOPS, // = 460,
        ERR_NEEDMOREPARAMS, // = 461,   // "<command> :Not enough parameters"
        ERR_ALREADYREGISTERED, // = 462,// ":You may not reregister"
        ERR_NOPERMFORHOST, // = 463,    // ":Your host isn't among the privileged"
        ERR_PASSWDMISMATCH, // = 464,   // ":Password incorrect"
        ERR_YOUREBANNEDCREEP, // = 465, // ":You are banned from this server"
        ERR_YOUWILLBEBANNED, // = 466   // (reserved numeric)
        ERR_KEYSET, // = 467,           // "<channel> :Channel key already set"
        ERR_NOCODEPAGE, // = 468,       // CONFLICT
        ERR_ONLYSERVERSCANCHANGE, // = 468,// CONFLICT
        ERR_INVALIDUSERNAME, // = 468,
        ERR_LINKSET, // = 469,
        ERR_7BIT, // = 470,             // CONFLICT
        ERR_KICKEDFROMCHAN, // = 470,   // CONFLICT
        ERR_LINKCHANNEL, // = 470       // <#original> <#new> :Forwarding to another channel
        ERR_CHANNELISFULL, // = 471,    // "<channel> :Cannot join channel (+l)"
        ERR_UNKNOWNMODE, // = 472,      // "<char> :is unknown mode char to me"
        ERR_INVITEONLYCHAN, // = 473,   // "<channel> :Cannot join channel (+i)"
        ERR_BANNEDFROMCHAN, // = 474,   // "<channel> :Cannot join channel (+b)"
        ERR_BADCHANNELKEY, // = 475,    // "<channel> :Cannot join channel (+k)"
        ERR_BADCHANMASK, // = 476,      // (reserved numeric)
        ERR_NOCHANMODES, // = 477       // CONFLICT
        ERR_NEEDREGGEDNICK, // = 477    // <nickname> <channel> :Cannot join channel (+r) - you need to be identified with services
        ERR_BANLISTFULL, // = 478,
        ERR_NOCOLOR, // = 479,          // CONFLICT
        ERR_BADCHANNAME, // = 479,      // CONFLICT
        ERR_LINKFAIL, // = 479,
        ERR_THROTTLE, // = 480,         // CONFLICT
        ERR_NOWALLOP, // = 480,         // CONFLICT
        ERR_SSLONLYCHAN, // = 480,      // CONFLICT
        ERR_NOULINE, // = 480,          // CONFLICT
        ERR_CANNOTKNOCK, // = 480,
        ERR_NOPRIVILEGES, // = 481,     // ":Permission Denied- You're not an IRC operator"
        ERR_CHANOPRIVSNEEDED, // = 482, // [sic] "<channel> :You're not channel operator"
        ERR_CANTKILLSERVER, // = 483,   // ":You cant kill a server!"
        ERR_ATTACKDENY, // = 484,        // CONFLICT
        ERR_DESYNC, // = 484,           // CONFLICT
        ERR_ISCHANSERVICE, // = 484,    // CONFLICT
        ERR_RESTRICTED, // = 484,
        ERR_BANNEDNICK, // = 485,       // CONFLICT
        ERR_CHANBANREASON, // = 485,    // CONFLICT
        ERR_KILLDENY, // = 485,         // CONFLICT
        ERR_CANTKICKADMIN, // = 485,    // CONFLICT
        ERR_ISREALSERVICE, // = 485,    // CONFLICT
        ERR_UNIQPRIVSNEEDED, // = 485,
        ERR_ACCOUNTONLY, // = 486,      // CONFLICT
        ERR_RLINED, // = 486,           // CONFLICT
        ERR_HTMDIABLED, // = 486,       // CONFLICT
        ERR_NONONREG, // = 486,
        ERR_NONONSSL, // = 487,         // CONFLICT
        ERR_NOTFORUSERS, // = 487,      // CONFLICT
        ERR_CHANTOORECENT, // = 487,    // CONFLICT
        ERR_MSGSERVICES, // = 487       // <nickname> :Error! "/msg NickServ" is no longer supported. Use "/msg NickServ@services.dal.net" or "/NickServ" instead.
        ERR_HTMDISABLED, // = 488,      // CONFLICT
        ERR_NOSSL, // = 488,            // CONFLICT
        ERR_TSLESSCHAN, // = 488,
        ERR_VOICENEEDED, // = 489,      // CONFLICT
        ERR_SECUREONLYCHAN, // = 489,
        ERR_NOSWEAR, // = 490,          // CONFLICT
        ERR_ALLMUSTSSL, // = 490,
        ERR_NOOPERHOST, // = 491,       // ":No O-lines for your host"
        ERR_CANNOTSENDTOUSER, // = 492, // CONFLICT
        ERR_NOCTCP, // = 492,           // CONFLICT
        ERR_NOTCP, // = 492,            // CONFLICT
        ERR_NOSERVICEHOST, // = 492,    // (reserved numeric)
        ERR_NOSHAREDCHAN, // = 493      // CONFLICT
        ERR_NOFEATURE, // = 493,
        ERR_OWNMODE, // = 494,          // CONFLICT
        ERR_BADFEATVALUE, // = 494,
        ERR_DELAYREJOIN, // = 495,      // CONFLICT
        ERR_BADLOGTYPE, // = 495,
        ERR_BADLOGSYS, // = 496,
        ERR_BADLOGVALUE, // = 497,
        ERR_ISOPERLCHAN, // = 498,
        ERR_CHANOWNPRIVNEEDED, // = 499,

        ERR_NOREHASHPARAM, // = 500,    // CONFLICT
        ERR_TOOMANYJOINS, // = 500,
        ERR_UNKNOWNSNOMASK, // = 501,    // CONFLICT
        ERR_UMODEUNKNOWNFLAG, // = 501, // ":Unknown MODE flag"
        ERR_USERSDONTMATCH, // = 502,   // ":Cant change mode for other users"
        ERR_VWORLDWARN, // = 503,       // CONFLICT
        ERR_GHOSTEDCLIENT, // = 503,
        ERR_USERNOTONSERV, // = 504,
        ERR_SILELISTFULL, // = 511,
        ERR_NOSUCHGLINE, // = 512,      // CONFLICT
        ERR_TOOMANYWATCH, // = 512,
        ERR_BADPING, // = 513,          // <nickname> :To connect type /QUOTE PONG <number>
        ERR_NOSUCHJUPE, // = 514,       // CONFLICT
        ERR_TOOMANYDCC, // = 514,       // CONFLICT
        ERR_INVALID_ERROR, // = 514,
        ERR_BADEXPIRE, // = 515,
        ERR_DONTCHEAT, // = 516,
        ERR_DISABLED, // = 517,
        ERR_NOINVITE, // = 518,         // CONFLICT
        ERR_LONGMASK, // = 518,
        ERR_ADMONLY, // = 519,          // CONFLICT
        ERR_TOOMANYUSERS, // = 519,
        ERR_WHOTRUNC, // = 520,         // CONFLICT
        ERR_MASKTOOWIDE, // = 520,      // CONFLICT
        ERR_OPERONLY, // = 520,
        //ERR_NOSUCHGLINE, // = 521,      // CONFLICT
        ERR_LISTSYNTAX, // = 521,
        ERR_WHOSYNTAX, // = 522,
        ERR_WHOLIMEXCEED, // = 523,
        ERR_HELPNOTFOUND, // = 524,     // CONFLICT
        ERR_OPERSPVERIFY, // = 524,     // CONFLICT
        ERR_QUARANTINED, // = 524,
        ERR_INVALIDKEY, // = 525,       // CONFLICT
        ERR_REMOTEPFX, // = 525,
        ERR_PFXUNROUTABLE, // = 526,
        ERR_CANTSENDTOUSER, // = 531,
        ERR_BADHOSTMASK, // = 550,
        ERR_HOSTUNAVAIL, // = 551,
        ERR_USINGSLINE, // = 552,
        ERR_STATSSLINE, // = 553,
        ERR_NOTLOWEROPLEVEL, // = 560,
        ERR_NOTMANAGER, // = 561,
        ERR_CHANSECURED, // = 562,
        ERR_UPASSSET, // = 563,
        ERR_UPASSNOTSET, // = 564,
        ERR_NOMANAGER, // = 566,
        ERR_UPASS_SAME_APASS, // = 567,
        RPL_NOMOTD, // = 568            // CONFLICT
        ERR_LASTERROR, // = 568,
        RPL_REAWAY, // = 597,
        RPL_GONEAWAY, // = 598,
        RPL_NOTAWAY, // = 599,

        RPL_LOGON, // = 600,
        RPL_LOGOFF, // = 601,
        RPL_WATCHOFF, // = 602,
        RPL_WATCHSTAT, // = 603,
        RPL_NOWON, // = 604,
        RPL_NOWFF, // = 605,
        RPL_WATCHLIST, // = 606,
        RPL_ENDOFWATCHLIST, // = 607,
        RPL_WATCHCLEAR, // = 608,
        RPL_NOWISAWAY, // = 609,
        RPL_ISOPER, // = 610            // CONFLICT
        //RPL_MAPMORE, // = 610,
        RPL_ISLOCOP, // = 611,
        RPL_ISNOTOPER, // = 612,
        RPL_ENDOFISOPER, // = 613,
        //RPL_MAPMORE, // = 615,       // CONFLICT
        //RPL_WHOISMODES, // = 615,
        //RPL_WHOISHOST, // = 616,
        RPL_WHOISSSLFP, // = 617,       // CONFLICT
        //RPL_WHOISBOT, // = 617,         // CONFLICT
        RPL_DCCSTATUS, // = 617,
        RPL_DCCLIST, // = 618,
        RPL_WHOWASHOST, // = 619,       // CONFLICT
        RPL_ENDOFDCCLIST, // = 619,
        //RPL_RULESSTART, // = 620,       // CONFLICT
        RPL_DCCINFO, // = 620,
        //RPL_RULES, // = 621,
        //RPL_ENDOFRULES, // = 622,
        //RPL_MAPMORE, // = 623,
        RPL_OMOTDSTART, // = 624,
        RPL_OMOTD, // = 625
        RPL_ENDOFO, // = 626,
        RPL_SETTINGS, // = 630,
        RPL_ENDOFSETTINGS, // = 631,
        RPL_DUMPING, // = 640,
        RPL_DUMPRPL, // = 641,
        RPL_EODUMP, // = 642,
        RPL_SPAMCMDFWD, // = 659,
        RPL_TRACEROUTE_HOP, // = 660,
        RPL_TRACEROUTE_START, // = 661,
        RPL_MODECHANGEWARN, // = 662,
        RPL_CHANREDIR, // = 663,
        RPL_SERVMODEIS, // = 664,
        RPL_OTHERUMODEIS, // = 665,
        RPL_ENDOF_GENERIC, // = 666,
        RPL_WHOWASDETAILS, // = 670,    // CONFLICT
        RPL_STARTTLS, // = 670,
        RPL_WHOISSECURE, // = 671       // "<nickname> :is using a secure connection"
        RPL_UNKNOWNMODES, // = 672,     // CONFLICT
        RPL_WHOISREALIP, // 672,
        RPL_CANNOTSETMODES, // = 673,
        RPL_WHOISYOURID, // = 674,
        RPL_LUSERSTAFF, // = 678,
        RPL_TIMEONSERVERIS, // = 679,
        RPL_NETWORKS, // = 682,
        RPL_YOURLANGUAGEIS, // = 687,
        RPL_LANGUAGE, // = 688,
        RPL_WHOISSTAFF, // = 689,
        RPL_WHOISLANGUAGE, // = 690,
        ERR_STARTTLS, // = 691,

        //RPL_MODLIST, // = 702,          // CONFLICT
        RPL_COMMANDS, // = 702,
        RPL_ENDOFMODLIST, // = 703,     // CONFLICT
        RPL_COMMANDSEND, // = 703,
        RPL_HELPSTART, // = 704         // <nickname> index :Help topics available to users:
        RPL_HELPTXT, // = 705           // <nickname> index :ACCEPT\tADMIN\tAWAY\tCHALLENGE
        RPL_ENDOFHELP, // = 706         // <nickname> index :End of /HELP.
        ERR_TARGCHANGE, // = 707,
        RPL_ETRACEFULL, // = 708,
        RPL_ETRACE, // = 709,
        RPL_KNOCK, // = 710,
        RPL_KNOCKDLVR, // = 711,
        ERR_TOOMANYKNOCK, // = 712,
        ERR_CHANOPEN, // = 713,
        ERR_KNOCKONCHAN, // = 714,
        ERR_KNOCKDISABLED, // = 715,    // CONFLICT
        ERR_TOOMANYINVITE, // = 715,    // CONFLICT
        RPL_INVITETHROTTLE, // = 715,
        RPL_TARGUMODEG, // = 716,
        RPL_TARGNOTIFY, // = 717,
        RPL_UMODEGMSG, // = 718,
        //RPL_OMOTDSTART, // = 720
        //RPL_OMOTD, // = 721,
        RPL_ENDOFOMOTD, // = 722,
        ERR_NOPRIVS, // = 723,
        RPL_TESTMASK, // = 724,
        RPL_TESTLINE, // = 725,
        RPL_NOTESTLINE, // = 726,
        RPL_TESTMASKGECOS, // = 727,
        RPL_QUIETLIST, // = 728,
        RPL_ENDOFQUIETLIST, // = 729,
        RPL_MONONLINE, // = 730,
        RPL_MONOFFLINE, // = 731,
        RPL_MONLIST, // = 732,
        RPL_ENDOFMONLIST, // = 733,
        ERR_MONLISTFULL, // = 734,
        RPL_RSACHALLENGE2, // = 740,
        RPL_ENDOFRSACHALLENGE2, // = 741,
        ERR_MLOCKRESTRICTED, // = 742,
        ERR_INVALIDBAN, // = 743,
        ERR_TOPICLOCK, // = 744,
        RPL_SCANMATCHED, // = 750,
        RPL_SCANUMODES, // = 751,
        RPL_ETRACEEND, // = 759,
        RPL_WHOISKEYVALUE, // = 760,
        RPL_KEYVALUE, // = 761,
        RPL_METADATAEND, // = 762,
        ERR_METADATALIMIT, // = 764,
        ERR_TARGETINVALID, // = 765,
        ERR_NOMATCHINGKEY, // = 766,
        ERR_KEYINVALID, // = 767,
        ERR_KEYNOTSET, // = 768,
        ERR_KEYNOPERMISSION, // = 769,
        RPL_XINFO, // = 771,
        RPL_XINFOSTART, // = 773
        RPL_XINFOEND, // = 774,

        RPL_CHECK, // = 802,

        RPL_LOGGEDIN, // = 900,         // <nickname>!<ident>@<address> <nickname> :You are now logged in as <nickname>
        RPL_LOGGEDOUT, // = 901,
        ERR_NICKLOCKED, // = 902,
        RPL_SASLSUCCESS, // = 903,      // :cherryh.freenode.net 903 kameloso^ :SASL authentication successful
        ERR_SASLFAIL, // = 904,         // :irc.rizon.no 904 kameloso^^ :SASL authentication failed"
        ERR_SASLTOOLONG, // = 905,
        ERR_SASLABORTED, // = 906,      // :orwell.freenode.net 906 kameloso^ :SASL authentication aborted
        ERR_SASLALREADY, // = 907,
        RPL_SASLMECHS, // = 908,
        BOTSNOTWELCOME, // = 931,       // <nickname> :Malicious bot, spammers, and other automated systems of dubious origins are NOT welcome here.
        ERR_WORDFILTERED, // = 936,
        NICKUNLOCKED, // = 945,
        NICKNOTLOCKED, // = 946,
        ERR_CANTUNLOADMODULE, // = 972, // CONFLICT
        ERR_CANNOTDOCOMMAND, // = 972,
        ERR_CANNOTCHANGEUMODE, // = 973,
        ERR_CANTLOADMODULE, // = 974,   // CONFLICT
        ERR_CANNOTCHANGECHANMODE, // = 974,
        ERR_CANNOTCHANGESERVERMODE, // = 975,// CONFLICT
        //ERR_LASTERROR, // = 975,      // CONFLICT
        RPL_LOADEDMODULE, // = 975,
        ERR_CANNOTSENDTONICK, // = 976,
        ERR_UNKNOWNSERVERMODE, // = 977,
        ERR_SERVERMODELOCK, // = 979,
        ERR_BADCHARENCODING, // = 980,
        ERR_TOOMANYLANGUAGES, // = 981,
        ERR_NOLANGUAGE, // = 982,
        ERR_TEXTTOOSHORT, // = 983,

        ERR_NUMERIC_ERR, // = 999
    }


    Type type;
    string aux;
    uint num;
    long time;
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
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : format;

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
        unfamiliar,
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

    enum Daemon
    {
        unknown,
        unreal,
        inspircd,
        bahamut,
        ratbox,
        u2,
        hybrid,
        quakenet,
        rizon,
        undernet,

        ircu,
        aircd,
        rfc1459,
        rfc2812,
        nefarious,
        rusnet,
        austhex,
        ircnet,
        ptlink,
        ultimate,
        anothernet,
        sorircd,
        bdqircd,
        chatircd,
        charybdis,
        irch,
        ithildin,
    }

    Network network;
    Daemon daemon;
    string address = "irc.freenode.net";
    ushort port = 6667;

    @Unconfigurable
    {
        string resolvedAddress;
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : format;

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

    size_t lastWhois;

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : formattedWrite;

        sink.formattedWrite("n:%s l:%s a:%s i:%s s:%s%s w:%s",
            nickname, login, alias_, ident, address,
            special ? " (*)" : string.init, lastWhois);
    }
}

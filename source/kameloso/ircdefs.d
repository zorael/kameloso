/++
 +  Definitions of struct aggregates used throughout the program, representing
 +  `IRCEvent`s and thereto related objects like `IRCServer` and `IRCUser`.
 +/
module kameloso.ircdefs;

import kameloso.common : Hidden, Separator, Unconfigurable;

final:
@safe:
pure:
nothrow:


// IRCEvent
/++
 +  A single IRC event, parsed from server input.
 +
 +  The `IRCEvent` struct is a construct with fields extracted from raw server
 +  strings. Since structs are not polymorphic the `Type` enum dictates what
 +  kind of event it is.
 +/
struct IRCEvent
{
    /++
     +  `Type`s of `IRCEvent`s.
     +
     +  Taken from https://tools.ietf.org/html/rfc1459 with many additions.
     +
     +  https://www.alien.net.au/irc/irc2numerics.html
     +  https://defs.ircdocs.horse
     +
     +  Some are outright fabrications of ours, like `CHAN` and `QUERY`, to make
     +  things easier for plugins.
     +/
    enum Type
    {
        UNSET,      /// Invalid `IRCEvent` with no `Type`.
        ANY,        /// Meta-`Type` for *any* kind of `IRCEvent`.
        ERROR,      /// Generic error `Type`.
        NUMERIC,    /// *Numeric* event of an unknown `Type`.
        PRIVMSG,    /// Private message or channel message.
        CHAN,       /// Channel message.
        QUERY,      /// Private query message.
        EMOTE,      /// CTCP **ACTION**; `/me slaps Foo with a large trout`.
        SELFQUERY,  /// A message from you in a query (CAP `znc.in/self-message`).
        SELFCHAN,   /// A message from you in a channel (CAP `znc.in/self-message`).
        AWAY,       /// Someone flagged themselves as away (from keyboard).
        BACK,       /// Someone returned from `AWAY`.
        JOIN,       /// Someone joined a channel.
        PART,       /// Someone left a channel.
        QUIT,       /// Someone quit the server.
        KICK,       /// Someone was kicked from a channel.
        INVITE,     /// You were invited to a channel.
        NOTICE,     /// A server `NOTICE` event.
        PING,       /// The server periodically `PING`ed you.
        PONG,       /// The server actually `PONG`ed you.
        NICK,       /// Someone changed nickname.
        MODE,       /// Someone changed the modes of a channel.
        SELFQUIT,   /// You quit the server.
        SELFJOIN,   /// You joined a channel.
        SELFPART,   /// You left a channel.
        SELFMODE,   /// You changed your modes.
        SELFNICK,   /// You changed your nickname.
        SELFKICK,   /// You were kicked.
        TOPIC,      /// Someone changed channel topic.
        CAP,        /// CAPability exchange during connect.
        CTCP_VERSION,/// Something requested bot version info.
        CTCP_TIME,  /// Something requested your time.
        CTCP_PING,  /// Something pinged you.
        CTCP_CLIENTINFO,/// Something asked what CTCP events the bot can handle.
        CTCP_DCC,   /// Something requested a DCC connection (chat, file transfer).
        CTCP_SOURCE,/// Something requested an URL to the bot source code.
        CTCP_USERINFO,/// Something requested the nickname and user of the bot.
        CTCP_FINGER,/// Someone requested miscellaneous info about the bot.
        CTCP_LAG,   /// Something requested LAG info?
        CTCP_AVATAR,/// Someone requested an avatar image.
        CTCP_SLOTS, /// Someone broadcasted their file transfer slots.
        USERSTATE,  /// Twitch user information.
        ROOMSTATE,  /// Twitch channel information.
        GLOBALUSERSTATE,/// Twitch information about self upon login.
        CLEARCHAT,  /// Twitch `CLEARCHAT` event, clearing the chat or banning a user.
        USERNOTICE, /// Twitch subscription or resubscription event.
        HOSTTARGET, /// Twitch channel hosting target.
        HOSTSTART,  /// Twitch channel hosting start.
        HOSTEND,    /// Twitch channel hosting end.
        SUB,        /// Twitch subscription event.
        RESUB,      /// Twitch resub event.
        TEMPBAN,    /// Twitch temporary ban (seconds in `aux`).
        PERMBAN,    /// Twitch permanent ban.
        SUBGIFT,    /// Twitch subscription gift event.
        BITS,       /// Twitch "bits" donation.
        ACCOUNT,    /// Someone logged in on nickname services.
        SASL_AUTHENTICATE,/// SASL authentication negotiation.
        AUTH_CHALLENGE,/// Authentication challenge.
        AUTH_FAILURE,/// Authentication failure.
        CHGHOST,    /// User "changes host", which is a thing on some networks.
        ENDOFEXEMPTOPSLIST,// = 953 ///End of exempt channel ops list.

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
        //RPL_STATSBLINE, // = 222,     // CONFLICT
        RPL_SQLINE_NICK, // = 222,      // CONFLICT
        RPL_CODEPAGE, // = 222,         // CONFLICT
        RPL_STATSJLINE, // = 222,       // CONFLICT
        RPL_MODLIST, // = 222,
        RPL_STATSGLINE, // = 223,       // CONFLICT
        RPL_CHARSET, // = 223,          // CONFLICT
        RPL_STATSELINE, // = 223,
        RPL_STATSTLINE, // = 224,       // CONFLICT
        RPL_STATSFLINE, // = 224,
        //RPL_STATSELINE, // = 225,     // CONFLICT
        RPL_STATSZLINE, // = 225,       // CONFLICT
        RPL_STATSCLONE, // = 225,       // CONFLICT
        RPL_STATSDLINE, // = 225,
        //RPL_STATSNLINE, // = 226,     // CONFLICT
        RPL_STATSALINE, // = 226,       // CONFLICT
        RPL_STATSCOUNT, // = 226,
        //RPL_STATSGLINE, // = 227,     // CONFLICT
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
        //RPL_STATSFLINE, // = 238,     // Feature lines?
        RPL_STATSIAUTH, // = 239,
        RPL_STATSXLINE, // = 240,       // CONFLICT
        //RPL_STATSVLINE, // = 240,
        RPL_STATSLLINE, // = 241,       // "L <hostmask> * <servername> <maxdepth>"
        RPL_STATSUPTIME, // = 242,      // ":Server Up %d days %d:%02d:%02d"
        RPL_STATSOLINE, // = 243,       // "O <hostmask> * <name>"
        RPL_STATSHLINE, // = 244,       // "H <hostmask> * <servername>"
        //RPL_STATSTLINE, // = 245,     // CONFLICT
        RPL_STATSSLINE, // = 245,
        RPL_STATSSERVICE, // = 246,     // CONFLICT
        //RPL_STATSTLINE, // = 246,     // CONFLICT
        RPL_STATSULINE, // = 246,       // CONFLICT
        RPL_STATSPING, // = 246,
        //RPL_STATSXLINE, // = 247,     // CONFLICT
        //RPL_STATSGLINE, // = 247,     // CONFLICT
        //RPL_STATSBLINE, // = 247,
        RPL_STATSDEFINE, // = 248,      // CONFLICT
        //RPL_STATSULINE, // = 248,
        RPL_STATSDEBUG, // = 249,       // CONFLICT
        //RPL_STATSULINE, // = 249,
        //RPL_STATSDLINE, // = 250,     // CONFLICT
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
        //RPL_USINGSSL, // = 275,       // CONFLICT
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
        RPL_USERIP, // = 307,           // CONFLICT
        RPL_WHOISREGNICK, // = 307      // <nickname> :has identified for this nick
        RPL_WHOISADMIN, // = 308,       // CONFLICT
        RPL_RULESSTART, // = 308,       // CONFLICT
        RPL_NOTIFYACTION, // = 308,
        RPL_WHOISHELPER, // = 309,      // CONFLICT
        RPL_ENDOFRULES, // = 309,       // CONFLICT
        //RPL_WHOISADMIN, // = 309,     // CONFLICT
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
        //RPL_WHOISHOST, // = 327,        // CONFLICT
        RPL_CHPASSUNKNOWN, // = 327,
        RPL_CHANNEL_URL, // = 328       // "http://linux.chat"
        RPL_CREATIONTIME, // = 329,
        RPL_WHOWAS_TIME, // = 330,      // CONFLICT
        RPL_WHOISACCOUNT, // = 330      // "<nickname> <account> :is logged in as"
        RPL_NOTOPIC, // = 331,          // "<channel> :No topic is set"
        RPL_TOPIC, // = 332,            // "<channel> :<topic>"
        RPL_TOPICWHOTIME, // = 333,     // "#channel user!~ident@address 1476294377"
        RPL_COMMANDSYNTAX, // = 334,    // CONFLICT
        RPL_LISTSYNTAX, // = 334,       // CONFLICT
        RPL_LISTUSAGE, // = 334,
        RPL_WHOISTEXT, // = 335,        // CONFLICT
        RPL_WHOISACCOUNTONLY, // = 335, // CONFLICT
        RPL_WHOISBOT, // = 335,         // "<nick> <othernick> :is a Bot on <server>"
        //RPL_WHOISBOT, // = 336,       // CONFLICT
        RPL_INVITELIST, // = 336,
        //RPL_WHOISTEXT, // = 337,      // CONFLICT
        RPL_ENDOFINVITELIST, // = 337,  // CONFLICT
        RPL_CHANPASSOK, // = 338,       // CONFLICT
        RPL_WHOISACTUALLY, // = 338,
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
        //RPL_MOTD, // = 378,           // CONFLICT
        RPL_WHOISHOST, // = 378         // <nickname> :is connecting from *@<address> <ip>
        RPL_KICKLINKED, // = 379,       // CONFLICT
        RPL_WHOWASIP, // = 379,         // CONFLICT
        RPL_WHOISMODES, // = 379,       // <nickname> :is using modes <modes>
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
        //RPL_IRCOPS, // = 387,         // CONFLICT
        RPL_ENDOFQLIST, // = 387,
        //RPL_ENDOFIRCOPS, // = 388,    // CONFLICT
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
        ERR_SERVICENAMEINUSE, // = 434, //CONFLICT
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
        ERR_FORBIDDENCHANNEL, // = 448,
        ERR_NOTIMPLEMENTED, // = 449,
        ERR_NOTREGISTERED, // = 451,    // ":You have not registered"
        ERR_IDCOLLISION, // = 452,
        ERR_NICKLOST, // = 453,
        //ERR_IDCOLLISION, // = 455     // <nickname> :Your username <nickname> contained the invalid character(s) <characters> and has been changed to mrkaufma. Please use only the characters 0-9 a-z A-Z _ - or . in your username. Your username is the part before the @ in your email address.
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
        ERR_ATTACKDENY, // = 484,       // CONFLICT
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
        ERR_UNKNOWNSNOMASK, // = 501,   // CONFLICT
        ERR_UMODEUNKNOWNFLAG, // = 501, // ":Unknown MODE flag"
        ERR_USERSDONTMATCH, // = 502,   // ":Cant change mode for other users"
        ERR_VWORLDWARN, // = 503,       // CONFLICT
        ERR_GHOSTEDCLIENT, // = 503,
        ERR_USERNOTONSERV, // = 504,
        ERR_SILELISTFULL, // = 511,
        ERR_NOSUCHGLINE, // = 512,      // CONFLICT
        ERR_TOOMANYWATCH, // = 512,
        //ERR_NEEDPONG, // 513,         // CONFLICT
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
        //ERR_NOSUCHGLINE, // = 521,    // CONFLICT
        ERR_LISTSYNTAX, // = 521,
        ERR_WHOSYNTAX, // = 522,
        ERR_WHOLIMEXCEED, // = 523,
        ERR_OPERSPVERIFY, // = 524,     // CONFLICT
        ERR_QUARANTINED, // = 524,      // CONFLICT
        ERR_HELPNOTFOUND, // = 524,
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
        //RPL_MAPMORE, // = 615,        // CONFLICT
        //RPL_WHOISMODES, // = 615,
        //RPL_WHOISHOST, // = 616,
        RPL_WHOISSSLFP, // = 617,       // CONFLICT
        //RPL_WHOISBOT, // = 617,       // CONFLICT
        RPL_DCCSTATUS, // = 617,
        RPL_DCCLIST, // = 618,
        RPL_WHOWASHOST, // = 619,       // CONFLICT
        RPL_ENDOFDCCLIST, // = 619,
        //RPL_RULESSTART, // = 620,     // CONFLICT
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

        //RPL_MODLIST, // = 702,        // CONFLICT
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
        RPL_QUIETLIST, // = 728,        // also 344 on oftc
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
        ENDOFSPAMFILTERLIST, // = 940,  // <nickname> <channel> :End of channel spamfilter list
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

    /*
        /// Run this to generate the Type[n] map.
        void generateTypenums()
        {
            import std.regex;
            import std.algorithm;
            import std.stdio;

            enum pattern = r" *([A-Z0-9_]+),? [/= ]* ([0-9]+),?.*";
            static engine = ctRegex!pattern;
            string[1024] arr;

            foreach (line; s.splitter("\n"))
            {
                auto hits = line.matchFirst(engine);
                if (hits.length < 2) continue;

                try
                {
                    size_t idx = hits[2].to!size_t;
                    if (arr[idx] != typeof(arr[idx]).init) stderr.writeln("DUPLICATE! ", idx);
                    arr[idx] = hits[1];
                }
                catch (Exception e)
                {
                    //writeln(e.msg, ": ", line);
                }
            }

            writeln("static immutable Type[1024] typenums =\n[");

            foreach (i, val; arr)
            {
                if (!val.length) continue;

                writefln("    %-3d : Type.%s,", i, val);
            }

            writeln("];");
        }
    */

    /// The event type, signifying what *kind* of event this is.
    Type type;

    /// The raw IRC string, untouched.
    string raw;

    /// The name of whoever (or whatever) sent this event.
    IRCUser sender;

    /// The channel the event transpired in, or is otherwise related to.
    string channel;

    /// The target of the event. May be a nickname or a channel.
    IRCUser target;

    /// The main body of the event.
    string content;

    /// The auxiliary storage, containing type-specific extra bits of information.
    string aux;

    /// IRCv3 message tags attached to this event.
    string tags;

    /++
     +  With a numeric event, the number of the event type, alternatively some
     +  other kind of arbitrary numeral associated with the event (such a Twitch
     +  resub number of months).
     +/
    uint num;

    /// A timestamp of when the event transpired.
    long time;
}


/++
 +  Aggregate collecting all the relevant settings, options and state needed for
 +  an IRC bot. Many fields are transient and unfit to be saved to disk, and
 +  some are simply too sensitive for it.
 +/
struct IRCBot
{
    /// Bot nickname.
    string nickname   = "kameloso";

    /// Bot "user" or full name.
    string user       = "kameloso!";

    /// Bot IDENT identifier.
    string ident      = "NaN";

    /// Default reason given when quitting without specifying one.
    string quitReason = "beep boop I am a bot";

    /// Username to use for services account.
    string authLogin;

    @Hidden
    {
        /// Password for services account.
        string authPassword;

        /// Login `PASS`, different from `SASL` and services.
        string pass;
    }

    @Separator(",")
    {
        /// The nickname services accounts of the bot's *administrators*.
        string[] admins;

        /// List of homes, where the bot should be active.
        string[] homes;

        /// Whitelist of services accounts that may trigger the bot.
        string[] whitelist;

        /// Currently inhabited channels (though not neccessarily homes).
        string[] channels;
    }

    /// Status of a process.
    enum Status
    {
        unset,
        notStarted,
        started,
        finished,
    }

    @Unconfigurable
    {
        /// The current `IRCServer` we're connected to.
        IRCServer server;

        /// The original bot nickname before connecting, in case it changed.
        string origNickname;

        /// Status of authentication process (SASL, NickServ).
        Status authentication;

        /// Status of registration process (logon).
        Status registration;

        /// Whether or not the bot was altered.
        bool updated;
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : format;

        sink("%s:%s!~%s | homes:%s | chans:%s | whitelist:%s | server:%s"
             .format(nickname, authLogin, ident, homes, channels, whitelist, server));
    }
}


/++
 +  Aggregate of all information and state pertaining to the connected IRC
 +  server. Some fields are transient on a per-connection basis and should not
 +  be saved to the configuration file.
 +/
struct IRCServer
{
    /++
     +  Server daemons, or families of server programs.
     +
     +  Many daemons handle some events slightly differently than others do, and
     +  by tracking which daemon the server is running we can apply the
     +  differences and always have an appropriate tables of events.
     +/
    enum Daemon
    {
        unset,      /// Unset or invalid daemon.
        unknown,    /// Reported but unknown daemon.

        unreal,
        inspircd,
        bahamut,
        ratbox,
        u2,
        hybrid,
        snircd,
        rizon,
        undernet,
        ircdseven,
        twitch,

        charybdis,
        sorircd,

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
        bdqircd,
        chatircd,
        irch,
        ithildin,
    }

    /// Server address (or IP).
    string address = "irc.freenode.net";

    /// The port to connect to, usually 6667-6669.
    ushort port = 6667;

    @Unconfigurable
    {
        /// The server daemon family the server is running.
        Daemon daemon;

        /// Server network string, like Freenode, QuakeNet, Rizon.
        string network;

        /// The reported daemon, with version.
        string daemonstring;

        /// The IRC server address handed to us by the round robin pool.
        string resolvedAddress;

        /// Max nickname length as per IRC specs, but not the de facto standard.
        uint maxNickLength = 9;

        /// Max channel name length as per IRC specs.
        uint maxChannelLength = 200;

        /+
         +  A = Mode that adds or removes a nick or address to a list.
         +      Always has a parameter.
         +/
        string aModes;

        /// B = Mode that changes a setting and always has a parameter.
        string bModes;

        /// C = Mode that changes a setting and only has a parameter when set.
        string cModes;

        /// D = Mode that changes a setting and never has a parameter.
        string dModes;

        /// Prefix characters by mode character; o by @, v by +, etc.
        char[char] prefixchars;

        /// Characer channel mode prefixes (o,v,h,...)
        string prefixes;

        /++
        +  Supported channel prefix characters, as announced by the server in
        +  the `ISUPPORT` event, before the MOTD.
        +/
        string chantypes = "#";
    }

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : format;

        sink("[Daemon.%s@%s] %s:%d (%s)"
            .format(daemon, network, address, port,resolvedAddress));
    }
}


/++
 +  An aggregate of fields representing a single user on IRC. Instances of these
 +  should not survive a disconnect and reconnect; they are on a per-connection
 +  basis.
 +/
struct IRCUser
{
    @safe:

    /// The user's nickname.
    string nickname;

    /// The alternate "display name" of the user, such as those on Twitch.
    string alias_;

    /// Ther user's IDENT identification.
    string ident;

    /// The reported user address, which may be a cloak.
    string address;

    /// Services account name (to `NickServ`, `AuthServ`, `Q`, etc).
    string account;

    /// The highest priority "badge" the sender has, in this context.
    string badge;

    /// The colour (RRGGBB) to tint the user's nickname with.
    string colour;

    /++
     +  Flag that the user is "special", which is usually that it is a service
     +  like nickname services, or channel or memo or spam.
     +/
    bool special;

    /// Timestamp when the user was last `WHOIS`ed, so it's not done too often.
    long lastWhois;

    /// How many references to this user exists (in channels).
    int refcount;

    /// Create a new `IRCUser` based on a `*!*@*` mask string.
    this(string userstring) pure
    {
        import std.format : formattedRead;

        userstring.formattedRead("%s!%s@%s", nickname, ident, address);
        if (nickname == "*") nickname = string.init;
        if (ident == "*") ident = string.init;
        if (address == "*") address = string.init;
    }

    /++
     +  Create a new `IRCUser` inheriting passed `nickname`, `ident`, and
     +  `address` strings.
     +/
    this(const string nickname, const string ident, const string address) pure nothrow @nogc
    {
        this.nickname = nickname;
        this.ident = ident;
        this.address = address;
    }

    /// Formats the `IRCBot` to a humanly readable (and printable) string.
    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : formattedWrite;

        sink.formattedWrite("n:%s L:%s a:%s i!%s A:%s%s w:%s   [%d]",
            nickname, account, alias_, ident, address,
            special ? "*" : string.init, lastWhois, refcount);
    }

    /// Guesses that a sender is a server.
    bool isServer() pure @property const
    {
        import kameloso.string : has;
        return (!nickname.length && address.has('.'));
    }


    // matchesByMask
    /++
     +  Compares this `IRCUser` with a second one, treating fields with
     +  asterisks as glob wildcards, mimicking `*!*@*` mask matching.
     +
     +  Example:
     +  ------------
     +  IRCUser u1;
     +  with (u1)
     +  {
     +      nickname = "foo";
     +      ident = "NaN";
     +      address = "asdf.asdf.com";
     +  }
     +
     +  IRCUser u2;
     +  with (u2)
     +  {
     +      nickname = "*";
     +      ident = "NaN";
     +      address = "*";
     +  }
     +
     +  assert(u1.matchesByMask(u2));
     +  ------------
     +
     +  Params:
     +      other = `IRCUser` to compare this one with.
     +
     +  Returns:
     +      `true` if the `IRCUser`s are deemed to match, `false` if not.
     +
     +  TODO:
     +      Support partial globs.
     +/
    bool matchesByMask(IRCUser other) pure nothrow @nogc const
    {
        // Match first
        // If no match and either is empty, that means they're *
        immutable matchNick = ((this.nickname == other.nickname) ||
            (!this.nickname.length || !other.nickname.length));
        if (!matchNick) return false;

        immutable matchIdent = ((ident == other.ident) ||
            (!this.ident.length || !other.ident.length));
        if (!matchIdent) return false;

        immutable matchAddress = ((address == other.address) ||
            (!this.address.length || !other.address.length));
        if (!matchAddress) return false;

        return true;
    }

    /// Ditto
    bool matchesByMask(const string userstring) pure const
    {
        return matchesByMask(IRCUser(userstring));
    }
}


// Typenums
/++
 +  Reverse mappings of *numerics* to `IRCEvent.Type`s.
 +
 +  One `base` table that covers most cases, and then specialised arrays for
 +  different server daemons, to meld into `base` for a union of the two
 +  (or more). This speeds up translation greatly and allows us to have
 +  different mappings for different daemons.
 +/
struct Typenums
{
    alias Type = IRCEvent.Type;

    /// Default mappings
    static immutable Type[1024] base =
    [
        1   : Type.RPL_WELCOME,
        2   : Type.RPL_YOURHOST,
        3   : Type.RPL_CREATED,
        4   : Type.RPL_MYINFO,
        5   : Type.RPL_ISUPPORT,
        6   : Type.RPL_MAP,
        7   : Type.RPL_MAPEND,
        8   : Type.RPL_SNOMASK,
        9   : Type.RPL_STATMEMTOT,
        10  : Type.RPL_STATMEM,
        14  : Type.RPL_YOURCOOKIE,
        15  : Type.RPL_MAP,
        16  : Type.RPL_MAPMORE,
        17  : Type.RPL_MAPEND,
        20  : Type.RPL_HELLO,
        30  : Type.RPL_APASSWARN_SET,
        31  : Type.RPL_APASSWARN_SECRET,
        32  : Type.RPL_APASSWARN_CLEAR,
        42  : Type.RPL_YOURID,
        43  : Type.RPL_SAVENICK,
        50  : Type.RPL_ATTEMPTINGJUNC,
        51  : Type.RPL_ATTEMPTINGREROUTE,
        105 : Type.RPL_REMOTEISUPPORT,
        200 : Type.RPL_TRACELINK,
        201 : Type.RPL_TRACECONNECTING,
        202 : Type.RPL_TRACEHANDSHAKE,
        203 : Type.RPL_TRACEUNKNOWN,
        204 : Type.RPL_TRACEOPERATOR,
        205 : Type.RPL_TRACEUSER,
        206 : Type.RPL_TRACESERVER,
        207 : Type.RPL_TRACESERVICE,
        208 : Type.RPL_TRACENEWTYPE,
        209 : Type.RPL_TRACECLASS,
        210 : Type.RPL_STATS,
        211 : Type.RPL_STATSLINKINFO,
        212 : Type.RPL_STATSCOMMAND,
        213 : Type.RPL_STATSCLINE,
        214 : Type.RPL_STATSNLINE,
        215 : Type.RPL_STATSILINE,
        216 : Type.RPL_STATSKLINE,
        217 : Type.RPL_STATSQLINE,
        218 : Type.RPL_STATSYLINE,
        219 : Type.RPL_ENDOFSTATS,
        220 : Type.RPL_STATSPLINE,
        221 : Type.RPL_UMODEIS,
        222 : Type.RPL_MODLIST,
        223 : Type.RPL_STATSELINE,
        224 : Type.RPL_STATSFLINE,
        225 : Type.RPL_STATSDLINE,
        226 : Type.RPL_STATSCOUNT,
        227 : Type.RPL_STATSBLINE,
        228 : Type.RPL_STATSQLINE,
        229 : Type.RPL_STATSSPAMF,
        230 : Type.RPL_STATSEXCEPTTKL,
        231 : Type.RPL_SERVICEINFO,
        232 : Type.RPL_ENDOFSERVICES,
        233 : Type.RPL_SERVICE,
        234 : Type.RPL_SERVLIST,
        235 : Type.RPL_SERVLISTEND,
        236 : Type.RPL_STATSVERBOSE,
        237 : Type.RPL_STATSENGINE,
        238 : Type.RPL_STATSFLINE,
        239 : Type.RPL_STATSIAUTH,
        240 : Type.RPL_STATSVLINE,
        241 : Type.RPL_STATSLLINE,
        242 : Type.RPL_STATSUPTIME,
        243 : Type.RPL_STATSOLINE,
        244 : Type.RPL_STATSHLINE,
        245 : Type.RPL_STATSSLINE,
        246 : Type.RPL_STATSPING,
        247 : Type.RPL_STATSBLINE,
        248 : Type.RPL_STATSULINE,
        249 : Type.RPL_STATSULINE,
        250 : Type.RPL_STATSCONN,
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
        262 : Type.RPL_TRACEPING,
        263 : Type.RPL_TRYAGAIN,
        264 : Type.RPL_USINGSSL,
        265 : Type.RPL_LOCALUSERS,
        266 : Type.RPL_GLOBALUSERS,
        267 : Type.RPL_START_NETSTAT,
        268 : Type.RPL_NETSTAT,
        269 : Type.RPL_END_NETSTAT,
        270 : Type.RPL_PRIVS,
        271 : Type.RPL_SILELIST,
        272 : Type.RPL_ENDOFSILELIST,
        273 : Type.RPL_NOTIFY,
        274 : Type.RPL_ENDNOTIFY,
        275 : Type.RPL_STATSDLINE,
        276 : Type.RPL_STATSRLINE,
        277 : Type.RPL_VCHANLIST,
        278 : Type.RPL_VCHANHELP,
        280 : Type.RPL_GLIST,
        281 : Type.RPL_ACCEPTLIST,
        282 : Type.RPL_ENDOFACCEPT,
        283 : Type.RPL_ALIST,
        284 : Type.RPL_ENDOFALIST,
        285 : Type.RPL_GLIST_HASH,
        286 : Type.RPL_CHANINFO_USERS,
        287 : Type.RPL_CHANINFO_CHOPS,
        288 : Type.RPL_CHANINFO_VOICES,
        289 : Type.RPL_CHANINFO_AWAY,
        290 : Type.RPL_CHANINFO_OPERS,
        291 : Type.RPL_CHANINFO_BANNED,
        292 : Type.RPL_CHANINFO_BANS,
        293 : Type.RPL_CHANINFO_INVITE,
        294 : Type.RPL_CHANINFO_INVITES,
        295 : Type.RPL_CHANINFO_KICK,
        296 : Type.RPL_CHANINFO_KICKS,
        299 : Type.RPL_END_CHANINFO,
        300 : Type.RPL_NONE,
        301 : Type.RPL_AWAY,
        302 : Type.RPL_USERHOST,
        303 : Type.RPL_ISON,
        304 : Type.RPL_TEXT,
        305 : Type.RPL_UNAWAY,
        306 : Type.RPL_NOWAWAY,
        307 : Type.RPL_WHOISREGNICK,
        308 : Type.RPL_NOTIFYACTION,
        309 : Type.RPL_NICKTRACE,
        310 : Type.RPL_WHOISSVCMSG,
        311 : Type.RPL_WHOISUSER,
        312 : Type.RPL_WHOISSERVER,
        313 : Type.RPL_WHOISOPERATOR,
        314 : Type.RPL_WHOWASUSER,
        315 : Type.RPL_ENDOFWHO,
        316 : Type.RPL_WHOISCHANOP,
        317 : Type.RPL_WHOISIDLE,
        318 : Type.RPL_ENDOFWHOIS,
        319 : Type.RPL_WHOISCHANNELS,
        320 : Type.RPL_WHOISSPECIAL,
        321 : Type.RPL_LISTSTART,
        322 : Type.RPL_LIST,
        323 : Type.RPL_LISTEND,
        324 : Type.RPL_CHANNELMODEIS,
        325 : Type.RPL_CHANNELPASSIS,
        326 : Type.RPL_NOCHANPASS,
        327 : Type.RPL_CHPASSUNKNOWN,
        328 : Type.RPL_CHANNEL_URL,
        329 : Type.RPL_CREATIONTIME,
        330 : Type.RPL_WHOISACCOUNT,
        331 : Type.RPL_NOTOPIC,
        332 : Type.RPL_TOPIC,
        333 : Type.RPL_TOPICWHOTIME,
        334 : Type.RPL_LISTUSAGE,
        335 : Type.RPL_WHOISBOT,
        336 : Type.RPL_INVITELIST,
        337 : Type.RPL_ENDOFINVITELIST,
        338 : Type.RPL_WHOISACTUALLY,
        339 : Type.RPL_BADCHANPASS,
        340 : Type.RPL_USERIP,
        341 : Type.RPL_INVITING,
        342 : Type.RPL_SUMMONING,
        343 : Type.RPL_WHOISKILL,
        345 : Type.RPL_INVITED,
        346 : Type.RPL_INVITELIST,
        347 : Type.RPL_ENDOFINVITELIST,
        348 : Type.RPL_EXCEPTLIST,
        349 : Type.RPL_ENDOFEXCEPTLIST,
        351 : Type.RPL_VERSION,
        352 : Type.RPL_WHOREPLY,
        353 : Type.RPL_NAMREPLY,
        354 : Type.RPL_WHOSPCRPL,
        355 : Type.RPL_NAMREPLY_,
        357 : Type.RPL_MAP,
        358 : Type.RPL_MAPMORE,
        359 : Type.RPL_MAPEND,
        360 : Type.RPL_WHOWASREAL,
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
        377 : Type.RPL_KICKEXPIRED,
        378 : Type.RPL_WHOISHOST,
        379 : Type.RPL_WHOISMODES,
        380 : Type.RPL_BANLINKED,
        381 : Type.RPL_YOUREOPER,
        382 : Type.RPL_REHASHING,
        383 : Type.RPL_YOURESERVICE,
        384 : Type.RPL_MYPORTIS,
        385 : Type.RPL_NOTOPERANYMORE,
        386 : Type.RPL_QLIST,
        387 : Type.RPL_ENDOFQLIST,
        388 : Type.RPL_ALIST,
        389 : Type.RPL_ENDOFALIST,
        391 : Type.RPL_TIME,
        392 : Type.RPL_USERSTART,
        393 : Type.RPL_USERS,
        394 : Type.RPL_ENDOFUSERS,
        395 : Type.RPL_NOUSERS,
        396 : Type.RPL_HOSTHIDDEN,
        400 : Type.ERR_UNKNOWNERROR,
        401 : Type.ERR_NOSUCHNICK,
        402 : Type.ERR_NOSUCHSERVER,
        403 : Type.ERR_NOSUCHCHANNEL,
        404 : Type.ERR_CANNOTSENDTOCHAN,
        405 : Type.ERR_TOOMANYCHANNELS,
        406 : Type.ERR_WASNOSUCHNICK,
        407 : Type.ERR_TOOMANYTARGETS,
        408 : Type.ERR_NOSUCHSERVICE,
        409 : Type.ERR_NOORIGIN,
        410 : Type.ERR_INVALIDCAPCMD,
        411 : Type.ERR_NORECIPIENT,
        412 : Type.ERR_NOTEXTTOSEND,
        413 : Type.ERR_NOTOPLEVEL,
        414 : Type.ERR_WILDTOPLEVEL,
        415 : Type.ERR_BADMASK,
        416 : Type.ERR_TOOMANYMATCHES,
        417 : Type.ERR_INPUTTOOLONG,
        419 : Type.ERR_LENGTHTRUNCATED,
        421 : Type.ERR_UNKNOWNCOMMAND,
        422 : Type.ERR_NOMOTD,
        423 : Type.ERR_NOADMININFO,
        424 : Type.ERR_FILEERROR,
        425 : Type.ERR_NOOPERMOTD,
        429 : Type.ERR_TOOMANYAWAY,
        430 : Type.ERR_EVENTNICKCHANGE,
        431 : Type.ERR_NONICKNAMEGIVEN,
        432 : Type.ERR_ERRONEOUSNICKNAME,
        433 : Type.ERR_NICKNAMEINUSE,
        434 : Type.ERR_NORULES,
        435 : Type.ERR_BANONCHAN,
        436 : Type.ERR_NICKCOLLISION,
        437 : Type.ERR_UNAVAILRESOURCE,
        438 : Type.ERR_NICKTOOFAST,
        439 : Type.ERR_TARGETTOOFAST,
        440 : Type.ERR_SERVICESDOWN,
        441 : Type.ERR_USERNOTINCHANNEL,
        442 : Type.ERR_NOTONCHANNEL,
        443 : Type.ERR_USERONCHANNEL,
        444 : Type.ERR_NOLOGIN,
        445 : Type.ERR_SUMMONDISABLED,
        446 : Type.ERR_USERSDISABLED,
        447 : Type.ERR_NONICKCHANGE,
        448 : Type.ERR_FORBIDDENCHANNEL,
        449 : Type.ERR_NOTIMPLEMENTED,
        451 : Type.ERR_NOTREGISTERED,
        452 : Type.ERR_IDCOLLISION,
        453 : Type.ERR_NICKLOST,
        455 : Type.ERR_HOSTILENAME,
        456 : Type.ERR_ACCEPTFULL,
        457 : Type.ERR_ACCEPTEXIST,
        458 : Type.ERR_ACCEPTNOT,
        459 : Type.ERR_NOHIDING,
        460 : Type.ERR_NOTFORHALFOPS,
        461 : Type.ERR_NEEDMOREPARAMS,
        462 : Type.ERR_ALREADYREGISTERED,
        463 : Type.ERR_NOPERMFORHOST,
        464 : Type.ERR_PASSWDMISMATCH,
        465 : Type.ERR_YOUREBANNEDCREEP,
        466 : Type.ERR_YOUWILLBEBANNED,
        467 : Type.ERR_KEYSET,
        468 : Type.ERR_INVALIDUSERNAME,
        469 : Type.ERR_LINKSET,
        470 : Type.ERR_LINKCHANNEL,
        471 : Type.ERR_CHANNELISFULL,
        472 : Type.ERR_UNKNOWNMODE,
        473 : Type.ERR_INVITEONLYCHAN,
        474 : Type.ERR_BANNEDFROMCHAN,
        475 : Type.ERR_BADCHANNELKEY,
        476 : Type.ERR_BADCHANMASK,
        477 : Type.ERR_NEEDREGGEDNICK,
        478 : Type.ERR_BANLISTFULL,
        479 : Type.ERR_LINKFAIL,
        480 : Type.ERR_CANNOTKNOCK,
        481 : Type.ERR_NOPRIVILEGES,
        482 : Type.ERR_CHANOPRIVSNEEDED,
        483 : Type.ERR_CANTKILLSERVER,
        484 : Type.ERR_RESTRICTED,
        485 : Type.ERR_UNIQPRIVSNEEDED,
        486 : Type.ERR_NONONREG,
        487 : Type.ERR_MSGSERVICES,
        488 : Type.ERR_TSLESSCHAN,
        489 : Type.ERR_SECUREONLYCHAN,
        490 : Type.ERR_ALLMUSTSSL,
        491 : Type.ERR_NOOPERHOST,
        492 : Type.ERR_NOSERVICEHOST,
        493 : Type.ERR_NOFEATURE,
        494 : Type.ERR_BADFEATVALUE,
        495 : Type.ERR_BADLOGTYPE,
        496 : Type.ERR_BADLOGSYS,
        497 : Type.ERR_BADLOGVALUE,
        498 : Type.ERR_ISOPERLCHAN,
        499 : Type.ERR_CHANOWNPRIVNEEDED,
        500 : Type.ERR_TOOMANYJOINS,
        501 : Type.ERR_UMODEUNKNOWNFLAG,
        502 : Type.ERR_USERSDONTMATCH,
        503 : Type.ERR_GHOSTEDCLIENT,
        504 : Type.ERR_USERNOTONSERV,
        511 : Type.ERR_SILELISTFULL,
        512 : Type.ERR_TOOMANYWATCH,
        513 : Type.ERR_BADPING,
        514 : Type.ERR_INVALID_ERROR,
        515 : Type.ERR_BADEXPIRE,
        516 : Type.ERR_DONTCHEAT,
        517 : Type.ERR_DISABLED,
        518 : Type.ERR_LONGMASK,
        519 : Type.ERR_TOOMANYUSERS,
        520 : Type.ERR_OPERONLY,
        521 : Type.ERR_LISTSYNTAX,
        522 : Type.ERR_WHOSYNTAX,
        523 : Type.ERR_WHOLIMEXCEED,
        524 : Type.ERR_HELPNOTFOUND,
        525 : Type.ERR_REMOTEPFX,
        526 : Type.ERR_PFXUNROUTABLE,
        531 : Type.ERR_CANTSENDTOUSER,
        550 : Type.ERR_BADHOSTMASK,
        551 : Type.ERR_HOSTUNAVAIL,
        552 : Type.ERR_USINGSLINE,
        553 : Type.ERR_STATSSLINE,
        560 : Type.ERR_NOTLOWEROPLEVEL,
        561 : Type.ERR_NOTMANAGER,
        562 : Type.ERR_CHANSECURED,
        563 : Type.ERR_UPASSSET,
        564 : Type.ERR_UPASSNOTSET,
        566 : Type.ERR_NOMANAGER,
        567 : Type.ERR_UPASS_SAME_APASS,
        568 : Type.ERR_LASTERROR,
        597 : Type.RPL_REAWAY,
        598 : Type.RPL_GONEAWAY,
        599 : Type.RPL_NOTAWAY,
        600 : Type.RPL_LOGON,
        601 : Type.RPL_LOGOFF,
        602 : Type.RPL_WATCHOFF,
        603 : Type.RPL_WATCHSTAT,
        604 : Type.RPL_NOWON,
        605 : Type.RPL_NOWFF,
        606 : Type.RPL_WATCHLIST,
        607 : Type.RPL_ENDOFWATCHLIST,
        608 : Type.RPL_WATCHCLEAR,
        609 : Type.RPL_NOWISAWAY,
        610 : Type.RPL_MAPMORE,
        611 : Type.RPL_ISLOCOP,
        612 : Type.RPL_ISNOTOPER,
        613 : Type.RPL_ENDOFISOPER,
        615 : Type.RPL_WHOISMODES,
        616 : Type.RPL_WHOISHOST,
        617 : Type.RPL_DCCSTATUS,
        618 : Type.RPL_DCCLIST,
        619 : Type.RPL_ENDOFDCCLIST,
        620 : Type.RPL_DCCINFO,
        621 : Type.RPL_RULES,
        622 : Type.RPL_ENDOFRULES,
        623 : Type.RPL_MAPMORE,
        624 : Type.RPL_OMOTDSTART,
        625 : Type.RPL_OMOTD,
        626 : Type.RPL_ENDOFO,
        630 : Type.RPL_SETTINGS,
        631 : Type.RPL_ENDOFSETTINGS,
        640 : Type.RPL_DUMPING,
        641 : Type.RPL_DUMPRPL,
        642 : Type.RPL_EODUMP,
        659 : Type.RPL_SPAMCMDFWD,
        660 : Type.RPL_TRACEROUTE_HOP,
        661 : Type.RPL_TRACEROUTE_START,
        662 : Type.RPL_MODECHANGEWARN,
        663 : Type.RPL_CHANREDIR,
        664 : Type.RPL_SERVMODEIS,
        665 : Type.RPL_OTHERUMODEIS,
        666 : Type.RPL_ENDOF_GENERIC,
        670 : Type.RPL_STARTTLS,
        671 : Type.RPL_WHOISSECURE,
        672 : Type.RPL_WHOISREALIP,
        673 : Type.RPL_CANNOTSETMODES,
        674 : Type.RPL_WHOISYOURID,
        678 : Type.RPL_LUSERSTAFF,
        679 : Type.RPL_TIMEONSERVERIS,
        682 : Type.RPL_NETWORKS,
        687 : Type.RPL_YOURLANGUAGEIS,
        688 : Type.RPL_LANGUAGE,
        689 : Type.RPL_WHOISSTAFF,
        690 : Type.RPL_WHOISLANGUAGE,
        691 : Type.ERR_STARTTLS,
        702 : Type.RPL_COMMANDS,
        703 : Type.RPL_COMMANDSEND,
        704 : Type.RPL_HELPSTART,
        705 : Type.RPL_HELPTXT,
        706 : Type.RPL_ENDOFHELP,
        707 : Type.ERR_TARGCHANGE,
        708 : Type.RPL_ETRACEFULL,
        709 : Type.RPL_ETRACE,
        710 : Type.RPL_KNOCK,
        711 : Type.RPL_KNOCKDLVR,
        712 : Type.ERR_TOOMANYKNOCK,
        713 : Type.ERR_CHANOPEN,
        714 : Type.ERR_KNOCKONCHAN,
        715 : Type.RPL_INVITETHROTTLE,
        716 : Type.RPL_TARGUMODEG,
        717 : Type.RPL_TARGNOTIFY,
        718 : Type.RPL_UMODEGMSG,
        720 : Type.RPL_OMOTDSTART,
        721 : Type.RPL_OMOTD,
        722 : Type.RPL_ENDOFOMOTD,
        723 : Type.ERR_NOPRIVS,
        724 : Type.RPL_TESTMASK,
        725 : Type.RPL_TESTLINE,
        726 : Type.RPL_NOTESTLINE,
        727 : Type.RPL_TESTMASKGECOS,
        728 : Type.RPL_QUIETLIST,
        729 : Type.RPL_ENDOFQUIETLIST,
        730 : Type.RPL_MONONLINE,
        731 : Type.RPL_MONOFFLINE,
        732 : Type.RPL_MONLIST,
        733 : Type.RPL_ENDOFMONLIST,
        734 : Type.ERR_MONLISTFULL,
        740 : Type.RPL_RSACHALLENGE2,
        741 : Type.RPL_ENDOFRSACHALLENGE2,
        742 : Type.ERR_MLOCKRESTRICTED,
        743 : Type.ERR_INVALIDBAN,
        744 : Type.ERR_TOPICLOCK,
        750 : Type.RPL_SCANMATCHED,
        751 : Type.RPL_SCANUMODES,
        759 : Type.RPL_ETRACEEND,
        760 : Type.RPL_WHOISKEYVALUE,
        761 : Type.RPL_KEYVALUE,
        762 : Type.RPL_METADATAEND,
        764 : Type.ERR_METADATALIMIT,
        765 : Type.ERR_TARGETINVALID,
        766 : Type.ERR_NOMATCHINGKEY,
        767 : Type.ERR_KEYINVALID,
        768 : Type.ERR_KEYNOTSET,
        769 : Type.ERR_KEYNOPERMISSION,
        771 : Type.RPL_XINFO,
        773 : Type.RPL_XINFOSTART,
        774 : Type.RPL_XINFOEND,
        802 : Type.RPL_CHECK,
        900 : Type.RPL_LOGGEDIN,
        901 : Type.RPL_LOGGEDOUT,
        902 : Type.ERR_NICKLOCKED,
        903 : Type.RPL_SASLSUCCESS,
        904 : Type.ERR_SASLFAIL,
        905 : Type.ERR_SASLTOOLONG,
        906 : Type.ERR_SASLABORTED,
        907 : Type.ERR_SASLALREADY,
        908 : Type.RPL_SASLMECHS,
        931 : Type.BOTSNOTWELCOME,
        936 : Type.ERR_WORDFILTERED,
        940 : Type.ENDOFSPAMFILTERLIST,
        945 : Type.NICKUNLOCKED,
        946 : Type.NICKNOTLOCKED,
        972 : Type.ERR_CANNOTDOCOMMAND,
        973 : Type.ERR_CANNOTCHANGEUMODE,
        974 : Type.ERR_CANNOTCHANGECHANMODE,
        975 : Type.RPL_LOADEDMODULE,
        976 : Type.ERR_CANNOTSENDTONICK,
        977 : Type.ERR_UNKNOWNSERVERMODE,
        979 : Type.ERR_SERVERMODELOCK,
        980 : Type.ERR_BADCHARENCODING,
        981 : Type.ERR_TOOMANYLANGUAGES,
        982 : Type.ERR_NOLANGUAGE,
        983 : Type.ERR_TEXTTOOSHORT,
        999 : Type.ERR_NUMERIC_ERR,
    ];

    /++
     +  Delta typenum mappings for servers running the `UnrealIRCd` daemon.
     +
     +  https://www.unrealircd.org
     +/
    static immutable Type[975] unreal =
    [
        6 : Type.RPL_MAP,
        7 : Type.RPL_MAPEND,
        210 : Type.RPL_STATSHELP,
        220 : Type.RPL_STATSBLINE,
        222 : Type.RPL_SQLINE_NICK,
        223 : Type.RPL_STATSGLINE,
        224 : Type.RPL_STATSTLINE,
        225 : Type.RPL_STATSELINE,
        226 : Type.RPL_STATSNLINE,
        227 : Type.RPL_STATSVLINE,
        228 : Type.RPL_STATSBANVER,
        232 : Type.RPL_RULES,
        247 : Type.RPL_STATSXLINE,
        250 : Type.RPL_STATSCONN,
        290 : Type.RPL_HELPHDR,
        291 : Type.RPL_HELPOP,
        292 : Type.RPL_HELPTLR,
        293 : Type.RPL_HELPHLP,
        294 : Type.RPL_HELPFWD,
        295 : Type.RPL_HELPIGN,
        307 : Type.RPL_WHOISREGNICK,
        308 : Type.RPL_RULESSTART,
        309 : Type.RPL_ENDOFRULES,
        310 : Type.RPL_WHOISHELPOP,
        320 : Type.RPL_WHOISSPECIAL,
        334 : Type.RPL_LISTSYNTAX,
        335 : Type.RPL_WHOISBOT,
        378 : Type.RPL_WHOISHOST,
        379 : Type.RPL_WHOISMODES,
        386 : Type.RPL_QLIST,
        387 : Type.RPL_ENDOFQLIST,
        388 : Type.RPL_ALIST,
        434 : Type.ERR_NORULES,
        435 : Type.ERR_SERVICECONFUSED,
        438 : Type.ERR_ONLYSERVERSCANCHANGE,
        470 : Type.ERR_LINKCHANNEL,
        477 : Type.ERR_NEEDREGGEDNICK,
        479 : Type.ERR_LINKFAIL,
        480 : Type.ERR_CANNOTKNOCK,
        484 : Type.ERR_ATTACKDENY,
        485 : Type.ERR_KILLDENY,
        486 : Type.ERR_HTMDISABLED,         // CONFLICT ERR_NONONREG
        487 : Type.ERR_NOTFORUSERS,
        488 : Type.ERR_HTMDISABLED,         // again?
        489 : Type.ERR_SECUREONLYCHAN,      // AKA ERR_SSLONLYCHAN
        490 : Type.ERR_ALLMUSTSSL,          // CONFLICT ERR_NOSWEAR
        492 : Type.ERR_NOCTCP,
        500 : Type.ERR_TOOMANYJOINS,
        518 : Type.ERR_NOINVITE,
        519 : Type.ERR_ADMONLY,
        520 : Type.ERR_OPERONLY,
        524 : Type.ERR_OPERSPVERIFY,
        610 : Type.RPL_MAPMORE,
        972 : Type.ERR_CANNOTDOCOMMAND,
        974 : Type.ERR_CANNOTCHANGECHANMODE,
    ];

    /++
     +  Delta typenum mappings for servers running the `ircu` (Undernet) daemon.
     +
     +  http://coder-com.undernet.org
     +/
    static immutable Type[569] ircu =
    [
        15 : Type.RPL_MAP,
        16 : Type.RPL_MAPMORE,
        17 : Type.RPL_MAPEND,
        222 : Type.RPL_STATSJLINE,
        228 : Type.RPL_STATSQLINE,
        238 : Type.RPL_STATSFLINE,
        246 : Type.RPL_STATSTLINE,
        247 : Type.RPL_STATSGLINE,
        248 : Type.RPL_STATSULINE,
        250 : Type.RPL_STATSCONN,
        270 : Type.RPL_PRIVS,
        275 : Type.RPL_STATSDLINE,
        276 : Type.RPL_STATSRLINE,
        281 : Type.RPL_ENDOFGLIST,
        282 : Type.RPL_JUPELIST,
        283 : Type.RPL_ENDOFJUPELIST,
        284 : Type.RPL_FEATURE,
        330 : Type.RPL_WHOISACCOUNT,
        334 : Type.RPL_LISTUSAGE,
        338 : Type.RPL_WHOISACTUALLY,
        391 : Type.RPL_TIME,
        437 : Type.ERR_BANNICKCHANGE,
        438 : Type.ERR_NICKTOOFAST,
        468 : Type.ERR_INVALIDUSERNAME,
        477 : Type.ERR_NEEDREGGEDNICK,
        493 : Type.ERR_NOFEATURE,
        494 : Type.ERR_BADFEATVALUE,
        495 : Type.ERR_BADLOGTYPE,
        512 : Type.ERR_NOSUCHGLINE,
        514 : Type.ERR_INVALID_ERROR,
        518 : Type.ERR_LONGMASK,
        519 : Type.ERR_TOOMANYUSERS,
        520 : Type.ERR_MASKTOOWIDE,
        524 : Type.ERR_QUARANTINED,
        568 : Type.ERR_LASTERROR,
    ];

    /++
     +  Delta typenum mappings for servers running the `aircd` (?) daemon.
     +
     +  "After AnotherNet had become a commercial and proprietary-client chat
     +  network, the former users of AnotherNet's #trax decided to found their
     +  own network - "where free speech and ideas would be able to run
     +  unbounded through the pastures of #trax and #coders". They use the
     +  "`aircd`" IRC daemon, coded by an ex-member of the demoscene, simon
     +  kirby."
     +/
    static immutable Type[471] aircd =
    [
        210 : Type.RPL_STATS,
        274 : Type.RPL_ENDNOTIFY,
        285 : Type.RPL_CHANINFO_HANDLE,
        286 : Type.RPL_CHANINFO_USERS,
        287 : Type.RPL_CHANINFO_CHOPS,
        288 : Type.RPL_CHANINFO_VOICES,
        289 : Type.RPL_CHANINFO_AWAY,
        290 : Type.RPL_CHANINFO_OPERS,
        291 : Type.RPL_CHANINFO_BANNED,
        292 : Type.RPL_CHANINFO_BANS,
        293 : Type.RPL_CHANINFO_INVITE,
        294 : Type.RPL_CHANINFO_INVITES,
        295 : Type.RPL_CHANINFO_KICKS,
        308 : Type.RPL_NOTIFYACTION,
        309 : Type.RPL_NICKTRACE,
        377 : Type.RPL_KICKEXPIRED,
        378 : Type.RPL_BANEXPIRED,
        379 : Type.RPL_KICKLINKED,
        380 : Type.RPL_BANLINKED,
        470 : Type.ERR_KICKEDFROMCHAN,
    ];

    /++
     +  Delta typenum mappings for servers adhering to the `RFC1459` draft.
     +
     +  https://tools.ietf.org/html/rfc1459
     +/
    static immutable Type[502] rfc1459 =
    [
        214 : Type.RPL_STATSNLINE,
        217 : Type.RPL_STATSQLINE,
        232 : Type.RPL_ENDOFSERVICES,
        316 : Type.RPL_WHOISCHANOP, // deprecated
        391 : Type.RPL_TIME,
        492 : Type.ERR_NOSERVICEHOST,
        501 : Type.ERR_UMODEUNKNOWNFLAG,
    ];

    /++
     +  Delta typenum mappings for servers adhering to the `RFC2812` draft.
     +
     +  https://tools.ietf.org/html/rfc2812
     +/
    static immutable Type[485] rfc2812 =
    [
        240 : Type.RPL_STATSVLINE,
        246 : Type.RPL_STATSPING,
        247 : Type.RPL_STATSBLINE,
        250 : Type.RPL_STATSDLINE,
        262 : Type.RPL_TRACEEND,
        325 : Type.RPL_UNIQOPIS,
        437 : Type.ERR_UNAVAILRESOURCE,
        477 : Type.ERR_NOCHANMODES,
        484 : Type.ERR_RESTRICTED,
    ];

    /++
     +  Delta typenum mappings for servers running the `IRCD-Hybrid` daemon.
     +
     +  http://www.ircd-hybrid.org
     +/
    static immutable Type[716] hybrid =
    [
        220 : Type.RPL_STATSPLINE,
        224 : Type.RPL_STATSFLINE,
        225 : Type.RPL_STATSDLINE,
        226 : Type.RPL_STATSALINE,
        245 : Type.RPL_STATSSLINE,      // CONFLICT: Type.RPL_STATSTLINE
        246 : Type.RPL_STATSSERVICE,    // CONFLICT: Type.RPL_STATSULINE
        247 : Type.RPL_STATSXLINE,
        249 : Type.RPL_STATSDEBUG,
        276 : Type.RPL_WHOISCERTFP,     // oftc-hybrid?
        335 : Type.RPL_WHOISTEXT,
        336 : Type.RPL_INVITELIST,
        337 : Type.RPL_ENDOFINVITELIST, // CONFLICT: Type.RPL_WHOISTEXT
        344 : Type.RPL_QUIETLIST,       // oftc
        345 : Type.RPL_ENDOFQUIETLIST,  // CONFLICT: Type.RPL_INVITED, oftc
        386 : Type.RPL_RSACHALLENGE,
        396 : Type.RPL_VISIBLEHOST,
        408 : Type.ERR_NOCTRLSONCHAN,
        479 : Type.ERR_BADCHANNAME,
        480 : Type.ERR_SSLONLYCHAN,     // deprecated
        484 : Type.ERR_DESYNC,
        485 : Type.ERR_CHANBANREASON,
        492 : Type.ERR_NOCTCP,
        503 : Type.ERR_GHOSTEDCLIENT,
        524 : Type.ERR_HELPNOTFOUND,
        715 : Type.ERR_TOOMANYINVITE,
    ];

    /++
     +  Delta typenum mappings for servers running the `Bahamut` daemon
     +  (DALnet).
     +
     +  https://www.dal.net/?page=bahamut
     +/
    static immutable Type[621] bahamut =
    [
        220 : Type.RPL_STATSBLINE,
        222 : Type.RPL_STATSBLINE,
        223 : Type.RPL_STATSELINE,
        224 : Type.RPL_STATSFLINE,
        225 : Type.RPL_STATSCLONE,      // DEPRECATED CONFLICT: Type.RPL_STATSZLINE
        226 : Type.RPL_STATSCOUNT,
        227 : Type.RPL_STATSGLINE,
        245 : Type.RPL_STATSSLINE,
        275 : Type.RPL_USINGSSL,
        307 : Type.RPL_WHOISREGNICK,
        308 : Type.RPL_WHOISADMIN,
        309 : Type.RPL_WHOISADMIN,      // duplicate?
        310 : Type.RPL_WHOISSVCMSG,
        334 : Type.RPL_COMMANDSYNTAX,
        338 : Type.RPL_WHOISACTUALLY,
        408 : Type.ERR_NOCOLORSONCHAN,
        435 : Type.ERR_BANONCHAN,
        468 : Type.ERR_ONLYSERVERSCANCHANGE,
        477 : Type.ERR_NEEDREGGEDNICK,
        484 : Type.ERR_DESYNC,
        487 : Type.ERR_MSGSERVICES,
        488 : Type.ERR_NOSSL,
        493 : Type.ERR_NOSHAREDCHAN,
        494 : Type.ERR_OWNMODE,
        512 : Type.ERR_TOOMANYWATCH,
        514 : Type.ERR_TOOMANYDCC,
        521 : Type.ERR_LISTSYNTAX,
        617 : Type.RPL_DCCSTATUS,
        619 : Type.RPL_ENDOFDCCLIST,
        620 : Type.RPL_DCCINFO,
    ];

    /++
     +  Delta typenum mappings for servers running the `snircd` daemon
     +  (QuakeNet), based on `ircu`.
     +
     +  https://development.quakenet.org
     +/
    static immutable Type[554] snircd =
    [
        285 : Type.RPL_NEWHOSTIS,
        286 : Type.RPL_CHKHEAD,
        287 : Type.RPL_CHANUSER,
        288 : Type.RPL_PATCHHEAD,
        289 : Type.RPL_PATCHCON,
        290 : Type.RPL_DATASTR,
        291 : Type.RPL_ENDOFCHECK,
        485 : Type.ERR_ISREALSERVICE,
        486 : Type.ERR_ACCOUNTONLY,
        553 : Type.ERR_STATSSLINE,
    ];

    /++
     +  Delta typenum mappings for servers running the `Nefarious` or
     +  `Nefarious2` daemons, based on `ircu`.
     +
     +  https://github.com/evilnet/nefarious
     +  https://github.com/evilnet/nefarious2
     +/
    static immutable Type[976] nefarious =
    [
        220 : Type.RPL_STATSWLINE,
        292 : Type.ERR_SEARCHNOMATCH,
        316 : Type.RPL_WHOISPRIVDEAF,
        320 : Type.RPL_WHOISWEBIRC,
        335 : Type.RPL_WHOISACCOUNTONLY,
        336 : Type.RPL_WHOISBOT,
        339 : Type.RPL_WHOISMARKS,
        386 : Type.RPL_IRCOPSHEADER,
        387 : Type.RPL_IRCOPS,
        388 : Type.RPL_ENDOFIRCOPS,
        521 : Type.ERR_NOSUCHGLINE,
        568 : Type.RPL_NOMOTD,
        617 : Type.RPL_WHOISSSLFP,
        975 : Type.ERR_LASTERROR,
    ];

    /++
     +  Delta typenum mappings for `RusNet` servers. Unsure of what daemon they
     +  run.
     +
     +  http://www.rus-net.org
     +/
    static immutable Type[501] rusnet =
    [
        222 : Type.RPL_CODEPAGE,
        223 : Type.RPL_CHARSET,
        327 : Type.RPL_WHOISHOST,
        468 : Type.ERR_NOCODEPAGE,
        470 : Type.ERR_7BIT,
        479 : Type.ERR_NOCOLOR,
        480 : Type.ERR_NOWALLOP,
        486 : Type.ERR_RLINED,
        500 : Type.ERR_NOREHASHPARAM,
    ];

    /++
     +  Delta typenum mappings for `Rizon` network servers. Supposedly they use
     +  a mixture of Hybrid typenums, plus a few of their own.
     +
     +  https://www.rizon.net
     +/
    static immutable Type[716] rizon =
    [
        227 : Type.RPL_STATSBLINE,
        672 : Type.RPL_WHOISREALIP,
        715 : Type.RPL_INVITETHROTTLE,
    ];

    /++
     +  Delta typenum mappings for `austHex` AUSTNet Development servers.
     +
     +  https://sourceforge.net/projects/austhex
     +/
    static immutable Type[521] austHex =
    [
        240 : Type.RPL_STATSXLINE,
        307 : Type.RPL_SUSERHOST,
        309 : Type.RPL_WHOISHELPER,
        310 : Type.RPL_WHOISSERVICE,
        320 : Type.RPL_WHOISVIRT,
        357 : Type.RPL_MAP,
        358 : Type.RPL_MAPMORE,
        359 : Type.RPL_MAPEND,
        377 : Type.RPL_SPAM,            // deprecated
        378 : Type.RPL_MOTD,
        380 : Type.RPL_YOURHELPER,
        434 : Type.ERR_SERVICENAMEINUSE,
        480 : Type.ERR_NOULINE,
        503 : Type.ERR_VWORLDWARN,
        520 : Type.ERR_WHOTRUNC,        // deprecated
    ];

    /++
     +  Delta typenum mappings for the `IRCnet` network of servers. Unsure of
     +  what server daemon they run.
     +
     +  http://www.ircnet.org
     +/
    static immutable Type[489] ircNet =
    [
        245 : Type.RPL_STATSSLINE,
        248 : Type.RPL_STATSDEFINE,
        274 : Type.RPL_STATSDELTA,
        438 : Type.ERR_DEAD,
        487 : Type.ERR_CHANTOORECENT,
        488 : Type.ERR_TSLESSCHAN,
    ];

    /++
     +  Delta typenum mappings for servers running the `PTlink` daemon.
     +
     +  https://sourceforge.net/projects/ptlinksoft
     +/
    static immutable Type[616] ptlink =
    [
        247 : Type.RPL_STATSXLINE,
        484 : Type.ERR_DESYNC,
        485 : Type.ERR_CANTKICKADMIN,
        615 : Type.RPL_MAPMORE,
    ];

    /++
     +  Delta typenum mappings for servers running the `InspIRCd` daemon.
     +
     +  http://www.inspircd.org
     +/
    static immutable Type[976] inspIRCd =
    [
        270 : Type.RPL_MAPUSERS,
        304 : Type.RPL_SYNTAX,
        379 : Type.RPL_WHOWASIP,
        495 : Type.ERR_DELAYREJOIN,
        501 : Type.ERR_UNKNOWNSNOMASK,
        702 : Type.RPL_COMMANDS,
        703 : Type.RPL_COMMANDSEND,
        953 : Type.ENDOFEXEMPTOPSLIST,
        972 : Type.ERR_CANTUNLOADMODULE,
        974 : Type.ERR_CANTLOADMODULE,
        975 : Type.RPL_LOADEDMODULE
    ];

    /++
     +  Delta typenum mapping for servers running the `ultimate` daemon.
     +  Based off of `Bahamut`.
     +/
    static immutable Type[624] ultimate =
    [
        275 : Type.RPL_USINGSSL,
        386 : Type.RPL_IRCOPS,
        387 : Type.RPL_ENDOFIRCOPS,
        434 : Type.ERR_NORULES,
        610 : Type.RPL_ISOPER,
        615 : Type.RPL_WHOISMODES,
        616 : Type.RPL_WHOISHOST,
        617 : Type.RPL_WHOISBOT,
        619 : Type.RPL_WHOWASHOST,
        620 : Type.RPL_RULESSTART,
        621 : Type.RPL_RULES,
        622 : Type.RPL_ENDOFRULES,
        623 : Type.RPL_MAPMORE,
    ];

    /++
     +  Delta typenum mappings extending `ircu` typenums, for UnderNet.
     +
     +  https://github.com/UndernetIRC/ircu2
     +/
    static immutable Type[490] undernet =
    [
        396 : Type.RPL_HOSTHIDDEN,
        484 : Type.ERR_ISCHANSERVICE,
        489 : Type.ERR_VOICENEEDED,
    ];

    /++
     +  Delta typenum mapping for servers running the `ratbox` daemon. It is
     +  primarily used on EFnet.
     +
     +  https://www.ratbox.org
     +/
    static immutable Type[716] ratBox =
    [
        480 : Type.ERR_THROTTLE,
        485 : Type.ERR_BANNEDNICK,      // deprecated
        702 : Type.RPL_MODLIST,
        703 : Type.RPL_ENDOFMODLIST,
        715 : Type.ERR_KNOCKDISABLED,
    ];

    /++
     +  Delta typenum mappings for servers running the `charybdis` daemon.
     +
     +  https://github.com/charybdis-ircd/charybdis
     +/
    static immutable Type[495] charybdis =
    [
        492 : Type.ERR_CANNOTSENDTOUSER,
        494 : Type.ERR_OWNMODE,
    ];

    /++
     +  Delta typenum mappings for servers running the `sorircd` daemon
     +  (SorceryNet).
     +
     +  http://www.nongnu.org/snservices/sorircd.html
     +/
    static immutable Type[326] sorircd =
    [
        325 : Type.RPL_CHANNELMLOCKIS,  // deprecated
    ];

    /*
    static immutable Type[321] anothernet =
    [
        320 : Type.RPL_WHOIS_HIDDEN,
    ];

    static immutable Type[392] bdqIRCd =
    [
        391 : Type.RPL_TIME,
    ];

    static immutable Type[488] chatIRCd =
    [
        487 : Type.ERR_NONONSSL,
    ];

    static immutable Type[515] irch =
    [
        514 : Type.ERR_NOSUCHJUPE,
    ];

    static immutable Type[672] ithildin =
    [
        672 : Type.RPL_UNKNOWNMODES,
    ];
    */
}


// IRCChannel
/++
 +  Aggregate personifying an IRC channel and its state.
 +
 +  An IRC channel may have a topic, a creation date, and one or more *modes*.
 +  Modes define how the channel behaves and how it treats its users, including
 +  which ones have operator and voice status, as well as which are banned, and
 +  more.
 +/
struct IRCChannel
{
    /++
     +  A channel mode.
     +
     +  Some modes overwrite themselves; a channel may be `+i` or `-i`, never
     +  `i` twice. Others stack; a channel may have an arbitrary number of `b`
     +  bans. We try our best to support both.
     +/
    struct Mode
    {
        /// The character that implies this `Mode` (`i`, `z`, `l` ...).
        char modechar;

        /++
         +  The data associated with the `Mode`, if applicable. This is often a
         +  number, such as what `l` takes (join limit).
         +/
        string data;

        /// The user associated with the `Mode`, when it is not just `data`.
        IRCUser user;

        /// Users that are explicitly exempt from the `Mode`.
        IRCUser[] exemptions;

        /// Whether this `Mode` should be considered to be its own antithesis.
        bool negated;

        /++
         +  Compare two `Mode`s with eachother to see if they are both of the
         +  same type, as well as having the same `data` and/or `user`.
         +/
        bool opEquals(const Mode other) pure nothrow @nogc @safe const
        {
            // Ignore exemptions when comparing Modes
            immutable charMatch = (modechar == other.modechar);
            immutable dataMatch = (data == other.data);
            immutable userMatch = user.matchesByMask(other.user);

            immutable match = (charMatch && dataMatch && userMatch);
            return negated ? !match : match;
        }

        void toString(scope void delegate(const(char)[]) @safe sink) const
        {
            import std.format : formattedWrite;
            sink.formattedWrite("+%c (%s@%s) <%s>", modechar, data, user,
                exemptions);
        }

        string toString() const
        {
            import std.format : format;
            return "+%c (%s@%s) <%s>".format(modechar, data, user, exemptions);
        }
    }

    /// The current topic of the channel, as set by operators.
    string topic;

    /// The current non-`data`-sporting `Mode`s of the channel.
    char[] modechars;

    /// Array of all `Mode`s that are not simply represented in `modechars`.
    Mode[] modes;

    /++
     +  Array of all the nicknames inhabiting the channel. These are not
     +  `IRCUser`s; those are kept in the `users` associative array of
     +  `kameloso.plugins.common.IRCPluginState.users`. These are merely keys to
     +  that array.
     +/
    string[] users;

    /++
     +  Associative array of nicknames with a prefixing channel mode (operator,
     +  halfops, voiced, ...) keyed by modechar.
     +/
    string[][char] mods;

    /// Template to deduplicate code for mods shorthands.
    ref string[] modsShorthand(char prefix)()
    {
        auto modsOp = prefix in mods;

        if (!modsOp)
        {
            mods[prefix] = [];
            modsOp = prefix in mods;
        }

        return *modsOp;
    }

    /// Array of channel operators.
    alias ops = modsShorthand!'o';

    /// Array of channel halfops.
    alias halfops = modsShorthand!'h';

    /// Array of voiced channel users.
    alias voiced = modsShorthand!'v';

    /// When the channel was created, expresed in UNIX time.
    long created;

    void toString(scope void delegate(const(char)[]) @safe sink) const
    {
        import std.format : formattedWrite;

        sink.formattedWrite("TOPIC:%s\nnUSERS:%d\nMODES(%s):%s",
            topic, users.length, modechars, modes);

        foreach (immutable prefix, list; mods)
        {
            sink.formattedWrite("\n+%s: %s", prefix, list);
        }
    }
}
